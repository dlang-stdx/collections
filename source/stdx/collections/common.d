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
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator, theAllocator, dispose;
    import std.experimental.allocator.building_blocks.affix_allocator;
    import core.atomic : atomicOp;

    private struct RefCountedMutable
    {
        RCIAllocator _alloc;
        T _payload;
        size_t _rc;
    }

    private void[] _mutableSupport;
    private AffixAllocator!(RCIAllocator, RefCountedMutable) _mutableAllocator;

    this(this _)(T theMutable)
    {
        this(theAllocator, theMutable);
    }

    this(this _)(RCIAllocator alloc, T theMutable)
    {
        auto t = AffixAllocator!(RCIAllocator, RefCountedMutable)(alloc);
        auto tSupport = (() @trusted => t.allocate(1))();
        () @trusted {
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

    @trusted void addRef(AllocQual, SupportQual, this Qualified)(AllocQual alloc, SupportQual support)
    {
        assert(support !is null);
        static if (is(Qualified == immutable) || is(Qualified == const))
        {
            auto p = cast(shared uint*)(&alloc.prefix(support)._rc);
            atomicOp!"+="(*p, 1);
        }
        else
        {
            ++alloc.prefix(support)._rc;
        }
    }

    ~this() @trusted
    {
        if (_mutableSupport !is null)
        {
            if (_mutableAllocator.prefix(_mutableSupport)._rc == 0)
            {
                auto origAlloc = _mutableAllocator.prefix(_mutableSupport)._alloc;
                auto disposer = AffixAllocator!(RCIAllocator, RefCountedMutable)(origAlloc);
                disposer.dispose(_mutableSupport);
            }
            else
            {
                --_mutableAllocator.prefix(_mutableSupport)._rc;
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
            //() @trusted {
                //++rhs._mutableAllocator.prefix(rhs._mutableSupport)._rc;
            //}();
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
            //alias PayloadType = typeof(_mutableAllocator.prefix(_mutableSupport)._payload);
            static if (is(Q == immutable))
            {
                alias PayloadType = shared(AffixAllocator!(shared RCISharedAllocator, ulong, void));
            }
            else
            {
                alias PayloadType = const(AffixAllocator!(shared RCISharedAllocator, ulong, void));
            }
            pragma(msg, "pld type is " ~ PayloadType.stringof);
            return cast(shared PayloadType)(_mutableAllocator.prefix(_mutableSupport)._payload);
        }
        else
        {
            return _mutableAllocator.prefix(_mutableSupport)._payload;
        }
    }

    void set(T v)
    {
        _mutableAllocator.prefix(_mutableSupport)._payload = v;
    }
}
