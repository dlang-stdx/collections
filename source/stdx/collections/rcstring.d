/**
`RCString` is a reference-counted string which is based on
$(REF Array, std,experimental,collections) of `ubyte`s.
By default, `RCString` is not a range. The `.by` helpers can be used to specify
the iteration mode.
RCString internally stores the string as UTF-8 $(REF Array, stdx,collections,array).

$(UL
    $(LI `str.by!char` - iterates over individual `char` characters. No auto-decoding is done.)
    $(LI `str.by!wchar` - iterates over `wchar` characters. Auto-decoding is done.)
    $(LI `str.by!dchar` - iterates over `dchar` characters. Auto-decoding is done.)
    $(LI `str.by!ubyte`- iterates over the raw `ubyte` representation. No auto-decoding is done. This is similar to $(REF representation, std,string) for built-in strings)
)
*/
module stdx.collections.rcstring;

import stdx.collections.array;
import core.internal.traits : Unqual;

/**
 * Detect whether type `T` is an aggregate type.
 */
enum bool isAggregateType(T) = is(T == struct) || is(T == union) ||
                               is(T == class) || is(T == interface);

enum bool isSomeChar(T) = is(Unqual!T == char) || is(Unqual!T == wchar) || is(Unqual!T == dchar);

enum bool isSomeString(T) = isSomeChar!(ElementType!T)
                            && !isAggregateType!T
                            && !is(T == enum)
                            //TODO: Phobos explicitly denies static arrays. Why?
                            && !__traits(isStaticArray, T);

enum bool isInputRange(R) =
    is(typeof(R.init) == R)
    && is(typeof(R.init.empty) == bool)
    && is(typeof((return ref R r) => r.front))
    && !is(typeof((R r) => r.front) == void)
    && is(typeof((R r) => r.popFront));

enum bool isAutodecodableString(T) = (is(T : const char[]) || is(T : const wchar[]))
                                     && !__traits(isStaticArray, T);

/**
The element type of `R`. `R` does not have to be a range. The element type is
determined as the type yielded by `r[0]` for an object `r` of type `R`.
 */
private template ElementType(R)
{
    static if (is(typeof(R.init[0].init) T))
        alias ElementType = T;
    else static if (is(typeof(R.init.front.init) T))
        alias ElementType = T;
    else
        alias ElementType = void;
}

/**
 * Detect whether type `T` is a narrow string.
 *
 * All arrays that use char, wchar, and their qualified versions are narrow
 * strings. (Those include string and wstring).
 */
enum bool isNarrowString(T) = isSomeString!T && !is(T : const dchar[]);

/*
Always returns the Dynamic Array version.

NOTE: slightly altered Phobos std.traits.StringTypeOf version
 */
template StringTypeOf(T)
{
    static if (isSomeString!T)
    {
        static if (is(T : U[], U))
            alias StringTypeOf = U[];
        else
            static assert(0);
    }
    else
        static assert(0, T.stringof~" is not a string type");
}

/**
 * Inserted in place of invalid UTF sequences.
 *
 * References:
 *      $(LINK http://en.wikipedia.org/wiki/Replacement_character#Replacement_character)
 */
enum dchar replacementDchar = '\uFFFD';

/**
The encoding element type of `R`. For narrow strings (`char[]`,
`wchar[]` and their qualified variants including `string` and
`wstring`), `ElementEncodingType` is the character type of the
string. For all other types, `ElementEncodingType` is the same as
`ElementType`.
 */
template ElementEncodingType(R)
{
    static if (is(StringTypeOf!R) && is(R : E[], E))
        alias ElementEncodingType = E;
    else
        alias ElementEncodingType = ElementType!R;
}

/********************************************
 * Iterate a range of char, wchar, or dchars by code unit.
 *
 * The purpose is to bypass the special case decoding that
 * $(REF front, std,range,primitives) does to character arrays. As a result,
 * using ranges with `byCodeUnit` can be `nothrow` while
 * $(REF front, std,range,primitives) throws when it encounters invalid Unicode
 * sequences.
 *
 * A code unit is a building block of the UTF encodings. Generally, an
 * individual code unit does not represent what's perceived as a full
 * character (a.k.a. a grapheme cluster in Unicode terminology). Many characters
 * are encoded with multiple code units. For example, the UTF-8 code units for
 * `ø` are `0xC3 0xB8`. That means, an individual element of `byCodeUnit`
 * often does not form a character on its own. Attempting to treat it as
 * one while iterating over the resulting range will give nonsensical results.
 *
 * Params:
 *      r = an $(REF_ALTTEXT input range, isInputRange, std,range,primitives)
 *      of characters (including strings) or a type that implicitly converts to a string type.
 * Returns:
 *      If `r` is not an auto-decodable string (i.e. a narrow string or a
 *      user-defined type that implicits converts to a string type), then `r`
 *      is returned.
 *
 *      Otherwise, `r` is converted to its corresponding string type (if it's
 *      not already a string) and wrapped in a random-access range where the
 *      element encoding type of the string (its code unit) is the element type
 *      of the range, and that range returned. The range has slicing.
 *
 *      If `r` is quirky enough to be a struct or class which is an input range
 *      of characters on its own (i.e. it has the input range API as member
 *      functions), $(I and) it's implicitly convertible to a string type, then
 *      `r` is returned, and no implicit conversion takes place.
 *
 *      If `r` is wrapped in a new range, then that range has a `source`
 *      property for returning the string that's currently contained within that
 *      range.
 *
 * See_Also:
 *      Refer to the $(MREF std, uni) docs for a reference on Unicode
 *      terminology.
 *
 *      For a range that iterates by grapheme cluster (written character) see
 *      $(REF byGrapheme, std,uni).
 */
auto byCodeUnit(R)(R r)
if (isAutodecodableString!R ||
    //TODO: How important is it? Is it ok to replace this with isSomeString?
    isInputRange!R && isSomeChar!(ElementEncodingType!R) ||
    //isSomeString!R ||
    (is(R : const dchar[]) && !__traits(isStaticArray, R)))
{
    static if (isNarrowString!R ||
               // This would be cleaner if we had a way to check whether a type
               // was a range without any implicit conversions.
               (isAutodecodableString!R && !__traits(hasMember, R, "empty") &&
                !__traits(hasMember, R, "front") && !__traits(hasMember, R, "popFront")))
    {
        static struct ByCodeUnitImpl
        {
        @safe pure nothrow @nogc:

            @property bool empty() const     { return source.length == 0; }
            @property auto ref front() inout { return source[0]; }
            void popFront()                  { source = source[1 .. $]; }

            @property auto save() { return ByCodeUnitImpl(source.save); }

            @property auto ref back() inout { return source[$ - 1]; }
            void popBack()                  { source = source[0 .. $-1]; }

            auto ref opIndex(size_t index) inout     { return source[index]; }
            auto opSlice(size_t lower, size_t upper) { return ByCodeUnitImpl(source[lower .. upper]); }

            @property size_t length() const { return source.length; }
            alias opDollar = length;

            StringTypeOf!R source;
        }

        // IMHO, Redundant check
        //static assert(isRandomAccessRange!ByCodeUnitImpl);

        return ByCodeUnitImpl(r);
    }
    else static if (is(R : const dchar[]) && !__traits(hasMember, R, "empty") &&
                    !__traits(hasMember, R, "front") && !__traits(hasMember, R, "popFront"))
    {
        return cast(StringTypeOf!R) r;
    }
    else
    {
        // byCodeUnit for ranges and dchar[] is a no-op
        return r;
    }
}

@property bool empty(T)(auto ref scope const(T) a)
if (is(typeof(a.length) : size_t) || isNarrowString!T)
{
    return !a.length;
}

@property ref T front(T)(return scope T[] a) @safe pure nothrow @nogc
//if (!isNarrowString!(T[]) && !is(T[] == void[]))
{
    assert(a.length, "Attempting to fetch the front of an empty array of " ~ T.stringof);
    return a[0];
}

void popFront(T)(scope ref inout(T)[] a) @safe pure nothrow @nogc
//if (!isNarrowString!(T[]) && !is(T[] == void[]))
{
    assert(a.length, "Attempting to popFront() past the end of an array of " ~ T.stringof);
    a = a[1 .. $];
}

@property inout(T)[] save(T)(return scope inout(T)[] a) @safe pure nothrow @nogc
{
    return a;
}

/****************************
 * Iterate an $(REF_ALTTEXT input range, isInputRange, std,range,primitives)
 * of characters by char type `C` by encoding the elements of the range.
 *
 * UTF sequences that cannot be converted to the specified encoding are
 * replaced by U+FFFD per "5.22 Best Practice for U+FFFD Substitution"
 * of the Unicode Standard 6.2. Hence byUTF is not symmetric.
 * This algorithm is lazy, and does not allocate memory.
 * `@nogc`, `pure`-ity, `nothrow`, and `@safe`-ty are inferred from the
 * `r` parameter.
 *
 * Params:
 *      C = `char`, `wchar`, or `dchar`
 *
 * Returns:
 *      A forward range if `R` is a range and not auto-decodable, as defined by
 *      $(REF isAutodecodableString, std, traits), and if the base range is
 *      also a forward range.
 *
 *      Or, if `R` is a range and it is auto-decodable and
 *      `is(ElementEncodingType!typeof(r) == C)`, then the range is passed
 *      to $(LREF byCodeUnit).
 *
 *      Otherwise, an input range of characters.
 */

template byUTF(C)
if (isSomeChar!C)
{
    enum bool isForwardRange(R) = isInputRange!R && is(typeof(R.init.save));
        //TODO: ok? __traits(hasMember, R, "save");

    static if (!is(Unqual!C == C))
        alias byUTF = byUTF!(Unqual!C);
    else:

    auto ref byUTF(R)(R r)
        if (isAutodecodableString!R && isInputRange!R && isSomeChar!(ElementEncodingType!R))
    {
        pragma(msg, "begin ", R.stringof, " ", C.stringof);
        return byUTF(r.byCodeUnit());
    }

    auto ref byUTF(R)(R r)
        if (!isAutodecodableString!R && isInputRange!R && isSomeChar!(ElementEncodingType!R))
    {
        alias RC = Unqual!(ElementEncodingType!R);
        pragma(msg, R.stringof, " ", RC.stringof, " ", C.stringof);

        static if (is(RC == C))
        {
            return r.byCodeUnit();
        }
        else static if (is(C == dchar))
        {
            static struct Result
            {
                this(R val)
                {
                    r = val;
                    popFront();
                }

                @property bool empty()
                {
                    return buff == uint.max;
                }

                @property auto front()
                {
                    assert(!empty, "Attempting to access the front of an empty byUTF");
                    return cast(dchar) buff;
                }

                void popFront() scope
                {
                    assert(!empty, "Attempting to popFront an empty byUTF");
                    if (r.empty)
                    {
                        buff = uint.max;
                    }
                    else
                    {
                        static if (is(RC == wchar))
                            enum firstMulti = 0xD800; // First high surrogate.
                        else
                            enum firstMulti = 0x80; // First non-ASCII.
                        if (r.front < firstMulti)
                        {
                            buff = r.front;
                            r.popFront;
                        }
                        else
                        {
                            buff = () @trusted { return decodeFront!(Yes.useReplacementDchar)(r); }();
                        }
                    }
                }

                static if (isForwardRange!R)
                {
                    @property auto save() return scope
                    {
                        auto ret = this;
                        ret.r = r.save;
                        return ret;
                    }
                }

                uint buff;
                R r;
            }

            return Result(r);
        }
        else
        {
            static struct Result
            {
                @property bool empty()
                {
                    return pos == fill && r.empty;
                }

                @property auto front() scope // 'scope' required by call to decodeFront() below
                {
                    if (pos == fill)
                    {
                        pos = 0;
                        auto c = r.front;

                        static if (C.sizeof >= 2 && RC.sizeof >= 2)
                            enum firstMulti = 0xD800; // First high surrogate.
                        else
                            enum firstMulti = 0x80; // First non-ASCII.
                        if (c < firstMulti)
                        {
                            fill = 1;
                            r.popFront;
                            buf[pos] = cast(C) c;
                        }
                        else
                        {
                            static if (is(RC == dchar))
                            {
                                r.popFront;
                                dchar dc = c;
                            }
                            else
                                dchar dc = () @trusted { return decodeFront!(Yes.useReplacementDchar)(r); }();
                            fill = cast(ushort) encode!(Yes.useReplacementDchar)(buf, dc);
                        }
                    }
                    return buf[pos];
                }

                void popFront()
                {
                    if (pos == fill)
                        front;
                    ++pos;
                }

                static if (isForwardRange!R)
                {
                    @property auto save() return scope
                    /* `return scope` cannot be inferred because compiler does not
                     * track it backwards from assignment to local `ret`
                     */
                    {
                        auto ret = this;
                        ret.r = r.save;
                        return ret;
                    }
                }

            private:

                R r;
                C[4 / C.sizeof] buf = void;
                ushort pos, fill;
            }

            return Result(r);
        }
    }
}

private dchar _utfException(UseReplacementDchar useReplacementDchar)(string msg, dchar c)
{
    static if (useReplacementDchar)
        return replacementDchar;
    else
        throw new UTFException(msg).setSequence(c);
}

/++
    Check whether the given Unicode code point is valid.

    Params:
        c = code point to check

    Returns:
        `true` if and only if `c` is a valid Unicode code point

    Note:
    `'\uFFFE'` and `'\uFFFF'` are considered valid by `isValidDchar`,
    as they are permitted for internal use by an application, but they are
    not allowed for interchange by the Unicode standard.
  +/
bool isValidDchar(dchar c) pure nothrow @safe @nogc
{
    return c < 0xD800 || (c > 0xDFFF && c <= 0x10FFFF);
}


template Flag(string name) {
    ///
    enum Flag : bool
    {
        /**
         When creating a value of type `Flag!"Name"`, use $(D
         Flag!"Name".no) for the negative option. When using a value
         of type `Flag!"Name"`, compare it against $(D
         Flag!"Name".no) or just `false` or `0`.  */
        no = false,

        /** When creating a value of type `Flag!"Name"`, use $(D
         Flag!"Name".yes) for the affirmative option. When using a
         value of type `Flag!"Name"`, compare it against $(D
         Flag!"Name".yes).
        */
        yes = true
    }
}

/**
Convenience names that allow using e.g. `Yes.encryption` instead of
`Flag!"encryption".yes` and `No.encryption` instead of $(D
Flag!"encryption".no).
*/
struct Yes
{
    template opDispatch(string name)
    {
        enum opDispatch = Flag!name.yes;
    }
}
//template yes(string name) { enum Flag!name yes = Flag!name.yes; }

/// Ditto
struct No
{
    template opDispatch(string name)
    {
        enum opDispatch = Flag!name.no;
    }
}

alias UseReplacementDchar = Flag!"useReplacementDchar";

/++
    Encodes `c` into the static array, `buf`, and returns the actual
    length of the encoded character (a number between `1` and `4` for
    `char[4]` buffers and a number between `1` and `2` for
    `wchar[2]` buffers).

    Throws:
        `UTFException` if `c` is not a valid UTF code point.
  +/
size_t encode(UseReplacementDchar useReplacementDchar = No.useReplacementDchar)(
    out char[4] buf, dchar c) @safe pure
{
    if (c <= 0x7F)
    {
        assert(isValidDchar(c));
        buf[0] = cast(char) c;
        return 1;
    }
    if (c <= 0x7FF)
    {
        assert(isValidDchar(c));
        buf[0] = cast(char)(0xC0 | (c >> 6));
        buf[1] = cast(char)(0x80 | (c & 0x3F));
        return 2;
    }
    if (c <= 0xFFFF)
    {
        if (0xD800 <= c && c <= 0xDFFF)
            c = _utfException!useReplacementDchar("Encoding a surrogate code point in UTF-8", c);

        assert(isValidDchar(c));
    L3:
        buf[0] = cast(char)(0xE0 | (c >> 12));
        buf[1] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf[2] = cast(char)(0x80 | (c & 0x3F));
        return 3;
    }
    if (c <= 0x10FFFF)
    {
        assert(isValidDchar(c));
        buf[0] = cast(char)(0xF0 | (c >> 18));
        buf[1] = cast(char)(0x80 | ((c >> 12) & 0x3F));
        buf[2] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf[3] = cast(char)(0x80 | (c & 0x3F));
        return 4;
    }

    assert(!isValidDchar(c));
    c = _utfException!useReplacementDchar("Encoding an invalid code point in UTF-8", c);
    goto L3;
}

///
struct RCString
{
private:
    rcarray!ubyte _support;
public:

    /**
    Constructs a qualified rcstring out of a number of bytes
    that will use the provided allocator object.
    For `immutable` objects, a `RCISharedAllocator` must be supplied.
    If no allocator is passed, the default allocator will be used.

    Params:
         allocator = a $(REF RCIAllocator, std,experimental,allocator) or
                     $(REF RCISharedAllocator, std,experimental,allocator)
                     allocator object
         bytes = a variable number of bytes, either in the form of a
                  list or as a built-in RCString

    Complexity: $(BIGOH m), where `m` is the number of bytes.
    */
    this(this Q)(ubyte[] bytes...)
    if (!is(Q == shared))
    {
        _support = typeof(_support)(bytes);
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
    Constructs a qualified rcstring out of a string
    that will use the provided allocator object.
    For `immutable` objects, a `RCISharedAllocator` must be supplied.
    If no allocator is passed, the default allocator will be used.

    Params:
         allocator = a $(REF RCIAllocator, std,experimental,allocator) or
                     $(REF RCISharedAllocator, std,experimental,allocator)
                     allocator object
         s = input string

    Complexity: $(BIGOH m), where `m` is the number of bytes of the input string.
    */
    this()(string s)
    {
        import std.string : representation;
        this(s.dup.representation);
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;
        auto s = RCString("dlang");
        assert(s.by!char == "dlang");
    }

    /// ditto
    this(this Q)(dstring s)
    {
        pragma(msg, "===");
        alias T = typeof(s.byUTF!char);
        pragma(msg, T.stringof, " ", isInputRange!T, " ", isSomeChar!(ElementType!T), " ", isSomeString!T);
        pragma(msg, ElementType!T.stringof);
        pragma(msg, "===");
        this(s.byUTF!char);
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;
        auto s = RCString("dlang"d);
        assert(s.by!char == "dlang");
    }

    version(none)
    {
    /// ditto
    this(this Q)(wstring s)
    {
        this(s.byUTF!char);
    }

    ///
    @safe unittest
    {
        import std.algorithm.comparison : equal;
        auto s = RCString("dlang"w);
        assert(s.by!char == "dlang");
    }
    }

    /**
    Constructs a qualified rcstring out of an input range
    that will use the provided allocator object.
    For `immutable` objects, a `RCISharedAllocator` must be supplied.
    If no allocator is passed, the default allocator will be used.

    Params:
         allocator = a $(REF RCIAllocator, std,experimental,allocator) or
                     $(REF RCISharedAllocator, std,experimental,allocator)
                     allocator object
         r = input range

    Complexity: $(BIGOH n), where `n` is the number of elemtns of the input range.
    */
    this(this Q, R)(R r)
    if (!is(Q == shared)
        && isInputRange!R && isSomeChar!(ElementType!R) && !isSomeString!R)
    {
        static if (is(typeof(R.init.length)))
            _support.reserve(r.length);
        foreach (e; r.byUTF!char)
            _support ~= cast(ubyte) e;
    }

    ///
    @safe unittest
    {
        import std.range : take;
        import std.utf : byCodeUnit;
        auto s = RCString("dlang".byCodeUnit.take(10));
        assert(s == "dlang");
    }

    ///
    @nogc nothrow pure @safe
    bool empty() const
    {
        return _support.length == 0;
    }

    ///
    @safe unittest
    {
        import std.string : representation;
        assert(!RCString("dlang".dup.representation).empty);
        assert(RCString("".dup.representation).empty);
    }

    ///
    @trusted
    auto by(T)()
    if (is(T == char) || is(T == wchar) || is(T == dchar))
    {
        rcarray!char tmp = *cast(rcarray!char*)(&_support);
        static if (is(T == char))
        {
            return tmp;
        }
        else
        {
            //import std.utf : byUTF;
            return tmp.byUTF!T();
        }
    }

    /// TODO
    version(none)
    @safe unittest
    {
        import std.algorithm.comparison : equal;
        import std.utf : byChar, byWchar;
        auto hello = RCString("你好");
        assert(hello.by!char == "你好".byChar);
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
        static if (is(typeof(R.init.length)))
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
        assert((r1 ~ r2).by!char == "abcdef");
        assert((r1 ~ "foo").by!char == "abcfoo");
        assert(("abc" ~ r2).by!char == "abcdef");
        assert((r1 ~ 'd').by!char == "abcd");
        assert(('a' ~ r2).by!char == "adef");
    }

    ///
    @safe unittest
    {
        import std.range : take;
        import std.utf : byCodeUnit;
        auto r1 = RCString("abc");
        auto r2 = "def".byCodeUnit.take(3);
        assert((r1 ~ r2).by!char == "abcdef");
        assert((r2 ~ r1).by!char == "defabc");
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
        assert(r1.by!char == "abcdef");
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
        assert(r1.by!char == "abcdef");
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
        assert(r1.by!char == "abcd");
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
        assert(r1.by!char == "abcfoo");
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
        return _support == rhs.representation;
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

    version(none)
    {
    bool opEquals(R)(R r)
    if (isSomeChar!(ElementType!R) && isInputRange!R && !isSomeString!R)
    {
        alias ET = Unqual!(ElementType!R);

        pragma(msg, "+++");
        pragma(msg, R.stringof);
        pragma(msg, ET.stringof);
        pragma(msg, "+++");
        auto s = by!ET();
        while (!s.empty && !r.empty)
        {
            if (s.front != r.front)
                return false;
            s.popFront;
            r.popFront;
        }
        if (s.empty && r.empty)
            return true;
        return false;
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
        assert(a[0 .. 2].by!char == "ab");
        assert(a[2 .. $].by!char == "cdef");
        assert(a[3 .. $ - 1].by!char == "de");
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

    auto writeln(T...)(T rhs)
    {
        import std.stdio : writeln;
        return by!char.writeln(rhs);
    }

    version(none) // TODO
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
        assert(r1.by!char == "ab00ef");
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
        assert(rc.by!char == "foo");
        rc = RCString("bar1");
        assert(rc.by!char == "bar1");
        rc = "bar2";
        assert(rc.by!char == "bar2");

        import std.range : take;
        import std.utf : byCodeUnit;
        rc = "bar3".take(10).byCodeUnit;
        assert(rc.by!char ==  "bar3");
    }

    auto dup()()
    {
        RCString s;
        s._support = _support.dup();
        return s;
    }

    ///
    @safe unittest
    {
        auto s = RCString("foo");
        s = RCString("bar");
        assert(s.by!char == "bar");
        auto s2 = s.dup;
        s2 = RCString("fefe");
        assert(s.by!char == "bar");
        assert(s2.by!char == "fefe");
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
        assert(s.by!char == "bar");
        auto s2 = s.dup;
        s2 = RCString("fefe");
        assert(s.by!char == "bar");
        assert(s2.by!char == "fefe");
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
        assert(s.by!char == "far");
    }

    ///
    auto opIndexAssign(char c)
    {
        _support[] = cast(ubyte) c;
    }

    ///
    auto toHash()
    {
        return _support.hashOf;
    }

    ///
    @safe unittest
    {
        auto rc = RCString("abc");
        assert(rc.toHash == RCString("abc").toHash);
        rc ~= 'd';
        assert(rc.toHash == RCString("abcd").toHash);
        assert(RCString().toHash == RCString().toHash);
    }
}

@safe unittest
{
    import std.algorithm.comparison : equal;

    auto buf = cast(ubyte[])("aaa".dup);
    auto s = RCString(buf);

    assert(s.by!char == "aaa");
    s.by!char[0] = 'b';
    assert(s.by!char == "baa");
}

@safe unittest
{
    import std.algorithm.comparison : equal;

    auto buf = cast(ubyte[])("hell\u00F6".dup);
    auto s = RCString(buf);

    assert(s.by!char() == ['h', 'e', 'l', 'l', 0xC3, 0xB6]);

    // `wchar`s are able to hold the ö in a single element (UTF-16 code unit)
    // TODO
    //assert(s.by!wchar() == ['h', 'e', 'l', 'l', 'ö']);
}

@safe unittest
{
    import std.algorithm.comparison : equal;

    auto buf = cast(ubyte[])("hello".dup);
    auto s = RCString(buf);
    auto charStr = s.by!char;

    charStr[$ - 2] = cast(ubyte) 0xC3;
    charStr[$ - 1] = cast(ubyte) 0xB6;

    // TODO
    //assert(s.by!wchar().equal(['h', 'e', 'l', 'ö']));
}
