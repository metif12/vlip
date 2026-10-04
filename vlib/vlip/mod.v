module vlip

// Value is the runtime representation of every vlip datum.
//
// Two V facts shaped this, both found by measurement (src/gc_probe.v,
// src/bench_value.v):
//
//  1. A boxed sum type cannot represent a pair. `struct cons_v { tail Lst }` is
//     rejected as `invalid recursive struct`, and a sum-type variant field
//     cannot be initialised from a local at all (`error: x evaluated but not
//     used`) -- no loop or recursion required. So the option V would give us for
//     free does not exist.
//
//  2. A `voidptr` field is not a GC root. An object reachable only through one is
//     collected: a 2-million-cell cons chain walked 25 cells. V derives GC roots
//     from typed fields, and a voidptr does not say what it points at.
//
// Therefore `payload` is a typed `Payload` interface. An interface field is a
// genuine root, and scalars store `none`, so they still allocate nothing. The
// cost is two words per datum for the tag-and-pointer pair, which is the price
// of correctness rather than a tuning knob.

@[flag]
pub enum Tag {
	nil // the empty value
	boolean
	integer
	float
	rune      // code point, in `i`
	string
	symbol    // interned string
	keyword   // interned string, self-evaluating, callable
	pair
	vector
	array     // mutable
	table     // immutable
	buffer    // mutable
	closure
	primitive
	continuation
}

// Anything a Value can point at. Exists as an interface for one reason: so the
// reference in `Value.payload` is typed, and therefore visible to the GC.
//
// The method is required. A method-less marker interface holding a struct
// compiles and then dies with `invalid memory access` in both dev and -prod
// builds on V 0.5.2; adding one method fixes it. Keep the method.
pub interface Payload {
	payload_tag() Tag
}

pub struct StringPayload {
pub:
	tag Tag
	s   string
}

pub fn (p &StringPayload) payload_tag() Tag {
	return p.tag
}

pub struct Pair {
pub:
	tag Tag
	car Value
	cdr Value
}

pub fn (p &Pair) payload_tag() Tag {
	return p.tag
}

pub struct Vector {
pub:
	tag Tag
	data []Value
}

pub fn (v &Vector) payload_tag() Tag {
	return v.tag
}

// Not `@[packed]`: packing forces byte alignment, which misaligns the 8-byte
// pointer inside the interface field and crashes on any real target. Natural
// alignment costs nothing here anyway.
@[direct_array_access]
pub struct Value {
pub mut:
	tag     Tag
	i       i64
	f       f64
	payload Payload
}

// ---- constructors ----------------------------------------------------------

// Scalars carry no payload. V requires an interface field to be initialized,
// so they all share one zero-sized sentinel rather than leaving it unset.
pub struct NoPayload {}

pub fn (n &NoPayload) payload_tag() Tag {
	return .nil
}

pub const no_payload = Payload(&NoPayload{})

pub fn nil() Value {
	return Value{
		tag:     .nil
		payload: no_payload
	}
}

// Scalars share the no_payload sentinel. None of these allocate, which is the
// entire reason Value is not a sum type -- see docs/000-vlip-design.md.
pub fn boolean(b bool) Value {
	return Value{
		tag:     .boolean
		i:       if b { 1 } else { 0 }
		payload: no_payload
	}
}

pub fn integer(n i64) Value {
	return Value{
		tag:     .integer
		i:       n
		payload: no_payload
	}
}

pub fn float(f f64) Value {
	return Value{
		tag:     .float
		f:       f
		payload: no_payload
	}
}

pub fn rune(r u32) Value {
	return Value{
		tag:     .rune
		i:       i64(r)
		payload: no_payload
	}
}

pub fn rational(n i64, d i64) Value {
	return Value{
		tag:     .float // rendered as a fraction by the printer
		i:       n
		f:       f64(d)
		payload: no_payload
	}
}

pub fn keyword(name string) Value {
	return Value{
		tag:     .keyword
		payload: &StringPayload{
			tag: .keyword
			s:   name
		}
	}
}

pub fn symbol(name string) Value {
	return Value{
		tag:     .symbol
		payload: &StringPayload{
			tag: .symbol
			s:   name
		}
	}
}

pub fn string(s string) Value {
	return Value{
		tag:     .string
		payload: &StringPayload{
			tag: .string
			s:   s
		}
	}
}

pub fn cons(car Value, cdr Value) Value {
	return Value{
		tag:     .pair
		payload: &Pair{
			tag: .pair
			car: car
			cdr: cdr
		}
	}
}

// ---- accessors -------------------------------------------------------------

@[inline]
pub fn (v Value) as_int() i64 {
	assert v.tag == .integer || v.tag == .rune
	return v.i
}

@[inline]
pub fn (v Value) as_float() f64 {
	assert v.tag == .float
	return v.f
}

@[inline]
pub fn (v Value) as_bool() bool {
	assert v.tag == .boolean
	return v.i != 0
}

@[inline]
pub fn (v Value) as_string() string {
	assert v.tag in [.string, .symbol, .keyword]
	return (v.payload as &StringPayload).s
}

@[inline]
pub fn (v Value) as_pair() &Pair {
	assert v.tag == .pair
	return v.payload as &Pair
}

@[inline]
pub fn (v Value) as_vector() &Vector {
	assert v.tag == .vector
	return v.payload as &Vector
}

// Only `#f` is false -- as in R5RS and Clojure. `0`, `""`, `nil`, `()` and
// `(quote ())` are all true. Ruby and JavaScript say the opposite, which is why
// everyone arriving from them has to relearn this.
@[inline]
pub fn (v Value) truthy() bool {
	return !(v.tag == .boolean && v.i == 0)
}

@[inline]
pub fn (v Value) is_nil() bool {
	return v.tag == .nil
}