///
module stdx.collections.hashtable;

import stdx.collections.common;

debug(CollectionHashtable) import std.stdio;

version(unittest)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator.building_blocks.stats_collector;
    import std.experimental.allocator : allocatorObject,
           RCIAllocator, RCISharedAllocator;

    private alias SCAlloc = StatsCollector!(Mallocator, Options.bytesUsed);
}

///
struct Hashtable(K, V)
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator;
    import std.traits : isImplicitlyConvertible;
    import std.typecons : Tuple, Nullable;
    import std.algorithm.mutation : move;
    import stdx.collections.slist : SList;
    import stdx.collections.array : Array;

private:
    alias KVPair = Tuple!(K, "key", V, "value");
    Array!(SList!(KVPair)) _buckets;
    Array!size_t _numElems; // This needs to be ref counted
    static enum double loadFactor = 0.75;
    AllocatorHandler _allocator;

    // Allocators internals

    /// Constructs the ouroboros allocator from allocator if the ouroboros
    // allocator wasn't previously set
    /*@nogc*/ nothrow pure @safe
    bool setAllocator(A)(ref A allocator)
    if (is(A == RCIAllocator) || is(A == RCISharedAllocator))
    {
        if (_allocator.isNull)
        {
            auto a = typeof(_allocator)(allocator);
            move(a, _allocator);

            _buckets = Array!(SList!(KVPair))(allocator, SList!(KVPair)(allocator));
            //_buckets = Array!(SList!(KVPair))(allocator);
            _numElems = Array!size_t(allocator, 0UL);

            return true;
        }
        return false;
    }

public:
    /**
     * Constructs a qualified hashtable that will use the provided
     * allocator object. For `immutable` objects, a `RCISharedAllocator` must
     * be supplied.
     *
     * Params:
     *      allocator = a $(REF RCIAllocator, std,experimental,allocator) or
     *                  $(REF RCISharedAllocator, std,experimental,allocator)
     *                  allocator object
     *
     * Complexity: $(BIGOH 1)
     */
    this(A, this Q)(A allocator)
    if (!is(Q == shared)
        && (is(A == RCISharedAllocator) || !is(Q == immutable))
        && (is(A == RCIAllocator) || is(A == RCISharedAllocator)))
    {
        debug(CollectionHashtable)
        {
            writefln("Array.ctor: begin");
            scope(exit) writefln("Array.ctor: end");
        }
        static if (is(Q == immutable) || is(Q == const))
        {
            V[K] empty;
            this(allocator, empty);
        }
        else
        {
            setAllocator(allocator);
        }
    }

    ///
    @safe unittest
    {
        import std.experimental.allocator : theAllocator, processAllocator;

        auto h = Hashtable!(int, int)(theAllocator);
        auto ch = const Hashtable!(int, int)(processAllocator);
        auto ih = immutable Hashtable!(int, int)(processAllocator);
    }

    /**
     * Constructs a qualified hashtable out of an associative array.
     * Because no allocator was provided, the hashtable will use the
     * $(REF, GCAllocator, std,experimental,allocator,gc_allocator).
     *
     * Params:
     *      assocArr = an associative array
     *
     * Complexity: $(BIGOH m), where `m` is the number of (key, value) pairs
     *             in the associative array.
     */
    this(U, this Q)(U assocArr)
    if (is(U == Value[Key], Value : V, Key : K))
    {
        static if (is(Q == immutable) || is(Q == const))
        {
            this(processAllocatorObject(), assocArr);
        }
        else
        {
            this(threadAllocatorObject(), assocArr);
        }
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto h = Hashtable!(int, int)([1 : 10]);
        assert(equal(h.keys(), [1]));
        assert(equal(h.values(), [10]));
    }

    /**
     * Constructs a qualified hashtable out of an associative array
     * that will use the provided allocator object.
     * For `immutable` objects, a `RCISharedAllocator` must be supplied.
     *
     * Params:
     *      allocator = a $(REF RCIAllocator, std,experimental,allocator) or
     *                  $(REF RCISharedAllocator, std,experimental,allocator)
     *                  allocator object
     *      assocArr = an associative array
     *
     * Complexity: $(BIGOH m), where `m` is the number of (key, value) pairs
     *             in the associative array.
     */
    this(A, U, this Q)(A allocator, U assocArr)
    if (!is(Q == shared)
        && (is(A == RCISharedAllocator) || !is(Q == immutable))
        && (is(A == RCIAllocator) || is(A == RCISharedAllocator))
        && is(U == Value[Key], Value : V, Key : K))
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.ctor: begin");
            scope(exit) writefln("Hashtable.ctor: end");
        }
        static if (is(Q == immutable) || is(Q == const))
        {
            // Build a mutable hashtable on the stack and pass ownership to this

            // TODO: is this ok?
            auto tmp = Hashtable!(K, V)(assocArr);
            //_buckets = cast(typeof(_buckets))(tmp._buckets);
            _buckets = typeof(_buckets)(allocator, tmp._buckets);
            //_numElems = cast(typeof(_numElems))(tmp._numElems);
            _numElems = typeof(_numElems)(allocator, tmp._numElems);

            _allocator = immutable AllocatorHandler(allocator);
        }
        else
        {
            setAllocator(allocator);
            insert(assocArr);
        }
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;
        import stdx.collections.array : Array;

        {
            auto h = Hashtable!(int, int)([1 : 10]);
            assert(equal(h.keys(), [1]));
            assert(equal(h.values(), [10]));
        }

        {
            auto h = immutable Hashtable!(int, int)([1 : 10]);
            assert(equal(h.values(), Array!int([10])));
        }
    }

    /*nothrow*/ pure @safe unittest
    {
        auto h = Hashtable!(int, int)([1 : 42]);

        // Infer safety
        static assert(!__traits(compiles, () @safe { Hashtable!(Unsafe, int)([Unsafe(1) : 1]); }));
        static assert(!__traits(compiles, () @safe { auto s = const Hashtable!(Unsafe, int)([Unsafe(1) : 1]); }));
        static assert(!__traits(compiles, () @safe { auto s = immutable Hashtable!(Unsafe, int)([Unsafe(1) : 1]); }));

        static assert(!__traits(compiles, () @safe { Hashtable!(UnsafeDtor, int)([UnsafeDtor(1) : 1]); }));
        static assert(!__traits(compiles, () @safe { auto s = const Hashtable!(UnsafeDtor, int)([UnsafeDtor(1) : 1]); }));
        static assert(!__traits(compiles, () @safe { auto s = immutable Hashtable!(UnsafeDtor, int)([UnsafeDtor(1) : 1]); }));

        // Infer purity
        static assert(!__traits(compiles, () @safe { Hashtable!(Impure, int)([Impure(1) : 1]); }));
        static assert(!__traits(compiles, () @safe { auto s = const Hashtable!(Impure, int)([Impure(1) : 1]); }));
        static assert(!__traits(compiles, () @safe { auto s = immutable Hashtable!(Impure, int)([Impure(1) : 1]); }));

        static assert(!__traits(compiles, () @safe { Hashtable!(ImpureDtor, int)([ImpureDtor(1) : 1]); }));
        static assert(!__traits(compiles, () @safe { auto s = const Hashtable!(ImpureDtor, int)([ImpureDtor(1) : 1]); }));
        static assert(!__traits(compiles, () @safe { auto s = immutable Hashtable!(ImpureDtor, int)([ImpureDtor(1) : 1]); }));
    }

    /**
     * Insert the (key, value) pairs of an associative array into the
     * hashtable.
     *
     * If no allocator was provided when the list was created, the
     * $(REF, GCAllocator, std,experimental,allocator,gc_allocator) will be used.
     *
     * Params:
     *      assocArr = an associative array
     *
     * Complexity: $(BIGOH m), where `m` is the number of (key, value) pairs
     *             in the associative array.
     */
    size_t insert(U)(U assocArr)
    if (is(U == Value[Key], Value : V, Key : K))
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.insert: begin");
            scope(exit) writefln("Hashtable.insert: end");
        }

        // Will be optimized away, but the type system infers T's safety
        if (0) { K t = K.init; V v = V.init; }

        // Ensure we have an allocator. If it was already set, this will do nothing
        auto a = threadAllocatorObject();
        setAllocator(a);

        if (_buckets.empty)
        {
            auto reqCap = requiredCapacity(assocArr.length);
            _buckets.reserve(reqCap);
            _buckets.forceLength(reqCap);
            _numElems.reserve(1);
            _numElems.forceLength(1);
        }
        foreach(k, v; assocArr)
        {
            size_t pos = k.hashOf & (_buckets.length - 1);
            if (_buckets[pos].empty)
            {
                _buckets[pos] = SList!(KVPair)(_allocator.getLocalAlloc, KVPair(k, v));
            }
            else
            {
                _buckets[pos].insert(0, KVPair(k, v));
            }
        }
        _numElems[0] += assocArr.length;
        return assocArr.length;
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto h = Hashtable!(int, int)();
        assert(h.length == 0);
        h.insert([1 : 10]);
        assert(equal(h.keys(), [1]));
        assert(equal(h.values(), [10]));
    }

    private @nogc nothrow pure @safe
    size_t requiredCapacity(size_t numElems)
    {
        static enum size_t maxPow2 = cast(size_t)(1) << (size_t.sizeof * 8 - 1);
        while (numElems & (numElems - 1))
        {
            numElems &= (numElems - 1);
        }
        return numElems < maxPow2 ? 2 * numElems : maxPow2;
    }

    /**
     * Returns number of key-value pairs.
     *
     * Returns:
     *      a positive integer.
     *
     * Complexity: $(BIGOH 1).
     */
    @nogc nothrow pure @safe
    size_t length() const
    {
        return _numElems.empty ? 0 : _numElems[0];
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto h = Hashtable!(int, int)();
        assert(h.length == 0);
        h.insert([1 : 10]);
        assert(h.length == 1);
    }

    /**
     * Returns number of buckets.
     *
     * Returns:
     *      a positive integer.
     *
     * Complexity: $(BIGOH 1).
     */
    @nogc nothrow pure @safe
    size_t size() const
    {
        return _buckets.length;
    }

    /**
     * Check if the hashtable is empty.
     *
     * Returns:
     *      `true` if there are no elements in the hashtable; `false` otherwise.
     *
     * Complexity: $(BIGOH 1).
     */
    @nogc nothrow pure @safe
    bool empty() const
    {
        return _buckets.empty || _numElems.empty || _numElems[0] == 0;
    }

    /**
     * Provide access to the first value in the hashtable. The user must check
     * that the hashtable isn't `empty`, prior to calling this function.
     * There is no guarantee of the order of the values, as they are placed in
     * the hashtable based on the result of the hash function.
     *
     * Returns:
     *      a reference to the first found value.
     *
     * Complexity: $(BIGOH length).
     */
    ref auto front(this _)()
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.front: begin");
            scope(exit) writefln("Hashtable.front: end");
        }
        auto tmpBuckets = _buckets;
        while ((!tmpBuckets.empty) && tmpBuckets.front.empty)
        {
            tmpBuckets.popFront;
        }
        assert(!tmpBuckets.empty, "Hashtable.front: Hashtable is empty");
        return tmpBuckets.front.front;
    }

    void popFront()
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.popFront: begin");
            scope(exit) writefln("Hashtable.popFront: end");
        }
        if (!_buckets.isUnique)
        {
            _buckets = _buckets.dup();
            _numElems = _numElems.dup();
        }
        while ((!_buckets.empty) && _buckets.front.empty)
        {
            _buckets.popFront;
        }
        assert(!_buckets.empty, "Hashtable.front: Hashtable is empty");
        _buckets.front.popFront;
        --_numElems[0];
        // Find the next non-empty bucketList
        if (_buckets.front.empty)
        {
            while ((!_buckets.empty) && _buckets.front.empty)
            {
                _buckets.popFront;
            }
        }
    }

    private const
    void getKeyValues(string kv, BuckQual, ListQual, ArrQual)(BuckQual b, ListQual l, ref ArrQual values)
    {
        if (b.empty)
        {
            return;
        }
        else if (l.empty)
        {
            auto bTail = b.tail;
            if (!bTail.empty)
            {
                getKeyValues!kv(bTail, bTail.front, values);
            }
        }
        else
        {
            static if (kv.length)
            {
                mixin("values ~= l.front." ~ kv ~ ";");
            }
            else
            {
                mixin("values ~= l.front;");
            }
            getKeyValues!kv(b, l.tail, values);
        }
    }

    /**
     * Get an array with the existing keys in the hashtable.
     *
     * Returns:
     *      an `Array!K` array of keys
     *
     * Complexity: $(BIGOH size).
     */
    Array!K keys(this _)()
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.keys: begin");
            scope(exit) writefln("Hashtable.keys: end");
        }

        Array!K keys;
        auto tmp = _buckets;
        if (!_buckets.empty)
        //if (!tmp.empty)
        {
            //getKeyValues!("key")(tmp, tmp.front, keys);
            getKeyValues!("key")(_buckets, _buckets.front, keys);
        }
        return keys;
    }

    /**
     * Get an array with the existing values in the hashtable.
     *
     * Returns:
     *      an `Array!V` array of values
     *
     * Complexity: $(BIGOH length).
     */
    Array!V values(this _)()
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.values: begin");
            scope(exit) writefln("Hashtable.values: end");
        }

        Array!V values;
        if (!_buckets.empty)
        {
            getKeyValues!("value")(_buckets, _buckets.front, values);
        }

        return values;
    }

    /**
     * Get an array with the existing key-value pairs in the hashtable.
     *
     * Returns:
     *      an `Array!(Tuple!(K, "key", V, "value"))` array of key-value pairs
     *
     * Complexity: $(BIGOH length).
     */
    Array!(Tuple!(K, "key", V, "value")) keyValuePairs(this _)()
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.keyValuePairs: begin");
            scope(exit) writefln("Hashtable.keyValuePairs: end");
        }

        Array!KVPair pairs;
        if (!_buckets.empty)
        {
            getKeyValues!("")(_buckets, _buckets.front, pairs);
        }

        return pairs;
    }

    private const
    Nullable!V getValue(ListQual)(ListQual list, ref K key)
    {
        if (list.empty)
        {
            return Nullable!V.init;
        }
        else if (list.front.key == key)
        {
            return Nullable!V(list.front.value);
        }
        else
        {
            return getValue(list.tail, key);
        }
    }

    /**
     * Get the value corresponding to the given `key`; if it doesn't exist
     * return `nullValue`.
     *
     * Params:
     *      key = the key corresponding to a value
     *      nullValue = a value that will be returned if there is no such
     *                  key-value pair
     *
     * Returns:
     *      the corresponding key value, or `nullValue`.
     *
     * Complexity: $(BIGOH n), where n is the number of elements in the
     *             corresponding key bucket.
     */
    V get(this _)(K key, V nullValue)
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.get: begin");
            scope(exit) writefln("Hashtable.get: end");
        }

        size_t pos = key.hashOf & (_buckets.length - 1);
        auto result = getValue(_buckets[pos], key);
        if (!result.isNull)
        {
            return result.get;
        }
        return nullValue;
    }

    /**
     * Get a `Nullable!V` corresponding to the given `key` index.
     *
     * Params:
     *      key = the key corresponding to a value
     *
     * Returns:
     *      a nullable value
     *
     * Complexity: $(BIGOH n), where n is the number of elements in the
     *             corresponding key bucket.
     */
    Nullable!V opIndex(this _)(K key)
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.opIndex: begin");
            scope(exit) writefln("Hashtable.opIndex: end");
        }

        size_t pos = key.hashOf & (_buckets.length - 1);
        return getValue(_buckets[pos], key);
    }

    /**
     * Apply a unary operation to the value corresponding to `key`.
     * If there isn't such a value, return a `V.init` wrapped inside a
     * `Nullable`.
     *
     * Params:
     *      key = the key corresponding to a value
     *
     * Returns:
     *      a nullable value corresponding to the result or `V.init`.
     *
     * Complexity: $(BIGOH n), where n is the number of elements in the
     *             corresponding key bucket.
     */
    Nullable!V opIndexUnary(string op)(K key)
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.opIndexUnary!" ~ op ~ ": begin");
            scope(exit) writefln("Hashtable.opIndexUnary!" ~ op ~ ": end");
        }

        size_t pos = key.hashOf & (_buckets.length - 1);
        foreach(ref pair; _buckets[pos])
        {
            if (pair.key == key)
            {
                return Nullable!V(mixin(op ~ "pair.value"));
            }
        }
        return Nullable!V.init;
    }

    /**
     * Assign `val` to the element corresponding to `key`.
     * If there isn't such a value, return a `V.init` wrapped inside a
     * `Nullable`.
     *
     * Params:
     *      val = the value to be set
     *      key = the key corresponding to a value
     *
     * Returns:
     *      a nullable value corresponding to the result or `V.init`.
     *
     * Complexity: $(BIGOH n), where n is the number of elements in the
     *             corresponding key bucket.
     */
    Nullable!V opIndexAssign(U)(U val, K key)
    if (isImplicitlyConvertible!(U, V))
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.opIndexAssign: begin");
            scope(exit) writefln("Hashtable.opIndexAssign: end");
        }

        size_t pos = key.hashOf & (_buckets.length - 1);
        foreach(ref pair; _buckets[pos])
        {
            if (pair.key == key)
            {
                return Nullable!V(pair.value);
            }
        }
        return Nullable!V.init;
    }

    /**
     * Assign to the element corresponding to `key` the result of
     * applying `op` to the current value.
     * If there isn't such a value, return a `V.init` wrapped inside a
     * `Nullable`.
     *
     * Params:
     *      val = the value to be used with `op`
     *      key = the key corresponding to a value
     *
     * Returns:
     *      a nullable value corresponding to the result or `V.init`.
     *
     * Complexity: $(BIGOH n), where n is the number of elements in the
     *             corresponding key bucket.
     */
    Nullable!V opIndexOpAssign(string op, U)(U val, K key)
    if (isImplicitlyConvertible!(U, V))
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.opIndexOpAssign: begin");
            scope(exit) writefln("Hashtable.opIndexOpAssign: end");
        }

        size_t pos = key.hashOf & (_buckets.length - 1);
        foreach(ref pair; _buckets[pos])
        {
            if (pair.key == key)
            {
                return Nullable!V(mixin("pair.value" ~ op ~ "= val"));
            }
        }
        return Nullable!V.init;
    }

    auto ref opBinary(string op, U)(auto ref U rhs)
        if (op == "~" &&
            (is (U == typeof(this))
             || is (U : T)
             || (isInputRange!U && isImplicitlyConvertible!(ElementType!U, T))
            ));

    /**
     * Assign `rhs` to this hashtable. The current hashtable will now become
     * another reference to `rhs`, unless `rhs` is `null`, in which case the
     * current hashtable will become empty. If `rhs` refers to the current
     * hashtable nothing will happen.
     *
     * If there are no more references to the previous hashtable the previous
     * hashtable will be destroyed; this leads to a $(BIGOH length) complexity.
     *
     * Params:
     *      rhs = a reference to a hashtable
     *
     * Returns:
     *      a reference to this hashtable
     *
     * Complexity: $(BIGOH length).
     */
    auto ref opAssign()(auto ref typeof(this) rhs)
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.opAssign: begin");
            scope(exit) writefln("Hashtable.opAssign: end");
        }

        _buckets = rhs._buckets;
        _numElems = rhs._numElems;
        _ouroborosAllocator = rhs._ouroborosAllocator;
        return this;
    }

    void remove(K key);

    /**
     * Removes all the elements in the current hashtable.
     *
     * Complexity: $(BIGOH length).
     */
    void clear()
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.clear: begin");
            scope(exit) writefln("Hashtable.clear: end");
        }
        auto alloc = _allocator.getLocalAlloc;
        _buckets = Array!(SList!(KVPair))(alloc, SList!(KVPair)(alloc));
        _numElems = Array!size_t(alloc, 0UL);
    }

    void rehash();
}

version(unittest) private /*nothrow*/ pure @safe
void testSimple(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto h = Hashtable!(int, int)(allocator, [1 : 10]);

    assert(equal(h.keys(), [1]));
    assert(equal(h.values(), [10]));
    assert(h.get(1, -1) == 10);
    assert(h.get(200, -1) == -1);
    assert(--h[1] == 9);
    assert(h.get(1, -1) == 9);
}

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () /*nothrow pure*/ @safe {
            testSimple(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private /*nothrow*/ pure @safe
void testIndex(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;
    import std.typecons : Tuple;

    auto h = Hashtable!(int, int)();
    assert(h.length == 0);
    h.insert([1 : 10]);
    assert(h.length == 1);
    assert(h._buckets[0].front == Tuple!(int, int)(1, 10));
    h.clear();
    assert(h.length == 0);
    assert(h.empty);

    h.insert([1 : 10]);
    assert(equal(h.keys(), [1]));
}

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () /*nothrow pure*/ @safe {
            testIndex(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private /*nothrow*/ pure @safe
void testSimpleImmutable(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;
    import std.typecons : Tuple;
    import stdx.collections.array : Array;

    auto h = immutable Hashtable!(int, int)([1 : 10]);
    assert(h._buckets[0].front == Tuple!(int, int)(1, 10));
    assert(h.get(1, -1) == 10);
    assert(equal(h.values(), Array!int([10])));
    assert(equal(h.keyValuePairs(), Array!(Tuple!(int, int))(Tuple!(int, int)(1, 10))));
}

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () /*nothrow pure*/ @safe {
            testSimpleImmutable(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}
