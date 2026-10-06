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
	nil // the empty value: absence of a result
	boolean
	integer
	float
	rune      // code point, in `i`
	string
	symbol    // interned string
	keyword   // interned string, self-evaluating, callable
	pair
	emptylist // the empty list: a sequence of length zero
	vector
	array     // mutable vector
	table     // immutable map
	buffer    // mutable map
	closure
	primitive
	continuation
	struct_   // a struct instance; the constructor name is in the payload
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

// StructVal is a struct instance. Fields are kept in DECLARATION order, not
// sorted: `(Point 1 2)` has to print the way it was written, and a sorted map
// prints `(Point 2 1)`. Table's `keys()` sorts because a table's order is not
// anyone's business; a struct's field order is the declaration.
pub struct StructVal {
pub:
	name   string
	fields []string
	values map[string]Value
}

pub fn (s &StructVal) payload_tag() Tag {
	return .struct_
}

pub fn (s &StructVal) get(k string) Value {
	if k in s.values {
		return s.values[k]
	}
	return nil_value()
}

pub fn (s &StructVal) has(k string) bool {
	return k in s.values
}

// at returns a field by its index in the declaration.
pub fn (s &StructVal) at(i int) Value {
	return s.values[s.fields[i]]
}

// update returns a copy with one field replaced. Structs are immutable, so
// `p.y := 99` builds a new value and leaves the original alone -- which is the
// whole reason the syntax exists instead of `set!`.
pub fn (s &StructVal) with(k string, v Value) &StructVal {
	mut mm := map[string]Value{}
	for f in s.fields {
		if f == k {
			mm[f] = v
		} else {
			mm[f] = s.values[f]
		}
	}
	return &StructVal{
		name:   s.name
		fields: s.fields
		values: mm
	}
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

// Mutators take `&Vector`/`&Table` and need `unsafe`, because a `&T` receiver is
// immutable in V and these deliberately mutate the shared payload. They live here
// rather than in prims because the struct is declared here, and prims cannot reach
// through an immutable reference to a field of another module's struct.
//
// `mut v Vector` is NOT accepted as an alternative on V 0.5.2 for a receiver that
// is only ever obtained from a `&Vector`: the checker rejects the pair of methods
// with "use (mut v Vector) or (v &Vector) instead of (mut v &Vector)" and then
// rejects the mutation itself. The `unsafe` is the shape that compiles.
pub fn (v &Vector) set_at(i int, val Value) {
	unsafe {
		v.data[i] = val
	}
}

pub fn (v &Vector) push(val Value) {
	unsafe {
		// `.clone()` and not a straight assignment: V treats `mut d := v.data` on an
		// immutable receiver as aliasing, and rejects it. Cloning is CORRECT here
		// rather than a copy that breaks sharing, because every accessor reads
		// `v.data` again -- nothing else holds the old slice descriptor.
		mut d := v.data.clone()
		d << val
		v.data = d
	}
}

pub fn (v &Vector) pop() Value {
	unsafe {
		mut d := v.data.clone()
		last := d[d.len - 1]
		d = d[..d.len - 1]
		v.data = d
		return last
	}
}

pub fn (t &Table) set_at(k string, val Value) {
	unsafe {
		mut m := t.values
		m[k] = val
		t.values = m
	}
}

pub fn (t &Table) delete_at(k string) {
	unsafe {
		mut m := t.values
		m.delete(k)
		t.values = m
	}
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

// empty_list is the empty list, which is NOT the nil value.
//
// The examples assert both `(get {:a 1} :missing) ;=> nil` and `(list) ;=> ()`,
// so one value cannot print both ways. They are therefore two values, and
// `null?` / `nil?` are true of both -- which is also what Clojure does, and it
// is the only reading under which `nil` means "no result" while `(cdr '(1))`
// still reads back as `()`.
//
// The alternative, printing nil as `()`, makes every absent lookup and every
// missing argument indistinguishable from an empty sequence at a glance.
pub fn empty_list() Value {
	return Value{
		tag:     .emptylist
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

// list_from builds a cons chain right to left. An empty input gives the empty
// list, not nil: `list_from` is how a cons chain's base case is built, so the
// base case has to be a sequence.
pub fn list_from(items []Value) Value {
	if items.len == 0 {
		return empty_list()
	}
	mut out := empty_list()
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

pub fn struct_value(name string, fields []string, vals map[string]Value) Value {
	return Value{
		tag: .struct_
		payload: &StructVal{
			name:   name
			fields: fields
			values: vals
		}
	}
}

@[inline]
pub fn (v Value) as_struct() &StructVal {
	assert v.tag == .struct_
	return v.payload as &StructVal
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

// is_empty_seq is what `null?` asks: true for the empty list AND for nil, because
// both mean "no elements here", and the examples assert `(null? '())` is true.
@[inline]
pub fn (v Value) is_empty_seq() bool {
	return v.tag == .nil || v.tag == .emptylist
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

// Closure carries `rest` as a flag rather than a magic parameter name.
//
// The obvious version binds the rest to a parameter literally called `rest` and
// checks `params.last == 'rest'`. That makes `(define (f rest) ...)` -- a
// perfectly ordinary function of one argument -- silently variadic, and it makes
// the flag invisible in the parameter list, so a caller reading the signature
// cannot tell arity from arity-at-least.
//
// A flag costs one bool and keeps both cases unambiguous: `(define (f a . r) r)`
// is 1-or-more, `(define (f rest) rest)` is exactly 1.
pub struct Closure {
pub:
	params []string
	body   NodeId
	env    EnvId
	name   string
	arity  int
	rest   bool
	// Labelled parameters. `opt_from` is the index of the first one, or -1.
	// The keyword names and defaults are parallel arrays from there on, and a
	// default of `no_default` means the label is required.
	//
	// They are arena NodeIds rather than values because a default is evaluated at
	// the CALL, in the caller's scope -- `(connect #:port (+ port 1))` has to see
	// the caller's `port`. Baking the value into the closure at definition time
	// would evaluate it once, in the definition's scope, and be wrong.
	opt_from     int = -1
	opt_names    []string
	opt_defaults []NodeId
}

pub const no_default = NodeId(-2)

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

// new_rest_closure is the variadic constructor. `params` EXCLUDES the rest
// name; the rest name is kept separately so binding it cannot collide with an
// ordinary parameter.
pub fn new_rest_closure(params []string, rest_name string, body NodeId, env EnvId, name string) Value {
	mut all := []string{}
	all << params
	all << rest_name
	return Value{
		tag: .closure
		payload: &Closure{
			params: params
			body:   body
			env:    env
			name:   name
			arity:  params.len
			rest:   true
		}
	}
}

// labelled builds the closure for a parameter list that has labelled parameters.
pub fn labelled(params []string, body NodeId, env EnvId, name string, opt_from int, opt_names []string, opt_defaults []NodeId) Value {
	return Value{
		tag: .closure
		payload: &Closure{
			params:      params
			body:        body
			env:         env
			name:        name
			arity:       params.len
			opt_from:    opt_from
			opt_names:   opt_names
			opt_defaults: opt_defaults
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
	field_k // p.y := value, building the new instance
	assert_k // (assert test message)
	use_k // binding the values of an ok Result
	match_k // choosing a match clause
	guard_k // evaluating a #:when guard
	collect_k // evaluating the elements of a vector, table or array literal
	try_k // `try`: running one body form, or its #:finally
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
	// match_k and guard_k carry a clause list and an ordered binding list, which
	// is more state than the index/name fields hold. They live here rather than in
	// a second frame type because Kont is ONE struct on purpose: V 0.5.2 cannot
	// initialise a sum-type variant field from a local, so continuations cannot be
	// a sum type at all. See the note above the type.
	clauses []NodeId
	binds   []string
	vals    []Value
}

// ---- misc ------------------------------------------------------------------

// AtoF64Param is not exported by name in this V version, so it is built from its
// only public field. allow_extra_chars must be false: parsing "12abc" has to be
// rejected rather than silently yielding 12.
pub const strict_float = strconv.AtoF64Param{
	allow_extra_chars: false
}