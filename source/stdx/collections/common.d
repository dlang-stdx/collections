/**
Utility and ancillary artifacts of `stdx.collections`.
*/
module stdx.collections.common;
import std.range: isInputRange;

auto tail(Collection)(Collection collection)
    if (isInputRange!Collection)
{
    collection.popFront();
    return collection;
}

struct Mutable(T)
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           theAllocator, processAllocator, dispose;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import std.variant : Algebraic;
    import core.atomic : atomicOp;

    private struct RefCountedMutable
    {
        DualAllocator!(RCIAllocator, RCISharedAllocator) _alloc;
        T _payload;
        size_t _rc;
    }

    private void[] _mutableSupport;

    alias LocalAllocT = AffixAllocator!(RCIAllocator, RefCountedMutable);
    alias SharedAllocT = shared AffixAllocator!(RCISharedAllocator, RefCountedMutable);
    //alias AllocT = Algebraic!(LocalAllocT, SharedAllocT);
    alias AllocT = DualAllocator!(LocalAllocT, SharedAllocT);
    pragma(msg, AllocT.stringof);
    private AllocT _mutableAllocator;

    this(this Q)(T theMutable)
    {
        static if (is(Q == immutable) || is(Q == const))
        {
            this(processAllocator, theMutable);
        }
        else
        {
            this(theAllocator, theMutable);
        }
    }

    this(A, this Q)(A alloc, T theMutable)
    if (((is(Q == immutable) || is(Q == const)) && is(A == RCISharedAllocator))
        || (!(is(Q == immutable) || is(Q == const)) && is(A == RCIAllocator)))
    {
        static if (is(A == RCIAllocator))
        {
            auto t = LocalAllocT(alloc);
        }
        else
        {
            auto t = SharedAllocT(alloc);
        }
        auto tSupport = (() @trusted => t.allocate(1))();
        () @trusted {
            pragma(msg, typeof(t.prefix(tSupport)._alloc).stringof);
            pragma(msg, typeof(alloc).stringof);
            t.prefix(tSupport)._alloc = alloc;
            t.prefix(tSupport)._payload = theMutable;
        }();
        _mutableSupport = (() @trusted => cast(typeof(_mutableSupport))(tSupport))();
        _mutableAllocator = (() @trusted => cast(typeof(_mutableAllocator))(t))();
    }

    this(this) @trusted
    {
        if (_mutableSupport !is null)
        {
            addRef(_mutableAllocator, _mutableSupport);
        }
    }

    @trusted auto ref allocator(this Q)()
    {
        static if (is(Q == immutable) || is(Q == const))
        {
            assert(_mutableAllocator.peek!(SharedAllocT) !is null);
            return _mutableAllocator.get!(SharedAllocT);
        }
        else
        {
            assert(_mutableAllocator.peek!(LocalAllocT) !is null);
            return _mutableAllocator.get!(LocalAllocT);
        }
    }

    @trusted void addRef(AllocQ, SupportQ, this Q)(AllocQ alloc, SupportQ support)
    {
        assert(support !is null);
        static if (is(Q == immutable) || is(Q == const))
        {
            auto p = cast(shared uint*)(&allocator.prefix(support)._rc);
            atomicOp!"+="(*p, 1);
        }
        else
        {
            ++allocator.prefix(support)._rc;
        }
    }

    ~this() @trusted
    {
        if (_mutableSupport !is null)
        {
            if (allocator.prefix(_mutableSupport)._rc == 0)
            {
                auto origAlloc = allocator.prefix(_mutableSupport)._alloc;
                if (_mutableAllocator.peek!(SharedAllocT) !is null)
                {
                    auto disposer = SharedAllocT(origAlloc.get!(RCISharedAllocator));
                    disposer.dispose(_mutableSupport);
                }
                else
                {
                    auto disposer = LocalAllocT(origAlloc.get!(RCIAllocator));
                    disposer.dispose(_mutableSupport);
                }
            }
            else
            {
                --allocator.prefix(_mutableSupport)._rc;
            }
        }
    }

    auto ref opAssign()(auto ref typeof(this) rhs)
    {
        if (rhs._mutableSupport !is null
            && _mutableSupport is rhs._mutableSupport)
        {
            return this;
        }
        if (rhs._mutableSupport !is null)
        {
            addRef(rhs._mutableAllocator, rhs._mutableSupport);
        }
        __dtor();
        _mutableSupport = rhs._mutableSupport;
        _mutableAllocator = rhs._mutableAllocator;
        return this;
    }

    bool isNull(this _)()
    {
        return _mutableSupport is null;
    }

    auto ref get(this Q)()
    {
        static if (is(Q == immutable) || is(Q == const))
        {
            alias PayloadType = typeof(allocator.prefix(_mutableSupport)._payload);
            //pragma(msg, "pld type is " ~ typeof(PayloadType).stringof);
            return cast(shared PayloadType)(allocator.prefix(_mutableSupport)._payload);
        }
        else
        {
            return allocator.prefix(_mutableSupport)._payload;
        }
    }

    void set(T v)
    {
        allocator.prefix(_mutableSupport)._payload = v;
    }
}

@safe unittest
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           theAllocator, processAllocator, dispose;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import std.variant : Algebraic;
    //auto a = Mutable!(RCISharedAllocator)(processAllocator, processAllocator);
    //auto a = immutable Mutable!(RCISharedAllocator)(processAllocator);
    //auto a = shared Mutable!(RCIAllocator)(theAllocator, theAllocator);
    RCISharedAllocator al;
    assert(al.isNull);
    al = processAllocator();
    Algebraic!(RCIAllocator, RCISharedAllocator) _alloc;
    //_alloc = al;

    //alias AllocT = Algebraic!(AffixAllocator!(RCIAllocator, int),
                              //AffixAllocator!(shared RCISharedAllocator, int));
    //AllocT _mutableAllocator;
}

@safe unittest
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           theAllocator, processAllocator, dispose;
    import std.experimental.allocator.building_blocks.affix_allocator;

    struct RefCountedMutable(T)
    {
        DualAllocator!(RCIAllocator, RCISharedAllocator) _alloc;
        T _payload;
        size_t _rc;
    }

    //alias SharedAllocT = shared AffixAllocator!(RCISharedAllocator, RefCountedMutable!RCISharedAllocator);
    //pragma(msg, is(RCISharedAllocator == shared));
    //SharedAllocT a = SharedAllocT(processAllocator);
    //() @trusted shared {
        //auto buf = a.allocate(10);
        //assert(buf.length == 10);
    //}();

    alias T = RCIAllocator;
    alias LocalAllocT = AffixAllocator!(RCIAllocator, RefCountedMutable!T);
    alias TT = RCISharedAllocator;
    alias SharedAllocT = shared AffixAllocator!(RCISharedAllocator, RefCountedMutable!TT);
    //alias AllocT = Algebraic!(LocalAllocT, SharedAllocT);
    //alias AllocT = DualAllocator!(LocalAllocT, SharedAllocT);
    alias AllocT = OldDualAllocator!(LocalAllocT, SharedAllocT);
    AllocT _mutableAllocator;
}

struct OldDualAllocator(LocalAllocT, SharedAllocT)
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator;
    import std.traits : Unqual;

    private union Allocator
    {
        LocalAllocT localAlloc;
        SharedAllocT sharedAlloc;
    }

    bool _isShared = false;
    Allocator _alloc;

    this(A, this Q)(A alloc) @trusted
    {
        static if (is(Q == immutable))
        {
            _isShared = true;
            _alloc.sharedAlloc = cast(typeof(_alloc.sharedAlloc)) alloc;
        }
        else
        {
            _alloc.localAlloc = alloc;
        }
    }

    //this(this);

    //~this();

    inout(T)* peek(T)() inout
    if (is(T == LocalAllocT) || is(T == SharedAllocT))
    {
        static if (is(T == SharedAllocT))
        {
            assert(_isShared);
            return _alloc.sharedAlloc.isNull ? null : &_alloc.sharedAlloc;
        }
        else
        {
            return _alloc.localAlloc.isNull ? null : &_alloc.localAlloc;
        }
    }

    auto ref get(T, this _)()
    if (is(T == LocalAllocT) || is(T == SharedAllocT))
    {
        static if (is(T == SharedAllocT))
        {
            assert(_isShared);
            return _alloc.sharedAlloc;
        }
        else
        {
            return _alloc.localAlloc;
        }
    }
}

@safe unittest
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           theAllocator, processAllocator, dispose;
    import std.exception : enforce;

    auto a = OldDualAllocator!(RCIAllocator, RCISharedAllocator)(theAllocator);
    assert(!a._isShared);
    //assert(a.peek!(RCISharedAllocator)() !is null);
    //assert(a.get!(RCISharedAllocator).isNull);
    //pragma(msg, typeof(a.peek!(RCIAllocator)()).stringof);

    auto b = immutable OldDualAllocator!(RCIAllocator, RCISharedAllocator)(processAllocator);
    assert(b._isShared);
    assert(!b.get!(RCISharedAllocator).isNull);
    assert(!b.get!(RCIAllocator).isNull);

    OldDualAllocator!(RCIAllocator, RCISharedAllocator) c;
    assert(c.get!(RCIAllocator).isNull);
}

struct DualAllocator(LocalAllocT, SharedAllocT)
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator;
    import std.typecons : Ternary;
    import std.traits : Unqual;

    private LocalAllocT localAlloc;
    private SharedAllocT sharedAlloc;

    this(A, this Q)(A alloc) @trusted
    {
        static if (is(Q == immutable))
        {
            sharedAlloc = cast(typeof(sharedAlloc)) alloc;
            //sharedAlloc = alloc;
        }
        else
        {
            localAlloc = alloc;
        }
    }

    this(this) inout {}

    auto ref opAssign(A)(A rhs)
    if (is(A == LocalAllocT) || is(A == SharedAllocT))
    {
        static if (is(A == shared))
        {
            pragma(msg, "JAAAAA");
            sharedAlloc = rhs;
        }
        else
        {
            localAlloc = rhs;
        }
        return this;
    }

    // Only works for stateful allocators
    inout(T)* peek(T)() inout @trusted
    if (is(T == LocalAllocT) || is(T == SharedAllocT))
    {
        static if (is(T == SharedAllocT))
        {
            alias ST = typeof(sharedAlloc);
            return sharedAlloc == ST.init ? null : &sharedAlloc;
        }
        else
        {
            alias LT = typeof(localAlloc);
            return localAlloc == LT.init ? null : &localAlloc;
        }
    }

    auto ref get(T, this _)()
    if (is(T == LocalAllocT) || is(T == SharedAllocT))
    {
        static if (is(T == SharedAllocT))
        {
            return sharedAlloc;
        }
        else
        {
            return localAlloc;
        }
    }

    //Forward to thread local allocator

    //@property uint alignment()
    //{
        //return localAlloc.alignment();
    //}

    //size_t goodAllocSize(size_t s)
    //{
        //return localAlloc.goodAllocSize(s);
    //}

    void[] allocate(size_t n)
    {
        return localAlloc.allocate(n);
    }

    //void[] alignedAllocate(size_t n, uint a)
    //{
        //return localAlloc.alignedAllocate(n, a);
    //}

    //void[] allocateAll()
    //{
        //return localAlloc.allocateAll();
    //}

    //bool expand(ref void[] b, size_t size)
    //{
        //return localAlloc.expand(b, size);
    //}

    //bool reallocate(ref void[] b, size_t size)
    //{
        //return localAlloc.reallocate(b, size);
    //}

    //bool alignedReallocate(ref void[] b, size_t size, uint alignment)
    //{
        //return localAlloc.alignedReallocate(b, size, alignment);
    //}

    //Ternary owns(void[] b)
    //{
        //return localAlloc.owns(b);
    //}

    //Ternary resolveInternalPointer(const void* p, ref void[] result)
    //{
        //return localAlloc.resolveInternalPointer(p, result);
    //}

    bool deallocate(void[] b)
    {
        return localAlloc.deallocate(b);
    }

    //bool deallocateAll()
    //{
        //return localAlloc.deallocateAll();
    //}

    //Ternary empty()
    //{
        //return localAlloc.empty();
    //}


    // Forward to shared allocator

    //@property uint alignment() shared
    //{
        //return sharedAlloc.alignment();
    //}

    //size_t goodAllocSize(size_t s) shared
    //{
        //return sharedAlloc.goodAllocSize(s);
    //}

    void[] allocate(size_t n) shared
    {
        return sharedAlloc.allocate(n);
    }

    //void[] alignedAllocate(size_t n, uint a) shared
    //{
        //return sharedAlloc.alignedAllocate(n, a);
    //}

    //void[] allocateAll() shared
    //{
        //return sharedAlloc.allocateAll();
    //}

    //bool expand(ref void[] b, size_t size) shared
    //{
        //return sharedAlloc.expand(b, size);
    //}

    //bool reallocate(ref void[] b, size_t size) shared
    //{
        //return sharedAlloc.reallocate(b, size);
    //}

    //bool alignedReallocate(ref void[] b, size_t size, uint alignment) shared
    //{
        //return sharedAlloc.alignedReallocate(b, size, alignment);
    //}

    //Ternary owns(void[] b) shared
    //{
        //return sharedAlloc.owns(b);
    //}

    //Ternary resolveInternalPointer(const void* p, ref void[] result) shared
    //{
        //return sharedAlloc.resolveInternalPointer(p, result);
    //}

    bool deallocate(void[] b) shared
    {
        return sharedAlloc.deallocate(b);
    }

    //bool deallocateAll() shared
    //{
        //return sharedAlloc.deallocateAll();
    //}

    //Ternary empty() shared
    //{
        //return sharedAlloc.empty();
    //}
}

@safe unittest
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           theAllocator, processAllocator, dispose;
    import std.exception : enforce;

    auto a = DualAllocator!(RCIAllocator, RCISharedAllocator)(theAllocator);
    assert(a.peek!(RCISharedAllocator) is null);
    assert(a.peek!(RCIAllocator) !is null);
    assert(a.get!(RCISharedAllocator).isNull);
    assert(!a.get!(RCIAllocator).isNull);
    //pragma(msg, typeof(a.peek!(RCIAllocator)()).stringof);

    auto b = immutable DualAllocator!(RCIAllocator, RCISharedAllocator)(processAllocator);
    //assert(b._isShared);
    //assert(!b.get!(RCISharedAllocator).isNull);
    //assert(!b.get!(RCIAllocator).isNull);

    //OldDualAllocator!(RCIAllocator, RCISharedAllocator) c;
    //assert(c.get!(RCIAllocator).isNull);
}
