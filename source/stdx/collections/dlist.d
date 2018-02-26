module stdx.collections.dlist;

import stdx.collections.common;

debug(CollectionDList) import std.stdio;

version(unittest)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator.building_blocks.stats_collector;
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           allocatorObject, sharedAllocatorObject;

    private alias SCAlloc = StatsCollector!(Mallocator, Options.bytesUsed);
}

struct DList(T)
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           theAllocator, processAllocator, make, dispose, stateSize;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import std.traits : isImplicitlyConvertible;
    import std.range.primitives : isInputRange, ElementType;
    import std.variant : Algebraic;
    import std.conv : emplace;
    import core.atomic : atomicOp;
    import std.algorithm.mutation : move;

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

    // State {
    Node *_head;
    AllocatorHandler _allocator;
    // }

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
            return true;
        }
        return false;
    }

    @nogc nothrow pure @trusted
    void addRef(QualNode, this Q)(QualNode node)
    {
        assert(node !is null);
        cast(void) _allocator.opPrefix!("+=")(cast(void[Node.sizeof])(*node), 1);
    }

    void delRef(ref Node *node)
    {
        // Will be optimized away, but the type system infers T's safety
        if (0) { T t = T.init; }

        assert(node !is null);
        () @trusted {
            if (opCmpPrefix!"=="(node, 0))
            {
                dispose(_allocator, node);
                node = null;
            }
            else
            {
                cast(void) _allocator.opPrefix!("-=")(cast(void[Node.sizeof])(*node), 1);
            }
        }();
    }

    pragma(inline, true)
    @nogc nothrow pure @trusted
    size_t opCmpPrefix(string op)(const Node *node, size_t val) const
    if ((op == "==") || (op == "<=") || (op == "<") || (op == ">=") || (op == ">"))
    {
        return _allocator.opCmpPrefix!op(cast(void[Node.sizeof])(*node), val);
    }

    static string immutableInsert(string stuff)
    {
        return ""
            ~"_allocator = immutable AllocatorHandler(allocator);"
            ~"Node *tmpNode;"
            ~"Node *tmpHead;"
            ~"foreach (item; " ~ stuff ~ ")"
            ~"{"
                ~"Node *newNode;"
                ~"() @trusted { newNode ="
                    ~"_allocator.make!(Node)(item, null, null);"
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
    /**
     * Constructs a qualified doubly linked list that will use the provided
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
        debug(CollectionDList)
        {
            writefln("DList.ctor: begin");
            scope(exit) writefln("DList.ctor: end");
        }
        static if (is(Q == immutable) || is(Q == const))
        {
            T[] empty;
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
        auto dl = DList!int(theAllocator);
        auto cdl = const DList!int(processAllocator);
        auto idl = immutable DList!int(processAllocator);
    }

    /**
     * Constructs a qualified doubly linked list out of a number of items.
     * Because no allocator was provided, the list will use the
     * $(REF, GCAllocator, std,experimental,allocator).
     *
     * Params:
     *      values = a variable number of items, either in the form of a
     *               list or as a built-in array
     *
     * Complexity: $(BIGOH m), where `m` is the number of items.
     */
    this(U, this Q)(U[] values...)
    if (isImplicitlyConvertible!(U, T))
    {
        static if (is(Q == immutable) || is(Q == const))
        {
            this(processAllocatorObject(), values);
        }
        else
        {
            this(threadAllocatorObject(), values);
        }
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        // Create a list from a list of ints
        {
            auto dl = DList!int(1, 2, 3);
            assert(equal(dl, [1, 2, 3]));
        }
        // Create a list from an array of ints
        {
            auto dl = DList!int([1, 2, 3]);
            assert(equal(dl, [1, 2, 3]));
        }
        // Create a list from a list from an input range
        {
            auto dl = DList!int(1, 2, 3);
            auto dl2 = DList!int(dl);
            assert(equal(dl2, [1, 2, 3]));
        }
    }

    /**
     * Constructs a qualified doubly linked list out of a number of items
     * that will use the provided allocator object.
     * For `immutable` objects, a `RCISharedAllocator` must be supplied.
     *
     * Params:
     *      allocator = a $(REF RCIAllocator, std,experimental,allocator) or
     *                  $(REF RCISharedAllocator, std,experimental,allocator)
     *                  allocator object
     *      values = a variable number of items, either in the form of a
     *               list or as a built-in array
     *
     * Complexity: $(BIGOH m), where `m` is the number of items.
     */
    this(A, U, this Q)(A allocator, U[] values...)
    if (!is(Q == shared)
        && (is(A == RCISharedAllocator) || !is(Q == immutable))
        && (is(A == RCIAllocator) || is(A == RCISharedAllocator))
        && isImplicitlyConvertible!(U, T))
    {
        debug(CollectionDList)
        {
            writefln("DList.ctor: begin");
            scope(exit) writefln("DList.ctor: end");
        }
        static if (is(Q == immutable) || is(Q == const))
        {
            mixin(immutableInsert("values"));
        }
        else
        {
            setAllocator(allocator);
            insert(0, values);
        }
    }

    /**
     * Constructs a qualified doubly linked list out of an
     * $(REF_ALTTEXT input range, isInputRange, std,range,primitives).
     * Because no allocator was provided, the list will use the
     * $(REF, GCAllocator, std,experimental,allocator).
     *
     * Params:
     *      stuff = an input range of elements that are implitictly convertible
     *              to `T`
     *
     * Complexity: $(BIGOH m), where `m` is the number of elements in the range.
     */
    this(Stuff, this Q)(Stuff stuff)
    if (isInputRange!Stuff
        && isImplicitlyConvertible!(ElementType!Stuff, T)
        && !is(Stuff == T[]))
    {
        static if (is(Q == immutable) || is(Q == const))
        {
            this(processAllocatorObject(), stuff);
        }
        else
        {
            this(threadAllocatorObject(), stuff);
        }
    }

    /**
     * Constructs a qualified doubly linked list out of an
     * $(REF_ALTTEXT input range, isInputRange, std,range,primitives)
     * that will use the provided allocator object.
     * For `immutable` objects, a `RCISharedAllocator` must be supplied.
     *
     * Params:
     *      allocator = a $(REF RCIAllocator, std,experimental,allocator) or
     *                  $(REF RCISharedAllocator, std,experimental,allocator)
     *                  allocator object
     *      stuff = an input range of elements that are implitictly convertible
     *              to `T`
     *
     * Complexity: $(BIGOH m), where `m` is the number of elements in the range.
     */
    this(A, Stuff, this Q)(A allocator, Stuff stuff)
    if (!is(Q == shared)
        && (is(A == RCISharedAllocator) || !is(Q == immutable))
        && (is(A == RCIAllocator) || is(A == RCISharedAllocator))
        && isInputRange!Stuff
        && isImplicitlyConvertible!(ElementType!Stuff, T)
        && !is(Stuff == T[]))
    {
        debug(CollectionDList)
        {
            writefln("DList.ctor: begin");
            scope(exit) writefln("DList.ctor: end");
        }
        static if (is(Q == immutable) || is(Q == const))
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
        _allocator.bootstrap();
        if (_head !is null)
        {
            addRef(_head);
            debug(CollectionDList) writefln("DList.postblit: Node %s has refcount: %s",
                    _head._payload, *prefCount(_head));
        }
    }

    // Immutable ctors
    // Very important to pass the allocator by ref! (Related to postblit bug)
    private this(NodeQual, AllocQual, this Q)(NodeQual _newHead, ref AllocQual _newAllocator)
        if (is(typeof(_head) : typeof(_newHead))
            && (is(Q == immutable) || is(Q == const)))
    {
        _head = _newHead;
        // Needs a bootstrap
        // bootstrap is the equivalent of incRef
        _newAllocator.bootstrap();
        _allocator = _newAllocator;
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

    nothrow pure @safe unittest
    {
        auto s = DList!int(1, 2, 3);

        // Infer safety
        static assert(!__traits(compiles, () @safe { DList!Unsafe(Unsafe(1)); }));
        static assert(!__traits(compiles, () @safe { auto s = const DList!Unsafe(Unsafe(1)); }));
        static assert(!__traits(compiles, () @safe { auto s = immutable DList!Unsafe(Unsafe(1)); }));

        static assert(!__traits(compiles, () @safe { DList!UnsafeDtor(UnsafeDtor(1)); }));
        static assert(!__traits(compiles, () @safe { auto s = const DList!UnsafeDtor(UnsafeDtor(1)); }));
        static assert(!__traits(compiles, () @safe { auto s = immutable DList!UnsafeDtor(UnsafeDtor(1)); }));

        // Infer purity
        static assert(!__traits(compiles, () pure { DList!Impure(Impure(1)); }));
        static assert(!__traits(compiles, () pure { auto s = const DList!Impure(Impure(1)); }));
        static assert(!__traits(compiles, () pure { auto s = immutable DList!Impure(Impure(1)); }));

        static assert(!__traits(compiles, () pure { DList!ImpureDtor(ImpureDtor(1)); }));
        static assert(!__traits(compiles, () pure { auto s = const DList!ImpureDtor(ImpureDtor(1)); }));
        static assert(!__traits(compiles, () pure { auto s = immutable DList!ImpureDtor(ImpureDtor(1)); }));

        // Infer throwability
        static assert(!__traits(compiles, () nothrow { DList!Throws(Throws(1)); }));
        static assert(!__traits(compiles, () nothrow { auto s = const DList!Throws(Throws(1)); }));
        static assert(!__traits(compiles, () nothrow { auto s = immutable DList!Throws(Throws(1)); }));

        static assert(!__traits(compiles, () nothrow { DList!ThrowsDtor(ThrowsDtor(1)); }));
        static assert(!__traits(compiles, () nothrow { auto s = const DList!ThrowsDtor(ThrowsDtor(1)); }));
        static assert(!__traits(compiles, () nothrow { auto s = immutable DList!ThrowsDtor(ThrowsDtor(1)); }));
    }

    private void destroyUnused(Node *startNode)
    {
        debug(CollectionDList)
        {
            writefln("DList.destoryUnused: begin");
            scope(exit) writefln("DList.destoryUnused: end");
        }

        // Will be optimized away, but the type system infers T's safety
        if (0) { T t = T.init; }

        if (startNode is null) return;

        Node *tmpNode = startNode;
        bool isCycle = true;
        while (tmpNode !is null)
        {
            if (((tmpNode._next is null || tmpNode._prev is null)
                  && opCmpPrefix!"=="(tmpNode, 0))
                || (tmpNode._next !is null && tmpNode._prev !is null
                    && opCmpPrefix!"=="(tmpNode, 1)))
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
                  && opCmpPrefix!"=="(tmpNode, 0))
                || (tmpNode._next !is null && tmpNode._prev !is null
                    && opCmpPrefix!"=="(tmpNode, 1)))
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
            // We could be in the middle of the list so we need to go both
            // forwards and backwards
            tmpNode = startNode._next;
            while (tmpNode !is null)
            {
                Node *oldNode = tmpNode;
                tmpNode = tmpNode._next;
                () @trusted { dispose(_allocator, oldNode); }();
            }
            tmpNode = startNode;
            while (tmpNode !is null)
            {
                Node *oldNode = tmpNode;
                tmpNode = tmpNode._prev;
                () @trusted { dispose(_allocator, oldNode); }();
            }
        }
    }

    /**
     * Check whether there are no more references to this list instance.
     *
     * Returns:
     *      `true` if this is the only reference to this list instance;
     *      `false` otherwise.
     *
     * Complexity: $(BIGOH n).
     */
    bool isUnique() const
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
        if (tmpNode._next is null && opCmpPrefix!">"(tmpNode, 0))
        {
            return false;
        }

        while (tmpNode !is null)
        {
            if (tmpNode._next is null || tmpNode._prev is null)
            {
                // The first and last node should have rc == 0 unless the _head
                // is pointing to them, in which case rc must be 1
                if (((tmpNode is _head) && opCmpPrefix!">"(tmpNode, 1))
                    || ((tmpNode !is _head) && opCmpPrefix!">"(tmpNode, 0)))
                {
                    return false;
                }
            }
            else if (((tmpNode is _head) && opCmpPrefix!">"(tmpNode, 2))
                     || ((tmpNode !is _head) && opCmpPrefix!">"(tmpNode, 1)))
            {
                // Any other node should have rc == 1 unless the _head
                // is pointing to it, in which case rc must be 2
                return false;
            }
            tmpNode = tmpNode._next;
        }
        return true;
    }

    ///
    @safe unittest
    {
        auto dl = DList!int(24, 42);
        assert(dl.isUnique);
        {
            auto dl2 = dl;
            assert(!dl.isUnique);
            dl2.front = 0;
            assert(dl.front == 0);
        } // dl2 goes out of scope
        assert(dl.isUnique);
    }

    /**
     * Check if the list is empty.
     *
     * Returns:
     *      `true` if there are no nodes in the list; `false` otherwise.
     *
     * Complexity: $(BIGOH 1).
     */
    @nogc nothrow pure @safe
    bool empty() const
    {
        return _head is null;
    }

    ///
    @safe unittest
    {
        DList!int dl;
        assert(dl.empty);
        size_t pos = 0;
        dl.insert(pos, 1);
        assert(!dl.empty);
    }

    /**
     * Provide access to the first element in the list. The user must check
     * that the list isn't `empty`, prior to calling this function.
     *
     * Returns:
     *      a reference to the first element.
     *
     * Complexity: $(BIGOH 1).
     */
    ref auto front(this _)()
    {
        assert(!empty, "DList.front: List is empty");
        return _head._payload;
    }

    ///
    @safe unittest
    {
        auto dl = DList!int(1, 2, 3);
        assert(dl.front == 1);
        dl.front = 0;
        assert(dl.front == 0);
    }

    /**
     * Advance to the next element in the list. The user must check
     * that the list isn't `empty`, prior to calling this function.
     *
     * If this was the last element in the list and there are no more
     * references to the current list, then the list and all it's elements
     * will be destroyed; this will call `T`'s dtor, if one is defined,
     * and will collect the resources.
     *
     * Complexity: usually $(BIGOH 1), worst case $(BIGOH n).
     */
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

    ///
    @safe unittest
    {
        auto a = [1, 2, 3];
        auto dl = DList!int(a);
        size_t i = 0;
        while (!dl.empty)
        {
            assert(dl.front == a[i++]);
            dl.popFront;
        }
        assert(dl.empty);
    }

    /**
     * Go to the previous element in the list. The user must check
     * that the list isn't `empty`, prior to calling this function.
     *
     * If this was the first element in the list and there are no more
     * references to the current list, then the list and all it's elements
     * will be destroyed; this will call `T`'s dtor, if one is defined,
     * and will collect the resources.
     *
     * Complexity: usually $(BIGOH 1), worst case $(BIGOH n).
     */
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

    ///
    @safe unittest
    {
        auto dl = DList!int([1, 2, 3]);
        dl.popFront;
        assert(dl.front == 2);
        dl.popPrev;
        assert(dl.front == 1);
        dl.popPrev;
        assert(dl.empty);
    }

    /**
     * Advance to the next element in the list. The user must check
     * that the list isn't `empty`, prior to calling this function.
     *
     * This must be used in order to iterate through a `const` or `immutable`
     * list. For a mutable list this is equivalent to calling `popFront`.
     *
     * Returns:
     *      a list that starts with the next element in the original list
     *
     * Complexity: $(BIGOH 1).
     */
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
            return typeof(this)(_head._next, _allocator);
        }
        else
        {
            return .tail(this);
        }
    }

    ///
    @safe unittest
    {
        auto idl = immutable DList!int([1, 2, 3]);
        assert(idl.tail.front == 2);
    }

    /**
     * Eagerly iterate over each element in the list and call `fun` over each
     * element. This should be used to iterate through `const` and `immutable`
     * lists.
     *
     * Normally, the entire list is iterated. If partial iteration (early stopping)
     * is desired, `fun` needs to return a value of type
     * $(REF Flag, std,typecons)`!"each"` (`Yes.each` to continue iteration, or
     * `No.each` to stop).
     *
     * Params:
     *      fun = unary function to apply on each element of the list.
     *
     * Returns:
     *      `Yes.each` if it has iterated through all the elements in the list,
     *      or `No.each` otherwise.
     *
     * Complexity: $(BIGOH n).
     */
    template each(alias fun)
    {
        import std.typecons : Flag, Yes, No;
        import std.functional : unaryFun;
        import stdx.collections.slist : SList;

        Flag!"each" each(this Q)()
        if (is (typeof(unaryFun!fun(T.init))))
        {
            alias fn = unaryFun!fun;

            auto sl = SList!(const DList!T)(this);
            while (!sl.empty && !sl.front.empty)
            {
                static if (!is(typeof(fn(T.init)) == Flag!"each"))
                {
                    cast(void) fn(sl.front.front);
                }
                else
                {
                    if (fn(sl.front.front) == No.each)
                        return No.each;
                }
                sl ~= sl.front.tail;
                sl.popFront;
            }
            return Yes.each;
        }
    }

    ///
    @safe unittest
    {
        import std.typecons : Flag, Yes, No;

        auto idl = immutable DList!int([1, 2, 3]);

        static bool foo(int x) { return x > 0; }

        assert(idl.each!foo == Yes.each);
    }

    /**
     * Perform a shallow copy of the list.
     *
     * Returns:
     *      a new reference to the current list.
     *
     * Complexity: $(BIGOH 1).
     */
    ref Qualified save(this Qualified)()
    {
        debug(CollectionDList)
        {
            writefln("DList.save: begin");
            scope(exit) writefln("DList.save: end");
        }
        return this;
    }

    ///
    @safe unittest
    {
        auto a = [1, 2, 3];
        auto dl = DList!int(a);
        size_t i = 0;

        auto tmp = dl.save;
        while (!tmp.empty)
        {
            assert(tmp.front == a[i++]);
            tmp.popFront;
        }
        assert(tmp.empty);
        assert(!dl.empty);
    }

    /**
     * Perform a copy of the list. This will create a new list that will copy
     * the elements of the current list. This will `NOT` call `dup` on the
     * elements of the list, regardless if `T` defines it or not.
     *
     * Returns:
     *      a new list.
     *
     * Complexity: $(BIGOH n).
     */
    typeof(this) dup()
    {
        debug(CollectionDList)
        {
            writefln("DList.dup: begin");
            scope(exit) writefln("DList.dup: end");
        }

        DList!T result;
        result._allocator = _allocator;

        // TODO: this should rewind the list
        static if (is(Q == immutable) || is(Q == const))
        {
            auto tmp = this;
            while(!tmp.empty)
            {
                result ~= tmp.front;
                tmp = tmp.tail;
            }
        }
        else
        {
            result.insert(0, this);
        }
        return result;
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto dl = DList!int(1, 2, 3);
        auto dlDup = dl.dup;
        assert(equal(dl, dlDup));
        dlDup.front = 0;
        assert(!equal(dl, dlDup));
        assert(dlDup.front == 0);
        assert(dl.front == 1);
    }

    /**
     * Inserts the elements of an
     * $(REF_ALTTEXT input range, isInputRange, std,range,primitives), or a
     * variable number of items, at the given `pos`.
     *
     * If no allocator was provided when the list was created, the
     * $(REF, GCAllocator, std,experimental,allocator) will be used.
     *
     * Params:
     *      pos = a positive integral
     *      stuff = an input range of elements that are implitictly convertible
     *              to `T`; a variable number of items either in the form of a
     *              list or as a built-in array
     *
     * Returns:
     *      the number of elements inserted
     *
     * Complexity: $(BIGOH pos + m), where `m` is the number of elements in the range.
     */
    size_t insert(Stuff)(size_t pos, Stuff stuff)
    if (isInputRange!Stuff && isImplicitlyConvertible!(ElementType!Stuff, T))
    {
        debug(CollectionDList)
        {
            writefln("DList.insert: begin");
            scope(exit) writefln("DList.insert: end");
        }

        // Will be optimized away, but the type system infers T's safety
        if (0) { T t = T.init; }

        // Ensure we have an allocator. If it was already set, this will do nothing
        auto a = threadAllocatorObject();
        setAllocator(a);

        size_t result;
        Node *tmpNode;
        Node *tmpHead;
        foreach (item; stuff)
        {
            Node *newNode;
            () @trusted { newNode = _allocator.make!(Node)(item, null, null); }();
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

    /// ditto
    size_t insert(Stuff)(size_t pos, Stuff[] stuff...)
    if (isImplicitlyConvertible!(Stuff, T))
    {
        return insert(pos, stuff);
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto d = DList!int(4, 5);
        DList!int dl;
        assert(dl.empty);

        size_t pos = 0;
        pos += dl.insert(pos, 1);
        pos += dl.insert(pos, [2, 3]);
        assert(equal(dl, [1, 2, 3]));

        // insert from an input range
        pos += dl.insert(pos, d);
        assert(equal(dl, [1, 2, 3, 4, 5]));
        d.front = 0;
        assert(equal(dl, [1, 2, 3, 4, 5]));
    }

    /**
     * Inserts the elements of an
     * $(REF_ALTTEXT input range, isInputRange, std,range,primitives), or a
     * variable number of items, at the end of the list.
     *
     * If no allocator was provided when the list was created, the
     * $(REF, GCAllocator, std,experimental,allocator) will be used.
     *
     * Params:
     *      stuff = an input range of elements that are implitictly convertible
     *              to `T`; a variable number of items either in the form of a
     *              list or as a built-in array
     *
     * Returns:
     *      the number of elements inserted
     *
     * Complexity: $(BIGOH pos + m), where `m` is the number of elements in the range.
     */
    size_t insertBack(Stuff)(Stuff stuff)
    if (isInputRange!Stuff && isImplicitlyConvertible!(ElementType!Stuff, T))
    {
        debug(CollectionDList)
        {
            writefln("DList.insertBack: begin");
            scope(exit) writefln("DList.insertBack: end");
        }

        // Will be optimized away, but the type system infers T's safety
        if (0) { T t = T.init; }

        // Ensure we have an allocator. If it was already set, this will do nothing
        auto a = threadAllocatorObject();
        setAllocator(a);

        size_t result;
        Node *tmpNode;
        Node *tmpHead;
        foreach (item; stuff)
        {
            Node *newNode;
            () @trusted { newNode = _allocator.make!(Node)(item, null, null); }();
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

    /// ditto
    size_t insertBack(Stuff)(Stuff[] stuff...)
    if (isImplicitlyConvertible!(Stuff, T))
    {
        return insertBack(stuff);
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto d = DList!int(4, 5);
        DList!int dl;
        assert(dl.empty);

        dl.insertBack(1);
        dl.insertBack([2, 3]);
        assert(equal(dl, [1, 2, 3]));

        // insert from an input range
        dl.insertBack(d);
        assert(equal(dl, [1, 2, 3, 4, 5]));
        d.front = 0;
        assert(equal(dl, [1, 2, 3, 4, 5]));
    }

    /**
     * Create a new list that results from the concatenation of this list
     * with `rhs`.
     *
     * Params:
     *      rhs = can be an element that is implicitly convertible to `T`, an
     *            input range of such elements, or another doubly linked list
     *
     * Returns:
     *      the newly created list
     *
     * Complexity: $(BIGOH n + m), where `m` is the number of elements in `rhs`.
     */
    auto ref opBinary(string op, U)(auto ref U rhs)
        if (op == "~" &&
            //(is (U : const typeof(this))
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

        auto newList = this.dup();
        newList.insertBack(rhs);
        return newList;
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto dl = DList!int(1);
        auto dl2 = dl ~ 2;

        assert(equal(dl2, [1, 2]));
        dl.front = 0;
        assert(equal(dl2, [1, 2]));
    }

    /**
     * Assign `rhs` to this list. The current list will now become another
     * reference to `rhs`, unless `rhs` is `null`, in which case the current
     * list will become empty. If `rhs` refers to the current list nothing will
     * happen.
     *
     * All the previous list elements that have no more references to them
     * will be destroyed; this leads to a $(BIGOH n) complexity.
     *
     * Params:
     *      rhs = a reference to a doubly linked list
     *
     * Returns:
     *      a reference to this list
     *
     * Complexity: $(BIGOH n).
     */
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
                    rhs._head._payload, *localPrefCount(rhs._head));
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
        _allocator = rhs._allocator;
        return this;
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto dl = DList!int(1);
        auto dl2 = DList!int(1, 2);

        dl = dl2; // this will free the old dl
        assert(equal(dl, [1, 2]));
        dl.front = 0;
        assert(equal(dl2, [0, 2]));
    }

    /**
     * Append the elements of `rhs` at the end of the list.
     *
     * If no allocator was provided when the list was created, the
     * $(REF, GCAllocator, std,experimental,allocator) will be used.
     *
     * Params:
     *      rhs = can be an element that is implicitly convertible to `T`, an
     *            input range of such elements, or another doubly linked list
     *
     * Returns:
     *      a reference to this list
     *
     * Complexity: $(BIGOH n + m), where `m` is the number of elements in `rhs`.
     */
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

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto d = DList!int(4, 5);
        DList!int dl;
        assert(dl.empty);

        dl ~= 1;
        dl ~= [2, 3];
        assert(equal(dl, [1, 2, 3]));

        // append an input range
        dl ~= d;
        assert(equal(dl, [1, 2, 3, 4, 5]));
        d.front = 0;
        assert(equal(dl, [1, 2, 3, 4, 5]));
    }

    /**
     * Remove the current element from the list. If there are no
     * more references to the current element, then it will be destroyed.
     */
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

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto dl = DList!int(1, 2, 3);
        auto dl2 = dl;

        assert(equal(dl, [1, 2, 3]));
        dl.popFront;
        dl.remove();
        assert(equal(dl, [3]));
        assert(equal(dl2, [1, 3]));
        dl.popPrev;
        assert(equal(dl, [1, 3]));
    }

    debug(CollectionDList)
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
                    tmpNode._payload, *localPrefCount(tmpNode));
            tmpNode = tmpNode._next;
        }
    }
}

version (unittest) private nothrow pure @safe
void testInit(RCIAllocator allocator)
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

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () nothrow pure @safe {
            testInit(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version (unittest) private nothrow pure @safe
void testInsert(RCIAllocator allocator)
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

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () nothrow pure @safe {
            testInsert(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version (unittest) private nothrow pure @safe
void testRemove(RCIAllocator allocator)
{
    import std.algorithm.comparison : equal;

    DList!int dl = DList!int(allocator, 1);
    size_t pos = 0;
    dl.remove();
    assert(dl.empty);
    assert(dl.isUnique);
    assert(!dl._allocator.isNull);

    dl.insert(pos, 2);
    auto dl2 = dl;
    auto dl3 = dl;
    assert(!dl.isUnique);

    dl.popFront();
    assert(dl.empty);
    assert(!dl._allocator.isNull);

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

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () nothrow pure @safe {
            testRemove(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version (unittest) private nothrow pure @safe
void testCopyAndRef(RCIAllocator allocator)
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

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () nothrow pure @safe {
            testCopyAndRef(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

@safe unittest
{
    import std.algorithm.comparison : equal;

    SCAlloc statsCollectorAlloc;
    auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();

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

version(unittest) private nothrow pure @safe
void testImmutability(RCISharedAllocator allocator)
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

version(unittest) private nothrow pure @safe
void testConstness(RCISharedAllocator allocator)
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

@safe unittest
{
    import std.conv;
    import std.experimental.allocator : processAllocator;
    SCAlloc statsCollectorAlloc;
    {
        // TODO: StatsCollector need to be made shareable
        //auto _allocator = sharedAllocatorObject(&statsCollectorAlloc);
        () nothrow pure @safe {
            testConstness(processAllocatorObject());
            testImmutability(processAllocatorObject());
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private nothrow pure @safe
void testConcatAndAppend(RCIAllocator allocator)
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

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () nothrow pure @safe {
            testConcatAndAppend(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private nothrow pure @safe
void testAssign(RCIAllocator allocator)
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

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () nothrow pure @safe {
            testAssign(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private nothrow pure @safe
void testWithStruct(RCIAllocator allocator, RCISharedAllocator sharedAlloc)
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

        auto immListOfLists = immutable DList!(DList!int)(sharedAlloc, list);
        assert(immListOfLists.front.front == 2);
        static assert(!__traits(compiles, immListOfLists.front.front = 2));
    }
    assert(equal(list, [2, 2, 3]));
}

@safe unittest
{
    import std.conv;
    import std.experimental.allocator : processAllocator;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () nothrow pure @safe {
            testWithStruct(_allocator, processAllocatorObject());
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private nothrow pure @safe
void testWithClass(RCIAllocator allocator)
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

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () nothrow pure @safe {
            testWithClass(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "DList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}
