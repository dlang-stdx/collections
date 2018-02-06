///
module stdx.collections.hashtable;

import stdx.collections.common;
import std.experimental.allocator : IAllocator, theAllocator, make, dispose;
import std.experimental.allocator.building_blocks.affix_allocator;
import std.experimental.allocator.gc_allocator;
//import stdx.collections.pair : Pair;
import stdx.collections.slist : SList;
import stdx.collections.array : Array;

debug(CollectionHashtable) import std.stdio;

version(unittest)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator.building_blocks.stats_collector;

    private alias Alloc = StatsCollector!(
                        AffixAllocator!(Mallocator, uint),
                        Options.bytesUsed
    );
    Alloc _allocator;
}

struct Hashtable(K, V)
{
    import std.traits : isImplicitlyConvertible, Unqual, isArray;
    import std.range.primitives : isInputRange, isForwardRange, isInfinite,
           ElementType, hasLength;
    import std.conv : emplace;
    import std.typecons : Tuple, Nullable;
    import core.atomic : atomicOp;

private:
    alias KVPair = Tuple!(K, "key", V, "value");
    Array!(SList!(KVPair)) _buckets;
    Array!size_t _numElems; // This needs to be ref counted
    static enum double loadFactor = 0.75;

    alias MutableAlloc = AffixAllocator!(IAllocator, size_t);
    Mutable!MutableAlloc _ouroborosAllocator;

    /// Returns the actual allocator from ouroboros
    @trusted ref auto allocator(this _)()
    {
        assert(!_ouroborosAllocator.isNull);
        return _ouroborosAllocator.get();
    }

public:
    /// Constructs the ouroboros allocator from allocator if the ouroboros
    //allocator wasn't previously set
    @trusted bool setAllocator(IAllocator allocator)
    {
        if (_ouroborosAllocator.isNull)
        {
            _ouroborosAllocator = Mutable!(MutableAlloc)(allocator,
                    MutableAlloc(allocator));
            _buckets = Array!(SList!(KVPair))(allocator);
            _numElems = Array!size_t(allocator);
            return true;
        }
        return false;
    }

    @trusted IAllocator getAllocator(this _)()
    {
        return _ouroborosAllocator.isNull ? null : allocator().parent;
    }

    this(this _)(IAllocator allocator)
    {
        debug(CollectionHashtable)
        {
            writefln("Array.ctor: begin");
            scope(exit) writefln("Array.ctor: end");
        }
        setAllocator(allocator);
    }

    this(U, this Qualified)(U assocArr)
    if (is(U == Value[Key], Value : V, Key : K))
    {
        this(theAllocator, assocArr);
    }

    this(U, this Qualified)(IAllocator allocator, U assocArr)
    if (is(U == Value[Key], Value : V, Key : K))
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.ctor: begin");
            scope(exit) writefln("Hashtable.ctor: end");
        }
        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            // Build a mutable hashtable on the stack and pass ownership to this
            auto tmp = Hashtable!(K, V)(allocator, assocArr);
            _buckets = cast(typeof(_buckets))(tmp._buckets);
            _numElems = cast(typeof(_numElems))(tmp._numElems);
            auto tmpAlloc = Mutable!(MutableAlloc)(allocator, MutableAlloc(allocator));
            _ouroborosAllocator = (() @trusted => cast(immutable)(tmpAlloc))();
        }
        else
        {
            setAllocator(allocator);
            insert(assocArr);
        }
    }

    size_t insert(U)(U assocArr)
    if (is(U == Value[Key], Value : V, Key : K))
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.insert: begin");
            scope(exit) writefln("Hashtable.insert: end");
        }

        setAllocator(theAllocator);
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
                _buckets[pos] = SList!(KVPair)(_buckets.getAllocator(), KVPair(k, v));
            }
            else
            {
                _buckets[pos].insert(0, KVPair(k, v));
            }
        }
        _numElems[0] += assocArr.length;
        return assocArr.length;
    }

    private size_t requiredCapacity(size_t numElems)
    {
        static enum size_t maxPow2 = cast(size_t)(1) << (size_t.sizeof * 8 - 1);
        while (numElems & (numElems - 1))
        {
            numElems &= (numElems - 1);
        }
        return numElems < maxPow2 ? 2 * numElems : maxPow2;
    }

    /// Returns number of key-value pairs
    size_t length() const
    {
        return _numElems.empty ? 0 : _numElems[0];
    }

    /// Returns number of buckets
    size_t size() const
    {
        return _buckets.length;
    }

    bool empty(this _)()
    {
        return _buckets.empty || _numElems.empty || _numElems[0] == 0;
    }

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

    void clear()
    {
        debug(CollectionHashtable)
        {
            writefln("Hashtable.clear: begin");
            scope(exit) writefln("Hashtable.clear: end");
        }
        _buckets = Array!(SList!(KVPair))(getAllocator());
        _numElems = Array!size_t(getAllocator());
    }

    void rehash();
}

@trusted unittest
{
    import std.algorithm.comparison : equal;

    auto h = Hashtable!(int, int)([1 : 10]);

    assert(*h._buckets.prefCount(h._buckets._support) == 0);
    assert(!h._buckets[0].empty && (*h._buckets[0].prefCount(h._buckets[0]._head) == 0));

    assert(equal(h.keys(), [1]));
    assert(equal(h.values(), [10]));
    assert(h.get(1, -1) == 10);
    assert(h.get(200, -1) == -1);
    assert(--h[1] == 9);
    assert(h.get(1, -1) == 9);

    assert(*h._buckets.prefCount(h._buckets._support) == 0);
    assert(!h._buckets[0].empty && (*h._buckets[0].prefCount(h._buckets[0]._head) == 0));
}

@trusted unittest
{
    import std.typecons : Tuple;

    auto h2 = Hashtable!(int, int)();
    assert(h2.length == 0);
    h2.insert([1 : 10]);
    assert(h2.length == 1);
    assert(h2._buckets[0].front == Tuple!(int, int)(1, 10));
    h2.clear();
    assert(h2.length == 0);
    assert(h2.empty);
}

@trusted unittest
{
    import std.algorithm.comparison : equal;
    import std.typecons : Tuple;

    auto h3 = immutable Hashtable!(int, int)([1 : 10]);
    assert(h3._buckets[0].front == Tuple!(int, int)(1, 10));
    assert(h3.get(1, -1) == 10);
    assert(equal(h3.values(), Array!int([10])));
    assert(equal(h3.keyValuePairs(), Array!(Tuple!(int, int))(Tuple!(int, int)(1, 10))));
}
