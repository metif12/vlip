module vlip

// Value is the runtime representation of every vlip datum, plus the environment
// and closure machinery the machine needs.
//
// Three V facts shaped this, all found by measurement rather than by reading the
// documentation (src/gc_probe.v, src/bench_value.v, tools/sumtype_local.v):
//
//  1. A boxed sum type cannot represent a pair. `struct cons_v { tail Lst }` is
//     rejected as `invalid recursive struct`, and a sum-type variant field
//     cannot be initialised from a local at all. The representation V would
//     hand us for free does not exist.
//
//  2. A `voidptr` field is not a GC root. An object reachable only through one
//     is collected: a 2,000,000-cell cons chain walked 25 cells. So the payload
//     must be a TYPED reference.
//
//  3. `&T` fields trigger V's reference and aliasing rules hard enough that
//     walking a linked list of them is not writable: `cur = cur.parent` is
//     rejected as "cannot be assigned outside unsafe". So environments are
//     referenced by i32 index into an arena, which sidesteps the question and
//     matches how the datum arena already works.

import strconv

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
	array     // mutable vector
	table     // immutable map
	buffer    // mutable map
	closure
	primitive
	continuation
}

// NodeId indexes the reader's flat arena. It lives here rather than in the
// reader so closures can name a body form without the core importing the
// reader, which would be circular: the reader needs Value.
pub type NodeId = i32

pub const no_node = NodeId(-1)

// Anything a Value can point at.
//
// The method is REQUIRED. A method-less marker interface holding a struct
// compiles and then dies with `invalid memory access` in both dev and -prod
// builds on V 0.5.2.
pub interface Payload {
	payload_tag() Tag
}

// Scalars share this zero-sized sentinel. V requires an interface field to be
// initialised, and none of the scalars allocate -- which is the entire reason
// Value is not a sum type.
pub struct NoPayload {}

pub fn (n &NoPayload) payload_tag() Tag {
	return .nil
}

pub const no_payload = Payload(&NoPayload{})

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
	tag  Tag
	data []Value
}

pub fn (v &Vector) payload_tag() Tag {
	return v.tag
}

// Table is an immutable string-keyed map. A buffer uses the same payload with a
// different tag, so `get`/`put` serve both and mutability is visible in the tag.
pub struct Table {
pub:
	tag    Tag
	values map[string]Value
}

pub fn (t &Table) payload_tag() Tag {
	return t.tag
}

// keys is sorted, not insertion-ordered. A table whose iteration order varied
// between runs would make every error message and every test output unstable.
pub fn (t &Table) keys() []string {
	mut out := []string{}
	out << t.values.keys()
	out.sort()
	return out
}

// get returns nil for an absent key. Absent is nil, not an error, which is what
// makes `(get tbl k)` total.
pub fn (t &Table) get(k string) Value {
	if k in t.values {
		return t.values[k]
	}
	return nil_value()
}

pub fn (t &Table) has(k string) bool {
	return k in t.values
}

// Not `@[packed]`: packing forces byte alignment, which misaligns the pointer
// inside the interface field and crashes. Natural alignment costs nothing here.
@[direct_array_access]
pub struct Value {
pub mut:
	tag     Tag
	i       i64
	f       f64
	payload Payload
}

// ---- constructors ----------------------------------------------------------

pub fn nil_value() Value {
	return Value{
		tag:     .nil
		payload: no_payload
	}
}

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

pub fn string(s string) Value {
	return Value{
		tag: .string
		payload: &StringPayload{
			tag: .string
			s:   s
		}
	}
}

pub fn symbol(name string) Value {
	return Value{
		tag: .symbol
		payload: &StringPayload{
			tag: .symbol
			s:   name
		}
	}
}

pub fn keyword(name string) Value {
	return Value{
		tag: .keyword
		payload: &StringPayload{
			tag: .keyword
			s:   name
		}
	}
}

pub fn cons(car Value, cdr Value) Value {
	return Value{
		tag: .pair
		payload: &Pair{
			tag: .pair
			car: car
			cdr: cdr
		}
	}
}

// list_from builds a cons chain right to left.
pub fn list_from(items []Value) Value {
	mut out := nil_value()
	mut i := items.len - 1
	for i >= 0 {
		out = cons(items[i], out)
		i--
	}
	return out
}

pub fn vector(items []Value) Value {
	return Value{
		tag: .vector
		payload: &Vector{
			tag:  .vector
			data: items
		}
	}
}

pub fn table(m map[string]Value) Value {
	return Value{
		tag: .table
		payload: &Table{
			tag:    .table
			values: m
		}
	}
}

pub fn buffer(m map[string]Value) Value {
	return Value{
		tag: .buffer
		payload: &Table{
			tag:    .buffer
			values: m
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
	assert v.tag in [.string, .symbol, .keyword, .primitive]
	return (v.payload as &StringPayload).s
}

@[inline]
pub fn (v Value) as_pair() &Pair {
	assert v.tag == .pair
	return v.payload as &Pair
}

@[inline]
pub fn (v Value) as_vector() &Vector {
	assert v.tag == .vector || v.tag == .array
	return v.payload as &Vector
}

@[inline]
pub fn (v Value) as_table() &Table {
	assert v.tag == .table || v.tag == .buffer
	return v.payload as &Table
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

// ---- environments ----------------------------------------------------------

// Env is one lexical scope. Environments live in an arena and are referenced by
// index, for the reason given at the top of this file.
pub type EnvId = i32

pub const no_env = EnvId(-1)

pub struct Env {
pub mut:
	parent EnvId
	names  []string
	vals   []Value
}

pub struct EnvArena {
pub mut:
	frames []Env
}

pub fn (mut ea EnvArena) new_env(parent EnvId) EnvId {
	ea.frames << Env{
		parent: parent
		names:  []string{}
		vals:   []Value{}
	}
	return EnvId(ea.frames.len - 1)
}

pub fn (ea &EnvArena) get(id EnvId) &Env {
	if id == no_env {
		return unsafe { nil }
	}
	return &ea.frames[int(id)]
}

pub fn (mut ea EnvArena) define(id EnvId, name string, val Value) {
	mut frame := ea.get(id)
	for i, n in frame.names {
		if n == name {
			frame.vals[i] = val
			return
		}
	}
	frame.names << name
	frame.vals << val
}

pub fn (mut ea EnvArena) lookup(id EnvId, name string) ?Value {
	mut cur := id
	for cur != no_env {
		frame := ea.get(cur)
		for i, n in frame.names {
			if n == name {
				return frame.vals[i]
			}
		}
		cur = frame.parent
	}
	return none
}

// set assigns to the frame that owns the binding, so a `set!` inside a closure
// is visible on that closure's next call.
pub fn (mut ea EnvArena) set(id EnvId, name string, val Value) bool {
	mut cur := id
	for cur != no_env {
		mut frame := ea.get(cur)
		for i, n in frame.names {
			if n == name {
				frame.vals[i] = val
				return true
			}
		}
		cur = frame.parent
	}
	return false
}

// ---- callables -------------------------------------------------------------

pub struct Closure {
pub:
	params []string
	body   NodeId
	env    EnvId
	name   string
	arity  int
}

pub fn (c &Closure) payload_tag() Tag {
	return .closure
}

pub fn new_closure(params []string, body NodeId, env EnvId, name string) Value {
	return Value{
		tag: .closure
		payload: &Closure{
			params: params
			body:   body
			env:    env
			name:   name
			arity:  params.len
		}
	}
}

@[inline]
pub fn (v Value) as_closure() &Closure {
	assert v.tag == .closure
	return v.payload as &Closure
}

// PrimFn takes only its arguments, deliberately: if it took the machine, this
// module and the machine would be mutually dependent. The few builtins that need
// the interpreter are handled by the machine itself.
pub type PrimFn = fn (args []Value) !Value

// A primitive Value carries only its name; the implementation lives in the
// machine's table keyed by that name.
pub fn new_prim(name string) Value {
	return Value{
		tag: .primitive
		payload: &StringPayload{
			tag: .primitive
			s:   name
		}
	}
}

// Kont is ONE tagged struct rather than a sum type. That is a workaround for a V
// 0.5.2 limitation: a sum-type variant cannot have a field initialised from a
// local (`if_k{outcome: x}` fails with "x evaluated but not used"), so
// continuations could not be a sum type at all.
@[flag]
pub enum KontTag {
	done
	app_fn // operator evaluated; arguments remain
	app_arg // evaluating one argument
	if_k // evaluating an if test
	seq // begin: more expressions remain
	define_k
	set_k
	and_k
	or_k
}

pub struct Kont {
pub mut:
	tag  KontTag
	expr NodeId // the form being evaluated when this frame was pushed
	env  EnvId
	slot int // which child or argument index
	rest NodeId // the enclosing form
	acc  []Value
	name string
}

// ---- misc ------------------------------------------------------------------

// AtoF64Param is not exported by name in this V version, so it is built from its
// only public field. allow_extra_chars must be false: parsing "12abc" has to be
// rejected rather than silently yielding 12.
pub const strict_float = strconv.AtoF64Param{
	allow_extra_chars: false
}