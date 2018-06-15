/**
`RCString` is a reference-counted string which is based on
$(REF Array, std,experimental,collections) of `ubyte`s.
By default, `RCString` is not a range. The `.by` helpers can be used to specify
the iteration mode.
RC-String internally stores the string as UTF-8.

$(UL
    $(LI `str.by!char` - iterates over individual `char` characters. No auto-decoding is done.)
    $(LI `str.by!wchar` - iterates over `wchar` characters. Auto-decoding is done.)
    $(LI `str.by!dchar` - iterates over `dchar` characters. Auto-decoding is done.)
    $(LI `str.by!ubyte`- iterates over the raw `ubyte` representation. No auto-decoding is done. This is similar to $(REF representation, std,string) for built-in strings)
)
*/
module stdx.collections.rcstring;

import stdx.collections.common;
import stdx.collections.array;

debug(CollectionRCString) import std.stdio;

version(unittest)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator.building_blocks.stats_collector;
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           allocatorObject, sharedAllocatorObject;
    import std.algorithm.mutation : move;

    private alias SCAlloc = StatsCollector!(Mallocator, Options.bytesUsed);
}

///
struct RCString
{
private:
    Array!ubyte _support;
    mixin(allocatorHandler);
public:

    /**
     * Constructs a qualified rcstring that will use the provided
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
        debug(CollectionRCString)
        {
            writefln("RCString.ctor: begin");
            scope(exit) writefln("RCString.ctor: end");
        }
        static if (is(Q == immutable) || is(Q == const))
        {
            this(allocator, null);
        }
        else
        {
            setAllocator(allocator);
        }
    }

    ///
    @safe unittest
    {
        import std.experimental.allocator : theAllocator, processAllocator;

        auto a = RCString(theAllocator);
        auto ca = const RCString(processAllocator);
        auto ia = immutable RCString(processAllocator);
    }

    /**
     * Constructs a qualified rcstring out of an `ubyte` array.
     * Because no allocator was provided, the rcstring will use the
     * $(REF GCAllocator, std,experimental,allocator,gc_allocator).
     *
     * Params:
     *      bytes = a variable number of bytes, either in the form of a
     *               list or as a built-in array
     *
     * Complexity: $(BIGOH m), where `m` is the number of bytes.
     */
    this(this Q)(ubyte[] bytes...)
    {
        static if (is(Q == immutable) || is(Q == const))
        {
            this(processAllocatorObject(), bytes);
        }
        else
        {
            this(threadAllocatorObject(), bytes);
        }
    }

    ///
    @safe unittest
    {
        // Create a list from a list of bytes
        auto a = RCString('1', '2', '3');

        // Create a list from an array of bytes
        auto b = RCString(['1', '2', '3']);
    }

    /**
     * Constructs a qualified rcstring out of a number of bytes
     * that will use the provided allocator object.
     * For `immutable` objects, a `RCISharedAllocator` must be supplied.
     *
     * Params:
     *      allocator = a $(REF RCIAllocator, std,experimental,allocator) or
     *                  $(REF RCISharedAllocator, std,experimental,allocator)
     *                  allocator object
     *      bytes = a variable number of bytes, either in the form of a
     *               list or as a built-in RCString
     *
     * Complexity: $(BIGOH m), where `m` is the number of bytes.
     */
    this(A, this Q)(A allocator, ubyte[] bytes...)
    if (!is(Q == shared)
        && (is(A == RCISharedAllocator) || !is(Q == immutable))
        && (is(A == RCIAllocator) || is(A == RCISharedAllocator)))
    {
        debug(CollectionRCString)
        {
            writefln("RCString.ctor: begin");
            scope(exit) writefln("RCString.ctor: end");
        }
        static if (is(Q == immutable) || is(Q == const))
        {
            _allocator = immutable AllocatorHandler(allocator);
        }
        else
        {
            setAllocator(allocator);
        }
        _support = typeof(_support)(allocator, bytes);
    }

    ///
    @safe unittest
    {
        import std.experimental.allocator : theAllocator, processAllocator;

        // Create a list from a list of ints
        auto a = RCString(theAllocator, '1', '2', '3');

        // Create a list from an array of ints
        auto b = RCString(theAllocator, ['1', '2', '3']);
    }

    this(this Q)(string s)
    {
        import std.string : representation;
        static if (is(Q == immutable) || is(Q == const))
        {
            this(processAllocatorObject(), s.dup.representation);
        }
        else
        {
            this(threadAllocatorObject(), s.dup.representation);
        }
    }

    @safe unittest
    {
        import std.algorithm.comparison : equal;
        auto s = RCString("dlang");
        assert(s.by!char.equal("dlang"));
    }

    bool empty() const
    {
        return _support.empty;
    }

    @trusted
    auto by(T)()
    if (is(T == char) || is(T == wchar) || is(T == dchar))
    {
        Array!char tmp = *cast(Array!char*)(&_support);
        static if (is(T == char))
        {
            return tmp;
        }
        else
        {
            import std.utf : byUTF;
            return tmp.byUTF!T();
        }
    }

}

@safe unittest
{
    import std.algorithm.comparison : equal;

    auto buf = cast(ubyte[])("aaa".dup);
    auto s = RCString(buf);

    assert(equal(s.by!char, "aaa"));
    s.by!char.front = 'b';
    assert(equal(s.by!char, "baa"));
}

@safe unittest
{
    import std.algorithm.comparison : equal;

    auto buf = cast(ubyte[])("hell\u00F6".dup);
    auto s = RCString(buf);

    assert(s.by!char().equal(['h', 'e', 'l', 'l', 0xC3, 0xB6]));

    // `wchar`s are able to hold the ö in a single element (UTF-16 code unit)
    assert(s.by!wchar().equal(['h', 'e', 'l', 'l', 'ö']));
}

@safe unittest
{
    import std.algorithm.comparison : equal;

    auto buf = cast(ubyte[])("hello".dup);
    auto s = RCString(buf);
    auto charStr = s.by!char;

    charStr[$ - 2] = cast(ubyte) 0xC3;
    charStr[$ - 1] = cast(ubyte) 0xB6;

    assert(s.by!wchar().equal(['h', 'e', 'l', 'ö']));
}
