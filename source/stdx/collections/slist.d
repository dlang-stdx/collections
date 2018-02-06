///
module stdx.collections.slist;

import stdx.collections.common;

debug(CollectionSList) import std.stdio;

version(unittest)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator.building_blocks.stats_collector;
    import std.experimental.allocator : IAllocator, allocatorObject;

    private alias SCAlloc = StatsCollector!(Mallocator, Options.bytesUsed);
}

///
struct SList(T)
{
    import std.experimental.allocator : IAllocator, theAllocator, make, dispose;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import std.traits : isImplicitlyConvertible;
    import std.range.primitives : isInputRange, ElementType;
    import std.conv : emplace;
    import core.atomic : atomicOp;

//private:
    struct Node
    {
        T _payload;
        Node *_next;

        this(T v, Node *n)
        {
            debug(CollectionSList) writefln("SList.Node.ctor: Constructing node" ~
                    " with payload: %s", v);
            _payload = v;
            _next = n;
        }

        ~this()
        {
            debug(CollectionSList) writefln("SList.Node.dtor: Destroying node" ~
                    " with payload: %s", _payload);
        }
    }

    Node *_head;

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

    @trusted void addRef(QualNode, this Qualified)(QualNode node)
    {
        assert(node !is null);
        debug(CollectionSList)
        {
            writefln("SList.addRef: Node %s has refcount: %s; will be: %s",
                    node._payload, *prefCount(node), *prefCount(node) + 1);
        }
        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            atomicOp!"+="(*prefCount(node), 1);
        }
        else
        {
            ++*prefCount(node);
        }
    }

    @trusted void delRef(ref Node *node)
    {
        assert(node !is null);
        size_t *pref = prefCount(node);
        debug(CollectionSList) writefln("SList.delRef: Node %s has refcount: %s; will be: %s",
                node._payload, *pref, *pref - 1);
        if (*pref == 0)
        {
            debug(CollectionSList) writefln("SList.delRef: Deleting node %s", node._payload);
            allocator.dispose(node);
            node = null;
        }
        else
        {
            --*pref;
        }
    }

    @trusted auto prefCount(QualNode, this Qualified)(QualNode node)
    {
        assert(node !is null);
        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            return cast(shared size_t*)(&allocator.prefix(cast(void[Node.sizeof])(*node)));
        }
        else
        {
            return cast(size_t*)(&allocator.prefix(cast(void[Node.sizeof])(*node)));
        }
    }

    static string immutableInsert(string stuff)
    {
        return ""
            ~"auto tmpAlloc = Mutable!(MutableAlloc)(allocator, MutableAlloc(allocator));"
            ~"_ouroborosAllocator = (() @trusted => cast(immutable)(tmpAlloc))();"
            ~"Node *tmpNode;"
            ~"Node *tmpHead;"
            ~"foreach (item; " ~ stuff ~ ")"
            ~"{"
                ~"Node *newNode;"
                ~"() @trusted { newNode ="
                    ~"tmpAlloc.get().make!(Node)(item, null);"
                ~"}();"
                ~"(tmpHead ? tmpNode._next : tmpHead) = newNode;"
                ~"tmpNode = newNode;"
            ~"}"
            ~"_head = (() @trusted => cast(immutable Node*)(tmpHead))();";
    }

public:
    this(this _)(IAllocator allocator)
    {
        debug(CollectionSList)
        {
            writefln("SList.ctor: begin");
            scope(exit) writefln("SList.ctor: end");
        }
        setAllocator(allocator);
    }

    ///
    this(U, this Qualified)(U[] values...)
    if (isImplicitlyConvertible!(U, T))
    {
        this(theAllocator, values);
    }

    /// ditto
    this(U, this Qualified)(IAllocator allocator, U[] values...)
    if (isImplicitlyConvertible!(U, T))
    {
        debug(CollectionSList)
        {
            writefln("SList.ctor: begin");
            scope(exit) writefln("SList.ctor: end");
        }
        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            mixin(immutableInsert("values"));
        }
        else
        {
            setAllocator(allocator);
            insert(0, values);
        }
    }

    /// ditto
    this(Stuff, this Qualified)(Stuff stuff)
    if (isInputRange!Stuff
        && isImplicitlyConvertible!(ElementType!Stuff, T)
        && !is(Stuff == T[]))
    {
        this(theAllocator, stuff);
    }

    /// ditto
    this(Stuff, this Qualified)(IAllocator allocator, Stuff stuff)
    if (isInputRange!Stuff
        && isImplicitlyConvertible!(ElementType!Stuff, T)
        && !is(Stuff == T[]))
    {
        debug(CollectionSList)
        {
            writefln("SList.ctor: begin");
            scope(exit) writefln("SList.ctor: end");
        }
        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            mixin(immutableInsert("stuff"));
        }
        else
        {
            setAllocator(allocator);
            insert(0, stuff);
        }
    }

    this(this)
    {
        debug(CollectionSList)
        {
            writefln("SList.postblit: begin");
            scope(exit) writefln("SList.postblit: end");
        }
        if (_head !is null)
        {
            addRef(_head);
            debug(CollectionSList) writefln("SList.postblit: Node %s has refcount: %s",
                    _head._payload, *prefCount(_head));
        }
    }

    // Immutable ctors
    private this(NodeQual, OuroQual, this Qualified)(NodeQual _newHead,
            OuroQual ouroborosAllocator)
        if (is(typeof(_head) : typeof(_newHead))
            && (is(Qualified == immutable) || is(Qualified == const)))
    {
        _head = _newHead;
        _ouroborosAllocator = ouroborosAllocator;
        if (_head !is null)
        {
            addRef(_head);
            debug(CollectionSList) writefln("SList.ctor immutable: Node %s has "
                    ~ "refcount: %s", _head._payload, *prefCount(_head));
        }
    }

    @trusted ~this()
    {
        debug(CollectionSList)
        {
            writefln("SList.dtor: Begin for instance %s of type %s",
                cast(size_t)(&this), typeof(this).stringof);
            scope(exit) writefln("SList.dtor: End for instance %s of type %s",
                    cast(size_t)(&this), typeof(this).stringof);
        }
        destroyUnused();
    }

    ///
    void destroyUnused()
    {
        debug(CollectionSList)
        {
            writefln("SList.destoryUnused: begin");
            scope(exit) writefln("SList.destoryUnused: end");
        }
        while (_head !is null && *prefCount(_head) == 0)
        {
            debug(CollectionSList) writefln("SList.destoryUnused: One ref with head at %s",
                    _head._payload);
            Node *tmpNode = _head;
            _head = _head._next;
            delRef(tmpNode);
        }

        if (_head !is null && *prefCount(_head) > 0)
        {
            // We reached a copy, so just remove the head ref, thus deleting
            // the copy in constant time (we are undoing the postblit)
            debug(CollectionSList) writefln("SList.destoryUnused: Multiple refs with head at %s",
                    _head._payload);
            delRef(_head);
        }
    }

    ///
    bool isUnique(this _)()
    {
        debug(CollectionSList)
        {
            writefln("SList.isUnique: begin");
            scope(exit) writefln("SList.isUnique: end");
        }

        Node *tmpNode = (() @trusted => cast(Node*)_head)();
        while (tmpNode !is null)
        {
            if (*prefCount(tmpNode) > 0)
            {
                return false;
            }
            tmpNode = tmpNode._next;
        }
        return true;
    }

    bool empty(this _)()
    {
        return _head is null;
    }

    ref auto front(this _)()
    {
        assert(!empty, "SList.front: List is empty");
        return _head._payload;
    }

    void popFront()
    {
        debug(CollectionSList)
        {
            writefln("SList.popFront: begin");
            scope(exit) writefln("SList.popFront: end");
        }
        assert(!empty, "SList.popFront: List is empty");

        Node *tmpNode = _head;
        _head = _head._next;
        if (*prefCount(tmpNode) > 0 &&  _head !is null)
        {
            // If we have another copy of the list then the refcount
            // must increase, otherwise it will remain the same
            // This condition is needed because the recounting is zero based
            addRef(_head);
        }
        delRef(tmpNode);
    }

    Qualified tail(this Qualified)()
    {
        debug(CollectionSList)
        {
            writefln("SList.tail: begin");
            scope(exit) writefln("SList.tail: end");
        }
        assert(!empty, "SList.tail: List is empty");

        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            return typeof(this)(_head._next, _ouroborosAllocator);
        }
        else
        {
            return .tail(this);
        }
    }

    ref Qualified save(this Qualified)()
    {
        debug(CollectionSList)
        {
            writefln("SList.save: begin");
            scope(exit) writefln("SList.save: end");
        }
        return this;
    }

    typeof(this) dup()
    {
        debug(CollectionSList)
        {
            writefln("SList.dup: begin");
            scope(exit) writefln("SList.dup: end");
        }
        IAllocator alloc = getAllocator();
        if (alloc is null)
        {
            alloc = theAllocator;
        }
        return typeof(this)(alloc, this);
    }

    size_t insert(Stuff)(size_t pos, Stuff stuff)
    if (isInputRange!Stuff && isImplicitlyConvertible!(ElementType!Stuff, T))
    {
        debug(CollectionSList)
        {
            writefln("SList.insert: begin");
            scope(exit) writefln("SList.insert: end");
        }
        // Ensure we have an allocator. If it was already set, this will do nothing
        setAllocator(theAllocator);

        size_t result;
        Node *tmpNode;
        Node *tmpHead;
        foreach (item; stuff)
        {
            Node *newNode;
            () @trusted { newNode = allocator.make!(Node)(item, null); }();
            (tmpHead ? tmpNode._next : tmpHead) = newNode;
            tmpNode = newNode;
            ++result;
        }

        if (!tmpNode)
        {
            return 0;
        }

        Node *needle = _head;
        Node *needlePrev = null;
        while (pos)
        {
            needlePrev = needle;
            needle = needle._next;
            --pos;
        }

        tmpNode._next = needle;
        if (needlePrev is null)
        {
            _head = tmpHead;
        }
        else
        {
            needlePrev._next = tmpHead;
        }
        return result;
    }

    size_t insert(Stuff)(size_t pos, Stuff[] stuff...)
    if (isImplicitlyConvertible!(Stuff, T))
    {
        return insert(pos, stuff);
    }

    size_t insertBack(Stuff)(Stuff stuff)
    if (isInputRange!Stuff && isImplicitlyConvertible!(ElementType!Stuff, T))
    {
        debug(CollectionSList)
        {
            writefln("SList.insertBack: begin");
            scope(exit) writefln("SList.insertBack: end");
        }
        // Ensure we have an allocator. If it was already set, this will do nothing
        setAllocator(theAllocator);

        size_t result;
        Node *tmpNode;
        Node *tmpHead;
        foreach (item; stuff)
        {
            Node *newNode;
            () @trusted { newNode = allocator.make!(Node)(item, null); }();
            (tmpHead ? tmpNode._next : tmpHead) = newNode;
            tmpNode = newNode;
            ++result;
        }

        if (!tmpNode)
        {
            return 0;
        }

        if (_head is null)
        {
            _head = tmpHead;
        }
        else
        {
            Node *endNode;
            for (endNode = _head; endNode._next !is null; endNode = endNode._next) { }
            endNode._next = tmpHead;
        }

        return result;
    }

    size_t insertBack(Stuff)(Stuff[] stuff...)
    if (isImplicitlyConvertible!(Stuff, T))
    {
        return insertBack(stuff);
    }

    auto ref opBinary(string op, U)(auto ref U rhs)
        if (op == "~" &&
            (is (U == typeof(this))
             || is (U : T)
             || (isInputRange!U && isImplicitlyConvertible!(ElementType!U, T))
            ))
    {
        debug(CollectionSList)
        {
            writefln("SList.opBinary!~: begin");
            scope(exit) writefln("SList.opBinary!~: end");
        }

        IAllocator alloc = getAllocator();
        if (alloc is null)
        {
            static if (is(U == typeof(this)))
            {
                alloc = rhs.getAllocator();
            }
            else
            {
                alloc = null;
            }
            if (alloc is null)
            {
                alloc = theAllocator;
            }
        }
        typeof(this) newList = typeof(this)(alloc, rhs);
        newList.insert(0, this);
        return newList;
    }

    auto ref opAssign()(auto ref typeof(this) rhs)
    {
        debug(CollectionSList)
        {
            writefln("SList.opAssign: begin");
            scope(exit) writefln("SList.opAssign: end");
        }

        if (rhs._head !is null && _head is rhs._head)
        {
            return this;
        }

        if (rhs._head !is null)
        {
            rhs.addRef(rhs._head);
            debug(CollectionSList) writefln("SList.opAssign: Node %s has refcount: %s",
                    rhs._head._payload, *prefCount(rhs._head));
        }
        destroyUnused();
        _head = rhs._head;
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
        debug(CollectionSList)
        {
            writefln("SList.opOpAssign!~: %s begin", typeof(this).stringof);
            scope(exit) writefln("SList.opOpAssign!~: %s end", typeof(this).stringof);
        }

        insertBack(rhs);
        return this;
    }

    void remove(size_t idx = 0)
    {
        assert(!empty, "SList.remove: List is empty");
        if (idx == 0)
        {
            popFront();
            return;
        }

        Node *tmpNode = _head;
        while(--idx != 0)
        {
            tmpNode = tmpNode._next;
        }
        Node *toDel = tmpNode._next;
        assert(toDel !is null, "SList.remove: Index out of bounds");
        tmpNode._next = tmpNode._next._next;
        delRef(toDel);
    }

    debug(CollectionSList) void printRefCount(this _)()
    {
        writefln("SList.printRefCount: begin");
        scope(exit) writefln("SList.printRefCount: end");

        Node *tmpNode = (() @trusted => cast(Node*)_head)();
        while (tmpNode !is null)
        {
            writefln("SList.printRefCount: Node %s has ref count %s",
                    tmpNode._payload, *prefCount(tmpNode));
            tmpNode = tmpNode._next;
        }
    }
}

version(unittest) private @safe void testImmutability(IAllocator allocator)
{
    auto s = immutable SList!(int)(allocator, 1, 2, 3);
    auto s2 = s;
    auto s3 = s2.save();

    assert(s2.front == 1);
    static assert(!__traits(compiles, s2.front = 4));
    static assert(!__traits(compiles, s2.popFront()));

    auto s4 = s2.tail;
    assert(s4.front == 2);
    static assert(!__traits(compiles, s4 = s4.tail));
}

version(unittest) private @safe void testConstness(IAllocator allocator)
{
    auto s = const SList!(int)(allocator, 1, 2, 3);
    auto s2 = s;
    auto s3 = s2.save();

    assert(s2.front == 1);
    static assert(!__traits(compiles, s2.front = 4));
    static assert(!__traits(compiles, s2.popFront()));

    auto s4 = s2.tail;
    assert(s4.front == 2);
    static assert(!__traits(compiles, s4 = s4.tail));
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
        assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();

    //() @nogc {
        //_allocator.allocate(1);
    //}();

    //() @nogc {
        //import std.experimental.allocator.building_blocks.affix_allocator;
        //import std.stdio;
        //auto a = AffixAllocator!(Mallocator, size_t).instance;
        //auto ia = allocatorObject(a);
        //pragma(msg, typeof(a));
        //auto b = ia.allocate(1);
        //pragma(msg, typeof(ia.impl.prefix(b)));
    //}();
}

version(unittest) private @safe void testConcatAndAppend(IAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto sl = SList!(int)(allocator, 1, 2, 3);
    SList!(int) sl2 = SList!int(allocator);

    auto sl3 = sl ~ sl2;
    assert(equal(sl3, [1, 2, 3]));

    auto sl4 = sl3;
    sl3 = sl3 ~ 4;
    assert(equal(sl3, [1, 2, 3, 4]));
    sl3 = sl3 ~ [5];
    assert(equal(sl3, [1, 2, 3, 4, 5]));
    assert(equal(sl4, [1, 2, 3]));

    sl4 = sl3;
    sl3 ~= 6;
    assert(equal(sl3, [1, 2, 3, 4, 5, 6]));
    sl3 ~= [7];
    assert(equal(sl3, [1, 2, 3, 4, 5, 6, 7]));
    assert(equal(sl4, [1, 2, 3, 4, 5, 6, 7]));

    sl3 ~= sl3;
    assert(equal(sl3, [1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7]));
    assert(equal(sl4, [1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7]));

    SList!int sl5 = SList!int(allocator);
    sl5 ~= [1, 2, 3];
    assert(equal(sl5, [1, 2, 3]));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testConcatAndAppend(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @safe void testSimple(IAllocator allocator)
{
    import std.algorithm.comparison : equal;
    import std.algorithm.searching : canFind;
    import std.range.primitives : walkLength;

    auto sl = SList!int(allocator);
    assert(sl.empty);
    assert(sl.isUnique);

    size_t pos = 0;
    sl.insert(pos, 1, 2, 3);
    assert(sl.front == 1);
    assert(equal(sl, sl));
    assert(equal(sl, [1, 2, 3]));

    sl.popFront();
    assert(sl.front == 2);
    assert(equal(sl, [2, 3]));

    sl.insert(pos, [4, 5, 6]);
    sl.insert(pos, 7);
    sl.insert(pos, [8]);
    assert(equal(sl, [8, 7, 4, 5, 6, 2, 3]));

    sl.insertBack(0, 1);
    sl.insertBack([-1, -2]);
    assert(equal(sl, [8, 7, 4, 5, 6, 2, 3, 0, 1, -1, -2]));

    sl.front = 9;
    assert(equal(sl, [9, 7, 4, 5, 6, 2, 3, 0, 1, -1, -2]));

    auto slTail = sl.tail;
    assert(slTail.front == 7);
    slTail.front = 8;
    assert(slTail.front == 8);
    assert(sl.tail.front == 8);
    assert(!sl.isUnique);

    assert(canFind(sl, 2));
    assert(!canFind(sl, -10));

    sl.remove();
    assert(equal(sl, [8, 4, 5, 6, 2, 3, 0, 1, -1, -2]));
    sl.remove(2);
    assert(equal(sl, [8, 4, 6, 2, 3, 0, 1, -1, -2]));
    sl.remove(walkLength(sl) - 1);
    assert(equal(sl, [8, 4, 6, 2, 3, 0, 1, -1]));
    pos = 1;
    sl.insert(pos, 10);
    assert(equal(sl, [8, 10, 4, 6, 2, 3, 0, 1, -1]));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testSimple(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @safe void testSimpleImmutable(IAllocator allocator)
{
    import std.algorithm.comparison : equal;
    import std.algorithm.searching : canFind;
    import std.range.primitives : walkLength;

    auto sl = SList!(immutable int)(allocator);
    assert(sl.empty);

    size_t pos = 0;
    sl.insert(pos, 1, 2, 3);
    assert(sl.front == 1);
    assert(equal(sl, sl));
    assert(equal(sl, [1, 2, 3]));

    sl.popFront();
    assert(sl.front == 2);
    assert(equal(sl, [2, 3]));
    assert(sl.tail.front == 3);

    sl.insert(pos, [4, 5, 6]);
    sl.insert(pos, 7);
    sl.insert(pos, [8]);
    assert(equal(sl, [8, 7, 4, 5, 6, 2, 3]));

    sl.insertBack(0, 1);
    sl.insertBack([-1, -2]);
    assert(equal(sl, [8, 7, 4, 5, 6, 2, 3, 0, 1, -1, -2]));

    // Cannot modify immutable values
    static assert(!__traits(compiles, sl.front = 9));

    assert(canFind(sl, 2));
    assert(!canFind(sl, -10));

    sl.remove();
    assert(equal(sl, [7, 4, 5, 6, 2, 3, 0, 1, -1, -2]));
    sl.remove(2);
    assert(equal(sl, [7, 4, 6, 2, 3, 0, 1, -1, -2]));
    sl.remove(walkLength(sl) - 1);
    assert(equal(sl, [7, 4, 6, 2, 3, 0, 1, -1]));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testSimpleImmutable(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @safe void testCopyAndRef(IAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto slFromList = SList!int(allocator, 1, 2, 3);
    auto slFromRange = SList!int(allocator, slFromList);
    assert(equal(slFromList, slFromRange));

    slFromList.popFront();
    assert(equal(slFromList, [2, 3]));
    assert(equal(slFromRange, [1, 2, 3]));

    SList!int slInsFromRange = SList!int(allocator);
    size_t pos = 0;
    slInsFromRange.insert(pos, slFromList);
    slFromList.popFront();
    assert(equal(slFromList, [3]));
    assert(equal(slInsFromRange, [2, 3]));

    SList!int slInsBackFromRange = SList!int(allocator);
    slInsBackFromRange.insert(pos, slFromList);
    slFromList.popFront();
    assert(slFromList.empty);
    assert(equal(slInsBackFromRange, [3]));

    auto slFromRef = slInsFromRange;
    auto slFromDup = slInsFromRange.dup;
    assert(slInsFromRange.front == 2);
    slFromRef.front = 5;
    assert(slInsFromRange.front == 5);
    assert(slFromDup.front == 2);
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testCopyAndRef(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @safe void testWithStruct(IAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto list = SList!int(allocator, 1, 2, 3);
    {
        auto listOfLists = SList!(SList!int)(allocator, list);
        assert(equal(listOfLists.front, [1, 2, 3]));
        listOfLists.front.front = 2;
        assert(equal(listOfLists.front, [2, 2, 3]));
        size_t pos = 0;
        static assert(!__traits(compiles, listOfLists.insert(pos, 1)));

        auto immListOfLists = immutable SList!(SList!int)(allocator, list);
        assert(immListOfLists.front.front == 2);
        static assert(!__traits(compiles, immListOfLists.front.front = 2));
    }
    assert(equal(list, [2, 2, 3]));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(statsCollectorAlloc);

    () @safe {
        testWithStruct(_allocator);
        auto bytesUsed = _allocator.impl.bytesUsed;
        assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}

version(unittest) private @safe void testWithClass(IAllocator allocator)
{
    class MyClass
    {
        int x;
        this(int x) { this.x = x; }
    }

    MyClass c = new MyClass(10);
    {
        auto sl = SList!MyClass(allocator, c);
        assert(sl.front.x == 10);
        assert(sl.front is c);
        sl.front.x = 20;
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
        assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
                ~ to!string(bytesUsed) ~ " bytes");
    }();
}
