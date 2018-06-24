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
import std.range.primitives : isInputRange, ElementType, hasLength;
import std.traits : isSomeChar, isSomeString;

debug(CollectionRCString) import std.stdio;

version(unittest)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator.building_blocks.stats_collector;
    import std.experimental.allocator : RCIAllocator, RCISharedAllocator,
           allocatorObject, sharedAllocatorObject;
    import std.algorithm.mutation : move;
    import std.stdio;

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
     Constructs a qualified rcstring that will use the provided
     allocator object. For `immutable` objects, a `RCISharedAllocator` must
     be supplied.

     Params:
          allocator = a $(REF RCIAllocator, std,experimental,allocator) or
                      $(REF RCISharedAllocator, std,experimental,allocator)
                      allocator object

     Complexity: $(BIGOH 1)
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
            _allocator = immutable AllocatorHandler(allocator);
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
     Constructs a qualified rcstring out of an `ubyte` array.
     Because no allocator was provided, the rcstring will use the
     $(REF GCAllocator, std,experimental,allocator,gc_allocator).

     Params:
          bytes = a variable number of bytes, either in the form of a
                   list or as a built-in array

     Complexity: $(BIGOH m), where `m` is the number of bytes.
    */
    this(this Q)(ubyte[] bytes...)
    {
        this(defaultAllocator, bytes);
    }

    private auto defaultAllocator(this Q)()
    {
        static if (is(Q == immutable) || is(Q == const))
        {
            return processAllocatorObject();
        }
        else
        {
            return threadAllocatorObject();
        }
    }

    ///
    @safe unittest
    {
        // Create a list from a list of bytes
        auto a = RCString('1', '2', '3');

        // Create a list from an array of bytes
        auto b = RCString(['1', '2', '3']);

        // Create a const list from a list of bytes
        auto c = const RCString('1', '2', '3');
    }

    /**
     Constructs a qualified rcstring out of a number of bytes
     that will use the provided allocator object.
     For `immutable` objects, a `RCISharedAllocator` must be supplied.

     Params:
          allocator = a $(REF RCIAllocator, std,experimental,allocator) or
                      $(REF RCISharedAllocator, std,experimental,allocator)
                      allocator object
          bytes = a variable number of bytes, either in the form of a
                   list or as a built-in RCString

     Complexity: $(BIGOH m), where `m` is the number of bytes.
    */
    this(A, this Q)(A allocator, ubyte[] bytes...)
    if (!is(Q == shared)
        && (is(A == RCISharedAllocator) || !is(Q == immutable))
        && (is(A == RCIAllocator) || is(A == RCISharedAllocator)))
    {
        this(allocator);
        static if (is(Q == immutable) || is(Q == const))
            "_support".writeln;
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

    /// ditto
    this(this Q)(string s)
    {
        import std.string : representation;
        static if (is(Q == immutable) || is(Q == const))
            this(processAllocatorObject(), s.dup.representation);
        else
            this(threadAllocatorObject(), s.dup.representation);
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;
        auto s = RCString("dlang");
        assert(s.by!char.equal("dlang"));
    }

    /// ditto
    this(this Q)(dstring s)
    {
        import std.utf : byChar;
        this(s.byChar);
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;
        auto s = RCString("dlang"d);
        assert(s.by!char.equal("dlang"));
    }

    /// ditto
    this(this Q)(wstring s)
    {
        import std.utf : byChar;
        this(s.byChar);
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;
        auto s = RCString("dlang"w);
        assert(s.by!char.equal("dlang"));
    }

    /// ditto
    this(this Q, A, R)(A allocator, R r)
    if (!is(Q == shared)
        && (is(A == RCISharedAllocator) || !is(Q == immutable))
        && (is(A == RCIAllocator) || is(A == RCISharedAllocator))
        && isInputRange!R && isSomeChar!(ElementType!R) && !isSomeString!R)
    {
        this(allocator);
        static if (hasLength!R)
            _support.reserve(r.length);
        foreach (e; r)
            _support ~= cast(ubyte) e;
    }

    /// ditto
    this(this Q, R)(R r)
    if (isInputRange!R && isSomeChar!(ElementType!R) && !isSomeString!R)
    {
        static if (is(Q == immutable) || is(Q == const))
            this(processAllocatorObject(), r);
        else
            this(threadAllocatorObject(), r);
    }

    ///
    @safe unittest
    {
        import std.range : take;
        import std.utf : byCodeUnit;
        auto s = RCString("dlang".byCodeUnit.take(10));
        assert(s.equal("dlang"));
    }

    ///
    @nogc nothrow pure @safe
    bool empty() const
    {
        return _support.empty;
    }

    ///
    @safe unittest
    {
        assert(!RCString("dlang").empty);
        assert(RCString("").empty);
    }

    ///
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

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;
        import std.utf : byChar, byWchar;
        auto hello = RCString("你好");
        assert(hello.by!char.equal("你好".byChar));
        assert(hello.by!wchar.equal("你好".byWchar));
        assert(hello.by!dchar.equal("你好"));
    }

    ///
    typeof(this) opBinary(string op)(typeof(this) rhs)
    if (op == "~")
    {
        RCString s = this;
        s._support ~= rhs._support;
        return s;
    }

    /// ditto
    typeof(this) opBinary(string op)(string rhs)
    if (op == "~")
    {
        auto rcs = RCString(rhs);
        RCString s = this;
        s._support ~= rcs._support;
        return s;
    }

    /// ditto
    typeof(this) opBinaryRight(string op)(string rhs)
    if (op == "~")
    {
        auto s = RCString(rhs);
        RCString rcs = this;
        s._support ~= rcs._support;
        return s;
    }

    /// ditto
    typeof(this) opBinary(string op, C)(C c)
    if (op == "~" && isSomeChar!C)
    {
        RCString s = this;
        s._support ~= cast(ubyte) c;
        return s;
    }

    /// ditto
    typeof(this) opBinaryRight(string op, C)(C c)
    if (op == "~" && isSomeChar!C)
    {
        RCString rcs = this;
        rcs._support.insert(0, cast(ubyte) c);
        return rcs;
    }

    /// ditto
    typeof(this) opBinary(string op, R)(R r)
    if (op == "~" && isInputRange!R && isSomeChar!(ElementType!R) && !isSomeString!R)
    {
        RCString s = this;
        static if (hasLength!R)
            s._support.reserve(s._support.length + r.length);
        foreach (el; r)
        {
            s._support ~= cast(ubyte) el;
        }
        return s;
    }

    /// ditto
    typeof(this) opBinaryRight(string op, R)(R lhs)
    if (op == "~" && isInputRange!R && isSomeChar!(ElementType!R) && !isSomeString!R)
    {
        auto l = RCString(lhs);
        RCString rcs = this;
        l._support ~= rcs._support;
        return l;
    }

    ///
    @safe unittest
    {
        auto r1 = RCString("abc");
        auto r2 = RCString("def");
        assert((r1 ~ r2).equal("abcdef"));
        assert((r1 ~ "foo").equal("abcfoo"));
        assert(("abc" ~ r2).equal("abcdef"));
        assert((r1 ~ 'd').equal("abcd"));
        assert(('a' ~ r2).equal("adef"));
    }

    ///
    @safe unittest
    {
        import std.range : take;
        import std.utf : byCodeUnit;
        auto r1 = RCString("abc");
        auto r2 = "def".byCodeUnit.take(3);
        assert((r1 ~ r2).equal("abcdef"));
        assert((r2 ~ r1).equal("defabc"));
    }

    ///
    auto opBinary(string op)(typeof(this) rhs)
    if (op == "in")
    {
        // TODO
        import std.algorithm.searching : find;
        return this.by!char.find(rhs.by!char);
    }

    auto opBinaryRight(string op)(string rhs)
    if (op == "in")
    {
        // TODO
        import std.algorithm.searching : find;
        return rhs.find(this.by!char);
    }

    ///
    @safe unittest
    {
        auto r1 = RCString("abc");
        auto r2 = RCString("def");
        auto rtext = RCString("abcdefgh");
        //import std.stdio;
        //(r1 in rtext).writeln;
        //(r1 in rtext).writeln;
    }

    ///
    typeof(this) opOpAssign(string op)(typeof(this) rhs)
    if (op == "~")
    {
        _support ~= rhs._support;
        return this;
    }

    ///
    @safe unittest
    {
        auto r1 = RCString("abc");
        r1 ~= RCString("def");
        assert(r1.equal("abcdef"));
    }

    /// ditto
    typeof(this) opOpAssign(string op)(string rhs)
    if (op == "~")
    {
        import std.string : representation;
        _support ~= rhs.representation;
        return this;
    }

    ///
    @safe unittest
    {
        auto r1 = RCString("abc");
        r1 ~= "def";
        assert(r1.equal("abcdef"));
    }

    typeof(this) opOpAssign(string op, C)(C c)
    if (op == "~" && isSomeChar!C)
    {
        _support ~= cast(ubyte) c;
        return this;
    }

    ///
    @safe unittest
    {
        auto r1 = RCString("abc");
        r1 ~= 'd';
        assert(r1.equal("abcd"));
    }

    typeof(this) opOpAssign(string op, R)(R r)
    if (op == "~" && isSomeChar!(ElementType!R) && isInputRange!R && !isSomeString!R)
    {
        _support ~= RCString(r)._support;
        return this;
    }

    ///
    @safe unittest
    {
        import std.range : take;
        import std.utf : byCodeUnit;
        auto r1 = RCString("abc");
        r1 ~= "foo".byCodeUnit.take(4);
        assert(r1.equal("abcfoo"));
    }

    ///
    bool opEquals()(auto ref typeof(this) rhs) const
    {
        return _support == rhs._support;
    }

    ///
    @safe unittest
    {
        assert(RCString("abc") == RCString("abc"));
        assert(RCString("abc") != RCString("Abc"));
        assert(RCString("abc") != RCString("abd"));
        assert(RCString("abc") != RCString(""));
        assert(RCString("") == RCString(""));
    }

    /// ditto
    bool opEquals()(string rhs) const
    {
        import std.string : representation;
        import std.algorithm.comparison : equal;
        return _support._payload.equal(rhs.representation);
    }

    ///
    @safe unittest
    {
        assert(RCString("abc") == "abc");
        assert(RCString("abc") != "Abc");
        assert(RCString("abc") != "abd");
        assert(RCString("abc") != "");
        assert(RCString("") == "");
    }

    bool opEquals(R)(R r)
    if (isSomeChar!(ElementType!R) && isInputRange!R && !isSomeString!R)
    {
        import std.algorithm.comparison : equal;
        return _support.equal(r);
    }

    ///
    @safe unittest
    {
        import std.range : take;
        import std.utf : byCodeUnit;
        assert(RCString("abc") == "abc".byCodeUnit.take(3));
        assert(RCString("abc") != "Abc".byCodeUnit.take(3));
        assert(RCString("abc") != "abd".byCodeUnit.take(3));
        assert(RCString("abc") != "".byCodeUnit.take(3));
        assert(RCString("") == "".byCodeUnit.take(3));
    }

    ///
    int opCmp()(auto ref typeof(this) rhs)
    {
        return _support.opCmp(rhs._support);
    }

    ///
    @safe unittest
    {
        assert(RCString("abc") <= RCString("abc"));
        assert(RCString("abc") >= RCString("abc"));
        assert(RCString("abc") > RCString("Abc"));
        assert(RCString("Abc") < RCString("abc"));
        assert(RCString("abc") < RCString("abd"));
        assert(RCString("abc") > RCString(""));
        assert(RCString("") <= RCString(""));
        assert(RCString("") >= RCString(""));
    }

    int opCmp()(string rhs)
    {
        import std.string : representation;
        return _support.opCmp(rhs.representation);
    }

    ///
    @safe unittest
    {
        assert(RCString("abc") <= "abc");
        assert(RCString("abc") >= "abc");
        assert(RCString("abc") > "Abc");
        assert(RCString("Abc") < "abc");
        assert(RCString("abc") < "abd");
        assert(RCString("abc") > "");
        assert(RCString("") <= "");
        assert(RCString("") >= "");
    }

    int opCmp(R)(R rhs)
    if (isSomeChar!(ElementType!R) && isInputRange!R && !isSomeString!R)
    {
        import std.string : representation;
        return _support.opCmp(rhs);
    }

    ///
    @safe unittest
    {
        import std.range : take;
        import std.utf : byCodeUnit;
        assert(RCString("abc") <= "abc".byCodeUnit.take(3));
        assert(RCString("abc") >= "abc".byCodeUnit.take(3));
        assert(RCString("abc") > "Abc".byCodeUnit.take(3));
        assert(RCString("Abc") < "abc".byCodeUnit.take(3));
        assert(RCString("abc") < "abd".byCodeUnit.take(3));
        assert(RCString("abc") > "".byCodeUnit.take(3));
        assert(RCString("") <= "".byCodeUnit.take(3));
        assert(RCString("") >= "".byCodeUnit.take(3));
    }

    auto opSlice(size_t start, size_t end)
    {
        RCString s = save;
        s._support = s._support[start .. end];
        return s;
    }

    ///
    @safe unittest
    {
        auto a = RCString("abcdef");
        assert(a[2 .. $].equal("cdef"));
        assert(a[0 .. 2].equal("ab"));
        assert(a[3 .. $ - 1].equal("de"));
    }

    ///
    auto opDollar()
    {
        return _support.length;
    }

    ///
    auto save()
    {
        RCString s = this;
        return s;
    }

    ///
    auto opSlice()
    {
        return this.save;
    }

    // Phobos
    auto equal(T)(T rhs)
    {
        import std.algorithm.comparison : equal;
        return by!char.equal(rhs);
    }

    auto writeln(T...)(T rhs)
    {
        import std.stdio : writeln;
        return by!char.writeln(rhs);
    }

    string toString()
    {
        import std.array : array;
        import std.exception : assumeUnique;
        return by!char.array.assumeUnique;
    }

    ///
    auto opSliceAssign(char c, size_t start, size_t end)
    {
        _support[start .. end] = cast(ubyte) c;
    }

    ///
    @safe unittest
    {
        auto r1 = RCString("abcdef");
        r1[2..4] = '0';
        assert(r1.equal("ab00ef"));
    }

    ///
    bool opCast(T : bool)()
    {
        return !empty;
    }

    ///
    @safe unittest
    {
        assert(RCString("foo"));
        assert(!RCString(""));
    }

    /// ditto
    auto ref opAssign()(RCString rhs)
    {
        _support = rhs._support;
        return this;
    }

    /// ditto
    auto ref opAssign(R)(R rhs)
    {
        _support = RCString(rhs)._support;
        return this;
    }

    ///
    @safe unittest
    {
        auto rc = RCString("foo");
        assert(rc.equal("foo"));
        rc = RCString("bar1");
        assert(rc.equal("bar1"));
        rc = "bar2";
        assert(rc.equal("bar2"));

        import std.range : take;
        import std.utf : byCodeUnit;
        rc = "bar3".take(10).byCodeUnit;
        assert(rc.equal("bar3"));
    }

    auto dup()()
    {
        return RCString(by!char);
    }

    ///
    @safe unittest
    {
        auto s = RCString("foo");
        s = RCString("bar");
        assert(s.equal("bar"));
        auto s2 = s.dup;
        s2 = RCString("fefe");
        assert(s.equal("bar"));
        assert(s2.equal("fefe"));
    }

    auto idup()()
    {
        return RCString!(immutable(char))(by!char);
    }

    ///
    @safe unittest
    {
        auto s = RCString("foo");
        s = RCString("bar");
        assert(s.equal("bar"));
        auto s2 = s.dup;
        s2 = RCString("fefe");
        assert(s.equal("bar"));
        assert(s2.equal("fefe"));
    }

    ///
    auto opIndex(size_t pos)
    in
    {
        assert(pos < _support.length, "Invalid position.");
    }
    body
    {
        return _support[pos];
    }

    ///
    @safe unittest
    {
        auto s = RCString("bar");
        assert(s[0] == 'b');
        assert(s[1] == 'a');
        assert(s[2] == 'r');
    }

    ///
    auto opIndexAssign(char el, size_t pos)
    in
    {
        assert(pos < _support.length, "Invalid position.");
    }
    body
    {
        return _support[pos] = cast(ubyte) el;
    }

    ///
    @safe unittest
    {
        auto s = RCString("bar");
        assert(s[0] == 'b');
        s[0] = 'f';
        assert(s.equal("far"));
    }

    ///
    auto opIndexAssign(char c)
    {
        _support[] = cast(ubyte) c;
    }

    ///
    @safe unittest
    {
        auto rc = RCString("abc");
        rc[] = '0';
        assert(rc.equal("000"));
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
