# cython: embedsignature=True

#
# Note about API documentation:
#
# The API reference for all classes and methods is maintained in
# a separate file: doc/api.rst. The Sphinx 'autodoc' feature does not
# work too well for this project (requires module compilation, chokes on
# syntax differences, does not work with documentation hosting sites).
# Make sure the API reference and the actual code are kept in sync!
#

"""
Plyvel, a Python LevelDB interface.

Use plyvel.DB() to create or open a database.
"""

import sys
import threading
import weakref

cimport cython

from libc.stdint cimport uint64_t
from libc.stdlib cimport malloc, free
from libcpp.string cimport string
from libcpp cimport bool

cimport leveldb
from leveldb cimport (
    BytewiseComparator,
    Cache,
    Comparator,
    DestroyDB,
    NewBloomFilterPolicy,
    NewLRUCache,
    Options,
    Range,
    ReadOptions,
    RepairDB,
    Slice,
    Status,
    WriteOptions,
)

from comparator cimport NewPlyvelCallbackComparator


__leveldb_version__ = '%d.%d' % (leveldb.kMajorVersion,
                                 leveldb.kMinorVersion)


#
# Errors and error handling
#

class Error(Exception):
    pass


class IOError(Error, IOError):
    pass


class CorruptionError(Error):
    pass


cdef int raise_for_status(Status st) except -1:
    if st.ok():
        return 0

    if st.IsIOError():
        raise IOError(st.ToString())

    if st.IsCorruption():
        raise CorruptionError(st.ToString())

    # Generic fallback
    raise Error(st.ToString())


#
# Utilities
#

cdef inline db_get(DB db, bytes key, object default, ReadOptions read_options):
    cdef string value
    cdef Status st
    cdef Slice key_slice = Slice(key, len(key))

    with nogil:
        st = db._db.Get(read_options, key_slice, &value)

    if st.IsNotFound():
        return default
    raise_for_status(st)

    return value


cdef bytes to_file_system_name(name):
    if isinstance(name, bytes):
        return name

    if not isinstance(name, unicode):
        raise TypeError(
            "'name' arg must be a byte string or a unicode string")

    encoding = sys.getfilesystemencoding() or 'ascii'
    try:
        return name.encode(encoding)
    except UnicodeEncodeError as exc:
        raise ValueError(
            "Cannot convert unicode 'name' to a file system name: %s" % exc)


cdef bytes bytes_increment(bytes s):
    # Increment the last byte that is not 0xff, and returned a new byte
    # string truncated after the position that was incremented. We use
    # a temporary bytearray to construct a new byte string, since that
    # works the same in Python 2 and Python 3.

    b = bytearray(s)
    cdef int i = len(s) - 1
    while i >= 0:
        if b[i] == 0xff:
            i = i - 1
            continue

        # Found byte smaller than 0xff: increment and truncate
        b[i] += 1
        return bytes(b[:i + 1])

    # Input contained only 0xff bytes
    return None


cdef int parse_options(Options *options, bool create_if_missing,
                       bool error_if_exists, object paranoid_checks,
                       object write_buffer_size, object max_open_files,
                       object lru_cache_size, object block_size,
                       object block_restart_interval, object compression,
                       int bloom_filter_bits, object comparator,
                       bytes comparator_name) except -1:
    cdef int c_lru_cache_size

    options.create_if_missing = create_if_missing
    options.error_if_exists = error_if_exists

    if paranoid_checks is not None:
        options.paranoid_checks = paranoid_checks

    if write_buffer_size is not None:
        options.write_buffer_size = write_buffer_size

    if max_open_files is not None:
        options.max_open_files = max_open_files

    if lru_cache_size is not None:
        c_lru_cache_size = lru_cache_size
        with nogil:
            options.block_cache = NewLRUCache(c_lru_cache_size)

    if block_size is not None:
        options.block_size = block_size

    if block_restart_interval is not None:
        options.block_restart_interval = block_restart_interval

    if compression is None:
        options.compression = leveldb.kNoCompression
    else:
        if isinstance(compression, bytes):
            compression = compression.decode('UTF-8')
        if not isinstance(compression, unicode):
            raise TypeError("'compression' must be None or a string")
        if compression == u'snappy':
            options.compression = leveldb.kSnappyCompression
        else:
            raise ValueError("'compression' must be None or 'snappy'")

    if bloom_filter_bits > 0:
        with nogil:
            options.filter_policy = NewBloomFilterPolicy(bloom_filter_bits)

    if (comparator is None) != (comparator_name is None):
        raise ValueError(
            "'comparator' and 'comparator_name' must be specified together")

    if comparator is not None:
        if not callable(comparator):
            raise TypeError("custom comparator object must be callable")

        options.comparator = NewPlyvelCallbackComparator(
            comparator_name, comparator)


#
# Database
#

@cython.final
cdef class DB:
    cdef leveldb.DB* _db
    cdef Options options
    cdef object lock
    cdef object iterators

    def __init__(self, name, *, bool create_if_missing=False,
                 bool error_if_exists=False, paranoid_checks=None,
                 write_buffer_size=None, max_open_files=None,
                 lru_cache_size=None, block_size=None,
                 block_restart_interval=None, compression='snappy',
                 int bloom_filter_bits=0, object comparator=None,
                 bytes comparator_name=None):
        cdef Status st
        cdef string fsname

        fsname = to_file_system_name(name)
        parse_options(
            &self.options, create_if_missing, error_if_exists, paranoid_checks,
            write_buffer_size, max_open_files, lru_cache_size, block_size,
            block_restart_interval, compression, bloom_filter_bits, comparator,
            comparator_name)
        with nogil:
            st = leveldb.DB_Open(self.options, fsname, &self._db)
        raise_for_status(st)

        # Keep weak references to open iterators, since deleting a C++
        # DB instance results in a segfault if associated Iterator
        # instances are not deleted beforehand (as mentioned in
        # leveldb/db.h). We don't use weakref.WeakSet here because it's
        # only available since Python 2.7. Instead we'll just use the
        # object's id() as the key.
        self.lock = threading.Lock()
        self.iterators = weakref.WeakValueDictionary()

    cpdef close(self):
        # If the constructor raised an exception (and hence never
        # completed), self.iterators can be None. In that case no
        # iterators need to be cleaned, since the database has never
        # produced any used.
        cdef Iterator iterator
        if self.iterators is not None:
            with self.lock:
                try:
                    itervalues = self.iterators.itervalues  # Python 2
                except AttributeError:
                    itervalues = self.iterators.values  # Python 3

                for iterator in itervalues():
                    iterator.close()

                self.iterators.clear()

        if self._db is not NULL:
            del self._db
            self._db = NULL

        if self.options.block_cache is not NULL:
            del self.options.block_cache
            self.options.block_cache = NULL

        if self.options.filter_policy is not NULL:
            del self.options.filter_policy
            self.options.filter_policy = NULL

        if self.options.comparator is not NULL:
            # The built-in BytewiseComparator must not be deleted
            if self.options.comparator is not BytewiseComparator():
                del self.options.comparator
                self.options.comparator = NULL

    property closed:
        def __get__(self):
            return self._db is NULL

    def __dealloc__(self):
        self.close()

    def get(self, bytes key, default=None, *, verify_checksums=None,
            fill_cache=None):
        if self._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        cdef ReadOptions read_options

        if verify_checksums is not None:
            read_options.verify_checksums = verify_checksums
        if fill_cache is not None:
            read_options.fill_cache = fill_cache

        return db_get(self, key, default, read_options)

    def put(self, bytes key, bytes value, *, sync=None):
        if self._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        cdef WriteOptions write_options = WriteOptions()
        cdef Slice key_slice = Slice(key, len(key))
        cdef Slice value_slice = Slice(value, len(value))
        cdef Status st

        if sync is not None:
            write_options.sync = sync

        with nogil:
            st = self._db.Put(write_options, key_slice, value_slice)
        raise_for_status(st)

    def delete(self, bytes key, *, sync=None):
        if self._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        cdef Status st
        cdef WriteOptions write_options = WriteOptions()

        if sync is not None:
            write_options.sync = sync

        cdef Slice key_slice = Slice(key, len(key))
        with nogil:
            st = self._db.Delete(write_options, key_slice)
        raise_for_status(st)

    def write_batch(self, *, transaction=False, sync=None):
        if self._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        return WriteBatch(db=self, transaction=transaction, sync=sync)

    def __iter__(self):
        if self._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        return self.iterator()

    def iterator(self, *, reverse=False, start=None, stop=None,
                 include_start=True, include_stop=False, prefix=None,
                 include_key=True, include_value=True, verify_checksums=None,
                 fill_cache=None):
        return Iterator(
            db=self, key_prefix=None, reverse=reverse, start=start, stop=stop,
            include_start=include_start, include_stop=include_stop,
            prefix=prefix, include_key=include_key,
            include_value=include_value, verify_checksums=verify_checksums,
            fill_cache=fill_cache, snapshot=None)

    cdef _register_iterator(self, Iterator iterator):
        # Store a weak reference to an iterator (needed when closing DB)
        self.iterators[id(iterator)] = iterator

    def snapshot(self):
        return Snapshot(db=self)

    def get_property(self, bytes name not None):
        if self._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        cdef Slice sl = Slice(name, len(name))
        cdef string value
        cdef bool result

        with nogil:
            result = self._db.GetProperty(sl, &value)

        return value if result else None

    def compact_range(self, *, bytes start=None, bytes stop=None):
        if self._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        cdef Slice start_slice
        cdef Slice stop_slice

        if start is not None:
            start_slice = Slice(start, len(start))

        if stop is not None:
            stop_slice = Slice(stop, len(stop))

        with nogil:
            self._db.CompactRange(&start_slice, &stop_slice)

    def approximate_size(self, bytes start not None, bytes stop not None):
        if self._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        return self.approximate_sizes((start, stop))[0]

    def approximate_sizes(self, *ranges):
        if self._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        cdef int n_ranges = len(ranges)
        cdef Range *c_ranges = <Range *>malloc(n_ranges * sizeof(Range))
        cdef uint64_t *sizes = <uint64_t *>malloc(n_ranges * sizeof(uint64_t))
        try:
            for i in xrange(n_ranges):
                start, stop = ranges[i]
                if not isinstance(start, bytes) or not isinstance(stop, bytes):
                    raise TypeError(
                        "Start and stop of range must be byte strings")
                c_ranges[i] = Range(
                    Slice(start, len(start)),
                    Slice(stop, len(stop)))

            with nogil:
                self._db.GetApproximateSizes(c_ranges, n_ranges, sizes)

            return [sizes[i] for i in xrange(n_ranges)]
        finally:
            free(c_ranges)
            free(sizes)

    def prefixed_db(self, bytes prefix not None):
        return PrefixedDB(db=self, prefix=prefix)


cdef class PrefixedDB:
    cdef readonly DB db
    cdef readonly bytes prefix

    def __init__(self, *, db, prefix):
        self.db = db
        self.prefix = prefix

    def get(self, bytes key, default=None, *, verify_checksums=None,
            fill_cache=None):
        return self.db.get(
            self.prefix + key,
            default=default,
            verify_checksums=verify_checksums,
            fill_cache=fill_cache)

    def put(self, bytes key, bytes value, *, sync=None):
        return self.db.put(self.prefix + key, value, sync=sync)

    def delete(self, bytes key, *, sync=None):
        return self.db.delete(self.prefix + key, sync=sync)

    def write_batch(self, *, transaction=False, sync=None):
        return WriteBatch(
            db=self.db, prefix=self.prefix, transaction=transaction, sync=sync)

    def __iter__(self):
        return self.iterator()

    def iterator(self, *, reverse=False, start=None, stop=None,
                 include_start=True, include_stop=False, prefix=None,
                 include_key=True, include_value=True, verify_checksums=None,
                 fill_cache=None):
        return Iterator(
            db=self.db, key_prefix=self.prefix, reverse=reverse, start=start,
            stop=stop, include_start=include_start, include_stop=include_stop,
            prefix=prefix, include_key=include_key,
            include_value=include_value, verify_checksums=verify_checksums,
            fill_cache=fill_cache, snapshot=None)

    def snapshot(self):
        return Snapshot(db=self.db, prefix=self.prefix)

    def prefixed_db(self, bytes prefix not None):
        return PrefixedDB(db=self.db, prefix=self.prefix + prefix)


def repair_db(name, *, paranoid_checks=None, write_buffer_size=None,
              max_open_files=None, lru_cache_size=None, block_size=None,
              block_restart_interval=None, compression='snappy',
              int bloom_filter_bits=0, comparator=None,
              bytes comparator_name=None):
    cdef Options options = Options()
    cdef Status st
    cdef string fsname

    fsname = to_file_system_name(name)
    create_if_missing = False
    error_if_exists = True
    parse_options(
        &options, create_if_missing, error_if_exists, paranoid_checks,
        write_buffer_size, max_open_files, lru_cache_size, block_size,
        block_restart_interval, compression, bloom_filter_bits, comparator,
        comparator_name)
    with nogil:
        st = RepairDB(fsname, options)
    raise_for_status(st)


def destroy_db(name):
    cdef Options options = Options()
    cdef Status st
    cdef string fsname

    fsname = to_file_system_name(name)
    with nogil:
        st = DestroyDB(fsname, options)
    raise_for_status(st)


#
# Write batch
#

@cython.final
cdef class WriteBatch:
    cdef leveldb.WriteBatch* _write_batch
    cdef WriteOptions write_options
    cdef DB db
    cdef bytes prefix
    cdef bool transaction

    def __init__(self, *, DB db not None, bytes prefix=None,
                 bool transaction=False, sync=None):
        self.db = db
        self.prefix = prefix
        self.transaction = transaction

        self.write_options = WriteOptions()
        if sync is not None:
            self.write_options.sync = sync

        self._write_batch = new leveldb.WriteBatch()

    def __dealloc__(self):
        del self._write_batch

    def put(self, bytes key, bytes value):
        if self.db._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        if self.prefix is not None:
            key = self.prefix + key

        cdef Slice key_slice = Slice(key, len(key))
        cdef Slice value_slice = Slice(value, len(value))
        with nogil:
            self._write_batch.Put(key_slice, value_slice)

    def delete(self, bytes key):
        if self.db._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        if self.prefix is not None:
            key = self.prefix + key

        cdef Slice key_slice = Slice(key, len(key))
        with nogil:
            self._write_batch.Delete(key_slice)

    def clear(self):
        if self.db._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        with nogil:
            self._write_batch.Clear()

    def write(self):
        if self.db._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        cdef Status st
        with nogil:
            st = self.db._db.Write(self.write_options, self._write_batch)
        raise_for_status(st)

    def __enter__(self):
        if self.db._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.db._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        if self.transaction and exc_type is not None:
            # Exception occurred in transaction; do not write the batch
            self.clear()
            return

        self.write()
        self.clear()


#
# Iterator
#

cdef enum IteratorState:
    BEFORE_START
    AFTER_STOP
    IN_BETWEEN
    IN_BETWEEN_ALREADY_POSITIONED


cdef enum IteratorDirection:
    FORWARD
    REVERSE


@cython.final
cdef class Iterator:
    cdef DB db
    cdef leveldb.Iterator* _iter
    cdef IteratorDirection direction
    cdef IteratorState state
    cdef Comparator* comparator
    cdef bytes start
    cdef bytes stop
    cdef Slice start_slice
    cdef Slice stop_slice
    cdef bool include_start
    cdef bool include_stop
    cdef bool include_key
    cdef bool include_value

    # This is the number of bytes that should be skipped over when
    # returning keys from .current(). This avoids Python byte string
    # copying/slicing overhead for PrefixedDB iterators.
    cdef int skip_key_bytes

    # Iterators need to be weak referencable to ensure a proper cleanup
    # from DB.close()
    cdef object __weakref__

    def __init__(self, *, DB db not None, key_prefix, bool reverse,
                 bytes start, bytes stop, bool include_start,
                 bool include_stop, bytes prefix, bool include_key,
                 bool include_value, bool verify_checksums, bool fill_cache,
                 Snapshot snapshot):
        if db._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        self.db = db
        self.comparator = <leveldb.Comparator*>db.options.comparator
        self.direction = FORWARD if not reverse else REVERSE

        if key_prefix is None:
            self.skip_key_bytes = 0
        else:
            # This is an iterator on a PrefixedDB. Transform args so
            # that the database key prefix is taken into account.
            self.skip_key_bytes = len(key_prefix)
            if prefix is not None:
                # Both database key prefix and prefix on the iterator
                prefix = key_prefix + prefix
            else:
                # Adapt start and stop keys to use the database key
                # prefix.
                if start is None:
                    start = key_prefix
                    include_start = True
                else:
                    start = key_prefix + start

                if stop is None:
                    stop = bytes_increment(key_prefix)
                    include_stop = False
                else:
                    stop = key_prefix + stop

        if prefix is not None:
            if start is not None or stop is not None:
                raise TypeError(
                    "'prefix' cannot be used together with 'start' or 'stop'")
            # Use prefix to construct start and stop keys, and ignore
            # include_start and include_stop args
            start = prefix
            stop = bytes_increment(prefix)
            include_start = True
            include_stop = False

        if start is not None:
            self.start = start
            self.start_slice = Slice(start, len(start))

        if stop is not None:
            self.stop = stop
            self.stop_slice = Slice(stop, len(stop))

        self.include_start = include_start
        self.include_stop = include_stop
        self.include_key = include_key
        self.include_value = include_value

        cdef ReadOptions read_options
        if verify_checksums is not None:
            read_options.verify_checksums = verify_checksums
        if fill_cache is not None:
            read_options.fill_cache = fill_cache
        if snapshot is not None:
            read_options.snapshot = snapshot._snapshot

        with nogil:
            self._iter = db._db.NewIterator(read_options)

        if self.direction == FORWARD:
            self.seek_to_start()
        else:
            self.seek_to_stop()

        db._register_iterator(self)
        raise_for_status(self._iter.status())

    cdef close(self):
        # Note: this method is only for internal cleanups and hence not
        # accessible from Python.
        if self._iter is NULL:
            # Already closed
            return

        del self._iter
        self._iter = NULL

    def __dealloc__(self):
        self.close()

    def __iter__(self):
        return self

    cdef object current(self):
        """Return the current iterator key/value.

        This is an internal helper function that is not exposed in the
        external Python API.
        """
        cdef Slice key_slice
        cdef bytes key
        cdef Slice value_slice
        cdef bytes value
        cdef object out

        # Only build Python strings that will be returned
        if self.include_key:
            key_slice = self._iter.key()
            key = key_slice.data()[self.skip_key_bytes:key_slice.size()]

        if self.include_value:
            value_slice = self._iter.value()
            value = value_slice.data()[:value_slice.size()]

        if self.include_key and self.include_value:
            return (key, value)
        if self.include_key:
            return key
        if self.include_value:
            return value
        return None

    def __next__(self):
        """Return the next iterator entry.

        Note: Cython will also create a .next() method that does the
        same as this method.
        """
        if self.direction == FORWARD:
            return self.real_next()
        else:
            return self.real_prev()

    def prev(self):
        if self.direction == FORWARD:
            return self.real_prev()
        else:
            return self.real_next()

    cdef real_next(self):
        if self._iter is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        if self.state == IN_BETWEEN:
            with nogil:
                self._iter.Next()
            if not self._iter.Valid():
                self.state = AFTER_STOP
                raise StopIteration
        elif self.state == IN_BETWEEN_ALREADY_POSITIONED:
            self.state = IN_BETWEEN
        elif self.state == BEFORE_START:
            if self.start is None:
                with nogil:
                    self._iter.SeekToFirst()
            else:
                with nogil:
                    self._iter.Seek(self.start_slice)
            if not self._iter.Valid():
                # Iterator is empty
                raise StopIteration
            if self.start is not None and not self.include_start:
                # Start key is excluded, so skip past it if the db
                # contains it.
                if self.comparator.Compare(self._iter.key(),
                                           self.start_slice) == 0:
                    with nogil:
                        self._iter.Next()
                    if not self._iter.Valid():
                        raise StopIteration
            self.state = IN_BETWEEN
        elif self.state == AFTER_STOP:
            raise StopIteration

        raise_for_status(self._iter.status())

        # Check range boundaries
        if self.stop is not None:
            n = 1 if self.include_stop else 0
            if self.comparator.Compare(self._iter.key(), self.stop_slice) >= n:
                self.state = AFTER_STOP
                raise StopIteration

        return self.current()

    cdef real_prev(self):
        if self._iter is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        if self.state == IN_BETWEEN:
            pass
        elif self.state == IN_BETWEEN_ALREADY_POSITIONED:
            assert self._iter.Valid()
            with nogil:
                self._iter.Prev()
            if not self._iter.Valid():
                # The .seek() resulted in the first key in the database
                self.state = BEFORE_START
                raise StopIteration
            raise_for_status(self._iter.status())
        elif self.state == BEFORE_START:
            raise StopIteration
        elif self.state == AFTER_STOP:
            if self.stop is None:
                # No stop key, seek to last entry
                with nogil:
                    self._iter.SeekToLast()
            else:
                # Seek to stop key
                with nogil:
                    self._iter.Seek(self.stop_slice)

                if self._iter.Valid():
                    # Move one step back if stop is exclusive.
                    if not self.include_stop:
                        with nogil:
                            self._iter.Prev()
                else:
                    # Stop key did not exist; position at the last
                    # database entry instead.
                    with nogil:
                        self._iter.SeekToLast()

                # Make sure the iterator is not past the stop key
                if self._iter.Valid() and self.comparator.Compare(self._iter.key(), self.stop_slice) > 0:
                    with nogil:
                        self._iter.Prev()

            if not self._iter.Valid():
                # No entries left
                raise StopIteration

            # After all the stepping back, we might even have ended up
            # *before* the start key. In this case the iterator does not
            # yield any items.
            if self.start is not None and self.comparator.Compare(self.start_slice, self._iter.key()) >= 0:
                raise StopIteration

            raise_for_status(self._iter.status())

        # Unlike .real_next(), first obtain the value, then move the
        # iterator pointer (not the other way around), so that
        # repeatedly calling it.prev() and next(it) will work as
        # designed.
        out = self.current()
        with nogil:
            self._iter.Prev()
        if not self._iter.Valid():
            # Moved before the first key in the database
            self.state = BEFORE_START
        else:
            if self.start is None:
                # Iterator is valid
                self.state = IN_BETWEEN
            else:
                # Check range boundaries
                n = 0 if self.include_start else 1
                if self.comparator.Compare(
                        self._iter.key(), self.start_slice) >= n:
                    # Iterator is valid and within range boundaries
                    self.state = IN_BETWEEN
                else:
                    # Iterator is valid, but has moved before the
                    # 'start' key
                    self.state = BEFORE_START

        raise_for_status(self._iter.status())
        return out

    def seek_to_start(self):
        if self._iter is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        self.state = BEFORE_START

    def seek_to_stop(self):
        if self._iter is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        self.state = AFTER_STOP

    def seek(self, bytes target not None):
        if self._iter is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        cdef Slice target_slice = Slice(target, len(target))

        # Seek only within the start/stop boundaries
        if self.start is not None and self.comparator.Compare(
                target_slice, self.start_slice) < 0:
            target_slice = self.start_slice
        if self.stop is not None and self.comparator.Compare(
                target_slice, self.stop_slice) > 0:
            target_slice = self.stop_slice

        with nogil:
            self._iter.Seek(target_slice)
        if not self._iter.Valid():
            # Moved past the end (or empty database)
            self.state = AFTER_STOP
            return

        self.state = IN_BETWEEN_ALREADY_POSITIONED
        raise_for_status(self._iter.status())


#
# Snapshot
#

@cython.final
cdef class Snapshot:
    cdef leveldb.Snapshot* _snapshot
    cdef DB db
    cdef bytes prefix

    def __init__(self, *, DB db not None, bytes prefix=None):
        if db._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        self.db = db
        self.prefix = prefix
        with nogil:
            self._snapshot = <leveldb.Snapshot*>db._db.GetSnapshot()

    def __dealloc__(self):
        with nogil:
            if self.db._db is not NULL and self._snapshot is not NULL:
                self.db._db.ReleaseSnapshot(self._snapshot)

    def get(self, bytes key, default=None, *, verify_checksums=None,
            fill_cache=None):
        if self.db._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        cdef ReadOptions read_options
        read_options.snapshot = self._snapshot
        if verify_checksums is not None:
            read_options.verify_checksums = verify_checksums
        if fill_cache is not None:
            read_options.fill_cache = fill_cache

        if self.prefix is not None:
            key = self.prefix + key

        return db_get(self.db, key, default, read_options)

    def __iter__(self):
        if self.db._db is NULL:
            raise RuntimeError("Cannot operate on closed LevelDB database")

        return self.iterator()

    def iterator(self, *, reverse=False, start=None, stop=None,
                 include_start=True, include_stop=False, prefix=None,
                 include_key=True, include_value=True, verify_checksums=None,
                 fill_cache=None):
        return Iterator(
            db=self.db, key_prefix=self.prefix, reverse=reverse, start=start,
            stop=stop, include_start=include_start, include_stop=include_stop,
            prefix=prefix, include_key=include_key,
            include_value=include_value, verify_checksums=verify_checksums,
            fill_cache=fill_cache, snapshot=self)
