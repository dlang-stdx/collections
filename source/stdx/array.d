module stdx.collection.array;

import stdx.collection.common;

debug(CollectionArray) import std.stdio;

version(unittest)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator.building_blocks.stats_collector;
    import std.experimental.allocator : IAllocator, allocatorObject;

    private alias SCAlloc = StatsCollector!(Mallocator, Options.bytesUsed);
}

struct Array(T)
{
    import std.experimental.allocator : IAllocator, theAllocator, make, dispose;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import std.traits : isImplicitlyConvertible, Unqual, isArray;
    import std.range.primitives : isInputRange, isInfinite,
           ElementType, hasLength;
    import std.conv : emplace;
    import core.atomic : atomicOp;

//private:
    T[] _payload;
    Unqual!T[] _support;

    static enum double capacityFactor = 3.0 / 2;
    static enum initCapacity = 3;

    alias MutableAlloc = AffixAllocator!(IAllocator, size_t);
    Mutable!MutableAlloc _ouroborosAllocator;

    /// Returns the actual allocator from ouroboros
    @trusted ref auto allocator(this _)()
    {
        assert(!_ouroborosAllocator.isNull);
        return _ouroborosAllocator.get();
    }

    /// Constructs the ouroboros allocator from allocator if the ouroboros
    //allocator wasn't previously set
    @trusted bool setAllocator(IAllocator allocator)
    {
        if (_ouroborosAllocator.isNull)
        {
            _ouroborosAllocator = Mutable!(MutableAlloc)(allocator,
                    MutableAlloc(allocator));
            return true;
        }
        return false;
    }

    @trusted IAllocator getAllocator(this _)()
    {
        return _ouroborosAllocator.isNull ? null : allocator().parent;
    }

    @trusted void addRef(SupportQual, this Qualified)(SupportQual support)
    {
        assert(support !is null);
        debug(CollectionArray)
        {
            writefln("Array.addRef: Array %s has refcount: %s; will be: %s",
                    support, *prefCount(support), *prefCount(support) + 1);
        }
        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            atomicOp!"+="(*prefCount(support), 1);
        }
        else
        {
            ++*prefCount(support);
        }
    }

    @trusted void delRef(Unqual!T[] support)
    {
        assert(support !is null);
        size_t *pref = prefCount(support);
        debug(CollectionArray) writefln("Array.delRef: Array %s has refcount: %s; will be: %s",
                support, *pref, *pref - 1);
        if (*pref == 0)
        {
            debug(CollectionArray) writefln("Array.delRef: Deleting array %s", support);
            allocator.dispose(support);
        }
        else
        {
            --*pref;
        }
    }

    @trusted auto prefCount(SupportQual, this Qualified)(SupportQual support)
    {
        assert(support !is null);
        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            return cast(shared size_t*)(&allocator.prefix(support));
        }
        else
        {
            return cast(size_t*)(&allocator.prefix(support));
        }
    }

    static string immutableInsert(StuffType)(string stuff)
    {
        static if (hasLength!StuffType)
        {
            auto stuffLengthStr = ""
                ~"size_t stuffLength = " ~ stuff ~ ".length;";
        }
        else
        {
            auto stuffLengthStr = ""
                ~"import std.range.primitives : walkLength;"
                ~"size_t stuffLength = walkLength(" ~ stuff ~ ");";
        }

        return ""
        ~ stuffLengthStr
        ~"auto tmpAlloc = Mutable!(MutableAlloc)(allocator, MutableAlloc(allocator));"
        ~"_ouroborosAllocator = (() @trusted => cast(immutable)(tmpAlloc))();"
        ~"auto tmpSupport = cast(Unqual!T[])(tmpAlloc.get().allocate(stuffLength * T.sizeof));"
        ~"assert(stuffLength == 0 || (stuffLength > 0 && tmpSupport !is
        null));"
        ~"for (size_t i = 0; i < tmpSupport.length; ++i)"
        ~"{"
                ~"emplace(&tmpSupport[i]);"
        ~"}"
        ~"size_t i = 0;"
        ~"foreach (item; " ~ stuff ~ ")"
        ~"{"
            ~"tmpSupport[i++] = item;"
        ~"}"
        ~"_support = cast(typeof(_support))(tmpSupport);"
        ~"_payload = cast(T[])(_support[0 .. stuffLength]);";
    }

    void destroyUnused()
    {
        debug(CollectionArray)
        {
            writefln("Array.destoryUnused: begin");
            scope(exit) writefln("Array.destoryUnused: end");
        }
        if (_support !is null)
        {
            delRef(_support);
        }
    }

public:
    this(this _)(IAllocator allocator)
    {
        debug(CollectionArray)
        {
            writefln("Array.ctor: begin");
            scope(exit) writefln("Array.ctor: end");
        }
        setAllocator(allocator);
    }

    this(U, this Qualified)(U[] values...)
    if (isImplicitlyConvertible!(U, T))
    {
        this(theAllocator, values);
    }

    this(U, this Qualified)(IAllocator allocator, U[] values...)
    if (isImplicitlyConvertible!(U, T))
    {
        debug(CollectionArray)
        {
            writefln("Array.ctor: begin");
            scope(exit) writefln("Array.ctor: end");
        }
        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            mixin(immutableInsert!(typeof(values))("values"));
            assert(!_ouroborosAllocator.isNull);
        }
        else
        {
            setAllocator(allocator);
            insert(0, values);
        }
    }

    this(Stuff, this Qualified)(Stuff stuff)
    if (isInputRange!Stuff && !isInfinite!Stuff
        && isImplicitlyConvertible!(ElementType!Stuff, T)
        && !is(Stuff == T[]))
    {
        this(theAllocator, stuff);
    }

    this(Stuff, this Qualified)(IAllocator allocator, Stuff stuff)
    if (isInputRange!Stuff && !isInfinite!Stuff
        && isImplicitlyConvertible!(ElementType!Stuff, T)
        && !is(Stuff == T[]))
    {
        debug(CollectionArray)
        {
            writefln("Array.ctor: begin");
            scope(exit) writefln("Array.ctor: end");
        }
        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            mixin(immutableInsert!(typeof(stuff))("stuff"));
            assert(!_ouroborosAllocator.isNull);
        }
        else
        {
            setAllocator(allocator);
            insert(0, stuff);
        }
    }

    this(this)
    {
        debug(CollectionArray)
        {
            writefln("Array.postblit: begin");
            scope(exit) writefln("Array.postblit: end");
        }
        if (_support !is null)
        {
            addRef(_support);
            debug(CollectionArray) writefln("Array.postblit: Array %s has refcount: %s",
                    _support, *prefCount(_support));
        }
    }

    // Immutable ctors
    private this(SuppQual, PaylQual, OuroQual, this Qualified)(SuppQual support,
            PaylQual payload, OuroQual ouroborosAllocator)
        //if (is(typeof(_support) : typeof(support))
            //&& (is(Qualified == immutable) || is(Qualified == const)))
    {
        _support = support;
        _payload = payload;
        _ouroborosAllocator = ouroborosAllocator;
        if (_support !is null)
        {
            addRef(_support);
            debug(CollectionArray) writefln("Array.ctor immutable: Array %s has "
                    ~ "refcount: %s", _support, *prefCount(_support));
        }
    }

    @trusted ~this()
    {
        debug(CollectionArray)
        {
            writefln("Array.dtor: Begin for instance %s of type %s",
                cast(size_t)(&this), typeof(this).stringof);
            scope(exit) writefln("Array.dtor: End for instance %s of type %s",
                    cast(size_t)(&this), typeof(this).stringof);
        }
        destroyUnused();
    }

    private @trusted size_t slackFront() const
    {
        return _payload.ptr - _support.ptr;
    }

    private @trusted size_t slackBack() const
    {
        return _support.ptr + _support.length - _payload.ptr - _payload.length;
    }

    size_t length() const
    {
        return _payload.length;
    }

    void forceLength(size_t len)
    {
        assert(len <= capacity);
        _payload = cast(T[])(_support[slackFront .. len]);
    }

    alias opDollar = length;

    @trusted size_t capacity() const
    {
        return length + slackBack;
    }

    void reserve(size_t n)
    {
        debug(CollectionArray)
        {
            writefln("Array.reserve: begin");
            scope(exit) writefln("Array.reserve: end");
        }
        setAllocator(theAllocator);

        if (n <= capacity) { return; }
        if (_support && *prefCount(_support) == 0)
        {
            void[] buf = _support;
            if (allocator.expand(buf, (n - capacity) * T.sizeof))
            {
                _support = cast(Unqual!T[])(buf);
                // TODO: emplace extended buf
                return;
            }
            else
            {
                //assert(0, "Array.reserve: Failed to expand array.");
            }
        }

        auto tmpSupport = cast(Unqual!T[])(allocator.allocate(n * T.sizeof));
        assert(tmpSupport !is null);
        for (size_t i = 0; i < tmpSupport.length; ++i)
        {
                emplace(&tmpSupport[i]);
        }
        tmpSupport[0 .. _payload.length] = _payload[];
        __dtor();
        _support = tmpSupport;
        _payload = cast(T[])(_support[0 .. _payload.length]);
        assert(capacity >= n);
    }

    size_t insert(Stuff)(size_t pos, Stuff stuff)
    if (!isArray!(typeof(stuff)) && isInputRange!Stuff && !isInfinite!Stuff
        && isImplicitlyConvertible!(ElementType!Stuff, T))
    {
        debug(CollectionArray)
        {
            writefln("Array.insert: begin");
            scope(exit) writefln("Array.insert: end");
        }
        setAllocator(theAllocator);

        static if (hasLength!Stuff)
        {
            size_t stuffLength = stuff.length;
        }
        else
        {
            import std.range.primitives : walkLength;
            size_t stuffLength = walkLength(stuff);
        }
        if (stuffLength == 0) return 0;

        auto tmpSupport = cast(Unqual!T[])(allocator.allocate(stuffLength * T.sizeof));
        assert(stuffLength == 0 || (stuffLength > 0 && tmpSupport !is null));
        for (size_t i = 0; i < tmpSupport.length; ++i)
        {
                emplace(&tmpSupport[i]);
        }

        size_t i = 0;
        foreach (item; stuff)
        {
            tmpSupport[i++] = item;
        }
        size_t result = insert(pos, tmpSupport);
        allocator.dispose(tmpSupport);
        return result;
    }

    size_t insert(Stuff)(size_t pos, Stuff[] stuff...)
    if (isImplicitlyConvertible!(Stuff, T))
    {
        debug(CollectionArray)
        {
            writefln("Array.insert: begin");
            scope(exit) writefln("Array.insert: end");
        }
        assert(pos <= _payload.length);
        setAllocator(theAllocator);

        if (stuff.length == 0) return 0;
        if (stuff.length > slackBack)
        {
            double newCapacity = capacity ? capacity * capacityFactor : stuff.length;
            while (newCapacity < capacity + stuff.length)
            {
                newCapacity = newCapacity * capacityFactor;
            }
            reserve(cast(size_t)(newCapacity));
        }
        //_support[pos + stuff.length .. _payload.length + stuff.length] =
            //_support[pos .. _payload.length];
        for (size_t i = _payload.length + stuff.length - 1; i >= pos +
                stuff.length; --i)
        {
            // Avoids underflow if payload is empty
            _support[i] = _support[i - stuff.length];
        }
        _support[pos .. pos + stuff.length] = stuff[];
        _payload = cast(T[])(_support[0 .. _payload.length + stuff.length]);
        return stuff.length;
    }

    bool isUnique(this _)()
    {
        debug(CollectionArray)
        {
            writefln("Array.isUnique: begin");
            scope(exit) writefln("Array.isUnique: end");
        }

        if (_support !is null)
        {
            return *prefCount(_support) == 0;
        }
        return true;
    }

    bool empty(this _)()
    {
        return length == 0;
    }

    ref auto front(this _)()
    {
        assert(!empty, "Array.front: Array is empty");
        return _payload[0];
    }

    void popFront()
    {
        debug(CollectionArray)
        {
            writefln("Array.popFront: begin");
            scope(exit) writefln("Array.popFront: end");
        }
        assert(!empty, "Array.popFront: Array is empty");
        _payload = _payload[1 .. $];
    }

    Qualified tail(this Qualified)()
    {
        debug(CollectionArray)
        {
            writefln("Array.tail: begin");
            scope(exit) writefln("Array.tail: end");
        }
        assert(!empty, "Array.tail: Array is empty");

        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            return this[1 .. $];
        }
        else
        {
            return .tail(this);
        }
    }

    ref auto save(this _)()
    {
        debug(CollectionArray)
        {
            writefln("Array.save: begin");
            scope(exit) writefln("Array.save: end");
        }
        return this;
    }

    typeof(this) dup()
    {
        debug(CollectionArray)
        {
            writefln("Array.dup: begin");
            scope(exit) writefln("Array.dup: end");
        }
        IAllocator alloc = getAllocator();
        if (alloc is null)
        {
            alloc = theAllocator;
        }
        return typeof(this)(alloc, this);
    }

    Qualified opSlice(this Qualified)()
    {
        debug(CollectionArray)
        {
            writefln("Array.opSlice(): begin");
            scope(exit) writefln("Array.opSlice(): end");
        }
        return this.save;
    }

    Qualified opSlice(this Qualified)(size_t start, size_t end)
    in
    {
        assert(start <= end && end <= length,
               "Array.opSlice(s, e): Invalid bounds: Ensure start <= end <= length");
    }
    body
    {
        debug(CollectionArray)
        {
            writefln("Array.opSlice(s, e): begin");
            scope(exit) writefln("Array.opSlice(s, e): end");
        }
        return typeof(this)(_support, _payload[start .. end], _ouroborosAllocator);
    }

    ref auto opIndex(this _)(size_t idx)
    in
    {
        assert(idx <= length, "Array.opIndex: Index out of bounds");
    }
    body
    {
        return _payload[idx];
    }

    ref auto opIndexUnary(string op)(size_t idx)
    in
    {
        assert(idx <= length, "Array.opIndexUnary!" ~ op ~ ": Index out of bounds");
    }
    body
    {
        mixin("return " ~ op ~ "_payload[idx];");
    }

    ref auto opIndexAssign(U)(U elem, size_t idx)
    if (isImplicitlyConvertible!(U, T))
    in
    {
        assert(idx <= length, "Array.opIndexAssign: Index out of bounds");
    }
    body
    {
        return _payload[idx] = elem;
    }

    ref auto opIndexOpAssign(string op, U)(U elem, size_t idx)
    if (isImplicitlyConvertible!(U, T))
    in
    {
        assert(idx <= length, "Array.opIndexOpAssign!" ~ op ~ ": Index out of bounds");
    }
    body
    {
        mixin("return _payload[idx]" ~ op ~ "= elem;");
    }

    auto ref opBinary(string op, U)(auto ref U rhs)
        if (op == "~" &&
            (is (U == typeof(this))
             || is (U : T)
             || (isInputRange!U && isImplicitlyConvertible!(ElementType!U, T))
            ))
    {
        debug(CollectionArray)
        {
            writefln("Array.opBinary!~: begin");
            scope(exit) writefln("Array.opBinary!~: end");
        }

        //TODO: should work for immutable, const as well

        typeof(this) newArray = this.dup();
        newArray.insert(length, rhs);
        return newArray;
    }

    auto ref opAssign()(auto ref typeof(this) rhs)
    {
        debug(CollectionArray)
        {
            writefln("Array.opAssign: begin");
            scope(exit) writefln("Array.opAssign: end");
        }

        if (rhs._support !is null && _support is rhs._support)
        {
            return this;
        }

        if (rhs._support !is null)
        {
            rhs.addRef(rhs._support);
            debug(CollectionArray) writefln("Array.opAssign: Array %s has refcount: %s",
                    rhs._payload, *prefCount(rhs._support));
        }
        //__dtor();
        destroyUnused();
        _support = rhs._support;
        _payload = rhs._payload;
        _ouroborosAllocator = rhs._ouroborosAllocator;
        return this;
    }

    auto ref opOpAssign(string op, U)(auto ref U rhs)
        if (op == "~" &&
            (is (U == typeof(this))
             || is (U : T)
             || (isInputRange!U && isImplicitlyConvertible!(ElementType!U, T))
            ))
    {
        debug(CollectionArray)
        {
            writefln("Array.opOpAssign!~: %s begin", typeof(this).stringof);
            scope(exit) writefln("Array.opOpAssign!~: %s end", typeof(this).stringof);
        }
        insert(length, rhs);
        return this;
    }
}

version(unittest) private @trusted void testConcatAndAppend(IAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto a = Array!(int)(allocator, 1, 2, 3);
    Array!(int) a2 = Array!(int)(allocator);

    auto a3 = a ~ a2;
    assert(equal(a3, [1, 2, 3]));

    auto a4 = a3;
    a3 = a3 ~ 4;
    assert(equal(a3, [1, 2, 3, 4]));
    a3 = a3 ~ [5];
    assert(equal(a3, [1, 2, 3, 4, 5]));
    assert(equal(a4, [1, 2, 3]));

    a4 = a3;
    a3 ~= 6;
    assert(equal(a3, [1, 2, 3, 4, 5, 6]));
    a3 ~= [7];

    a3 ~= a3;
    assert(equal(a3, [1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7]));

    Array!int a5 = Array!(int)(allocator);
    a5 ~= [1, 2, 3];
    assert(equal(a5, [1, 2, 3]));
    auto a6 = a5;
    a5 = a5;
    a5[0] = 10;
    assert(equal(a5, a6));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testConcatAndAppend(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "Array ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @trusted void testSimple(IAllocator allocator)
{
    import std.algorithm.comparison : equal;
    import std.algorithm.searching : canFind;

    auto a = Array!int(allocator);
    assert(a.empty);
    assert(a.isUnique);

    size_t pos = 0;
    a.insert(pos, 1, 2, 3);
    assert(a.front == 1);
    assert(equal(a, a));
    assert(equal(a, [1, 2, 3]));

    a.popFront();
    assert(a.front == 2);
    assert(equal(a, [2, 3]));

    a.insert(pos, [4, 5, 6]);
    a.insert(pos, 7);
    a.insert(pos, [8]);
    assert(equal(a, [8, 7, 4, 5, 6, 2, 3]));

    a.insert(a.length, 0, 1);
    a.insert(a.length, [-1, -2]);
    assert(equal(a, [8, 7, 4, 5, 6, 2, 3, 0, 1, -1, -2]));

    a.front = 9;
    assert(equal(a, [9, 7, 4, 5, 6, 2, 3, 0, 1, -1, -2]));

    auto aTail = a.tail;
    assert(aTail.front == 7);
    aTail.front = 8;
    assert(aTail.front == 8);
    assert(a.tail.front == 8);
    assert(!a.isUnique);

    assert(canFind(a, 2));
    assert(!canFind(a, -10));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testSimple(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "Array ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @trusted void testSimpleImmutable(IAllocator allocator)
{
    import std.algorithm.comparison : equal;
    import std.algorithm.searching : canFind;

    auto a = Array!(immutable int)(allocator);
    assert(a.empty);

    size_t pos = 0;
    a.insert(pos, 1, 2, 3);
    assert(a.front == 1);
    assert(equal(a, a));
    assert(equal(a, [1, 2, 3]));

    a.popFront();
    assert(a.front == 2);
    assert(equal(a, [2, 3]));
    assert(a.tail.front == 3);

    a.insert(pos, [4, 5, 6]);
    a.insert(pos, 7);
    a.insert(pos, [8]);
    assert(equal(a, [8, 7, 4, 5, 6, 2, 3]));

    a.insert(a.length, 0, 1);
    a.insert(a.length, [-1, -2]);
    assert(equal(a, [8, 7, 4, 5, 6, 2, 3, 0, 1, -1, -2]));

    // Cannot modify immutable values
    static assert(!__traits(compiles, a.front = 9));

    assert(canFind(a, 2));
    assert(!canFind(a, -10));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testSimpleImmutable(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "Array ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @trusted void testCopyAndRef(IAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto aFromList = Array!int(allocator, 1, 2, 3);
    auto aFromRange = Array!int(allocator, aFromList);
    assert(equal(aFromList, aFromRange));

    aFromList.popFront();
    assert(equal(aFromList, [2, 3]));
    assert(equal(aFromRange, [1, 2, 3]));

    size_t pos = 0;
    Array!int aInsFromRange = Array!int(allocator);
    aInsFromRange.insert(pos, aFromList);
    aFromList.popFront();
    assert(equal(aFromList, [3]));
    assert(equal(aInsFromRange, [2, 3]));

    Array!int aInsBackFromRange = Array!int(allocator);
    aInsBackFromRange.insert(pos, aFromList);
    aFromList.popFront();
    assert(aFromList.empty);
    assert(equal(aInsBackFromRange, [3]));

    auto aFromRef = aInsFromRange;
    auto aFromDup = aInsFromRange.dup;
    assert(aInsFromRange.front == 2);
    aFromRef.front = 5;
    assert(aInsFromRange.front == 5);
    assert(aFromDup.front == 2);
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testCopyAndRef(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "Array ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @trusted void testImmutability(IAllocator allocator)
{
    auto a = immutable Array!(int)(allocator, 1, 2, 3);
    auto a2 = a;
    auto a3 = a2.save();

    assert(a2.front == 1);
    assert(a2[0] == a2.front);
    static assert(!__traits(compiles, a2.front = 4));
    static assert(!__traits(compiles, a2.popFront()));

    auto a4 = a2.tail;
    assert(a4.front == 2);
    static assert(!__traits(compiles, a4 = a4.tail));
}

version(unittest) private @trusted void testConstness(IAllocator allocator)
{
    auto a = const Array!(int)(allocator, 1, 2, 3);
    auto a2 = a;
    auto a3 = a2.save();

    assert(a2.front == 1);
    assert(a2[0] == a2.front);
    static assert(!__traits(compiles, a2.front = 4));
    static assert(!__traits(compiles, a2.popFront()));

    auto a4 = a2.tail;
    assert(a4.front == 2);
    static assert(!__traits(compiles, a4 = a4.tail));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testImmutability(_allocator);
        testConstness(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "Array ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @trusted void testWithStruct(IAllocator allocator)
{
    import std.algorithm.comparison : equal;
    import std.stdio;

    auto array = Array!int(allocator, 1, 2, 3);
    {
        auto arrayOfArrays = Array!(Array!int)(allocator, array);
        assert(equal(arrayOfArrays.front, [1, 2, 3]));
        arrayOfArrays.front.front = 2;
        assert(equal(arrayOfArrays.front, [2, 2, 3]));
        static assert(!__traits(compiles, arrayOfArrays.insert(1)));

        auto immArrayOfArrays = immutable Array!(Array!int)(allocator, array);
        assert(immArrayOfArrays.front.front == 2);
        static assert(!__traits(compiles, immArrayOfArrays.front.front = 2));
    }
    assert(equal(array, [2, 2, 3]));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testWithStruct(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "Array ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @trusted void testWithClass(IAllocator allocator)
{
    class MyClass
    {
        int x;
        this(int x) { this.x = x; }
    }

    MyClass c = new MyClass(10);
    {
        auto a = Array!MyClass(allocator, c);
        assert(a.front.x == 10);
        assert(a.front is c);
        a.front.x = 20;
    }
    assert(c.x == 20);
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testWithClass(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "Array ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @trusted void testOpOverloads(IAllocator allocator)
{
    auto a = Array!int(allocator, 1, 2, 3, 4);
    assert(a[0] == 1); // opIndex

    // opIndexUnary
    ++a[0];
    assert(a[0] == 2);
    --a[0];
    assert(a[0] == 1);
    a[0]++;
    assert(a[0] == 2);
    a[0]--;
    assert(a[0] == 1);

    // opIndexAssign
    a[0] = 2;
    assert(a[0] == 2);

    // opIndexOpAssign
    a[0] /= 2;
    assert(a[0] == 1);
    a[0] *= 2;
    assert(a[0] == 2);
    a[0] -= 1;
    assert(a[0] == 1);
    a[0] += 1;
    assert(a[0] == 2);
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testOpOverloads(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "Array ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @trusted void testSlice(IAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto a = Array!int(allocator, 1, 2, 3, 4);
    auto b = a[];
    assert(equal(a, b));
    b[1] = 5;
    assert(a[1] == 5);

    size_t startPos = 2;
    auto c = b[startPos .. $];
    assert(equal(c, [3, 4]));
    c[0] = 5;
    assert(equal(a, b));
    assert(equal(a, [1, 5, 5, 4]));
    assert(a.capacity == b.capacity && b.capacity == c.capacity + startPos);

    c ~= 5;
    assert(equal(c, [5, 4, 5]));
    assert(equal(a, b));
    assert(equal(a, [1, 5, 5, 4]));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testSlice(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "Array ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

//@trusted unittest {
    //import stdx.collection.slist;
    //import std.stdio;

    //{
        //auto a = Array!(SList!int)(SList!int(1));
        //writefln("Array: %s", *a.prefCount(a._support));
        //writefln("SList: %s", *a.front.prefCount(a.front._head));
        //{
            //auto b = a;
            //writefln("Array: %s", *a.prefCount(a._support));
            //writefln("SList: %s", *a.front.prefCount(a.front._head));
            //size_t i = 0;
            //auto sl = a.front;
            ////while(!a.front.empty)
            ////{
                ////writefln("[%s] %s", i, a.front.front);
                ////a.front.popFront;
            ////}
            //while(!sl.empty)
            //{
                //writefln("[%s] %s", i, sl.front);
                //sl.popFront;
            //}
            //writefln("At end of scope");
        //}
        //writefln("After end of scope");
        //writefln("Array: %s", *a.prefCount(a._support));
        //writefln("SList: %s", *a.front.prefCount(a.front._head));
    //}

    //import std.conv;
    //writefln("HERE");
    //auto bytesUsed = _allocator.bytesUsed;
    //assert(bytesUsed == 0, "Array ref count leaks memory; leaked "
                           //~ to!string(bytesUsed) ~ " bytes");
/*}*/
