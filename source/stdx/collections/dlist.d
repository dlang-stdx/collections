module stdx.collections.dlist;

import stdx.collections.common;

debug(CollectionDList) import std.stdio;

version(unittest)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator.building_blocks.stats_collector;
    import std.experimental.allocator : RCIAllocator, allocatorObject;

    private alias SCAlloc = StatsCollector!(Mallocator, Options.bytesUsed);
}

struct DList(T)
{
    import std.experimental.allocator : RCIAllocator, theAllocator, make, dispose;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import std.traits : isImplicitlyConvertible;
    import std.range.primitives : isInputRange, ElementType;
    import std.conv : emplace;
    import core.atomic : atomicOp;

private:
    struct Node
    {
        T _payload;
        Node *_next;
        Node *_prev;

        this(T v, Node *n, Node *p)
        {
            debug(CollectionDList) writefln("DList.Node.ctor: Constructing node" ~
                    " with payload: %s", v);
            _payload = v;
            _next = n;
            _prev = p;
        }

        ~this()
        {
            debug(CollectionDList) writefln("DList.Node.dtor: Destroying node" ~
                    " with payload: %s", _payload);
        }
    }

    Node *_head;

    alias MutableAlloc = AffixAllocator!(RCIAllocator, size_t);
    Mutable!MutableAlloc _ouroborosAllocator;

    /// Returns the actual allocator from ouroboros
    @trusted ref auto allocator(this _)()
    {
        assert(!_ouroborosAllocator.isNull);
        return _ouroborosAllocator.get();
    }

    /// Constructs the ouroboros allocator from allocator if the ouroboros
    //allocator wasn't previously set
    public @trusted bool setAllocator(RCIAllocator allocator)
    {
        if (_ouroborosAllocator.isNull)
        {
            _ouroborosAllocator = Mutable!(MutableAlloc)(allocator,
                    MutableAlloc(allocator));
            return true;
        }
        return false;
    }

    public @trusted RCIAllocator getAllocator(this _)()
    {
        return _ouroborosAllocator.isNull ? RCIAllocator(null) : allocator().parent;
    }

    @trusted void addRef(QualNode, this Qualified)(QualNode node)
    {
        assert(node !is null);
        debug(CollectionDList)
        {
            writefln("DList.addRef: Node %s has refcount: %s; will be: %s",
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
        debug(CollectionDList) writefln("DList.delRef: Node %s has refcount: %s; will be: %s",
                node._payload, *pref, *pref - 1);
        if (*pref == 0)
        {
            debug(CollectionDList) writefln("DList.delRef: Deleting node %s", node._payload);
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
                    ~"tmpAlloc.get().make!(Node)(item, null, null);"
                ~"}();"
                ~"if (tmpHead is null)"
                ~"{"
                    ~"tmpHead = tmpNode = newNode;"
                ~"}"
                ~"else"
                ~"{"
                    ~"tmpNode._next = newNode;"
                    ~"newNode._prev = tmpNode;"
                    ~"addRef(newNode._prev);"
                    ~"tmpNode = newNode;"
                ~"}"
            ~"}"
            ~"_head = (() @trusted => cast(immutable Node*)(tmpHead))();";
    }

public:
    this(this _)(RCIAllocator allocator)
    {
        debug(CollectionDList)
        {
            writefln("DList.ctor: begin");
            scope(exit) writefln("DList.ctor: end");
        }
        setAllocator(allocator);
    }

    this(U, this Qualified)(U[] values...)
    if (isImplicitlyConvertible!(U, T))
    {
        this(theAllocator, values);
    }

    this(U, this Qualified)(RCIAllocator allocator, U[] values...)
    if (isImplicitlyConvertible!(U, T))
    {
        debug(CollectionDList)
        {
            writefln("DList.ctor: begin");
            scope(exit) writefln("DList.ctor: end");
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

    this(Stuff, this Qualified)(Stuff stuff)
    if (isInputRange!Stuff
        && isImplicitlyConvertible!(ElementType!Stuff, T)
        && !is(Stuff == T[]))
    {
        this(theAllocator, stuff);
    }

    this(Stuff, this Qualified)(RCIAllocator allocator, Stuff stuff)
    if (isInputRange!Stuff
        && isImplicitlyConvertible!(ElementType!Stuff, T)
        && !is(Stuff == T[]))
    {
        debug(CollectionDList)
        {
            writefln("DList.ctor: begin");
            scope(exit) writefln("DList.ctor: end");
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
        debug(CollectionDList)
        {
            writefln("DList.postblit: begin");
            scope(exit) writefln("DList.postblit: end");
        }
        if (_head !is null)
        {
            addRef(_head);
            debug(CollectionDList) writefln("DList.postblit: Node %s has refcount: %s",
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
            debug(CollectionDList) writefln("DList.ctor immutable: Node %s has "
                    ~ "refcount: %s", _head._payload, *prefCount(_head));
        }
    }

    ~this()
    {
        debug(CollectionDList)
        {
            writefln("DList.dtor: Begin for instance %s of type %s",
                cast(size_t)(&this), typeof(this).stringof);
            scope(exit) writefln("DList.dtor: End for instance %s of type %s",
                    cast(size_t)(&this), typeof(this).stringof);
        }
        if (_head !is null)
        {
            delRef(_head);
            if (_head !is null
                && ((_head._prev !is null) || (_head._next !is null)))
            {
                // If it was a single node list, only delRef must be used
                // in order to avoid premature/double freeing
                destroyUnused(_head);
            }
        }
    }

    void destroyUnused(Node *startNode)
    {
        debug(CollectionDList)
        {
            writefln("DList.destoryUnused: begin");
            scope(exit) writefln("DList.destoryUnused: end");
        }

        if (startNode is null) return;

        Node *tmpNode = startNode;
        bool isCycle = true;
        while (tmpNode !is null)
        {
            if (((tmpNode._next is null || tmpNode._prev is null)
                  && *prefCount(tmpNode) == 0)
                || (tmpNode._next !is null && tmpNode._prev !is null
                    && *prefCount(tmpNode) == 1))
            {
                // The last node should always have rc == 0 (only one ref,
                // from prev._next)
                // The first node should always have rc == 0 (only one ref,
                // from next._prev), since we don't take into account
                // the head ref (that was deleted either by the dtor or by pop)
                // Nodes within the cycle should always have rc == 1
                tmpNode = tmpNode._next;
            }
            else
            {
                isCycle = false;
                break;
            }
        }

        tmpNode = startNode._prev;
        while (isCycle && tmpNode !is null)
        {
            if (((tmpNode._next is null || tmpNode._prev is null)
                  && *prefCount(tmpNode) == 0)
                || (tmpNode._next !is null && tmpNode._prev !is null
                    && *prefCount(tmpNode) == 1))
            {
                tmpNode = tmpNode._prev;
            }
            else
            {
                isCycle = false;
                break;
            }
        }

        if (isCycle)
        {
            // We can safely deallocate memory
            tmpNode = startNode._next;
            while (tmpNode !is null)
            {
                Node *oldNode = tmpNode;
                tmpNode = tmpNode._next;
                () @trusted { allocator.dispose(oldNode); }();
            }
            tmpNode = startNode;
            while (tmpNode !is null)
            {
                Node *oldNode = tmpNode;
                tmpNode = tmpNode._prev;
                () @trusted { allocator.dispose(oldNode); }();
            }
        }
    }

    bool isUnique(this _)()
    {
        debug(CollectionDList)
        {
            writefln("DList.isUnique: begin");
            scope(exit) writefln("DList.isUnique: end");
        }

        if (empty)
        {
            return true;
        }

        Node *tmpNode = (() @trusted => cast(Node*)_head)();

        // Rewind to the beginning of the list
        while (tmpNode !is null && tmpNode._prev !is null)
        {
            tmpNode = tmpNode._prev;
        }

        // For a single node list, head should have rc == 0
        if (tmpNode._next is null && (*prefCount(tmpNode) > 0))
        {
            return false;
        }

        while (tmpNode !is null)
        {
            if (tmpNode._next is null || tmpNode._prev is null)
            {
                // The first and last node should have rc == 0 unless the _head
                // is pointing to them, in which case rc must be 1
                if (((tmpNode is _head) && (*prefCount(tmpNode) > 1))
                    || ((tmpNode !is _head) && (*prefCount(tmpNode) > 0)))
                {
                    return false;
                }
            }
            else if (((tmpNode is _head) && (*prefCount(tmpNode) > 2))
                    || ((tmpNode !is _head) && (*prefCount(tmpNode) > 1)))
            {
                // Any other node should have rc == 1 unless the _head
                // is pointing to it, in which case rc must be 2
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
        assert(!empty, "DList.front: List is empty");
        return _head._payload;
    }

    void popFront()
    {
        debug(CollectionDList)
        {
            writefln("DList.popFront: begin");
            scope(exit) writefln("DList.popFront: end");
        }
        assert(!empty, "DList.popFront: List is empty");
        Node *tmpNode = _head;
        _head = _head._next;
        if (_head !is null)
        {
            addRef(_head);
            delRef(tmpNode);
        }
        else
        {
            delRef(tmpNode);
            if (tmpNode !is null
                && ((tmpNode._prev !is null) || (tmpNode._next !is null)))
            {
                // If it was a single node list, only delRef must be used
                // in order to avoid premature/double freeing
                destroyUnused(tmpNode);
            }
        }
    }

    void popPrev()
    {
        debug(CollectionDList)
        {
            writefln("DList.popPrev: begin");
            scope(exit) writefln("DList.popPrev: end");
        }
        assert(!empty, "DList.popPrev: List is empty");
        Node *tmpNode = _head;
        _head = _head._prev;
        if (_head !is null) {
            addRef(_head);
            delRef(tmpNode);
        }
        else
        {
            delRef(tmpNode);
            if (tmpNode !is null
                && ((tmpNode._prev !is null) || (tmpNode._next !is null)))
            {
                // If it was a single node list, only delRef must be used
                // in order to avoid premature/double freeing
                destroyUnused(tmpNode);
            }
        }
    }

    Qualified tail(this Qualified)()
    {
        debug(CollectionDList)
        {
            writefln("DList.popFront: begin");
            scope(exit) writefln("DList.popFront: end");
        }
        assert(!empty, "DList.popFront: List is empty");

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
        debug(CollectionDList)
        {
            writefln("DList.save: begin");
            scope(exit) writefln("DList.save: end");
        }
        return this;
    }

    typeof(this) dup()
    {
        debug(CollectionDList)
        {
            writefln("DList.dup: begin");
            scope(exit) writefln("DList.dup: end");
        }
        RCIAllocator alloc = getAllocator();
        if (alloc.isNull)
        {
            alloc = theAllocator;
        }
        return typeof(this)(alloc, this);
    }

    size_t insert(Stuff)(size_t pos, Stuff stuff)
    if (isInputRange!Stuff && isImplicitlyConvertible!(ElementType!Stuff, T))
    {
        debug(CollectionDList)
        {
            writefln("DList.insert: begin");
            scope(exit) writefln("DList.insert: end");
        }
        setAllocator(theAllocator);

        size_t result;
        Node *tmpNode;
        Node *tmpHead;
        foreach (item; stuff)
        {
            Node *newNode;
            () @trusted { newNode = allocator.make!(Node)(item, null, null); }();
            if (tmpHead is null)
            {
                tmpHead = tmpNode = newNode;
            }
            else
            {
                tmpNode._next = newNode;
                newNode._prev = tmpNode;
                addRef(newNode._prev);
                tmpNode = newNode;
            }
            ++result;
        }

        if (!tmpNode)
        {
            return 0;
        }

        if (!_head) assert(pos == 0);

        size_t initPos = pos;
        Node *needle = _head;
        while (pos && needle._next !is null)
        {
            needle = needle._next;
            --pos;
        }

        // Check if we need to insert at the back of the list
        if (initPos != 0 && needle._next is null && pos >= 1)
        {
            // We need to insert at the back of the list
            assert(pos == 1, "Index out of range");
            needle._next = tmpHead;
            tmpHead._prev = needle;
            addRef(needle);
            return result;
        }
        assert(pos == 0, "Index out of range");

        tmpNode._next = needle;
        if (needle !is null)
        {
            addRef(needle);
            if (needle._prev !is null)
            {
                tmpHead._prev = needle._prev;
                needle._prev._next = tmpHead;
                // Inc ref only when tmpHead will be the new head of the list
                if (initPos == 0)
                {
                    addRef(tmpHead);
                }

                // Delete extra ref, since we already added the ref earlier
                // through tmpNode._next
                delRef(needle);
            }
            if (initPos == 0)
            {
                // Pass the ref to the new head
                delRef(needle);
            }
            assert(needle !is null);
            needle._prev = tmpNode;
            if (tmpHead == tmpNode)
            {
                addRef(tmpHead);
            }
            else
            {
                addRef(needle._prev);
            }
        }

        if (initPos == 0)
        {
            _head = tmpHead;
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
        debug(CollectionDList)
        {
            writefln("DList.insertBack: begin");
            scope(exit) writefln("DList.insertBack: end");
        }
        setAllocator(theAllocator);

        size_t result;
        Node *tmpNode;
        Node *tmpHead;
        foreach (item; stuff)
        {
            Node *newNode;
            () @trusted { newNode = allocator.make!(Node)(item, null, null); }();
            if (tmpHead is null)
            {
                tmpHead = tmpNode = newNode;
            }
            else
            {
                tmpNode._next = newNode;
                newNode._prev = tmpNode;
                addRef(newNode._prev);
                tmpNode = newNode;
            }
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
            // don't addRef(tmpHead) since the ref will pass from tmpHead to
            // endNode._next when tmpHead's scope ends
            tmpHead._prev = endNode;
            addRef(endNode);
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
        debug(CollectionDList)
        {
            writefln("DList.opBinary!~: begin");
            scope(exit) writefln("DList.opBinary!~: end");
        }

        RCIAllocator alloc = getAllocator();
        if (alloc.isNull)
        {
            static if (is(U == typeof(this)))
            {
                alloc = rhs.getAllocator();
            }
            else
            {
                alloc = null;
            }
            if (alloc.isNull)
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
        debug(CollectionDList)
        {
            writefln("DList.opAssign: begin");
            scope(exit) writefln("DList.opAssign: end");
        }

        if (rhs._head !is null && _head is rhs._head)
        {
            return this;
        }

        if (rhs._head !is null)
        {
            rhs.addRef(rhs._head);
            debug(CollectionDList) writefln("DList.opAssign: Node %s has refcount: %s",
                    rhs._head._payload, *prefCount(rhs._head));
        }

        if (_head !is null)
        {
            Node *tmpNode = _head;
            delRef(tmpNode);
            if (tmpNode !is null
                && ((tmpNode._prev !is null) || (tmpNode._next !is null)))
            {
                // If it was a single node list, only delRef must be used
                // in order to avoid premature/double freeing
                destroyUnused(tmpNode);
            }
        }
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
        debug(CollectionDList)
        {
            writefln("DList.opOpAssign!~: %s begin", typeof(this).stringof);
            scope(exit) writefln("DList.opOpAssign!~: %s end", typeof(this).stringof);
        }

        insertBack(rhs);
        return this;
    }

    void remove()
    {
        debug(CollectionDList)
        {
            writefln("DList.remove: begin");
            scope(exit) writefln("DList.remove: end");
        }
        assert(!empty, "DList.remove: List is empty");

        Node *tmpNode = _head;
        _head = _head._next;
        if (_head !is null)
        {
            //addRef(_head);
            _head._prev = tmpNode._prev;
            delRef(tmpNode); // Remove tmpNode._next._prev ref
            tmpNode._next = null;
            //delRef(_head);
            if (tmpNode._prev !is null)
            {
                addRef(_head);
                tmpNode._prev._next = _head;
                delRef(tmpNode); // Remove tmpNode._prev._next ref
                tmpNode._prev = null;
            }
        }
        else if (tmpNode._prev !is null)
        {
            _head = tmpNode._prev;
            //addRef(_head);
            tmpNode._prev = null;
            //delRef(_head);
            _head._next = null;
            delRef(tmpNode);
        }
        delRef(tmpNode); // Remove old head ref
        if (tmpNode !is null
                && ((tmpNode._prev !is null) || (tmpNode._next !is null)))
        {
            // If it was a single node list, only delRef must be used
            // in order to avoid premature/double freeing
            destroyUnused(tmpNode);
        }
    }

    //debug(CollectionDList) void printRefCount(Node *sn = null)
    void printRefCount(Node *sn = null)
    {
        import std.stdio;
        writefln("DList.printRefCount: begin");
        scope(exit) writefln("DList.printRefCount: end");

        Node *tmpNode;
        if (sn is null)
            tmpNode = _head;
        else
            tmpNode = sn;

        while (tmpNode !is null && tmpNode._prev !is null)
        {
            // Rewind to the beginning of the list
            tmpNode = tmpNode._prev;
        }
        while (tmpNode !is null)
        {
            writefln("DList.printRefCount: Node %s has ref count %s",
                    tmpNode._payload, *prefCount(tmpNode));
            tmpNode = tmpNode._next;
        }
    }
}

version (unittest) private @trusted void testInit(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;

    DList!int dl = DList!int(allocator);
    assert(dl.empty);
    assert(dl.isUnique);
    int[] empty;
    assert(equal(dl, empty));

    DList!int dl2 = DList!int(allocator, 1);
    assert(equal(dl2, [1]));

    DList!int dl3 = DList!int(allocator, 1, 2);
    assert(equal(dl3, [1, 2]));

    DList!int dl4 = DList!int(allocator, [1]);
    assert(equal(dl4, [1]));

    DList!int dl5 = DList!int(allocator, [1, 2]);
    assert(equal(dl5, [1, 2]));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(&statsCollectorAlloc);

    () @safe {
        testInit(_allocator);
    }();
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version (unittest) private @trusted void testInsert(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;
    import std.range.primitives : walkLength;

    DList!int dl = DList!int(allocator, 1);
    size_t pos = 0;
    dl.insert(pos, 2);
    assert(equal(dl, [2, 1]));

    DList!int dl2 = DList!int(allocator, 1);
    dl2.insert(pos, 2, 3);
    assert(equal(dl2, [2, 3, 1]));

    DList!int dl3 = DList!int(allocator, 1, 2);
    dl3.insert(pos, 3);
    assert(equal(dl3, [3, 1, 2]));

    DList!int dl4 = DList!int(allocator, 1, 2);
    dl4.insert(pos, 3, 4);
    assert(equal(dl4, [3, 4, 1, 2]));

    DList!int dl5 = DList!int(allocator, 1, 2);
    dl5.popFront();
    dl5.insert(pos, 3);
    assert(equal(dl5, [3, 2]));
    dl5.popPrev();
    assert(equal(dl5, [1, 3, 2]));

    DList!int dl6 = DList!int(allocator, 1, 2);
    dl6.popFront();
    dl6.insert(pos, 3, 4);
    assert(equal(dl6, [3, 4, 2]));
    dl6.popPrev();
    assert(equal(dl6, [1, 3, 4, 2]));
    dl6.insertBack(5);
    assert(equal(dl6, [1, 3, 4, 2, 5]));
    dl6.insertBack(6, 7);
    assert(equal(dl6, [1, 3, 4, 2, 5, 6, 7]));
    dl6.insertBack([8]);
    assert(equal(dl6, [1, 3, 4, 2, 5, 6, 7, 8]));
    dl6.insertBack([9, 10]);
    assert(equal(dl6, [1, 3, 4, 2, 5, 6, 7, 8, 9, 10]));
    int[] empty;
    dl6.insertBack(empty);
    assert(equal(dl6, [1, 3, 4, 2, 5, 6, 7, 8, 9, 10]));
    dl6.insert(pos, empty);
    assert(equal(dl6, [1, 3, 4, 2, 5, 6, 7, 8, 9, 10]));

    DList!int dl7 = DList!int(allocator, 1);
    assert(equal(dl7, [1]));
    dl7.insert(pos, 2);
    assert(equal(dl7, [2, 1]));
    pos = walkLength(dl7);
    dl7.insert(pos, 3);
    assert(equal(dl7, [2, 1, 3]));
    dl7.insert(pos, 4);
    assert(equal(dl7, [2, 1, 4, 3]));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(&statsCollectorAlloc);

    () @safe {
        testInsert(_allocator);
    }();
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version (unittest) private @trusted void testRemove(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;

    DList!int dl = DList!int(allocator, 1);
    size_t pos = 0;
    dl.remove();
    assert(dl.empty);
    assert(dl.isUnique);
    assert(!dl._ouroborosAllocator.isNull);

    dl.insert(pos, 2);
    auto dl2 = dl;
    auto dl3 = dl;
    assert(!dl.isUnique);

    dl.popFront();
    assert(dl.empty);
    assert(!dl._ouroborosAllocator.isNull);

    dl2.popPrev();
    assert(dl2.empty);
    assert(dl3.isUnique);

    auto dl4 = dl3;
    assert(!dl3.isUnique);
    dl4.remove();
    assert(dl4.empty);
    assert(!dl3.empty);
    assert(dl3.isUnique);
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(&statsCollectorAlloc);

    () @safe {
        testRemove(_allocator);
    }();
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version (unittest) private @trusted void testCopyAndRef(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto dlFromList = DList!int(allocator, 1, 2, 3);
    auto dlFromRange = DList!int(allocator, dlFromList);
    assert(equal(dlFromList, dlFromRange));

    dlFromList.popFront();
    assert(equal(dlFromList, [2, 3]));
    assert(equal(dlFromRange, [1, 2, 3]));

    DList!int dlInsFromRange = DList!int(allocator);
    size_t pos = 0;
    dlInsFromRange.insert(pos, dlFromList);
    dlFromList.popFront();
    assert(equal(dlFromList, [3]));
    assert(equal(dlInsFromRange, [2, 3]));

    DList!int dlInsBackFromRange = DList!int(allocator);
    dlInsBackFromRange.insert(pos, dlFromList);
    dlFromList.popFront();
    assert(dlFromList.empty);
    assert(equal(dlInsBackFromRange, [3]));

    auto dlFromRef = dlInsFromRange;
    auto dlFromDup = dlInsFromRange.dup;
    assert(dlInsFromRange.front == 2);
    dlFromRef.front = 5;
    assert(dlInsFromRange.front == 5);
    assert(dlFromDup.front == 2);
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(&statsCollectorAlloc);

    () @safe {
        testCopyAndRef(_allocator);
    }();
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

@trusted unittest
{
    import std.algorithm.comparison : equal;

    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(&statsCollectorAlloc);

    DList!int dl = DList!int(_allocator, 1, 2, 3);
    auto before = statsCollectorAlloc.bytesUsed;
    {
        DList!int dl2 = dl;
        dl2.popFront();
        assert(equal(dl2, [2, 3]));
    }
    assert(before == statsCollectorAlloc.bytesUsed);
    assert(equal(dl, [1, 2, 3]));
    dl.tail();
}

version(unittest) private @trusted void testImmutability(RCIAllocator allocator)
{
    auto s = immutable DList!(int)(allocator, 1, 2, 3);
    auto s2 = s;
    auto s3 = s2.save();

    assert(s2.front == 1);
    static assert(!__traits(compiles, s2.front = 4));
    static assert(!__traits(compiles, s2.popFront()));

    auto s4 = s2.tail;
    assert(s4.front == 2);
    static assert(!__traits(compiles, s4 = s4.tail));
}

version(unittest) private @trusted void testConstness(RCIAllocator allocator)
{
    auto s = const DList!(int)(allocator, 1, 2, 3);
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
    auto _allocator = allocatorObject(&statsCollectorAlloc);

    () @safe {
        testConstness(_allocator);
        testImmutability(_allocator);
    }();
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private @trusted void testConcatAndAppend(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto dl = DList!(int)(allocator, 1, 2, 3);
    DList!(int) dl2 = DList!int(allocator);

    auto dl3 = dl ~ dl2;
    assert(equal(dl3, [1, 2, 3]));

    auto dl4 = dl3;
    dl3 = dl3 ~ 4;
    assert(equal(dl3, [1, 2, 3, 4]));
    dl3 = dl3 ~ [5];
    assert(equal(dl3, [1, 2, 3, 4, 5]));
    assert(equal(dl4, [1, 2, 3]));

    dl4 = dl3;
    dl3 ~= 6;
    assert(equal(dl3, [1, 2, 3, 4, 5, 6]));
    dl3 ~= [7];
    assert(equal(dl3, [1, 2, 3, 4, 5, 6, 7]));
    assert(equal(dl4, [1, 2, 3, 4, 5, 6, 7]));

    dl3 ~= dl3;
    assert(equal(dl3, [1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7]));
    assert(equal(dl4, [1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7]));

    DList!int dl5 = DList!int(allocator);
    dl5 ~= [1, 2, 3];
    assert(equal(dl5, [1, 2, 3]));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(&statsCollectorAlloc);

    () @safe {
        testConcatAndAppend(_allocator);
    }();
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private @trusted void testAssign(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto dl = DList!int(allocator, 1, 2, 3);
    assert(equal(dl, [1, 2, 3]));
    {
        auto dl2 = DList!int(allocator, 4, 5, 6);
        dl = dl2;
        assert(equal(dl, dl2));
    }
    assert(equal(dl, [4, 5, 6]));
    dl.popPrev();
    assert(dl.empty);
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(&statsCollectorAlloc);

    () @safe {
        testAssign(_allocator);
    }();
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private @trusted void testWithStruct(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;

    auto list = DList!int(allocator, 1, 2, 3);
    {
        auto listOfLists = DList!(DList!int)(allocator, list);
        size_t pos = 0;
        assert(equal(listOfLists.front, [1, 2, 3]));
        listOfLists.front.front = 2;
        assert(equal(listOfLists.front, [2, 2, 3]));
        static assert(!__traits(compiles, listOfLists.insert(pos, 1)));

        auto immListOfLists = immutable DList!(DList!int)(allocator, list);
        assert(immListOfLists.front.front == 2);
        static assert(!__traits(compiles, immListOfLists.front.front = 2));
    }
    assert(equal(list, [2, 2, 3]));
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(&statsCollectorAlloc);

    () @safe {
        testWithStruct(_allocator);
    }();
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private @trusted void testWithClass(RCIAllocator allocator)
{
    class MyClass
    {
        int x;
        this(int x) { this.x = x; }
    }

    MyClass c = new MyClass(10);
    {
        auto dl = DList!MyClass(allocator, c);
        assert(dl.front.x == 10);
        assert(dl.front is c);
        dl.front.x = 20;
    }
    assert(c.x == 20);
}

@trusted unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    auto _allocator = allocatorObject(&statsCollectorAlloc);

    () @safe {
        testWithClass(_allocator);
    }();
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}
