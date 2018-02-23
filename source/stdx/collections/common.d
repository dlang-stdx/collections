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
           theAllocator, processAllocator, dispose, stateSize;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import std.variant : Algebraic;
    import core.atomic : atomicOp;
    import std.algorithm.mutation : move;

    private static struct RefCountedMutable
    {
        DualAllocatorU!(RCIAllocator, RCISharedAllocator) _alloc;
        T _payload;
        size_t _rc;
    }

    private void[] _mutableSupport;

    alias LocalAllocT = AffixAllocator!(RCIAllocator, RefCountedMutable);
    alias SharedAllocT = shared AffixAllocator!(RCISharedAllocator, RefCountedMutable);
    //alias AllocT = Algebraic!(LocalAllocT, SharedAllocT);
    //alias AllocT = DualAllocatorU!(LocalAllocT, SharedAllocT);
    //pragma(msg, AllocT.stringof);
    //private AllocT _mutableAllocator;

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
            // TODO: this is opAssign
            t.prefix(tSupport)._alloc = DualAllocatorU!(RCIAllocator, RCISharedAllocator)(alloc);
            //move(DualAllocatorU!(RCIAllocator, RCISharedAllocator)(alloc), t.prefix(tSupport)._alloc);
            t.prefix(tSupport)._payload = theMutable;
        }();
        _mutableSupport = (() @trusted => cast(typeof(_mutableSupport))(tSupport))();
    }

    this(this) @trusted
    {
        if (_mutableSupport !is null)
        {
            addRef(_mutableSupport);
        }
    }

    @trusted void addRef(SupportQ, this Q)(SupportQ support)
    {
        assert(support !is null);
        static if (is(Q == immutable) || is(Q == const))
        {
            auto p = cast(shared uint*)(&SharedAllocT.prefix(support)._rc);
            atomicOp!"+="(*p, 1);
        }
        else
        {
            ++LocalAllocT.prefix(support)._rc;
        }
    }

    ~this() @trusted
    {
        if (_mutableSupport !is null)
        {
            if (LocalAllocT.prefix(_mutableSupport)._rc == 0)
            {
                // Workaround for disabled postblit, though I think move is the
                // correct behaviour
                alias AT = typeof(LocalAllocT.prefix(_mutableSupport)._alloc);
                AT origAlloc;
                move(LocalAllocT.prefix(_mutableSupport)._alloc, origAlloc);
                if (!origAlloc.get!(RCISharedAllocator).isNull)
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
                --LocalAllocT.prefix(_mutableSupport)._rc;
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
            addRef(rhs._mutableSupport);
        }
        __dtor();
        _mutableSupport = rhs._mutableSupport;
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
            return cast(shared PayloadType)(SharedAllocT.prefix(_mutableSupport)._payload);
        }
        else
        {
            return LocalAllocT.prefix(_mutableSupport)._payload;
        }
    }

    void set(T v)
    {
        LocalAllocT.prefix(_mutableSupport)._payload = v;
    }
}

@safe unittest
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           theAllocator, processAllocator, dispose;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import std.variant : Algebraic;

    auto a = Mutable!(RCIAllocator)(theAllocator);
    //auto a = immutable Mutable!(RCISharedAllocator)(processAllocator);
    //auto a = shared Mutable!(RCIAllocator)(theAllocator, theAllocator);
}

struct DualAllocatorU(LocalAllocT, SharedAllocT)
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator;
    import std.traits : Unqual;

    private union LAllocator
    {
        LocalAllocT alloc;
    }

    private union SAllocator
    {
        SharedAllocT alloc;
    }

    bool _isShared = false;
    LAllocator _localAlloc;
    SAllocator _sharedAlloc;

    this(A, this Q)(A alloc) @trusted
    {
        static if (is(Q == immutable))
        {
            _isShared = true;
            _sharedAlloc.alloc = cast(typeof(_sharedAlloc.alloc)) alloc;
        }
        else
        {
            _localAlloc.alloc = alloc;
        }
    }

    @disable this(this);
    //this(this)
    //{
        //_localAlloc.alloc.__xpostblit();
        //_sharedAlloc.alloc.__xpostblit();
    //}

    @disable this(shared this) shared;
    //this(this) shared
    //{
        //assert(_isShared);
        //_localAlloc.alloc.__xpostblit();
        //_sharedAlloc.alloc.__xpostblit();
    //}

    ~this()
    {
        if(_isShared)
        {
            _sharedAlloc.alloc.__xdtor();
        }
        else
        {
            _localAlloc.alloc.__xdtor();
        }
    }

    auto ref get(T, this _)()
    if (is(T == LocalAllocT) || is(T == SharedAllocT))
    {
        static if (is(T == SharedAllocT))
        {
            return _sharedAlloc.alloc;
        }
        else
        {
            return _localAlloc.alloc;
        }
    }

    //Forward to thread local allocator

    @property uint alignment()
    {
        return _localAlloc.alloc.alignment;
    }

    //size_t goodAllocSize(size_t s)
    //{
        //return _localAlloc.alloc.goodAllocSize(s);
    //}

    void[] allocate(size_t n)
    {
        return _localAlloc.alloc.allocate(n);
    }

    //void[] alignedAllocate(size_t n, uint a)
    //{
        //return _localAlloc.alloc.alignedAllocate(n, a);
    //}

    //void[] allocateAll()
    //{
        //return _localAlloc.alloc.allocateAll();
    //}

    //bool expand(ref void[] b, size_t size)
    //{
        //return _localAlloc.alloc.expand(b, size);
    //}

    //bool reallocate(ref void[] b, size_t size)
    //{
        //return _localAlloc.alloc.reallocate(b, size);
    //}

    //bool alignedReallocate(ref void[] b, size_t size, uint alignment)
    //{
        //return _localAlloc.alloc.alignedReallocate(b, size, alignment);
    //}

    //Ternary owns(void[] b)
    //{
        //return _localAlloc.alloc.owns(b);
    //}

    //Ternary resolveInternalPointer(const void* p, ref void[] result)
    //{
        //return _localAlloc.alloc.resolveInternalPointer(p, result);
    //}

    bool deallocate(void[] b)
    {
        return _localAlloc.alloc.deallocate(b);
    }

    //bool deallocateAll()
    //{
        //return _localAlloc.alloc.deallocateAll();
    //}

    //Ternary empty()
    //{
        //return _localAlloc.alloc.empty();
    //}


    // Forward to shared allocator

    @property uint alignment() shared
    {
        return _sharedAlloc.alloc.alignment;
    }

    //size_t goodAllocSize(size_t s) shared
    //{
        //return _sharedAlloc.alloc.goodAllocSize(s);
    //}

    void[] allocate(size_t n) shared
    {
        return _sharedAlloc.alloc.allocate(n);
    }

    //void[] alignedAllocate(size_t n, uint a) shared
    //{
        //return _sharedAlloc.alloc.alignedAllocate(n, a);
    //}

    //void[] allocateAll() shared
    //{
        //return _sharedAlloc.alloc.allocateAll();
    //}

    //bool expand(ref void[] b, size_t size) shared
    //{
        //return _sharedAlloc.alloc.expand(b, size);
    //}

    //bool reallocate(ref void[] b, size_t size) shared
    //{
        //return _sharedAlloc.alloc.reallocate(b, size);
    //}

    //bool alignedReallocate(ref void[] b, size_t size, uint alignment) shared
    //{
        //return _sharedAlloc.alloc.alignedReallocate(b, size, alignment);
    //}

    //Ternary owns(void[] b) shared
    //{
        //return _sharedAlloc.alloc.owns(b);
    //}

    //Ternary resolveInternalPointer(const void* p, ref void[] result) shared
    //{
        //return _sharedAlloc.alloc.resolveInternalPointer(p, result);
    //}

    bool deallocate(void[] b) shared
    {
        return _sharedAlloc.alloc.deallocate(b);
    }

    //bool deallocateAll() shared
    //{
        //return _sharedAlloc.alloc.deallocateAll();
    //}

    //Ternary empty() shared
    //{
        //return _sharedAlloc.alloc.empty();
    //}
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
    alias AllocT = shared DualAllocatorU!(LocalAllocT, SharedAllocT);
    AllocT _mutableAllocator;

    AffixAllocator!(AllocT, RefCountedMutable!T) a;
    //AffixAllocator!(AllocT, int) a;
}

@safe unittest
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           theAllocator, processAllocator, dispose;
    import std.exception : enforce;

    auto a = DualAllocatorU!(RCIAllocator, RCISharedAllocator)(theAllocator);
    assert(!a._isShared);
    assert(a.get!(RCISharedAllocator).isNull);

    auto b = immutable DualAllocatorU!(RCIAllocator, RCISharedAllocator)(processAllocator);
    assert(b._isShared);
    assert(!b.get!(RCISharedAllocator).isNull);
    assert(b.get!(RCIAllocator).isNull);

    DualAllocatorU!(RCIAllocator, RCISharedAllocator) c;
    assert(c.get!(RCIAllocator).isNull);
    assert(c.get!(RCISharedAllocator).isNull);
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

    auto b = immutable DualAllocatorU!(RCIAllocator, RCISharedAllocator)(processAllocator);
    assert(b._isShared);
    assert(!b.get!(RCISharedAllocator).isNull);
    assert(b.get!(RCIAllocator).isNull);

    DualAllocatorU!(RCIAllocator, RCISharedAllocator) c;
    assert(c.get!(RCIAllocator).isNull);
    assert(c.get!(RCISharedAllocator).isNull);
}

struct MutableAlloc(Alloc)
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           theAllocator, processAllocator, dispose, stateSize;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import std.variant : Algebraic;
    import core.atomic : atomicOp;
    import std.algorithm.mutation : move;

    private static struct RefCountedMutable
    {
        //DualAllocatorU!(RCIAllocator, RCISharedAllocator) _alloc;
        Alloc _alloc;
        //T _payload;
        size_t _rc;
    }

    private void[] _mutableSupport;

    alias LocalAllocT = AffixAllocator!(Alloc, RefCountedMutable);
    alias SharedAllocT = shared AffixAllocator!(Alloc, RefCountedMutable);

    this(this Q)(Alloc alloc)
    {
        auto t = LocalAllocT(alloc);
        auto tSupport = (() @trusted => t.allocate(1))();
        () @trusted {
            // TODO: this is opAssign
            t.prefix(tSupport)._alloc = alloc;
        }();
        _mutableSupport = (() @trusted => cast(typeof(_mutableSupport))(tSupport))();
    }

    this(this) @trusted
    {
        if (_mutableSupport !is null)
        {
            addRef(_mutableSupport);
        }
    }

    @trusted void addRef(SupportQ, this Q)(SupportQ support)
    {
        assert(support !is null);
        static if (is(Q == immutable) || is(Q == const))
        {
            auto p = cast(shared uint*)(&LocalAllocT.prefix(support)._rc);
            atomicOp!"+="(*p, 1);
        }
        else
        {
            ++LocalAllocT.prefix(support)._rc;
        }
    }

    ~this() @trusted
    {
        if (_mutableSupport !is null)
        {
            if (LocalAllocT.prefix(_mutableSupport)._rc == 0)
            {
                // Workaround for disabled postblit, though I think move is the
                // correct behaviour
                alias AT = typeof(LocalAllocT.prefix(_mutableSupport)._alloc);
                //AT origAlloc;
                //move(LocalAllocT.prefix(_mutableSupport)._alloc, origAlloc);
                pragma(msg, is(AT == shared));
                AT origAlloc = LocalAllocT.prefix(_mutableSupport)._alloc;
                auto disposer = LocalAllocT(origAlloc);
                pragma(msg, typeof(disposer).stringof);
                disposer.deallocate(_mutableSupport);
            }
            else
            {
                --LocalAllocT.prefix(_mutableSupport)._rc;
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
            addRef(rhs._mutableSupport);
        }
        __dtor();
        _mutableSupport = rhs._mutableSupport;
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
            alias PayloadType = typeof(allocator.prefix(_mutableSupport)._alloc);
            //pragma(msg, "pld type is " ~ typeof(PayloadType).stringof);
            return cast(shared PayloadType)(LocalAllocT.prefix(_mutableSupport)._alloc);
        }
        else
        {
            return LocalAllocT.prefix(_mutableSupport)._alloc;
        }
    }

    void set(Alloc v)
    {
        LocalAllocT.prefix(_mutableSupport)._alloc = v;
    }
}

@safe unittest
{
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           theAllocator, processAllocator, dispose;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import std.variant : Algebraic;

    auto a = MutableAlloc!(RCIAllocator)(theAllocator);
    auto a = immutable MutableAlloc!(RCISharedAllocator)(processAllocator);
}

