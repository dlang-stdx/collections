///
module stdx.collections.slist;

import stdx.collections.common;

debug(CollectionSList) import std.stdio;

version(unittest)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator.building_blocks.stats_collector;
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           allocatorObject, sharedAllocatorObject;

    private alias SCAlloc = StatsCollector!(Mallocator, Options.bytesUsed);
}

///
struct SList(T)
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
    // TODO: should this be static struct?
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

    // State {
    Node *_head;
    AllocatorHandler _allocator;
    // }

    /// Constructs the ouroboros allocator from allocator if the ouroboros
    //allocator wasn't previously set
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
        //if (_allocator.opPrefix!("-=")(cast(void[Node.sizeof])(*node), 1) == 0)
        //{
            //debug(CollectionSList) writefln("SList.delRef: Deleting node %s", node._payload);
            //dispose(_allocator, node);
            //node = null;
        //}
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
                    ~"_allocator.make!(Node)(item, null);"
                ~"}();"
                ~"(tmpHead ? tmpNode._next : tmpHead) = newNode;"
                ~"tmpNode = newNode;"
            ~"}"
            ~"_head = (() @trusted => cast(immutable Node*)(tmpHead))();";
    }

public:
    /**
     * Constructs a qualified singly linked list that will use the provided
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
        debug(CollectionSList)
        {
            writefln("SList.ctor: begin");
            scope(exit) writefln("SList.ctor: end");
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
        auto sl = SList!int(theAllocator);
        auto csl = const SList!int(processAllocator);
        auto isl = immutable SList!int(processAllocator);
    }

    /**
     * Constructs a qualified singly linked list out of a number of items.
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
            auto sl = SList!int(1, 2, 3);
            assert(equal(sl, [1, 2, 3]));
        }
        // Create a list from an array of ints
        {
            auto sl = SList!int([1, 2, 3]);
            assert(equal(sl, [1, 2, 3]));
        }
        // Create a list from a list from an input range
        {
            auto sl = SList!int(1, 2, 3);
            auto sl2 = SList!int(sl);
            assert(equal(sl2, [1, 2, 3]));
        }
    }

    /**
     * Constructs a qualified singly linked list out of a number of items
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
        debug(CollectionSList)
        {
            writefln("SList.ctor: begin");
            scope(exit) writefln("SList.ctor: end");
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
     * Constructs a qualified singly linked list out of an
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
     * Constructs a qualified singly linked list out of an
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
        debug(CollectionSList)
        {
            writefln("SList.ctor: begin");
            scope(exit) writefln("SList.ctor: end");
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
        debug(CollectionSList)
        {
            writefln("SList.postblit: begin");
            scope(exit) writefln("SList.postblit: end");
        }
        _allocator.bootstrap();
        if (_head !is null)
        {
            addRef(_head);
            debug(CollectionSList) writefln("SList.postblit: Node %s has refcount: %s",
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
            debug(CollectionSList) writefln("SList.ctor immutable: Node %s has "
                    ~ "refcount: %s", _head._payload, *sharedPrefCount(_head));
        }
    }

    ~this()
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

    nothrow pure @safe unittest
    {
        auto s = SList!int(1, 2, 3);

        // Infer safety
        static assert(!__traits(compiles, () @safe { SList!Unsafe(Unsafe(1)); }));
        static assert(!__traits(compiles, () @safe { auto s = const SList!Unsafe(Unsafe(1)); }));
        static assert(!__traits(compiles, () @safe { auto s = immutable SList!Unsafe(Unsafe(1)); }));

        static assert(!__traits(compiles, () @safe { SList!UnsafeDtor(UnsafeDtor(1)); }));
        static assert(!__traits(compiles, () @safe { auto s = const SList!UnsafeDtor(UnsafeDtor(1)); }));
        static assert(!__traits(compiles, () @safe { auto s = immutable SList!UnsafeDtor(UnsafeDtor(1)); }));

        // Infer purity
        static assert(!__traits(compiles, () pure { SList!Impure(Impure(1)); }));
        static assert(!__traits(compiles, () pure { auto s = const SList!Impure(Impure(1)); }));
        static assert(!__traits(compiles, () pure { auto s = immutable SList!Impure(Impure(1)); }));

        static assert(!__traits(compiles, () pure { SList!ImpureDtor(ImpureDtor(1)); }));
        static assert(!__traits(compiles, () pure { auto s = const SList!ImpureDtor(ImpureDtor(1)); }));
        static assert(!__traits(compiles, () pure { auto s = immutable SList!ImpureDtor(ImpureDtor(1)); }));

        // Infer throwability
        static assert(!__traits(compiles, () nothrow { SList!Throws(Throws(1)); }));
        static assert(!__traits(compiles, () nothrow { auto s = const SList!Throws(Throws(1)); }));
        static assert(!__traits(compiles, () nothrow { auto s = immutable SList!Throws(Throws(1)); }));

        static assert(!__traits(compiles, () nothrow { SList!ThrowsDtor(ThrowsDtor(1)); }));
        static assert(!__traits(compiles, () nothrow { auto s = const SList!ThrowsDtor(ThrowsDtor(1)); }));
        static assert(!__traits(compiles, () nothrow { auto s = immutable SList!ThrowsDtor(ThrowsDtor(1)); }));
    }

    private void destroyUnused()
    {
        debug(CollectionSList)
        {
            writefln("SList.destoryUnused: begin");
            scope(exit) writefln("SList.destoryUnused: end");
        }
        while (_head !is null && opCmpPrefix!"=="(_head, 0))
        {
            debug(CollectionSList) writefln("SList.destoryUnused: One ref with head at %s",
                    _head._payload);
            Node *tmpNode = _head;
            _head = _head._next;
            delRef(tmpNode);
        }

        if (_head !is null && opCmpPrefix!">"(_head, 0))
        {
            // We reached a copy, so just remove the head ref, thus deleting
            // the copy in constant time (we are undoing the postblit)
            debug(CollectionSList) writefln("SList.destoryUnused: Multiple refs with head at %s",
                    _head._payload);
            delRef(_head);
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
        debug(CollectionSList)
        {
            writefln("SList.isUnique: begin");
            scope(exit) writefln("SList.isUnique: end");
        }

        // TODO: change this to tail-impl for const/imm types
        Node *tmpNode = (() @trusted => cast(Node*)_head)();
        while (tmpNode !is null)
        {
            if (opCmpPrefix!">"(tmpNode, 0))
            {
                return false;
            }
            tmpNode = tmpNode._next;
        }
        return true;
    }

    ///
    @safe unittest
    {
        auto sl = SList!int(24, 42);
        assert(sl.isUnique);
        {
            auto sl2 = sl;
            assert(!sl.isUnique);
            sl2.front = 0;
            assert(sl.front == 0);
        } // sl2 goes out of scope
        assert(sl.isUnique);
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
        SList!int sl;
        assert(sl.empty);
        size_t pos = 0;
        sl.insert(pos, 1);
        assert(!sl.empty);
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
        assert(!empty, "SList.front: List is empty");
        return _head._payload;
    }

    ///
    @safe unittest
    {
        auto sl = SList!int(1, 2, 3);
        assert(sl.front == 1);
        sl.front = 0;
        assert(sl.front == 0);
    }

    /**
     * Advance to the next element in the list. The user must check
     * that the list isn't `empty`, prior to calling this function.
     *
     * If there are no more references to the current element (which is being
     * consumed), then the current element will be destroyed; this will call
     * `T`'s dtor, if one is defined, and will collect it's resources.
     *
     * Complexity: $(BIGOH 1).
     */
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
        if (opCmpPrefix!">"(tmpNode, 0) && _head !is null)
        {
            // If we have another copy of the list then the refcount
            // must increase, otherwise it will remain the same
            // This condition is needed because the recounting is zero based
            addRef(_head);
        }
        delRef(tmpNode);
    }

    ///
    @safe unittest
    {
        auto a = [1, 2, 3];
        auto sl = SList!int(a);
        size_t i = 0;
        while (!sl.empty)
        {
            assert(sl.front == a[i++]);
            sl.popFront;
        }
        assert(sl.empty);
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
        debug(CollectionSList)
        {
            writefln("SList.tail: begin");
            scope(exit) writefln("SList.tail: end");
        }
        assert(!empty, "SList.tail: List is empty");

        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            return Qualified(_head._next, _allocator);
        }
        else
        {
            return .tail(this);
        }
    }

    ///
    @safe unittest
    {
        auto isl = immutable SList!int([1, 2, 3]);
        assert(isl.tail.front == 2);
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

        Flag!"each" each(this Q)()
        if (is (typeof(unaryFun!fun(T.init))))
        {
            alias fn = unaryFun!fun;

            auto sl = SList!(const SList!T)(this);
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

        auto isl = immutable SList!int([1, 2, 3]);

        static bool foo(int x) { return x > 0; }

        assert(isl.each!foo == Yes.each);
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
        debug(CollectionSList)
        {
            writefln("SList.save: begin");
            scope(exit) writefln("SList.save: end");
        }
        return this;
    }

    ///
    @safe unittest
    {
        auto a = [1, 2, 3];
        auto sl = SList!int(a);
        size_t i = 0;

        auto tmp = sl.save;
        while (!tmp.empty)
        {
            assert(tmp.front == a[i++]);
            tmp.popFront;
        }
        assert(tmp.empty);
        assert(!sl.empty);
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
    SList!T dup(this Q)()
    {
        debug(CollectionSList)
        {
            writefln("SList.dup: begin");
            scope(exit) writefln("SList.dup: end");
        }

        SList!T result;
        result._allocator = _allocator;

        static if (is(Q == immutable) || is(Q == const))
        {
            static void appendEach(ref SList!T sl, const SList!T isl)
            {
                if (isl.empty) return;
                sl ~= isl.front;
                appendEach(sl, isl.tail);
            }

            appendEach(result, this);
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

        auto stuff = [1, 2, 3];
        auto sl = immutable SList!int(stuff);
        auto slDup = sl.dup;
        assert(equal(slDup, stuff));
        slDup.front = 0;
        assert(slDup.front == 0);
        assert(sl.front == 1);
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
     *      pos = a positive integer
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
        debug(CollectionSList)
        {
            writefln("SList.insert: begin");
            scope(exit) writefln("SList.insert: end");
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
            () @trusted { newNode = _allocator.make!(Node)(item, null); }();
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

        auto s = SList!int(4, 5);
        SList!int sl;
        assert(sl.empty);

        size_t pos = 0;
        pos += sl.insert(pos, 1);
        pos += sl.insert(pos, [2, 3]);
        assert(equal(sl, [1, 2, 3]));

        // insert from an input range
        pos += sl.insert(pos, s);
        assert(equal(sl, [1, 2, 3, 4, 5]));
        s.front = 0;
        assert(equal(sl, [1, 2, 3, 4, 5]));
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
        debug(CollectionSList)
        {
            writefln("SList.insertBack: begin");
            scope(exit) writefln("SList.insertBack: end");
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
            () @trusted { newNode = _allocator.make!(Node)(item, null); }();
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

        auto s = SList!int(4, 5);
        SList!int sl;
        assert(sl.empty);

        sl.insertBack(1);
        sl.insertBack([2, 3]);
        assert(equal(sl, [1, 2, 3]));

        // insert from an input range
        sl.insertBack(s);
        assert(equal(sl, [1, 2, 3, 4, 5]));
        s.front = 0;
        assert(equal(sl, [1, 2, 3, 4, 5]));
    }

    /**
     * Create a new list that results from the concatenation of this list
     * with `rhs`.
     *
     * Params:
     *      rhs = can be an element that is implicitly convertible to `T`, an
     *            input range of such elements, or another singly linked list
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
        debug(CollectionSList)
        {
            writefln("SList.opBinary!~: begin");
            scope(exit) writefln("SList.opBinary!~: end");
        }

        auto newList = this.dup();
        newList.insertBack(rhs);
        return newList;
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto sl = SList!int(1);
        auto sl2 = sl ~ 2;

        assert(equal(sl2, [1, 2]));
        sl.front = 0;
        assert(equal(sl2, [1, 2]));
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
     *      rhs = a reference to a singly linked list
     *
     * Returns:
     *      a reference to this list
     *
     * Complexity: $(BIGOH n).
     */
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
        _allocator = rhs._allocator;
        return this;
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto sl = SList!int(1);
        auto sl2 = SList!int(1, 2);

        sl = sl2; // this will free the old sl
        assert(equal(sl, [1, 2]));
        sl.front = 0;
        assert(equal(sl2, [0, 2]));
    }

    /**
     * Append the elements of `rhs` at the end of the list.
     *
     * If no allocator was provided when the list was created, the
     * $(REF, GCAllocator, std,experimental,allocator) will be used.
     *
     * Params:
     *      rhs = can be an element that is implicitly convertible to `T`, an
     *            input range of such elements, or another singly linked list
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
        debug(CollectionSList)
        {
            writefln("SList.opOpAssign!~: %s begin", typeof(this).stringof);
            scope(exit) writefln("SList.opOpAssign!~: %s end", typeof(this).stringof);
        }

        insertBack(rhs);
        return this;
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto s = SList!int(4, 5);
        SList!int sl;
        assert(sl.empty);

        sl ~= 1;
        sl ~= [2, 3];
        assert(equal(sl, [1, 2, 3]));

        // append an input range
        sl ~= s;
        assert(equal(sl, [1, 2, 3, 4, 5]));
        s.front = 0;
        assert(equal(sl, [1, 2, 3, 4, 5]));
    }

    /**
     * Remove the element at the given `idx` from the list. If there are no
     * more references to the given element, then it will be destroyed.
     *
     * Params:
     *      idx = a positive integer
     */
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

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;

        auto sl = SList!int(1, 2, 3);
        auto sl2 = sl;
        auto pos = 1;

        assert(equal(sl, [1, 2, 3]));
        sl.remove(pos);
        assert(equal(sl, [1, 3]));
        assert(equal(sl2, [1, 3]));
    }

    debug(CollectionSList)
    void printRefCount() const
    {
        writefln("SList.printRefCount: begin");
        scope(exit) writefln("SList.printRefCount: end");

        Node *tmpNode = (() @trusted => cast(Node*)_head)();
        while (tmpNode !is null)
        {
            writefln("SList.printRefCount: Node %s has ref count %s",
                    tmpNode._payload, *localPrefCount(tmpNode));
            tmpNode = tmpNode._next;
        }
    }
}

version(unittest) private nothrow pure @safe
void testImmutability(RCISharedAllocator allocator)
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

version(unittest) private nothrow pure @safe
void testConstness(RCISharedAllocator allocator)
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

@safe unittest
{
    import std.conv;
    import std.experimental.allocator : processAllocator;
    SCAlloc statsCollectorAlloc;
    {
        // TODO: StatsCollector need to be made shareable
        //auto _allocator = sharedAllocatorObject(&statsCollectorAlloc);
        () nothrow pure @safe {
            testImmutability(processAllocatorObject());
            testConstness(processAllocatorObject());
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private nothrow pure @safe
void testConcatAndAppend(RCIAllocator allocator)
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
    assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private nothrow pure @safe
void testSimple(RCIAllocator allocator)
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

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () nothrow pure @safe {
            testSimple(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private nothrow pure @safe
void testSimpleImmutable(RCIAllocator allocator)
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

@safe unittest
{
    import std.conv;
    SCAlloc statsCollectorAlloc;
    {
        auto _allocator = (() @trusted => allocatorObject(&statsCollectorAlloc))();
        () nothrow pure @safe {
            testSimpleImmutable(_allocator);
        }();
    }
    auto bytesUsed = statsCollectorAlloc.bytesUsed;
    assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private nothrow pure @safe
void testCopyAndRef(RCIAllocator allocator)
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
    assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}

version(unittest) private nothrow pure @safe
void testWithStruct(RCIAllocator allocator, RCISharedAllocator sharedAlloc)
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

        auto immListOfLists = immutable SList!(SList!int)(sharedAlloc, list);
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
    assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
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
        auto sl = SList!MyClass(allocator, c);
        assert(sl.front.x == 10);
        assert(sl.front is c);
        sl.front.x = 20;
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
    assert(bytesUsed == 0, "SList ref count leaks memory; leaked "
            ~ to!string(bytesUsed) ~ " bytes");
}
