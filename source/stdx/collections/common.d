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
        Algebraic!(RCIAllocator, RCISharedAllocator) _alloc;
        T _payload;
        size_t _rc;
    }

    private void[] _mutableSupport;

    alias LocalAllocT = AffixAllocator!(RCIAllocator, RefCountedMutable);
    alias SharedAllocT = AffixAllocator!(RCISharedAllocator, RefCountedMutable);
    alias AllocT = Algebraic!(LocalAllocT, SharedAllocT);
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
    //auto a = const Mutable!(RCISharedAllocator)(processAllocator);
    //auto a = shared Mutable!(RCIAllocator)(theAllocator, theAllocator);
    RCISharedAllocator al;
    assert(al.isNull);
    al = processAllocator();
    Algebraic!(RCIAllocator, RCISharedAllocator) _alloc;
    pragma(msg, Algebraic!(RCIAllocator, RCISharedAllocator).sizeof);
    //_alloc = al;

    //alias AllocT = Algebraic!(AffixAllocator!(RCIAllocator, int),
                              //AffixAllocator!(shared RCISharedAllocator, int));
    //AllocT _mutableAllocator;
}

struct DualAllocator(LocalAllocT, SharedAllocT)
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

    auto a = DualAllocator!(RCIAllocator, RCISharedAllocator)(theAllocator);
    assert(!a._isShared);
    //assert(a.peek!(RCISharedAllocator)() !is null);
    //assert(a.get!(RCISharedAllocator).isNull);
    //pragma(msg, typeof(a.peek!(RCIAllocator)()).stringof);

    auto b = immutable DualAllocator!(RCIAllocator, RCISharedAllocator)(processAllocator);
    assert(b._isShared);
    assert(b.get!(RCISharedAllocator).isNull);
    assert(!b.get!(RCIAllocator).isNull);

    DualAllocator!(RCIAllocator, RCISharedAllocator) c;
    assert(!c.get!(RCIAllocator)().isNull());
    pragma(msg, DualAllocator!(RCIAllocator, RCISharedAllocator).sizeof);
    pragma(msg, RCIAllocator.sizeof);
    pragma(msg, RCISharedAllocator.sizeof);

    union Allocator
    {
        RCIAllocator localAlloc;
        RCISharedAllocator sharedAlloc;
    }
    pragma(msg, Allocator.sizeof);
}
