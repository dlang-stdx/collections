/**
This module defines generic collections.

Collection_primitives:

Collections do not form a class hierarchy, instead they implement a
common set of primitives (see table below). These primitives each guarantee
a specific worst case complexity and thus allow generic code to be written
independently of the _collection implementation.

The following table describes the common set of primitives that collections
implement. A _collection need not implement all primitives, but if a primitive
is implemented, it must support the syntax described in the `syntax` column with
the semantics described in the `description` column, and it must not have a
worst-case complexity worse than denoted in big-O notation in the
$(BIGOH &middot;) column. Below, `C` means a _collection type, `c` is a value of
_collection type, $(D n$(SUBSCRIPT x)) represents the effective length of value
`x`, which could be a single element (in which case $(D n$(SUBSCRIPT x)) is `1`),
a _collection, or a range.

$(BOOKTABLE collection primitives,
$(TR
    $(TH Syntax)
    $(TH $(BIGOH &middot;))
    $(TH Description)
)
$(TR
    $(TDNW $(D C(x)))
    $(TDNW $(D n$(SUBSCRIPT x)))
    $(TD Creates a _collection of type $(D C) from either another _collection,
         a range or an element. The created _collection must not be a null
         reference even if x is empty.)
)
$(TR
    $(TDNW $(D c.dup))
    $(TDNW $(D n$(SUBSCRIPT c)))
    $(TD Returns a duplicate of the _collection.)
)
$(TR
    $(TDNW $(D c ~ x))
    $(TDNW $(D n$(SUBSCRIPT c) + n$(SUBSCRIPT x)))
    $(TD Returns the concatenation of `c` and `x`. `x` may be a single element
         or an input range.)
)
$(TR
    $(TDNW $(D x ~ c))
    $(TDNW $(D n$(SUBSCRIPT c) + n$(SUBSCRIPT x)))
    $(TD Returns the concatenation of `x` and `c`. `x` may be a single element
         or an input range type.)
)
$(LEADINGROWN 3, Iteration
)
$(TR
    $(TD $(D c.popFront()))
    $(TD `1`)
    $(TD Advances to the next element in the _collection.)
)
$(TR
    $(TD $(D c.save))
    $(TD `1`)
    $(TD Return a shallow copy of the _collection.)
)
$(TR
    $(TD $(D c[]))
    $(TDNW $(D n$(SUBSCRIPT c)))
    $(TD Returns a range
         iterating over the entire _collection, in a _collection-defined order.)
)
$(TR
    $(TDNW $(D c[a .. b]))
    $(TDNW $(D n$(SUBSCRIPT c)))
    $(TD Fetches a portion of the _collection from key `a` to key `b`.)
)
$(LEADINGROWN 3, Capacity
)
$(TR
    $(TD $(D c.empty))
    $(TD `1`)
    $(TD Returns `true` if the _collection has no elements, `false` otherwise.)
)
$(TR
    $(TD $(D c.length))
    $(TDNW `1`)
    $(TD Returns the number of elements in the _collection.)
)
$(TR
    $(TDNW $(D c.length = n))
    $(TDNW $(D max(n$(SUBSCRIPT c), n)))
    $(TD Forces the number of elements in the _collection to `n`. If the
         _collection ends up growing, the added elements are initialized
         in a _collection-dependent manner (usually with $(D T.init)).)
)
$(TR
    $(TD $(D c.capacity))
    $(TDNW $(D n$(SUBSCRIPT c)))
    $(TD Returns the maximum number of elements that can be stored in the
         _collection without triggering a reallocation.)
)
$(TR
    $(TD $(D c.reserve(x)))
    $(TD $(D n$(SUBSCRIPT c)))
    $(TD Forces `capacity` to at least `x` without reducing it.)
)
$(LEADINGROWN 3, Access
)
$(TR
    $(TDNW $(D c.front))
    $(TDNW `1`)
    $(TD Returns the first element of the _collection, in a _collection-defined
         order.)
)
$(TR
    $(TDNW $(D c.front = v))
    $(TDNW `1`)
    $(TD Assigns `v` to the first element of the _collection.)
)
$(TR
    $(TDNW $(D c.back))
    $(TDNW $(D log n$(SUBSCRIPT c)))
    $(TD Returns the last element of the _collection, in a _collection-defined order.)
)
$(TR
    $(TDNW $(D c.back = v))
    $(TDNW $(D n$(SUBSCRIPT c)))
    $(TD Assigns `v` to the last element of the _collection.)
)
$(TR
    $(TDNW $(D c[x]))
    $(TDNW $(D n$(SUBSCRIPT c)))
    $(TD Provides indexed access into the _collection. The index type is
         _collection-defined. A _collection may define several index types (and
         consequently overloaded indexing).)
)
$(TR
    $(TDNW $(D c[x] = v))
    $(TDNW $(D n$(SUBSCRIPT c)))
    $(TD Sets element at specified index into the _collection.)
)
$(TR
    $(TDNW $(D c[x] $(I op)= v))
    $(TDNW $(D n$(SUBSCRIPT c)))
    $(TD Performs read-modify-write operation at specified index into the
        _collection.)
)
$(LEADINGROWN 3, Operations
)
$(TR
    $(TDNW $(D e in c))
    $(TDNW $(D n$(SUBSCRIPT c)))
    $(TD Returns nonzero if e is found in $(D c).)
)
$(LEADINGROWN 3, Modifiers
)
$(TR
    $(TDNW $(D c ~= x))
    $(TDNW $(D n$(SUBSCRIPT c) + n$(SUBSCRIPT x)))
    $(TD Appends `x` to `c`. `x` may be a single element or an input range type.)
)
$(TR
    $(TDNW $(D c.clear()))
    $(TDNW $(D n$(SUBSCRIPT c)))
    $(TD Removes all elements in `c`.)
)
$(TR
    $(TDNW $(D c.insert(x)))
    $(TDNW $(D n$(SUBSCRIPT x)))
    $(TD Inserts `x` at the front of `c`. `x` may be a single element or an input
         range type.)
)
$(TR
    $(TDNW $(D c.insertBack(x)))
    $(TDNW $(D n$(SUBSCRIPT c) + n$(SUBSCRIPT x)))
    $(TD Inserts `x` at the back of `c`. `x` may be a single element or an input
         range type.)
)
$(TR
    $(TDNW $(D c.remove()))
    $(TDNW $(D 1))
    $(TD Removes the front element of `c`.)
)

$(TR
    $(TDNW $(D ))
    $(TDNW $(D ))
    $(TD )
)
)

Source: $(PHOBOSSRC std/experimental/_collection/package.d)

License: Distributed under the Boost Software License, Version 1.0.
(See accompanying file LICENSE_1_0.txt or copy at $(HTTP
boost.org/LICENSE_1_0.txt)).

Authors: Eduard Staniloiu, $(HTTP erdani.com, Andrei Alexandrescu)
 */

module stdx.collection;
