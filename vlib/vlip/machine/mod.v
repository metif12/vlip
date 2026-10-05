module machine

// M3: the CEK machine.
//
// State is (control, environment, continuation). Control is either "evaluate
// this form" or "a value came back". The continuation is an explicit array of
// tagged frames, which buys three things:
//
//   * TAIL CALLS ARE FREE. Applying a closure does not push a frame: the body is
//     evaluated with whatever continuations remain. So a tail call -- including
//     MUTUAL recursion -- is a loop iteration rather than a stack mutation.
//     Steel needs a separate TCOJMP opcode for this and still ships
//     SELFTAILCALLNOARITY.
//   * The stack is a plain heap array, so fibers later need no representation
//     change at all: capture the array and resume it.
//   * No bytecode serializer, so there is nothing to version and no encoder to
//     get wrong.
//
// Derived forms (`let`, `when`, `cond`, `loop`, ...) are implemented as
// TRANSFORMATIONS to the core forms, not as extra continuation types. That
// keeps the core small -- quote, if, define, set!, lambda, begin, and
// application -- and means every derived form inherits tail-call behaviour for
// free rather than needing it re-implemented per form.
//
// Kont is one tagged struct rather than a sum type, because V 0.5.2 cannot
// initialise a sum-type variant field from a local. See vlib/vlip/mod.v.

import strconv
import vlib.vlip
import vlib.vlip.host
import vlib.vlip.prims
import vlib.vlip.printer
import vlib.vlip.reader

@[flag]
enum Ctl {
	eval_form
	return_value
}

// Machine is @[heap] so that a `&Machine` is known to point at the heap. Without
// it V refuses every mutation through a machine reference held in another struct
// -- "cannot be assigned outside unsafe blocks as it might refer to an object
// stored on stack" -- which is most of what a REPL or a host does, since both hold
// the machine rather than own it inline.
@[heap]
pub struct Machine {
pub mut:
	arena     &reader.Arena
	kstack    []vlip.Kont
	globals   vlip.EnvId
	envs      vlip.EnvArena
	prims     map[string]vlip.PrimFn
	ctl       Ctl = .eval_form
	form      vlip.NodeId
	env       vlip.EnvId
	val       vlip.Value
	steps     int
	max_steps int = 100_000_000
	max_kont  int = 4_000_000
	out       []string
	gensym    int
	host      host.Host
	// source_name labels where the code being evaluated came from. It appears in
	// every error message, and a REPL that reports "unbound identifier: x" with
	// no indication of which of forty definitions introduced x is unusable.
	// `require` also resolves relative paths against it.
	source string
	// loaded is the set of module paths this machine has already evaluated.
	loaded []string
	// macros names the procedures defmacro created, so macex can tell a macro from
	// a function without guessing from its shape.
	macros []string
}

// new_machine builds a machine over an arena the caller already owns. The suites
// use it because they read their own source.
pub fn new_machine(a &reader.Arena) &Machine {
	return new_machine_with(a, &host.ConsoleHost{})
}

// new_machine_with is new_machine plus a host. Everything else about the machine
// is the same; only where print goes and where `load` reads from differ.
pub fn new_machine_with(a &reader.Arena, h host.Host) &Machine {
	// The reference fields (arena, globals, env, host) must be initialised inside
	// an unsafe block.
	mut m := unsafe {
		&Machine{
			arena:   a
			kstack:  []vlip.Kont{}
			envs:    vlip.EnvArena{}
			globals: vlip.no_env
			env:     vlip.no_env
			prims:   prims.table()
			host:    h
		}
	}
	// The global environment must be a real frame, not `no_env`: `no_env` is the
	// null env, and a `define` into it dereferences nil. Getting this wrong
	// crashes on the first `(define ...)` with no diagnostic.
	m.globals = m.envs.new_env(vlip.no_env)
	m.env = m.globals
	return m
}

// new_standalone builds a machine that owns its arena, so an embedder does not
// have to keep one alive or know that it has to.
//
// The arena is a heap reference rather than a field the caller passes in, because
// a second source read APPENDS to it: every NodeId already stored in a closure or
// a continuation frame has to stay valid, so there can only ever be one.
pub fn new_standalone(h host.Host) &Machine {
	a := &reader.Arena{
		nodes:    []reader.Datum{}
		children: []reader.NodeId{}
	}
	return new_machine_with(a, h)
}


// ---------------------------------------------------------------- the loop

// reset returns the control state to "nothing in flight".
//
// Without it, an ABORTED program leaves its continuation frames on the stack, and
// the next evaluation returns into them instead of finishing. The symptom is not
// an error: it is a wrong value, produced by a stale frame from a program that
// already failed. tests/embedding.v provokes it on purpose.
//
// `quasi_to_value` saves and restores the same fields by hand, because it calls
// eval_one from the MIDDLE of an evaluation and must not clear what it is in.
fn (mut m Machine) reset() {
	m.kstack = []vlip.Kont{}
	m.ctl = .eval_form
	m.env = m.globals
	m.form = vlip.no_node
	m.val = vlip.nil_value()
}

// run evaluates top-level forms in order and returns the last value.
pub fn (mut m Machine) run(forms []vlip.NodeId) !vlip.Value {
	mut last := vlip.nil_value()
	// An index loop, not `for f in forms`: the element type is a type alias from
	// another module, and V 0.5.2 emits the unresolved name into the generated C
	// for a range loop over such a slice. See docs/010-roadmap.md 7.3.
	mut i := 0
	for i < forms.len {
		m.reset()
		m.form = forms[i]
		m.ctl = .eval_form
		last = m.drive()!
		i++
	}
	return last
}

// run_str parses and evaluates `src` in THIS machine and returns the last value.
//
// One call, so an embedder never holds an Arena or a form list. The nodes are
// appended to the machine's own arena rather than read into a fresh one: a
// closure defined by the first run_str holds a NodeId, and a second arena would
// renumber it.
pub fn (mut m Machine) run_str(src string) !vlip.Value {
	res := m.arena.read_forms(src)
	return m.run_checked(res)
}

// run_forms evaluates forms already read into this machine's arena. It reports
// read diagnostics as an error rather than printing them, because a caller that
// embeds a machine has no one to print to.
pub fn (mut m Machine) run_checked(res reader.Forms) !vlip.Value {
	if res.diags.len > 0 {
		d := res.diags[0]
		return error('${m.where()}:${d.line}:${d.col}: ${d.msg}${
			if res.diags.len > 1 { ' (and ${res.diags.len - 1} more)' } else { '' }}')
	}
	return m.run(res.forms)
}

// load reads `path` through the host and evaluates it in this machine, so
// definitions made in the file are visible to the caller afterwards.
//
// It deliberately does not create a machine of its own. A `load` that started a
// fresh machine would run the file perfectly and then throw away every definition
// in it, which is the specific failure the roadmap calls out.
pub fn (mut m Machine) load(path string) !vlip.Value {
	src := m.host.host_load(path)!
	prev := m.source
	m.source = path
	res := m.arena.read_forms(src)
	out := m.run_checked(res)!
	m.source = prev
	return out
}

// where labels the current source for an error message.
pub fn (m &Machine) where() string {
	if m.source == '' {
		return 'vlip'
	}
	return m.source
}

// render_node prints a form back to source, for an error message that has to name
// a pattern or a message string.
pub fn (m &Machine) render_node(n vlip.NodeId) string {
	if n == vlip.no_node {
		return ''
	}
	return printer.write_datum(m.arena, n)
}

// eval_one evaluates a single form, for the REPL. It resets the control state
// first, so a form that failed to evaluate leaves nothing behind.
pub fn (mut m Machine) eval_one(f vlip.NodeId) !vlip.Value {
	m.reset()
	m.form = f
	m.ctl = .eval_form
	return m.drive()
}

// eval_string parses and evaluates `src` as a sequence of top-level forms,
// evaluating each in turn and returning the last value. Unlike run_str it does
// not stop at the first failure: the REPL needs to keep going, and so does a
// file that prints a warning and carries on.
pub fn (mut m Machine) eval_string_lenient(src string) !vlip.Value {
	res := m.arena.read_forms(src)
	mut last := vlip.nil_value()
	mut i := 0
	for i < res.forms.len {
		last = m.eval_one(res.forms[i])!
		i++
	}
	return last
}


fn (mut m Machine) drive() !vlip.Value {
	for {
		m.steps++
		if m.steps > m.max_steps {
			return error('step limit exceeded: the program did not terminate')
		}
		if m.kstack.len > m.max_kont {
			return error('continuation too deep: non-tail recursion is too deep')
		}
		// Two control states, so this is an if rather than a match. V 0.5.2
		// demands an `else` arm on a match over an enum even when every value is
		// covered, and there is no honest third state to put there.
		if m.ctl == .eval_form {
			m.step_eval()!
		} else if !m.step_return()! {
			return m.val
		}
	}
}

// kont builds a continuation frame. The env field inside Kont is a reference
// field, so V requires the literal to be unsafe.
fn (mut m Machine) kont(tag vlip.KontTag) vlip.Kont {
	return unsafe {
		vlip.Kont{
			tag: tag
		}
	}
}

fn (mut m Machine) push(k vlip.Kont) {
	m.kstack << k
}

fn (mut m Machine) pop() vlip.Kont {
	last := m.kstack[m.kstack.len - 1]
	m.kstack = m.kstack[..m.kstack.len - 1]
	return last
}

fn (mut m Machine) ret() {
	m.ctl = .return_value
}

fn (mut m Machine) goto(form vlip.NodeId) {
	m.form = form
	m.ctl = .eval_form
}

// Every failure in the machine is spelled `return error(msg)`.
//
// A helper such as `fn (m &Machine) err(msg string) !` is tempting and does not
// work: V 0.5.2 cannot infer a generic type parameter from the enclosing
// function's return type, so a generic `err[T]` has to be written `err[bool](..)`
// at every site -- more typing than `error(...)` and easier to get wrong. The
// built-in `error` is already generic and already inferred, so it wins.

// ------------------------------------------------------------------- EVAL

fn (mut m Machine) step_eval() ! {
	id := m.form
	d := m.arena.node(id)

	match d.tag {
		.nil {
			m.val = vlip.nil_value()
			m.ret()
			return
		}
		.bool {
			m.val = vlip.boolean(d.i != 0)
			m.ret()
			return
		}
		.int {
			m.val = vlip.integer(d.i)
			m.ret()
			return
		}
		.char {
			m.val = vlip.rune(u32(d.i))
			m.ret()
			return
		}
		.float {
			m.val = vlip.float(d.f)
			m.ret()
			return
		}
		.str {
			m.val = vlip.string(d.value)
			m.ret()
			return
		}
		.kw {
			m.val = vlip.keyword(d.value)
			m.ret()
			return
		}
		.sym {
			return m.eval_symbol(d.value)
		}
		.quoted {
			m.val = m.datum_to_value(m.arena.kids(id)[0])
			m.ret()
			return
		}
		.quasi {
			m.val = m.quasi_to_value(m.arena.kids(id)[0])
			m.ret()
			return
		}
		.list {
			kids := m.arena.kids(id)
			if kids.len == 0 {
				// `()` is the empty list, not nil: a form has to produce the
				// value it reads as, and the examples assert `(list) ;=> ()`.
				m.val = vlip.empty_list()
				m.ret()
				return
			}
			return m.eval_list(id, kids)
		}
		else {
			// vectors, tables, arrays, bytes as literals
			m.val = m.datum_to_value(id)
			m.ret()
			return
		}
	}
}

fn (mut m Machine) eval_symbol(name string) ! {
	// nil and the boolean symbols evaluate to themselves
	match name {
		'nil', 'none' {
			m.val = vlip.nil_value()
			m.ret()
			return
		}
		'true' {
			m.val = vlip.boolean(true)
			m.ret()
			return
		}
		'false' {
			m.val = vlip.boolean(false)
			m.ret()
			return
		}
		else {}
	}
	if found := m.envs.lookup(m.env, name) {
		m.val = found
		m.ret()
		return
	}
	// `p.x` is one symbol to the reader, so `(p.x)` -- a call with no arguments --
	// has to mean "read the field". A plain lookup would report "unbound identifier:
	// p.x", which is exactly the sort of message that sends a reader looking for a
	// missing definition that is really a struct field.
	if name.contains('.') {
		return m.eval_field_access(name)
	}
	if name in m.prims || machine_builtin(name) {
		m.val = vlip.new_prim(name)
		m.ret()
		return
	}
	return error('unbound identifier: ${name}')
}

// machine_builtin is the list of names call_primitive handles itself rather than
// through the prims table, because each one needs the machine: `apply` re-enters
// it, `error` and `raise` abort, `format` and `gensym` read machine state, the
// sequence functions call a user's closure, and `print`/`display` write to the
// host.
//
// They have to be listed in eval_symbol as well as handled here. They were not,
// and `(error "boom")` therefore failed as "unbound identifier: error" before it
// ever reached the application: the name did not resolve, so the abort path was
// dead code for exactly the input it exists to handle.
fn machine_builtin(name string) bool {
	return name in [
		'apply', 'error', 'raise', 'format', 'gensym', 'print', 'display', 'echo',
		'map', 'filter', 'reject', 'keep', 'fold', 'reduce', 'for-each', 'vector-map',
		'any?', 'every?', 'sort-by', 'ok', 'err', 'ok?', 'err?', 'ok-value',
		'err-value', 'map-result', 'unwrap-or', 'try-result', 'lazy-unwrap',
		'lazy-map-result', 'flatten-result', 'all-results',
	]
}

// show_value renders one argument. `quoted` distinguishes `print` from `display`:
// `print` shows strings with their quotes and `display` does not.
fn show_value(a vlip.Value, quoted bool) string {
	if a.tag == .string && !quoted {
		return a.as_string()
	}
	return printer.write(a)
}

// ------------------------------------------------- higher-order sequences

// hof is map/filter/reject/keep/for-each/vector-map. They differ only in what they
// keep and what they return, so one loop with a mode keeps them consistent --
// `keep` and `filter` are the same predicate with opposite answers, and having
// them as separate functions is how they drift.
//
// The sequence filter is called `reject`, not `remove`. `remove` is the TABLE
// operation and it is older: `(remove {:a 1} :a)` means "a table without :a". Two
// meanings under one name would have had to be chosen at the call site, and the
// examples use both.
fn (mut m Machine) hof(name string, args []vlip.Value) ! {
	if args.len < 2 {
		return error('${name} expects at least 2 arguments, got ${args.len}')
	}
	f := args[0]
	items := prims.seq(args[1]) or {
		return error('${name}: ${err.msg()}')
	}
	want_vector := name == 'vector-map'
	keep := name in ['filter', 'keep']
	drop := name == 'reject'
	mut out := []vlip.Value{}
	mut i := 0
	for i < items.len {
		mut one := []vlip.Value{}
		one << items[i]
		v := m.call_value(f, one)!
		if drop {
			if !v.truthy() {
				out << items[i]
			}
		} else if keep {
			if v.truthy() {
				out << items[i]
			}
		} else {
			out << v
		}
		i++
	}
	if name == 'for-each' {
		m.val = vlip.nil_value()
		m.ret()
		return
	}
	if want_vector {
		m.val = vlip.vector(out)
		m.ret()
		return
	}
	m.val = vlip.list_from(out)
	m.ret()
}

// fold is left-associative with an explicit initial value; reduce takes the first
// element as the initial one, which is the only difference between them that
// matters and is a whole extra function in every Lisp that has both.
fn (mut m Machine) fold(name string, args []vlip.Value) ! {
	if name == 'reduce' && args.len == 2 {
		items := prims.seq(args[1]) or {
			return error('reduce: ${err.msg()}')
		}
		if items.len == 0 {
			return error('reduce: the sequence is empty, so there is nothing to start from')
		}
		mut call := []vlip.Value{}
		call << args[0]
		mut i := 1
		for i < items.len {
			call << items[i]
			i++
		}
		m.val = m.call_value(args[0], call)!
		m.ret()
		return
	}
	if args.len < 3 {
		return error('${name} expects at least 3 arguments, got ${args.len}')
	}
	mut acc := args[1]
	items := prims.seq(args[2]) or {
		return error('${name}: ${err.msg()}')
	}
	mut i := 0
	for i < items.len {
		mut call := []vlip.Value{}
		call << acc
		call << items[i]
		acc = m.call_value(args[0], call)!
		i++
	}
	m.val = acc
	m.ret()
}

fn (mut m Machine) any_every(name string, args []vlip.Value) ! {
	if args.len < 2 {
		return error('${name} expects 2 arguments, got ${args.len}')
	}
	items := prims.seq(args[1]) or {
		return error('${name}: ${err.msg()}')
	}
	mut i := 0
	for i < items.len {
		mut one := []vlip.Value{}
		one << items[i]
		v := m.call_value(args[0], one)!
		if name == 'any?' && v.truthy() {
			m.val = v
			m.ret()
			return
		}
		if name == 'every?' && !v.truthy() {
			m.val = v
			m.ret()
			return
		}
		i++
	}
	// `any?` over an empty sequence is false and `every?` is true: the universal
	// quantifier over nothing holds. The other way round makes `(every? p '())`
	// false and every filter-then-check pipeline wrong at the edges.
	m.val = vlip.boolean(name == 'every?')
	m.ret()
}

fn (mut m Machine) sort_by(args []vlip.Value) ! {
	if args.len != 2 {
		return error('sort-by expects 2 arguments, got ${args.len}')
	}
	items := prims.seq(args[1]) or {
		return error('sort-by: ${err.msg()}')
	}
	mut keys := []vlip.Value{}
	mut i := 0
	for i < items.len {
		mut one := []vlip.Value{}
		one << items[i]
		keys << m.call_value(args[0], one)!
		i++
	}
	m.val = prims.sort_by_keyed(items, keys)!
	m.ret()
}

// call_value applies a callable value with no re-entry into the machine loop.
//
// It pushes a sentinel-free `.done` continuation instead of using call_closure,
// because call_closure GOTOS the body -- which is right for a normal call and
// wrong here: the caller is in the middle of call_primitive and would be
// overwritten. So this saves the control state, applies, drives to completion,
// and puts the state back. That is why eval_one had to save and restore too.
fn (mut m Machine) call_value(f vlip.Value, args []vlip.Value) !vlip.Value {
	saved_k := m.kstack
	saved_ctl := m.ctl
	saved_form := m.form
	saved_env := m.env
	saved_val := m.val
	m.kstack = []vlip.Kont{}
	m.ctl = .eval_form
	m.env = m.globals
	mut all := []vlip.Value{}
	all << f
	for a in args {
		all << a
	}
	m.apply_all(all)!
	out := m.drive() or { vlip.nil_value() }
	m.kstack = saved_k
	m.ctl = saved_ctl
	m.form = saved_form
	m.env = saved_env
	m.val = saved_val
	return out
}

// -------------------------------------------------------------- Result

// A Result is a plain list whose head is the symbol `ok` or `err`, so it prints
// as `(ok 42)`, compares structurally, and needs no new Value tag. The obvious
// alternative -- a dedicated struct -- makes every result a special case in the
// printer, in `=`, and in the pattern matcher, for no gain.
fn is_result_of(v vlip.Value, kind string) bool {
	if v.tag != .pair {
		return false
	}
	head := v.as_pair().car
	if head.tag != .symbol {
		return false
	}
	return head.as_string() == kind
}

fn kind_of(v vlip.Value) string {
	if v.tag == .pair {
		head := v.as_pair().car
		if head.tag == .symbol {
			return head.as_string()
		}
	}
	return 'not-a-result'
}

fn inner_value(v vlip.Value) vlip.Value {
	if v.tag != .pair {
		return vlip.nil_value()
	}
	return v.as_pair().cdr.as_pair().car
}

// result_combinator is map-result, try-result, lazy-map-result and lazy-unwrap.
// The lazy ones are separate names rather than a flag, because in a Lisp every
// argument is evaluated eagerly, so `(lazy-map-result (err 'e) (fn [x] (/ x 0)))`
// has already run `(/ x 0)` by the time the function is called. The name is the
// only place the laziness can be stated.
fn (mut m Machine) result_combinator(name string, args []vlip.Value) ! {
	if args.len != 2 {
		return error('${name} expects 2 arguments, got ${args.len}')
	}
	lazy := name.starts_with('lazy-')
	if !is_result_of(args[0], 'ok') {
		if !lazy {
			// The eager forms run the function anyway, because in a Lisp you cannot
			// stop an argument being evaluated. Wrapping the result so the
			// arguments become `(fn [] ...)` is the honest way to get laziness, and
			// `lazy-` names are the wrapper.
			if name == 'map-result' || name == 'try-result' {
				m.val = args[1]
				m.ret()
				return
			}
		}
		m.val = args[0]
		m.ret()
		return
	}
	if name == 'lazy-unwrap' {
		rest := prims.seq(args[0])!
		if rest.len > 1 {
			m.val = rest[1]
		} else {
			m.val = vlip.nil_value()
		}
		m.ret()
		return
	}
	mut one := []vlip.Value{}
	one << inner_value(args[0])
	v := m.call_value(args[1], one)!
	if is_result_of(v, 'err') {
		m.val = v
		m.ret()
		return
	}
	m.val = vlip.list_from([vlip.symbol('ok'), v])
	m.ret()
}


fn (mut m Machine) eval_list(id vlip.NodeId, kids []vlip.NodeId) ! {
	head := m.arena.node(kids[0])
	if head.tag == .sym {
		if special_form(head.value) {
			return m.eval_special(head.value, id, kids)
		}
		// `p.y := 99` is a field update, not a call. The reader cannot tell it
		// apart from a three-element application, so the shape does: a dotted
		// head, the marker `:=` in the second slot, and a value in the third.
		if head.value.contains('.') && kids.len == 3 && m.is_update_marker(kids[1]) {
			return m.eval_field_update(head.value, kids[2])
		}
	}
	// application: evaluate the operator with a frame that will then take the
	// arguments.
	mut nf := m.kont(.app_fn)
	nf.rest = id
	nf.env = m.env

	m.push(nf)
	m.goto(kids[0])
}

fn (m &Machine) is_update_marker(n vlip.NodeId) bool {
	d := m.arena.node(n)
	return d.tag == .sym && d.value == ':='
}

// eval_field_update evaluates `base.field := value`.
//
// Structs are immutable, so this builds a NEW instance and returns it; the
// original is untouched. That is the whole point of having `:=` at all: a `set!`
// on a field would make a struct quietly share state with everything that holds
// it.
//
// `base` is a NAME, not an expression. `(p.y := 1)` is the form the examples use
// and the reader produces that shape for it; `(mk).y := 1` is a different shape,
// and is not supported. Saying so here beats accepting half of it.
fn (mut m Machine) eval_field_update(what string, value_node vlip.NodeId) ! {
	dot := what.last_index('.') or {
		return error('${what} is not a field update')
	}
	base_name := what[..dot]
	field := what[dot + 1..]
	base := m.envs.lookup(m.env, base_name) or {
		return error('unbound identifier: ${base_name} (in ${what})')
	}
	mut nf := m.kont(.field_k)
	nf.name = field
	nf.acc = []vlip.Value{}
	nf.acc << base
	m.push(nf)
	m.goto(value_node)
}

fn (mut m Machine) eval_field_access(what string) ! {
	dot := what.last_index('.') or {
		return error('${what} is not a field access')
	}
	base_name := what[..dot]
	field := what[dot + 1..]
	if v := m.envs.lookup(m.env, base_name) {
		m.val = m.field_of(v, field)!
		m.ret()
		return
	}
	return error('unbound identifier: ${base_name} (in field access ${what})')
}

pub fn (m &Machine) field_of(v vlip.Value, field string) !vlip.Value {
	if v.tag == .struct_ {
		s := v.as_struct()
		if !s.has(field) {
			return error('${s.name} has no field ${field}')
		}
		return s.get(field)
	}
	if v.tag == .table || v.tag == .buffer {
		return v.as_table().get(field)
	}
	return error('cannot read field ${field} of ${printer.write(v)}')
}

// ----------------------------------------------------------------- RETURN

// step_return handles one value coming back. It returns false when the
// continuation stack is empty, which is the machine's answer.
//
// `!` is in the signature because applying a callable can fail -- a wrong arity,
// a keyword applied to something that is not a collection -- and a failure has
// to be a returned error. It used to be a panic, which unwound through the
// embedding host and killed it.
fn (mut m Machine) step_return() !bool {
	if m.kstack.len == 0 {
		return false
	}
	mut k := m.pop()
	match k.tag {
.app_fn {
			kids := m.arena.kids(k.rest)
			if kids.len == 1 {
				// zero arguments
				mut all := []vlip.Value{}
				all << m.val
				m.apply_all(all)!
			} else {
				mut k2 := m.kont(.app_arg)
				k2.rest = k.rest
				k2.env = k.env
				k2.slot = 1
				k2.acc = []vlip.Value{}
				k2.acc << m.val
				m.push(k2)
				m.env = k.env
				m.goto(kids[1])
			}
		}
		.app_arg {
			k.acc << m.val
			kids := m.arena.kids(k.rest)
			// acc holds [callee, arg1, ...]. Every argument is in place once
			// acc.len == kids.len, because kids[0] is the operator itself.
			// Testing k.slot instead double-counted and read past the end.
			if k.acc.len < kids.len {
				mut k2 := k
				k2.slot = k.acc.len
				m.push(k2)
				// Each argument is written in the CALLER's scope, not in
				// whatever scope a previous argument's evaluation left behind.
				m.env = k.env
				m.goto(kids[k.acc.len])
			} else {
				m.apply_all(k.acc)!
			}
		}
		.if_k {
			// kids[0] is the `if` itself, so the test is kids[1], the consequent
			// is kids[2], and the optional alternative is kids[3]. Using kids[1]
			// as the consequent re-evaluated the test as the answer, which made
			// `(if (= n 0) acc 1)` return the test's own value.
			kids := m.arena.kids(k.rest)
			// Restore the environment the branches were written in. Without this,
			// a branch evaluated after a function call sees that call's frame:
			// `(+ (f a) (g b))` would resolve `b` in f's scope.
			m.env = k.env
			if m.val.truthy() {
				m.goto(kids[2])
			} else if kids.len > 3 {
				m.goto(kids[3])
			} else {
				m.val = vlip.nil_value()
				m.ret()
			}
		}
		.seq {
			kids := m.arena.kids(k.rest)
			// next is the statement after the one that just finished. It has to be
			// bounds-checked against kids.len, not against the popped slot:
			// slot+1 == kids.len means the sequence is finished.
			next := k.slot + 1
			if next < kids.len {
				mut k2 := k
				k2.slot = next
				if next + 1 < kids.len {
					m.push(k2)
				}
				m.env = k.env
				m.goto(kids[next])
			} else {
				m.ret()
			}
		}
		.define_k {
			// Restore the scope the `define` was WRITTEN in. Without this,
			// `(define g (make-thunk))` binds `g` inside the thunk's frame --
			// which is gone by the time anyone looks for it. It reported as
			// "unbound identifier: g" and was invisible to every tail-call test,
			// because a global define at top level has m.env == m.globals and
			// the frame the value came back in happens to be the wrong one only
			// when the value was produced by a call.
			m.env = k.env
			m.envs.define(m.env, k.name, m.val)
			m.val = vlip.symbol(k.name)
			m.ret()
		}
		.set_k {
			// Same restoration as .define_k, and for the same reason:
			// `(set! x (f y))` must assign x in the scope it was written in, not
			// in f's frame.
			m.env = k.env
			if !m.envs.set(m.env, k.name, m.val) {
				// `set!` on a name that was never bound is an error, not a
				// silent no-op. The obvious alternative -- ignoring it -- turns a
				// typo into a value that quietly stays wrong for the rest of the
				// program.
				return error('set! cannot assign to unbound identifier: ${k.name}')
			}
			m.val = vlip.nil_value()
			m.ret()
		}
		.and_k {
			if !m.val.truthy() {
				m.ret() // short-circuits, and the falsy value is the result
			} else {
				kids := m.arena.kids(k.rest)
				if k.slot < kids.len {
					mut k2 := k
					k2.slot = k.slot + 1
					m.push(k2)
					m.goto(kids[k.slot])
				} else {
					m.ret()
				}
			}
		}
		.or_k {
			if m.val.truthy() {
				m.ret()
			} else {
				kids := m.arena.kids(k.rest)
				if k.slot < kids.len {
					mut k2 := k
					k2.slot = k.slot + 1
					m.push(k2)
					m.goto(kids[k.slot])
				} else {
					m.ret()
				}
			}
		}
		.field_k {
			base := k.acc[0]
			if base.tag != .struct_ {
				return error('${k.name} := : ${printer.write(base)} is not a struct')
			}
			if !base.as_struct().has(k.name) {
				return error('${base.as_struct().name} has no field ${k.name}')
			}
			next := base.as_struct().with(k.name, m.val)
			m.val = vlip.Value{
				tag:     .struct_
				payload: next
			}
			m.ret()
		}
		.use_k {
			kids := k.clauses
			// An error result skips the body entirely, and the error IS the value of
			// the whole `use`. That is what makes `use` safe to chain: nothing after
			// a failure sees a half-bound name.
			if !is_result_of(m.val, 'ok') {
				m.ret()
				return true
			}
			parts := prims.seq(m.val) or {
				m.ret()
				return true
			}
			frame := m.envs.new_env(k.env)
			mut n := 1
			for n < parts.len {
				m.envs.define(frame, m.use_name(n), parts[n])
				n++
			}
			m.enter_clause_body(frame, m.make_begin(kids[2..]))!
			return true
		}
		.match_k {
			m.try_clauses(k, m.val)!
			return true
		}
		.guard_k {
			// The guard's bindings are already defined in the current frame. A true
			// guard enters the body; a false one puts `env` back to where the clause
			// list started and carries on from the NEXT clause.
			if m.val.truthy() {
				m.goto(k.rest)
				return true
			}
			mut next := k
			next.slot = k.slot + 1
			mut subj := vlip.nil_value()
			if k.acc.len > 0 {
				subj = k.acc[0]
			}
			m.env = k.env
			m.try_clauses(next, subj)!
			return true
		}
		.assert_k {
			if m.val.truthy() {
				m.val = vlip.nil_value()
				m.ret()
				return true
			}
			return error('assertion failed: ${m.render_node(k.rest)}')
		}
		else {
			// .done is never pushed. Reaching it means the continuation stack was
			// corrupted by something that was not a Kont, which is a bug in this
			// interpreter rather than in the program -- so it is still an error
			// value, because the host must survive it either way.
			return error('machine: unexpected continuation ${k.tag}')
		}
	}
	return true
}

// -------------------------------------------------------------- application

// apply_all applies `all_in[0]` to the rest.
//
// Keyword application is the one non-obvious case. `(:a {:a 1})` is defined to
// mean `(:a {:a 1})` as a lookup, so a keyword in operator position is a key and
// the single argument is the collection. The alternative -- treating an
// unapplied keyword as nil, which is what the first version did -- turns the
// single most common Lisp idiom into a nil call.
fn (mut m Machine) apply_all(all_in []vlip.Value) ! {
	mut all := all_in.clone()
	callee := all[0]
	mut args := []vlip.Value{}
	for i in 1 .. all.len {
		args << all[i]
	}
	match callee.tag {
		.closure {
			m.call_closure(callee.as_closure(), args)!
		}
		.primitive {
			m.call_primitive(callee.as_string(), args)!
		}
		.keyword, .string, .symbol {
			// A key used in operator position looks itself up in the one
			// argument. `(:a {:a 1})` and `(:a m)` are the same call.
			if args.len != 1 {
				return error('a key used as a function takes 1 argument, got ${args.len}')
			}
			m.val = m.lookup_key(callee.as_string(), args[0])!
			m.ret()
		}
		.table, .buffer {
			if args.len != 1 {
				return error('a table used as a function takes 1 argument, got ${args.len}')
			}
			m.val = m.lookup_key(args[0].as_string(), callee)!
			m.ret()
		}
		.array, .vector {
			if args.len != 1 || args[0].tag != .integer {
				return error('an array used as a function takes 1 integer argument')
			}
			data := callee.as_vector().data
			idx := args[0].as_int()
			if idx < 0 || idx >= data.len {
				return error('array index ${idx} out of range (length ${data.len})')
			}
			m.val = data[idx]
			m.ret()
		}
		else {
			return error('cannot apply ${printer.write(callee)}: not a function')
		}
	}
}

// lookup_key is the one collection lookup every callable-collection path shares.
// `key` is already a string; the caller has decided where it came from.
fn (mut m Machine) lookup_key(key string, coll vlip.Value) !vlip.Value {
	match coll.tag {
		.table, .buffer {
			return coll.as_table().get(key)
		}
		.array, .vector {
			n := coll.as_vector().data.len
			i := strconv.atoi(key) or {
				return error('a vector used as a function needs an integer key, got ${key}')
			}
			if i < 0 || i >= n {
				return error('array index ${i} out of range (length ${n})')
			}
			return coll.as_vector().data[i]
		}
		else {
			return error('cannot look ${key} up in ${printer.write(coll)}')
		}
	}
}

fn (mut m Machine) call_closure(c &vlip.Closure, args []vlip.Value) ! {
	mut use_args := args
	if c.opt_from >= 0 {
		// The caller's scope is the environment the APPLICATION form was written in.
		// It is not m.env: after the last argument was evaluated, m.env is whatever
		// that argument's evaluation left behind, and a default evaluated there
		// would see the wrong names.
		use_args = m.fill_labels(c, args, m.kont_caller())!
	}
	// A trailing rest parameter, written `. name` in the parameter list, collects
	// the remaining arguments into a list. `c.arity` counts only the FIXED
	// parameters, so the arity check is "<=" rather than "==".
	if c.rest {
		if use_args.len < c.arity {
			return error('${c.name}: expected at least ${c.arity} argument${plural(c.arity)}, got ${use_args.len}')
		}
		frame := m.envs.new_env(c.env)
		mut i := 0
		for i < c.arity {
			m.envs.define(frame, c.params[i], use_args[i])
			i++
		}
		m.envs.define(frame, c.params[c.arity], vlip.list_from(use_args[c.arity..]))
		m.env = frame
		m.goto(c.body)
		return
	}
	if use_args.len != c.arity {
		return error('${c.name}: expected ${c.arity} argument${plural(c.arity)}, got ${use_args.len}')
	}
	frame := m.envs.new_env(c.env)
	mut i := 0
	for i < c.params.len {
		m.envs.define(frame, c.params[i], use_args[i])
		i++
	}
	m.env = frame
	// TAIL CALL: no continuation pushed. The body runs with whatever remains,
	// so recursion in tail position does not grow the stack.
	m.goto(c.body)
}

// eval_default evaluates one labelled parameter's default, with no arguments.
//
// The default is an arena NODE, not a value, so it needs the machine to evaluate.
// `call_value` applies a callable VALUE; this evaluates a FORM. Keeping them
// separate is why the two are not one function with a `?Value` parameter.
fn (mut m Machine) eval_default(n vlip.NodeId, args []vlip.Value) !vlip.Value {
	mut a := []vlip.Value{}
	for x in args {
		a << x
	}
	mut all := []vlip.Value{}
	all << m.closure_from_form(n)
	for x in a {
		all << x
	}
	return m.call_value(all[0], all[1..])
}

// closure_from_form builds a zero-parameter-callable from a form, so eval_default
// can reuse call_value. `(lambda (v) v)` is the identity on values and this is
// the identity on forms.
fn (mut m Machine) closure_from_form(n vlip.NodeId) vlip.Value {
	return vlip.new_closure([]string{}, n, m.env, 'default')
}
//
// The application frame is still on the stack when the callee is applied, so this
// is a peek rather than a stored field. A default expression must be evaluated
// there: `(connect m #:port (compute))` computes in the caller's scope, and
// `m.env` at this point is wherever the last argument left it.
fn (m &Machine) kont_caller() vlip.EnvId {
	if m.kstack.len == 0 {
		return m.globals
	}
	return m.kstack[m.kstack.len - 1].env
}

// fill_labels rewrites a call with keyword arguments into positional order and
// supplies the defaults for anything left out.
//
// `(connect m #:port 9000)` against `(connect m #:host [h "localhost"] #:port [p
// 8080])` becomes `(m "localhost" 9000)`. Doing it here rather than at the call
// site is deliberate: by this point the callee is a value, so its labels are
// known, and the keyword arguments have already been evaluated -- which is right,
// because `(connect m #:port (compute))` must run `compute`.
fn (mut m Machine) fill_labels(c &vlip.Closure, args []vlip.Value, caller vlip.EnvId) ![]vlip.Value {
	mut slots := []vlip.Value{}
	mut filled := []bool{}
	mut i := 0
	for i < c.params.len {
		slots << vlip.nil_value()
		filled << false
		i++
	}
	mut a := 0
	for a < args.len {
		v := args[a]
		if v.tag == .keyword {
			mut slot := -1
			mut j := c.opt_from
			for j < c.params.len {
				if c.opt_names[j - c.opt_from] == v.as_string() {
					slot = j
					break
				}
				j++
			}
			if slot < 0 {
				return error('${v.as_string()}: ${c.name} has no such labelled parameter')
			}
			if a + 1 >= args.len {
				return error('${v.as_string()}: needs a value')
			}
			if filled[slot] {
				return error('${c.name}: ${v.as_string()} was given twice')
			}
			slots[slot] = args[a + 1]
			filled[slot] = true
			a += 2
			continue
		}
		mut slot := -1
		mut j := 0
		for j < c.params.len {
			if !filled[j] {
				slot = j
				break
			}
			j++
		}
		if slot < 0 {
			return error('${c.name}: expected ${c.arity} argument${plural(c.arity)}, got ${args.len}')
		}
		slots[slot] = v
		filled[slot] = true
		a++
	}
	// Defaults, evaluated now, in the caller's scope.
	saved_env := m.env
	m.env = caller
	mut j := c.opt_from
	for j < c.params.len {
		if !filled[j] {
			d := c.opt_defaults[j - c.opt_from]
			if d == vlip.no_default {
				m.env = saved_env
				return error('${c.name}: ${c.opt_names[j - c.opt_from]} is required')
			}
			one := []vlip.Value{}
			slots[j] = m.eval_default(d, one)!
		}
		j++
	}
	m.env = saved_env
	return slots
}

// plural keeps "expected 1 argument" and "expected 2 arguments" honest. The
// obvious alternative, always writing "arguments", reads as a typo in a message
// that exists precisely to be read under pressure.
fn plural(n int) string {
	return if n == 1 { '' } else { 's' }
}

// format_args renders a format string plus its arguments.
//
// Two directives, and the distinction between them is not decoration:
//
//	~a  the value as text, with a string shown raw        (like Clojure's ~a)
//	~s  the value as the reader would write it            (like Clojure's ~s)
//
// ~a rendering strings WITH quotes was wrong, and it made every greeting-style
// message in the examples come out as `Hello, "world".` -- because ~a is the
// directive for "any value", and quoting is what `print` does, not what a
// formatter does.
fn format_args(args []vlip.Value) string {
	if args.len == 0 {
		return ''
	}
	fm := args[0].as_string()
	mut out := []u8{}
	mut i := 0
	mut next := 1
	mut spare := ''
	for i < fm.len {
		c := fm[i]
		// `~` followed by a or s.
		if c == u8(126) && i + 1 < fm.len {
			which := fm[i + 1]
			if which == u8(97) || which == u8(115) {
				if next < args.len {
					spare = show_value(args[next], which == u8(115))
					next++
				}
				out << spare.bytes()
				i += 2
				continue
			}
		}
		out << c
		i++
	}
	return out.bytestr()
}

fn (mut m Machine) call_primitive(name string, args []vlip.Value) ! {
	// Builtins that need to call back into the interpreter are handled here
	// rather than through the plain-function table.
	match name {
		'apply' {
			if args.len < 2 {
				return error('apply expects at least 2 arguments, got ${args.len}')
			}
			// (apply f a b) => (f a b); a trailing list argument is spliced.
			mut all := []vlip.Value{}
			all << args[0]
			mut i := 1
			for i < args.len {
				a := args[i]
				mut cur := a
				for cur.tag == .pair {
					all << cur.as_pair().car
					cur = cur.as_pair().cdr
				}
				i++
			}
			m.apply_all(all)!
			return
		}
		'error' {
			return error('error: ${format_args(args)}')
		}
		'raise' {
			return error('raised: ${format_args(args)}')
		}
		'format' {
			m.val = vlip.string(format_args(args))
			m.ret()
			return
		}
	'print', 'display' {
			// These two are machine builtins rather than table entries because
			// they have to reach `host` and `out`, which the prims table cannot
			// see: PrimFn deliberately takes only its arguments, so that prims
			// and the machine do not become mutually dependent.
			//
			// The line goes to the host AND to `out`. `out` is what a host
			// inspects afterwards; the host call is what makes a terminal show
			// anything at all.
			mut text := ''
			mut i := 0
			for i < args.len {
				if i > 0 {
					text += ' '
				}
				text += show_value(args[i], name == 'print')
				i++
			}
			m.out << text
			m.host.host_print(text)
			m.val = vlip.nil_value()
			m.ret()
			return
		}
		'gensym' {
			// Unhygienic macros need fresh names. Including the step counter
			// keeps them unique within one expansion run.
			m.val = vlip.symbol('g${m.steps}')
			m.ret()
			return
		}
		'echo' {
			// A pipeline tap: print the value and pass it on unchanged. It costs
			// nothing at runtime when a pipeline is not being debugged, which is the
			// whole argument for having it in the language rather than in the reader.
			text := if args.len == 0 { '' } else { show_value(args[0], false) }
			m.host.host_print(text)
			if args.len == 0 {
				m.val = vlip.nil_value()
			} else {
				m.val = args[0]
			}
			m.ret()
			return
		}
		// ---- higher-order sequences -------------------------------------
		//
		// These call a user closure, so they cannot live in the prims table:
		// PrimFn takes only its arguments and there is no way back into the
		// interpreter from there. That is the price of keeping prims and the
		// machine independent, and it is paid in one place rather than by giving
		// prims a machine reference.
		'map', 'filter', 'reject', 'keep', 'for-each', 'vector-map' {
			return m.hof(name, args)
		}
		'fold', 'reduce' {
			return m.fold(name, args)
		}
		'any?', 'every?' {
			return m.any_every(name, args)
		}
		'sort-by' {
			return m.sort_by(args)
		}
		// ---- Result ---------------------------------------------------
		'ok' {
			mut items := []vlip.Value{}
			items << vlip.symbol('ok')
			for a in args {
				items << a
			}
			m.val = vlip.list_from(items)
			m.ret()
			return
		}
		'err' {
			mut items := []vlip.Value{}
			items << vlip.symbol('err')
			for a in args {
				items << a
			}
			m.val = vlip.list_from(items)
			m.ret()
			return
		}
		'ok?', 'err?' {
			kind := if name == 'ok?' { 'ok' } else { 'err' }
			m.val = vlip.boolean(is_result_of(args[0], kind))
			m.ret()
			return
		}
		'ok-value', 'err-value' {
			kind := if name == 'ok-value' { 'ok' } else { 'err' }
			if !is_result_of(args[0], kind) {
				return error('${name}: ${printer.write(args[0])} is not a (${kind} ...), it is a ${kind_of(args[0])}')
			}
			rest := prims.seq(args[0]) or {
				return error('${name}: ${err.msg()}')
			}
			mut i := 1
			if i < rest.len {
				m.val = rest[i]
			} else {
				m.val = vlip.nil_value()
			}
			m.ret()
			return
		}
		'unwrap-or' {
			if is_result_of(args[0], 'ok') {
				rest := prims.seq(args[0])!
				if rest.len > 1 {
					m.val = rest[1]
				} else {
					m.val = vlip.nil_value()
				}
			} else {
				m.val = args[1]
			}
			m.ret()
			return
		}
		'flatten-result' {
			// ok(ok(1)) => ok(1); ok(err('inner')) => err('inner'). One level of
			// flattening only, because a nested result deeper than that is a bug in
			// the caller rather than something to normalise silently.
			inner_kind := kind_of(args[0])
			if inner_kind == 'nil' {
				m.val = args[0]
				m.ret()
				return
			}
			deeper := kind_of(inner_value(args[0]))
			if deeper != 'nil' {
				m.val = vlip.list_from([vlip.symbol(inner_kind), inner_value(args[0])])
			} else {
				m.val = args[0]
			}
			m.ret()
			return
		}
		'all-results' {
			mut vals := []vlip.Value{}
			mut i := 0
			for i < args.len {
				if !is_result_of(args[i], 'ok') {
					// The FIRST error wins. Returning the last would make the result
					// depend on evaluation order in a way nobody can see.
					m.val = args[i]
					m.ret()
					return
				}
				rest := prims.seq(args[i])!
				if rest.len > 1 {
					vals << rest[1]
				}
				i++
			}
			m.val = vlip.list_from([vlip.symbol('ok'), vlip.vector(vals)])
			m.ret()
			return
		}
		'map-result', 'try-result', 'lazy-map-result', 'lazy-unwrap' {
			return m.result_combinator(name, args)
		}
		else {}
	}
	f := m.prims[name] or {
		return error('unknown primitive: ${name}')
	}
	mut call_args := []vlip.Value{}
	for a in args {
		call_args << a
	}
	res := f(call_args) or {
		return error('${name}: ${err.msg()}')
	}
	m.val = res
	m.ret()
}
// ------------------------------------------------------------ special forms

pub fn special_form(name string) bool {
	return name in ['quote', 'if', 'define', 'set!', 'lambda', 'fn', 'begin', 'let', 'let*', 'letrec', 'and', 'or', 'when', 'unless', 'cond', 'case', 'loop', 'dotimes', 'use', 'match', 'match*', 'struct', 'struct-out', 'provide', 'require', 'let-assert', 'do', 'time', 'assert', '->', '->>', '|>', 'as->', 'cond->', 'def', 'defmacro']
}

fn (mut m Machine) eval_special(name string, id vlip.NodeId, kids []vlip.NodeId) ! {
	// Core forms first.
	match name {
		'quote' {
			m.val = m.datum_to_value(kids[1])
			m.ret()
			return
		}
		'if' {
			if kids.len < 3 {
				return error('if needs a test, a consequent, and optionally an alternative')
			}
			mut nf := m.kont(.if_k)
			nf.rest = id
			nf.env = m.env
	nf.env = m.env

	m.push(nf)
			m.goto(kids[1])
			return
		}
		'define' {
			return m.eval_define(kids)
		}
		'def' {
			// `def` is `define`. The examples use it to mean "introduce a name",
			// which is the same operation with a different connotation: `define` on
			// an existing name is a redefinition, `def` is not supposed to be.
			// vlip does not enforce the difference -- a stricter language would warn
			// -- and this comment is where that decision is recorded.
			return m.eval_define(kids)
		}
		'defmacro' {
			return m.eval_defmacro(kids)
		}
		'macex1' {
			if kids.len != 2 {
				return error('macex1 needs one form: (macex1 (macro arg ...))')
			}
			m.val = m.macex1(kids[1])!
			m.ret()
			return
		}
		'macex' {
			if kids.len != 2 {
				return error('macex needs one form: (macex (macro arg ...))')
			}
			m.val = m.macex(kids[1])!
			m.ret()
			return
		}
		'set!' {
			target := m.arena.node(kids[1])
			if target.tag != .sym {
				return error('set! needs a name')
			}
mut nf := m.kont(.set_k)
			nf.name = target.value
			nf.env = m.env
			m.push(nf)
			m.goto(kids[2])
			return

		}
		'lambda' {
			return m.eval_lambda(kids)
		}
		'fn' {
			// (fn [x] body) is (lambda (x) body): the short form every Lisp has.
			return m.eval_lambda([kids[0], m.make_begin(kids[1..2]),
				m.make_begin(kids[2..])])
		}
		'begin' {
			if kids.len == 1 {
				m.val = vlip.nil_value()
				m.ret()
				return
			}
			if kids.len == 2 {
				// No sequence frame for a single expression, which is what makes
				// a tail call a tail call.
				m.goto(kids[1])
				return
			}
// No frame for the LAST statement. A `begin` that always pushed one
			// made the final form a non-tail call, so a self-recursive loop grew
			// the continuation stack by one frame per iteration and stopped being
			// a loop at all. `next + 1 < kids.len` means "is there anything after
			// this statement"; if not, run it frame-free so it can tail-call.
			mut nf := m.kont(.seq)
			nf.rest = id
			nf.env = m.env
			nf.slot = 1
			if 2 < kids.len {
				m.push(nf)
			}
			m.goto(kids[1])
			return
		}
		'and', 'or' {
			if kids.len == 1 {
				m.val = vlip.boolean(name == 'and')
				m.ret()
				return
			}
	tag := if name == 'and' {
				vlip.KontTag.and_k
			} else {
				vlip.KontTag.or_k
			}
			mut nf := m.kont(tag)
			nf.rest = id
			nf.env = m.env
			nf.slot = 1
			m.push(nf)
			m.goto(kids[1])
			return
		}
		else {}
	}

	// Derived forms: transform to core forms and evaluate the result. Doing it
	// this way means every derived form gets tail calls for free.
	match name {
		'let' {
			m.goto(m.transform_let(kids)!)
		}
		'let*' {
			m.goto(m.transform_let_star(kids))
		}
		'letrec' {
			m.goto(m.transform_letrec(kids))
		}
		'when' {
			// (when c body...) => (if c (begin body...))
			body := m.node_of('begin', kids[1..])
			m.goto(m.node_of('if', [kids[1], body, m.nil_node()]))
		}
		'unless' {
			// (unless c body...) => (if c nil (begin body...))
			body := m.node_of('begin', kids[1..])
			m.goto(m.node_of('if', [kids[1], m.nil_node(), body]))
		}
		'cond' {
			m.goto(m.transform_cond(kids))
		}
		'case' {
			m.goto(m.transform_case(kids))
		}
		'loop' {
			m.goto(m.transform_loop(kids))
		}
		'dotimes' {
			m.goto(m.transform_dotimes(kids)!)
		}
		'use' {
			return m.eval_use(kids)
		}
		'do' {
			// `(do a b)` is `(begin a b)`, written so a macro can emit it. The
			// examples' macros use it because `begin` inside a macro reads as the
			// macro's own body.
			m.goto(m.make_begin(kids[1..]))
		}
		'match' {
			return m.eval_match(kids)
		}
		'match*' {
			m.goto(m.transform_match_star(kids))
		}
		'let-assert' {
			m.goto(m.transform_let_assert(kids))
		}
		'struct' {
			return m.eval_struct(kids)
		}
		'struct-out' {
			// Only meaningful inside `provide`, where it expands to the constructor
			// and the accessors. On its own it is a no-op that still succeeds, so a
			// module can `provide` the same names twice without breaking.
			m.val = vlip.nil_value()
			m.ret()
			return
		}
		'provide' {
			// `provide` documents a module's interface. Nothing reads it yet, so it
			// evaluates to nil rather than failing -- an unimplemented export list
			// should not stop the module loading.
			m.val = vlip.nil_value()
			m.ret()
			return
		}
		'require' {
			return m.eval_require(kids)
		}
		'assert' {
			// (assert test "message") -- executable documentation. The message is
			// required, because "assertion failed" tells a reader nothing about which
			// of four hundred promises broke.
			if kids.len < 3 {
				return error('assert needs a test and a message: (assert test "what it promises")')
			}
			mut af := m.kont(.assert_k)
			af.env = m.env
			af.rest = kids[2]
			m.push(af)
			m.goto(kids[1])
			return
		}
		'->', '->>', '|>', 'as->', 'cond->' {
			return m.eval_pipe(name, kids)
		}
		else {
			return error('unimplemented special form: ${name}')
		}
	}
}

// eval_pipe threads a value through a series of forms.
//
// Three forms, because people arrive with different muscle memory, and the
// difference between them is WHICH SLOT the value lands in:
//
//	->    the value becomes the FIRST argument
//	->>   the value becomes the LAST argument
//	|>    either: if the next form is a call, the value goes in first; if it is not
//	      a call at all, it BECOMES a call on the value
//
// `->` and `->>` are macros over `|>`, not three independent implementations. They
// have to agree about what a "call" is, and three copies of that test is three
// places for it to drift.
fn (mut m Machine) eval_pipe(name string, kids []vlip.NodeId) ! {
	if kids.len < 2 {
		return error('${name} needs a value to thread')
	}
	mut acc := kids[1]
	mut i := 2
	for i < kids.len {
		step := kids[i]
		// A pipe inside a pipe is SPLICED, not nested. `(->> x |> f |> g)` has to
		// thread x through f and then g, not call `|>` with two arguments.
		//
		// Without this, the inner `|>` received the outer form's value as its FIRST
		// argument -- so `f` ended up applied to nothing and the value ended up in
		// operator position. It reported "unbound identifier: >".
		d := m.arena.node(step)
		if d.tag == .list && m.is_pipe_head(step) {
			inner := m.arena.kids(step)
			mut j := 2
			for j < inner.len {
				acc = m.pipe_one(acc, inner[j], name)
				j++
			}
			i++
			continue
		}
		acc = m.pipe_one(acc, step, name)
		i++
	}
	m.goto(acc)
}

// is_pipe_head reports whether a form is one of the three threaders.
fn (m &Machine) is_pipe_head(n vlip.NodeId) bool {
	kids := m.arena.kids(n)
	if kids.len == 0 {
		return false
	}
	h := m.arena.node(kids[0])
	return h.tag == .sym && h.value in ['->', '->>', '|>', 'as->', 'cond->']
}

// pipe_one threads `acc` through one step under `mode`.
fn (mut m Machine) pipe_one(acc vlip.NodeId, step vlip.NodeId, mode string) vlip.NodeId {
	d := m.arena.node(step)
	// A `,echo` / bare symbol on the right of a pipe is a TAP: it is called on the
	// value and the value continues down the pipe.
	if d.tag == .sym && pipe_tap(d.value) {
		return m.pipe_through(acc, step, true)
	}
	mut slot := mode
	if mode == '|>' {
		slot = if m.is_call_form(step) { '->' } else { '->>' }
	}
	return m.pipe_through(acc, step, slot == '->>')
}

// pipe_through builds `(acc step)` when the value goes FIRST and `(step ... acc)`
// when it goes LAST.
//
// A bare symbol on the right is not a call, so there is nowhere to put a first
// argument: `(-> x f)` has to become `(f x)`, which is the LAST form. Treating a
// bare step as "thread last regardless" is the rule `|>` states explicitly, and
// it is the only one that leaves `(->> x | f)` meaning anything.
fn (mut m Machine) pipe_through(acc vlip.NodeId, step vlip.NodeId, last bool) vlip.NodeId {
	d := m.arena.node(step)
	if d.tag != .list {
		return m.list_of([step, acc])
	}
	skids := m.arena.kids(step)
	if last {
		mut items := []vlip.NodeId{}
		// An index loop, not `for s in skids`: the element type is a type alias from
		// another module and V 0.5.2 emits the unresolved name into the generated C.
		mut si := 0
		for si < skids.len {
			items << skids[si]
			si++
		}
		items << acc
		return m.list_of(items)
	}
	mut items := []vlip.NodeId{}
	items << skids[0]
	items << acc
	mut j := 1
	for j < skids.len {
		items << skids[j]
		j++
	}
	return m.list_of(items)
}

// pipe_tap names that tap a pipeline instead of transforming it. `echo` is the
// documented one; `tap` and `debug` are accepted because they are the names
// people reach for, and a symbol on the right of a pipe is unambiguous anyway.
fn pipe_tap(name string) bool {
	return name in ['echo', 'tap', 'debug']
}

fn (m &Machine) is_call_form(n vlip.NodeId) bool {
	return m.arena.node(n).tag == .list
}

fn (mut m Machine) eval_define(kids []vlip.NodeId) ! {
	if kids.len < 2 {
		return error('define needs a name or a (name . params) list')
	}
	target := m.arena.node(kids[1])
	if target.tag == .sym {
		if kids.len < 3 {
			return error('define needs a value for ${target.value}')
		}
		mut nf := m.kont(.define_k)
		nf.name = target.value
		nf.env = m.env
		m.push(nf)
		m.goto(kids[2])
		return
	}
	if target.tag == .list {
		sig := m.arena.kids(kids[1])
		if sig.len == 0 || m.arena.node(sig[0]).tag != .sym {
			return error('define needs a name')
		}
		fname := m.arena.node(sig[0]).value
		spec := m.parse_params(sig[1..], fname)!
		// The body is the forms AFTER the (name . params) signature, so it is
		// kids[2..] -- not sig[1..], which is the parameter list.
		body := m.apply_destructures(spec, m.make_begin(kids[2..]))
		m.envs.define(m.env, fname, m.make_closure(spec, body, m.env, fname))
		m.val = vlip.symbol(fname)
		m.ret()
		return
	}
	return error('define needs a name or a (name . params) list')
}

// ParamSpec is a parsed parameter list.
//
// `opt_from` is the index of the first labelled parameter, or -1. Labelled
// parameters are a TRAILING run -- `:name [default]` after a rest parameter could
// not be filled positionally at all -- so one index is enough and the keyword
// names and defaults are parallel arrays from there on.
pub struct ParamSpec {
pub mut:
	names     []string
	rest      string
	is_rest   bool
	opt_from  int = -1
	opt_names []string
	opt_defaults []vlip.NodeId
	// Destructuring parameters, in parameter order. Each binds a temporary -- the
	// name it was given in `names` -- and pulls names out of it with accessors
	// evaluated in the body.
	destructures []Destructure
}

// Destructure is one destructuring parameter: the temporary that receives the
// whole value, and the names pulled out of it.
pub struct Destructure {
pub mut:
	temp  vlip.NodeId
	parts []Destructured
}

// apply_destructures wraps a body in the lambda nest that binds the names a
// destructuring parameter introduces.
//
//	(define (dist (struct Point x: px y: py)) (+ px py))
//	; becomes, in effect
//	(define (dist param_1)
//	  ((fn ([px py]) (+ px py)) (point-x param_1) (point-y param_1)))
//
// The nest is built with `nest_lets`, the same helper `let` uses, because the
// requirement is identical: the accessors must be evaluated in a scope where the
// temporary is already bound, and the body must stay in tail position.
fn (mut m Machine) apply_destructures(ps ParamSpec, body vlip.NodeId) vlip.NodeId {
	mut groups := []Group{}
	for d in ps.destructures {
		mut names := []vlip.NodeId{}
		mut vals := []vlip.NodeId{}
		for p in d.parts {
			names << p.name
			vals << p.accessor
		}
		groups << Group{
			params: names
			args:   vals
		}
	}
	if groups.len == 0 {
		return body
	}
	return m.nest_lets(groups, [body])
}

// no_default marks a labelled parameter with no default: a missing map entry and
// a nil NodeId look the same in V, so one of them has to mean something else.
pub const no_default = vlip.NodeId(-2)

// parse_params accepts `(a b)`, `(a . b)` and the Racket-style `(fn [a b] ...)`
// spelling, which `fn` normalises before calling here.
//
// The dot form is a genuine dotted pair, not a two-element sequence: `.` alone
// is not a parameter. An earlier version appended `"."` and the rest name as two
// ordinary parameters, so `(define (f a . r) r)` had arity 3 and `(f 1 2 3)`
// bound `r` to `3`. That is the "rest parameters return 3" bug, and it was a
// parsing failure rather than a binding failure.
pub fn (mut m Machine) parse_params(plist []vlip.NodeId, who string) !ParamSpec {
	mut spec := ParamSpec{
		names:        []string{},
		opt_names:    []string{},
		opt_defaults: []vlip.NodeId{},
	}
	mut i := 0
	for i < plist.len {
		part := m.arena.node(plist[i])
		if part.tag == .list || part.tag == .table {
			// A destructuring parameter, `(struct Point x: px y: py)` or
			// `({:kind k} who)`. It binds one temporary, and the names come out of
			// it inside the BODY.
			//
			// The temporary is a real parameter rather than something computed at
			// the call site because the accessors have to be evaluated where the
			// temporary is already bound -- which is inside the body, not in the
			// caller's scope. The expansion is recorded here and applied by
			// `apply_destructures` once the body exists.
			//
			// Only the parenthesised and table forms destructure. A `[a b]` in a
			// `(fn [a b] ...)` parameter list is two ordinary parameters, and
			// treating a vector as a pattern would make every bracketed parameter
			// list a destructuring one.
			tmp := m.fresh('param')
			temp_node := m.sym_node(tmp)
			spec.names << tmp
			spec.destructures << Destructure{
				temp:  temp_node
				parts: m.destructuring(plist[i], temp_node)!
			}
			i++
			continue
		}
		if part.tag == .kw {
			// `#:name [default]` is a labelled parameter: the name after the colon
			// is the real one, and a caller may pass it by keyword.
			//
			// It is sugar over positional sugar -- `(connect #:port 9000)` becomes
			// `(connect m "localhost" 9000 30)` -- so nothing about calling a
			// closure changes. What does change is where the defaults are evaluated:
			// at the CALL, in the caller's scope, which is why they stay as arena
			// nodes in the closure rather than as values baked into it.
			//
			// The parser used to read `:host` as a parameter named ":host" and then
			// reject it as "not a name", which is how every labelled parameter in the
			// examples failed.
			if i + 1 >= plist.len {
				return error('${who}: ${m.render_node(plist[i])} needs a [name default] after it')
			}
			holder := m.arena.node(plist[i + 1])
			if holder.tag != .vector {
				return error('${who}: ${m.render_node(plist[i])} must be written ${m.render_node(plist[i])} [name default]')
			}
			inner := m.arena.kids(plist[i + 1])
			if inner.len != 1 && inner.len != 2 {
				return error('${who}: ${m.render_node(plist[i])} must be written [name default] or [default]')
			}
			mut nm_name := ''
			mut def := no_default
			if inner.len == 2 {
				nn := m.arena.node(inner[0])
				if nn.tag != .sym {
					return error('${who}: the parameter name in ${m.render_node(plist[i + 1])} is not a name')
				}
				nm_name = nn.value
				def = inner[1]
			} else {
				nm_name = part.value
				def = inner[0]
			}
			if spec.opt_from < 0 {
				spec.opt_from = spec.names.len
			}
			// The reader has already dropped the # and the :: #:port is a keyword
			// whose value is port, and the printer shows it back as :port. Storing
			// the value and not a reconstruction of the source spelling is what makes the
			// call-site comparison work -- the first version stored #port and compared
			// it against port, so every labelled argument was taken as positional.
			spec.opt_names << part.value
			spec.names << nm_name
			spec.opt_defaults << def
			i += 2
			continue
		}
		if part.tag != .sym {
			return error('${who}: parameter ${i} is not a name')
		}
		if part.value == '.' {
			if i + 2 != plist.len {
				return error('${who}: the dot must introduce the last parameter')
			}
			nm := m.arena.node(plist[i + 1])
			if nm.tag != .sym {
				return error('${who}: the dot needs a name after it')
			}
			spec.rest = nm.value
			spec.is_rest = true
			i += 2
			continue
		}
		mut dup := false
		mut seen := []string{}
		seen << spec.names
		for n in seen {
			if n == part.value {
				dup = true
			}
		}
		if dup {
			return error('${who}: parameter ${part.value} is named twice')
		}
		spec.names << part.value
		i++
	}
	if spec.is_rest {
		for n in spec.names {
			if n == spec.rest {
				return error('${who}: ${spec.rest} is both a fixed and a rest parameter')
			}
		}
	}
	return spec
}

fn (mut m Machine) eval_lambda(kids []vlip.NodeId) ! {
	if kids.len < 2 {
		return error('lambda needs a parameter list')
	}
	plist := m.arena.kids(kids[1])
	spec := m.parse_params(plist, 'lambda')!
	body := m.apply_destructures(spec, m.make_begin(kids[2..]))
	m.val = m.make_closure(spec, body, m.env, 'lambda')
	m.ret()
}

// make_closure builds the closure value for a parsed parameter list: variadic if
// there is a dot, labelled if there are `#:name` parameters, otherwise plain.
//
// One place, because a rest parameter and a labelled parameter are different
// constructors and picking the wrong one is silent: a labelled closure built by
// the plain constructor has arity 3 and rejects every call with two arguments.
pub fn (mut m Machine) make_closure(spec ParamSpec, body vlip.NodeId, env vlip.EnvId, name string) vlip.Value {
	if spec.opt_from >= 0 {
		return vlip.labelled(spec.names, body, env, name, spec.opt_from, spec.opt_names,
			spec.opt_defaults)
	}
	if spec.is_rest {
		return vlip.new_rest_closure(spec.names, spec.rest, body, env, name)
	}
	return vlip.new_closure(spec.names, body, env, name)
}

// ------------------------------------------------------------- arena helpers

// fresh builds a name no source program can contain, for the helper bindings the
// transforms introduce. The loop variable doubles as the loop function's own name
// in user code -- `(loop i 0 ...)` names both `i` -- so the body's recursive call
// would otherwise resolve `i` to the integer parameter instead of the closure.
//
// The separator is UNDERSCORE, not a dot, and that is not cosmetic: `p.x` is a
// field access, so a generated name containing a dot is read as a field lookup of
// a name that does not exist. The first version used dots and every `use` and
// every `let` destructuring failed with "unbound identifier: use (in field access
// use.1)".
pub fn (mut m Machine) fresh(base string) string {
	m.gensym++
	return base + '_' + m.gensym.str()
}

pub fn (mut m Machine) sym_node(name string) vlip.NodeId {
	return m.arena.str_leaf(.sym, name)
}

pub fn (mut m Machine) nil_node() vlip.NodeId {
	return m.arena.leaf(.nil)
}

pub fn (mut m Machine) int_node(n i64) vlip.NodeId {
	return m.arena.int_leaf(.int, n)
}

pub fn (mut m Machine) string_node(s string) vlip.NodeId {
	return m.arena.str_leaf(.str, s)
}

// list_of2 is list_of with the two lists zipped. Binding forms and argument lists
// are always written as pairs, and a helper that zips them keeps
// transform_let_assert and transform_use from each building the pair by hand.
pub fn (mut m Machine) list_of2(names []vlip.NodeId, vals []vlip.NodeId) vlip.NodeId {
	mut items := []vlip.NodeId{}
	mut i := 0
	for i < names.len {
		items << m.list_of([names[i], vals[i]])
		i++
	}
	return m.list_of(items)
}

// node_of builds a list headed by the named symbol, followed by `tail`.
pub fn (mut m Machine) node_of(head string, tail []vlip.NodeId) vlip.NodeId {
	mut items := []vlip.NodeId{}
	items << m.sym_node(head)
	// An index loop, not `for t in tail`: see the note in pipe_through.
	mut ti := 0
	for ti < tail.len {
		items << tail[ti]
		ti++
	}
	return m.list_of(items)
}

pub fn (mut m Machine) list_of(items []vlip.NodeId) vlip.NodeId {
	id := m.arena.open(.list)
	m.arena.finish(id, items)

	return id
}

pub fn (mut m Machine) call_node(callee vlip.NodeId, args []vlip.NodeId) vlip.NodeId {
	mut items := []vlip.NodeId{}
	items << callee
	for a in args {
		items << a
	}
	return m.list_of(items)
}

// make_begin synthesises (begin e ...). A one-expression body is returned as-is,
// and that is exactly what keeps a tail call a tail call.
pub fn (mut m Machine) make_begin(forms []vlip.NodeId) vlip.NodeId {
	if forms.len == 0 {
		return m.nil_node()
	}
	if forms.len == 1 {
		return forms[0]
	}
	return m.node_of('begin', forms)
}

// --------------------------------------------------------- datum -> value

struct Frame {
mut:
	id    vlip.NodeId
	kids  []vlip.NodeId
	start int
}

// datum_to_value converts a parsed form into a runtime value, for `quote`.
// Written with an explicit worklist rather than recursion, because V 0.5.2
// mis-reports "evaluated but not used" for a variable used only as an argument
// to a recursive call inside a for-loop body.
pub fn (mut m Machine) datum_to_value(id vlip.NodeId) vlip.Value {
	mut built := map[vlip.NodeId]vlip.Value{}
	mut work := []Frame{}
	work << Frame{
		id:    id
		kids:  m.arena.kids(id)
		start: 0
	}
	for work.len > 0 {
		mut f := work[work.len - 1]
		work = work[..work.len - 1]
		if f.start < f.kids.len {
			work << Frame{
				id:    f.id
				kids:  f.kids
				start: f.start + 1
			}
			work << Frame{
				id:    f.kids[f.start]
				kids:  []vlip.NodeId{}
				start: 0
			}
			continue
		}
		built[f.id] = m.assemble(f.id, f.kids, built)
	}
	return built[id]
}

fn (mut m Machine) assemble(id vlip.NodeId, kids []vlip.NodeId, built map[vlip.NodeId]vlip.Value) vlip.Value {
	d := m.arena.node(id)
	match d.tag {
		.nil { return vlip.nil_value() }
		.bool { return vlip.boolean(d.i != 0) }
		.int { return vlip.integer(d.i) }
		.float { return vlip.float(d.f) }
		.char { return vlip.rune(u32(d.i)) }
		.str { return vlip.string(d.value) }
		.sym { return vlip.symbol(d.value) }
		.kw { return vlip.keyword(d.value) }
		.quoted { return m.datum_to_value(m.arena.kids(id)[0]) }
		.unquote, .unquote_splice {
			// Nested inside a quasiquote. Evaluated here rather than treated as
			// data, which is the whole difference between `,x` and 'x.
			//
			// `assemble` has no other way to know, and it does not need to: a `.unquote`
			// node only ever appears inside a quasiquote in practice. It DOES appear
			// inside `'` too, and then `',x` evaluates -- which is surprising and is
			// why the examples never write it.
			return m.quasi_to_value(id)
		}
.list {
			mut items := []vlip.Value{}
			mut ki := 0
			for ki < kids.len {
				child := kids[ki]
				cd := m.arena.node(child)
				if cd.tag == .unquote_splice {
					// `,@xs` inside a list splices xs in. This is the one place a
					// node contributes more than one element, which is why the loop is
					// over the children and not over `built`.
					spliced := m.quasi_to_value(child)
					parts := prims.seq(spliced) or {
						return vlip.nil_value()
					}
					mut si := 0
					for si < parts.len {
						items << parts[si]
						si++
					}
				} else {
					items << built[child]
				}
				ki++
			}
			return vlip.list_from(items)
		}
		.vector {
			mut items := []vlip.Value{}
			mut ki := 0
			for ki < kids.len {
				items << built[kids[ki]]
				ki++
			}
			return vlip.vector(items)
		}
		.table {
			mut mm := map[string]vlip.Value{}
			mut i := 0
			for i + 1 < kids.len {
				mm[built[kids[i]].as_string()] = built[kids[i + 1]]
				i += 2
			}
			return vlip.table(mm)
		}
		.array {
			mut items := []vlip.Value{}
			mut ki := 0
			for ki < kids.len {
				items << built[kids[ki]]
				ki++
			}
			return vlip.Value{
				tag: .array
				payload: &vlip.Vector{
					tag:  .array
					data: items
				}
			}
		}
		.buffer {
			mut mm := map[string]vlip.Value{}
			mut i := 0
			for i + 1 < kids.len {
				mm[built[kids[i]].as_string()] = built[kids[i + 1]]
				i += 2
			}
			return vlip.buffer(mm)
		}
		else { return vlip.nil_value() }
	}
}

// quasi_to_value builds a form ready to be handed to a macro: an unquote is
// evaluated now, everything else becomes a literal.
//
// The save/restore is not optional. This runs in the MIDDLE of an evaluation --
// step_eval dispatches here for a quasiquoted form -- and eval_one resets the
// control state. Without the restore, evaluating an unquote would throw away the
// continuation frames of the form that contained it, and the macro expansion would
// return into the wrong place.
pub fn (mut m Machine) quasi_to_value(id vlip.NodeId) vlip.Value {
	d := m.arena.node(id)
	if d.tag == .unquote || d.tag == .unquote_splice {
		inner := m.arena.kids(id)[0]
		saved_k := m.kstack
		saved_ctl := m.ctl
		saved_form := m.form
		saved_env := m.env
		out := m.eval_one(inner) or { vlip.nil_value() }
		m.kstack = saved_k
		m.ctl = saved_ctl
		m.form = saved_form
		m.env = saved_env
		return out
	}
	return m.datum_to_value(id)
}

// ----------------------------------------------------------------- match

// eval_match pushes one `.match_k` frame and evaluates the subject.
//
// ONE frame for the whole `match`, not one per clause: a per-clause frame would
// mean a `match` in tail position grew the continuation stack by its clause count
// on every iteration, which is the same mistake `begin` used to make.
fn (mut m Machine) eval_match(kids []vlip.NodeId) ! {
	if kids.len < 2 {
		return error('match needs a subject and at least one clause')
	}
	mut nf := m.kont(.match_k)
	nf.rest = 0
	nf.slot = 0
	nf.clauses = []
	mut i := 2
	for i < kids.len {
		nf.clauses << kids[i]
		i++
	}
	nf.env = m.env
	m.push(nf)
	m.goto(kids[1])
}

// try_clauses walks the clause list from `k.slot`. It is called both when the
// subject first arrives and after a guard fails, which is why it takes the frame
// rather than being inlined twice.
fn (mut m Machine) try_clauses(k vlip.Kont, subject vlip.Value) ! {
	mut i := k.slot
	for i < k.clauses.len {
		clause := k.clauses[i]
		ckids := m.arena.kids(clause)
		if ckids.len == 0 {
			i++
			continue
		}
		mut pi := 0
		mut guard := vlip.NodeId(-1)
		if m.arena.node(ckids[0]).tag == .kw && m.arena.node(ckids[0]).value == '#:when' {
			if ckids.len < 2 {
				return error('match: #:when needs a test')
			}
			guard = ckids[1]
			pi = 2
		}
		mut pattern := vlip.NodeId(-1)
		if pi < ckids.len {
			pattern = ckids[pi]
			pi++
		}
		// `else` as a clause head matches everything with no bindings.
		mut is_else := false
		if pattern != vlip.NodeId(-1) {
			pd := m.arena.node(pattern)
			is_else = pd.tag == .sym && pd.value == 'else'
		}
		mut res := Matched{
			ok: true
		}
		if !is_else {
			res = m.match_pattern(pattern, subject)!
		}
		if res.ok {
			mut body := []vlip.NodeId{}
			mut b := pi
			for b < ckids.len {
				body << ckids[b]
				b++
			}
			frame := m.envs.new_env(k.env)
			mut n := 0
			for n < res.binds.len {
				m.envs.define(frame, res.binds[n].name, res.binds[n].val)
				n++
			}
			if guard != vlip.NodeId(-1) {
				// A guard is evaluated with the bindings in scope, and a false guard
				// discards them. They live in their own frame, so "discard" is just
				// putting `env` back.
				mut gf := m.kont(.guard_k)
				gf.env = k.env
				gf.slot = i
				gf.clauses = k.clauses
				gf.rest = m.make_begin(body)
				// The subject, so a false guard can carry on with the next clause
				// without re-evaluating anything.
				gf.acc = []vlip.Value{}
				gf.acc << subject
				m.env = frame
				m.push(gf)
				m.goto(guard)
				return
			}
			return m.enter_clause_body(frame, m.make_begin(body))
		}
		i++
	}
	// Nothing matched.
	m.env = k.env
	m.val = vlip.nil_value()
	m.ret()
}

// enter_clause_body evaluates a matched clause's body. The bindings' frame is the
// parent, and the body runs under a `seq` frame so that its LAST form is still a
// tail call. Reusing the `seq` handler rather than writing a second one is the
// point: `begin` already works out how not to push a frame for the last form.
fn (mut m Machine) enter_clause_body(frame vlip.EnvId, body vlip.NodeId) ! {
	bd := m.arena.node(body)
	if bd.tag != .list {
		m.env = frame
		m.goto(body)
		return
	}
	bkids := m.arena.kids(body)
	if bkids.len == 0 {
		m.env = frame
		m.val = vlip.empty_list()
		m.ret()
		return
	}
	if bkids.len == 1 {
		m.env = frame
		m.goto(bkids[0])
		return
	}
	mut nf := m.kont(.seq)
	nf.rest = body
	nf.env = frame
	nf.slot = 1
	m.env = frame
	m.push(nf)
	m.goto(bkids[0])
}

// match* => (match (list S1 S2 ...) [((list P1 P2 ...)) body] ...).
//
// A macro over `match`, and the desugaring is the interesting part: the subjects
// are collected into ONE list, so each is evaluated exactly once before any
// pattern is tested -- which is the guarantee Racket's own documentation warns
// implementers about -- and a clause matches only if EVERY pattern in it does.
// No new syntax, no new continuation tag.
fn (mut m Machine) transform_match_star(kids []vlip.NodeId) vlip.NodeId {
	subjects := m.arena.kids(kids[1])
	mut stmts := []vlip.NodeId{}
	// Every subject is passed straight into ONE `(list ...)` call, which is what
	// makes each exactly-once evaluation: the list is built before the match sees
	// it, and the match only ever reads it.
	//
	// An earlier version bound each subject to a fresh temporary first and did not
	// bind them in the generated `let`, so every `match*` failed with
	// "unbound identifier: s_1". The temporaries were never needed -- `(list a b)`
	// already evaluates each argument once.
	inner := m.call_node(m.sym_node('list'), subjects)
	mut clauses := []vlip.NodeId{}
	mut c := 2
	for c < kids.len {
		ckids := m.arena.kids(kids[c])
		if ckids.len == 0 {
			c++
			continue
		}
		mut body := []vlip.NodeId{}
		mut bi := 1
		for bi < ckids.len {
			body << ckids[bi]
			bi++
		}
		// One clause becomes [(list)] whose pattern is (list P1 P2 ...), so each
		// pattern sees the subject in its own position.
		mut pat := []vlip.NodeId{}
		pat << m.sym_node('list')
		mut p := 0
		for p < ckids.len {
			pat << ckids[p]
			p++
		}
		clauses << m.list_of([m.list_of(pat), m.make_begin(body)])
		c++
	}
mut items := []vlip.NodeId{}
	items << m.sym_node('match')
	items << inner
	mut ci := 0
	for ci < clauses.len {
		items << clauses[ci]
		ci++
	}
	return m.list_of(items)
}

// let assert PATTERN VALUE body... => a match with no other clauses, so a failure
// is a hard error naming the pattern instead of falling through to nil.
//
// `kids` here has already had the word `assert` removed by transform_let, so it is
// the ordinary [let, BINDINGS, body...] shape with BINDINGS replaced by two forms.
//
// The subject is bound once and the `match` runs against the temporary, so a
// VALUE with a side effect is evaluated exactly once even though the transform
// mentions it twice.
fn (mut m Machine) transform_let_assert(kids []vlip.NodeId) vlip.NodeId {
	if kids.len < 4 {
		return m.make_begin(kids[3..])
	}
	tmp := m.sym_node(m.fresh('assert'))
	fail := m.node_of('error', [m.string_node(
		'let assert failed: the value does not match the pattern')])
	mitems := m.node_of('match', [tmp, m.list_of([kids[1], m.sym_node('nil')]),
		m.list_of([m.sym_node('_'), fail])])
	return m.node_of('let', [m.list_of([m.list_of([tmp, kids[2]])]), mitems])
}

// use => bind the values of an ok Result, or return the error unchanged.
//
// It is a continuation tag rather than a transform, and the reason is the one
// thing a transform cannot do here: `use` does not know how many names to bind.
// `(use (parse "x") a b)` binds two, `(use (commit conn) (print "done"))` binds
// zero, and the difference is only visible in the VALUE the call returned. A
// transform would have to guess -- from the number of body forms, which is what
// the first version did, and `(list-ref r 2)` on a one-element result is what
// that produced.
fn (mut m Machine) eval_use(kids []vlip.NodeId) ! {
	if kids.len < 2 {
		return error('use needs a call: (use (f x) body...)')
	}
	mut nf := m.kont(.use_k)
	nf.rest = vlip.NodeId(0)
	nf.slot = 0
	nf.env = m.env
	nf.clauses = kids
	m.push(nf)
	m.goto(kids[1])
}

// use_bind_names are the names `use` binds. They are generated, so a body cannot
// refer to them by name -- which is exactly what `let` is for when it wants to.
fn (m &Machine) use_name(i int) string {
	return 'use_' + i.str()
}

// ------------------------------------------------------------------ macros

// defmacro => an ordinary closure whose parameters are bound to the UNEVALUATED
// argument forms.
//
// Nothing here is hygienic and nothing pretends to be. A macro's expansion is
// code that will be spliced into the caller's context, so a macro that expands to
// a `let` over a name the caller also uses will capture it. `gensym` exists for
// exactly that and the examples use it.
//
// What makes it a macro rather than a function is only WHERE the arguments come
// from: `macex1` and `macex` build them as data instead of evaluating them. That
// is the whole design, and it is why a macro call is spelled `(macex (f ...))`
// rather than `(f ...)`: a bare call would have to evaluate its arguments first,
// which is the one thing a macro exists to avoid.
fn (mut m Machine) eval_defmacro(kids []vlip.NodeId) ! {
	if kids.len < 4 {
		return error('defmacro needs a name, a parameter list and a body: (defmacro name (args) body)')
	}
	name_node := m.arena.node(kids[1])
	if name_node.tag != .sym {
		return error('defmacro needs a name')
	}
	name := name_node.value
	spec := m.parse_params(m.arena.kids(kids[2]), name)!
	body := m.apply_destructures(spec, m.make_begin(kids[3..]))
	m.envs.define(m.env, name, m.make_closure(spec, body, m.env, name))
	m.val = vlip.symbol(name)
	m.ret()
}

// macex1 expands a macro form once and returns whatever came out, macro or not.
fn (mut m Machine) macex1(n vlip.NodeId) !vlip.Value {
	// The form is turned into a value first and expanded there, so `macex` can
	// loop on the RESULT -- which is a value -- without converting back and forth.
	return m.expand_macro_value(m.datum_to_value(n))
}

fn (m &Machine) is_macro_form(v vlip.Value) bool {
	if v.tag != .pair {
		return false
	}
	head := v.as_pair().car
	if head.tag != .symbol {
		return false
	}
	found := m.envs.lookup(m.globals, head.as_string()) or {
		return false
	}
	return found.tag == .closure && m.is_macro_closure(found)
}

// is_macro_closure asks whether a closure was made by defmacro. It is recorded as
// a name in a set rather than guessed from, because a guess would expand every
// procedure that happens to take a form.
fn (m &Machine) is_macro_closure(v vlip.Value) bool {
	if v.tag != .closure {
		return false
	}
	return v.as_closure().name in m.macros
}

// expand_macro_value runs one macro over `v` when `v` is a macro call, and
// returns `v` unchanged when it is not.
//
// Everything here works on VALUES, not on forms. A macro's arguments are already
// values -- that is what "unevaluated" means once the reader has run -- so the
// expansion of one macro can be expanded again without a reader or an arena
// NodeId anywhere in the loop.
fn (mut m Machine) expand_macro_value(v vlip.Value) !vlip.Value {
	if !m.is_macro_form(v) {
		return v
	}
	name := v.as_pair().car.as_string()
	macro := m.envs.lookup(m.globals, name) or {
		return error('macex: ${name} is not defined')
	}
	if !m.is_macro_closure(macro) {
		return error('macex: ${name} is not a macro')
	}
	args := prims.seq(v.as_pair().cdr) or {
		return error('macex: ${name} has no arguments')
	}
	return m.call_value(macro, args)!
}

fn (mut m Machine) macex(n vlip.NodeId) !vlip.Value {
	mut v := m.macex1(n)!
	mut i := 0
	// Eight rounds is a bound, not a hope: a macro that expands to itself would
	// otherwise hang, and the failure a reader wants is "macex did not terminate",
	// not a machine at the step limit forty seconds later.
	for i < 8 {
		if !m.is_macro_form(v) {
			return v
		}
		v = m.expand_macro_value(v)!
		i++
	}
	if m.is_macro_form(v) {
		return error('macex: still a macro after 8 expansions; a macro is probably expanding to itself')
	}
	return v
}

// struct => a constructor, a predicate, an accessor per field, and (when mutable)
// a setter per field.
//
// It works by generating a few definitions in vlip source and evaluating them in
// THIS machine. That looks roundabout next to building closures by hand, and it
// is the right trade for two reasons: a vlip Closure needs an arena NodeId for its
// body, so building one by hand means synthesising source text anyway; and a
// primitive that takes a machine cannot be expressed in the prims table at all.
// The definitions land in the current frame, so `(define (f p) (point-x p))` can
// see `point-x` -- a struct you cannot name from another function is not a type.
fn (mut m Machine) eval_struct(kids []vlip.NodeId) ! {
	if kids.len < 3 {
		return error('struct needs a name and a field list: (struct Name (f1 f2))')
	}
	name_node := m.arena.node(kids[1])
	if name_node.tag != .sym {
		return error('struct needs a name')
	}
	name := name_node.value
	fl := m.arena.kids(kids[2])
	mut fields := []string{}
	mut i := 0
	for i < fl.len {
		d := m.arena.node(fl[i])
		if d.tag != .sym {
			return error('struct ${name}: field ${i} is not a name')
		}
		fields << d.value
		i++
	}
	mut mutable := false
	mut opaque := false
	i = 3
	for i < kids.len {
		d := m.arena.node(kids[i])
		if d.tag == .kw {
			if d.value == '#:mutable' {
				mutable = true
			}
			if d.value == '#:opaque' {
				opaque = true
			}
		}
		i++
	}
	low := name.to_lower()
	mut src := ''
	mut params := []string{}
	mut quoted_fields := []string{}
	for f in fields {
		params << f
		quoted_fields << '"' + f + '"'
	}
	// The values are passed as SEPARATE arguments, not as one vector. They are
	// expanded here rather than in `__make-struct` because a struct of two fields
	// called with one argument is otherwise an arity error reported about a
	// primitive the user never wrote.
	src += '(define (${name} ${params.join(' ')}) (__make-struct (quote ${name}) (quote [${quoted_fields.join(' ')}]) ${params.join(' ')}))\n'
	src += '(define ${low}? (fn [v] (and (struct? v) (= (struct-name v) (quote ${name})))))\n'
	for f in fields {
		src += '(define ${low}-${f} (fn [v] (struct-ref v (quote ${f}))))\n'
		if mutable {
			src += '(define set-${low}.${f}! (fn [v x] (struct-set! v (quote ${f}) x)))\n'
		}
	}
	if opaque {
		// An opaque struct's constructor exists but is not bound, so the smart
		// constructor is the only way in. The predicate and the accessors stay
		// public: they cannot make a value that does not exist.
		src = '(define ${name}__ctor (fn [${params.join(' ')}] (__make-struct (quote ${name}) (quote [${quoted_fields.join(' ')}]) ${params.join(' ')})))\n' + src
	}
	m.eval_string_lenient(src) or {
		return error('struct ${name}: the generated definitions failed: ${err.msg()}')
	}
	m.val = vlip.symbol(name)
	m.ret()
}

// ------------------------------------------------------------------ require

// require => load another file into THIS machine.
//
// `(require "lib/geometry.vl")` loads the file and its definitions land in the
// global frame, which is what makes them visible to the requirer. The filters --
// `only-in` and `prefix-in` -- are accepted and ignored, because implementing
// them means renaming what a file defines, which needs the file's forms rather
// than its evaluated result. A filter that silently does nothing would be worse
// than one that is visibly absent, so the documentation says so and this comment
// is the code that admits it.
// resolve_path makes a relative `require` relative to the file that required it,
// not to the process's working directory.
//
// `./x.vl` and `x.vl` therefore mean one thing -- the same module -- and a package
// can never be shadowed by an unrelated file of the same name sitting in whatever
// directory the program was started from. It is also why `load` records the
// source path it is running: this is the only consumer of it.
pub fn (m &Machine) resolve_path(path string) string {
	if path.starts_with('/') || path.starts_with('.') || m.source == '' {
		return path
	}
	base := m.source
	mut cut := -1
	mut i := 0
	for i < base.len {
		c := base[i]
		if c == `/` || c == `\\` {
			cut = i
		}
		i++
	}
	if cut < 0 {
		return path
	}
	return base[..cut] + '/' + path
}

// loaded remembers which paths have already been evaluated in this machine, so a
// file required twice runs once.
//
// Without it, `(require "lib/text.vl")` after `(require (only-in "lib/text.vl"
// ...))` re-evaluates the file and every definition in it is replaced by a
// freshly made one -- which quietly discards any `set!` a caller had made.
fn (m &Machine) already_loaded(path string) bool {
	return path in m.loaded
}

fn (mut m Machine) eval_require(kids []vlip.NodeId) ! {
	mut paths := []string{}
	// kids[0] is the `require` symbol itself. Scanning it as a clause is how the
	// first version reported "require is not a file path" on a perfectly good
	// require.
	mut i := 1
	for i < kids.len {
		part := m.require_paths(kids[i])
		mut j := 0
		for j < part.len {
			paths << part[j]
			j++
		}
		if part.len == 0 {
			return error('require: ${m.render_node(kids[i])} is not a file path, or a form containing one')
		}
		i++
	}
	if paths.len == 0 {
		return error('require: no file path given')
	}
	mut k := 0
	for k < paths.len {
		full := m.resolve_path(paths[k])
		if !m.already_loaded(full) {
			m.load(full) or {
				return error('require: ${err.msg()}')
			}
			m.loaded << full
		}
		k++
	}
	m.val = vlip.nil_value()
	m.ret()
}

// require_paths returns the file paths in one `require` clause.
//
// A clause is a string, or a form whose head is a filter and whose arguments
// include the path: `(only-in "x.vl" a b)`, `(prefix-in p: "x.vl")`. Recursing
// into the form and collecting every string is enough for those, and it
// deliberately does NOT try to understand the filters -- see eval_require's
// comment. It RETURNS the list rather than appending to one the caller passed,
// because a `mut []string` parameter is awkward in V and this is the whole
// function.
fn (m &Machine) require_paths(n vlip.NodeId) []string {
	d := m.arena.node(n)
	if d.tag == .str {
		return [d.value]
	}
	if d.tag != .list {
		return []string{}
	}
	mut out := []string{}
	kids := m.arena.kids(n)
	mut i := 0
	for i < kids.len {
		part := m.require_paths(kids[i])
		mut j := 0
		for j < part.len {
			out << part[j]
			j++
		}
		i++
	}
	return out
}

// let => ((lambda (a b) body) e1 e2). The values are evaluated in the enclosing
// scope, which is exactly let semantics, and the result is an ordinary
// application so it needs no new continuation.
//
// A binding may be a PATTERN as well as a name: `(let ([(list h t) '(1 2)]) ...)`.
// It is compiled into a `match` over a temporary, because destructuring is what
// the pattern matcher already knows how to do and writing a second binder for
// lists, tables and structs would be three implementations to keep in step.
pub fn (mut m Machine) transform_let(kids []vlip.NodeId) !vlip.NodeId {
	// `(let assert PATTERN VALUE body...)` is `let` with the word `assert` in the
	// binding slot. It is read here rather than as its own head symbol so that
	// `(let assert ...)` needs no reader change and so that a program can use
	// `assert` as an ordinary variable name everywhere else.
	if kids.len > 1 && m.arena.node(kids[1]).tag == .sym
		&& m.arena.node(kids[1]).value == 'assert' {
		return m.transform_let_assert(kids[1..])
	}
	// `(let NAME VALUE body...)` is the one-binding shorthand. It is unambiguous
	// because a bracketed binding list can never be a symbol: kids[1] being a
	// symbol means the programmer left the brackets out.
	if kids.len > 2 && m.arena.node(kids[1]).tag == .sym {
		pair := m.list_of2([kids[1]], [kids[2]])
		mut rest := [kids[0], pair]
		rest << kids[3..]
		return m.transform_let(rest)
	}
	binds := m.arena.kids(kids[1])
	if binds.len == 0 {
		return m.make_begin(kids[2..])
	}
	// Each binding becomes one lambda. A destructuring binding needs TWO: one to
	// bind the value to a temporary, and one to bind the names extracted from it.
	// They cannot be one lambda because a lambda application evaluates all of its
	// arguments in the CALLER's scope, where the temporary is not yet bound.
	mut groups := []Group{}
	mut i := 0
	for i < binds.len {
		if m.is_destructuring(binds[i]) {
			tmp := m.sym_node(m.fresh('let'))
			groups << Group{
				params: [tmp]
				args:   [m.binding_value(binds[i])]
			}
			mut names := []vlip.NodeId{}
			mut vals := []vlip.NodeId{}
			for p in m.destructuring(m.binding_pattern(binds[i]), tmp)! {
				names << p.name
				vals << p.accessor
			}
			groups << Group{
				params: names
				args:   vals
			}
		} else {
			groups << Group{
				params: [m.binding_name(binds[i])]
				args:   [m.binding_value(binds[i])]
			}
		}
		i++
	}
	return m.nest_lets(groups, kids[2..])
}

// Group is one lambda's parameter list and argument list. `let` is a nest of
// these rather than one wide lambda because destructuring needs a scope per step.
pub struct Group {
pub mut:
	params []vlip.NodeId
	args   []vlip.NodeId
}

// nest_lets builds the lambda nest, putting the body LAST so that the body stays
// in tail position at every level.
fn (mut m Machine) nest_lets(groups []Group, body []vlip.NodeId) vlip.NodeId {
	if groups.len == 0 {
		return m.make_begin(body)
	}
	g := groups[0]
	lam := m.node_of('lambda', [m.list_of(g.params), m.nest_lets(groups[1..], body)])
	return m.call_node(lam, g.args)
}

// Destructured is one name a destructuring binding introduces, with the EXPRESSION
// that produces it.
pub struct Destructured {
pub mut:
	name     vlip.NodeId
	accessor vlip.NodeId
}

// destructuring expands a binding pattern into names and accessor expressions.
//
// `(let ([(list h t) xs]) body)` becomes
//
//	(let ([__v xs]) (let ([h (list-ref __v 0)] [t (list-ref __v 1)]) body))
//
// and NOT a `match` over the pattern. The match version was the first attempt and
// it is wrong in a way that only shows up on the second line: a `match` binds its
// names in the frame of its own clause, so `body` -- evaluated after the match has
// returned -- cannot see them. It reported "unbound identifier: h".
//
// Accessors rather than a match also means a destructuring binding costs nothing
// at run time and cannot fail at run time, which is what a binding should be.
pub fn (mut m Machine) destructuring(pattern vlip.NodeId, value vlip.NodeId) ![]Destructured {
	d := m.arena.node(pattern)
	if d.tag == .sym {
		if d.value == '_' {
			return []Destructured{}
		}
		return [Destructured{
			name:     pattern
			accessor: value
		}]
	}
	if d.tag == .kw || d.tag == .int || d.tag == .str {
		return error('${m.render_node(pattern)} cannot be a destructuring binding: it is a literal')
	}
	if d.tag == .table {
		kids := m.arena.kids(pattern)
		mut out := []Destructured{}
		mut i := 0
		for i + 1 < kids.len {
			k := m.arena.node(kids[i])
			if k.tag != .kw {
				return error('a table destructuring binding needs keyword keys')
			}
			out << Destructured{
				name:     kids[i + 1]
				accessor: m.call_node(m.sym_node('get'), [value, kids[i]])
			}
			i += 2
		}
		return out
	}
	if d.tag != .list {
		return error('${m.render_node(pattern)} cannot be a destructuring binding')
	}
	kids := m.arena.kids(pattern)
	if kids.len == 0 {
		return []Destructured{}
	}
	head := m.pattern_head(pattern)
	if head == 'cons' {
		if kids.len != 3 {
			return error('(cons head tail) needs a head and a tail')
		}
		return [Destructured{
			name:     kids[1]
			accessor: m.call_node(m.sym_node('car'), [value])
		}, Destructured{
			name:     kids[2]
			accessor: m.call_node(m.sym_node('cdr'), [value])
		}]
	}
	if head == 'list' || head == 'vector' || head == '' {
		// No tail capture here, deliberately. In a MATCH, `(list 1 rest)` binds
		// the remainder, and `is_capturing_tail` decides that from a bare symbol in
		// the last position. In a BINDING that reading is ambiguous -- `(list h t)`
		// would bind only `h` and treat `t` as the rest -- so positions are
		// positional: `(list h t)` binds exactly two elements.
		mut out := []Destructured{}
		mut i := 1
		for i < kids.len {
			out << m.destructuring(kids[i], m.call_node(m.sym_node('list-ref'), [value,
				m.int_node(i64(i - 1))]))!
			i++
		}
		return out
	}
	if head == 'struct' {
		if kids.len < 2 {
			return error('(struct Name f: p ...) needs a name and a field')
		}
		nm := m.arena.node(kids[1])
		if nm.tag != .sym {
			return error('a struct destructuring binding needs a struct name')
		}
		mut out := []Destructured{}
		mut i := 2
		for i < kids.len {
			f := m.arena.node(kids[i])
			mut fname := ''
			if f.tag == .kw {
				fname = f.value
			} else if f.tag == .sym && f.value.ends_with(':') {
				fname = f.value[..f.value.len - 1]
			} else {
				return error('a struct destructuring field must be written field: pattern')
			}
			if i + 1 >= kids.len {
				return error('field ${fname} has no name')
			}
			out << m.destructuring(kids[i + 1], m.call_node(m.sym_node('${nm.value.to_lower()}-${fname}'), [value]))!
			i += 2
		}
		return out
	}
	return error('${m.render_node(pattern)} cannot be a destructuring binding')
}

// is_destructuring reports whether a binding form's left side is a PATTERN rather
// than a name. `((list a b) value)` and `({:kind k} value)` destructure; `[a 1]`
// and `(a 1)` bind one name.
pub fn (m &Machine) is_destructuring(b vlip.NodeId) bool {
	if !m.is_binding_form(b) {
		return false
	}
	k := m.arena.kids(b)
	if k.len == 0 {
		return false
	}
	bd := m.arena.node(k[0])
	return bd.tag in [.list, .table, .vector]
}

// binding_pattern is the left side of a destructuring binding.
pub fn (m &Machine) binding_pattern(b vlip.NodeId) vlip.NodeId {
	return m.arena.kids(b)[0]
}

// match_clause builds `(match subject [pattern body] [_ (error ...)])`.
//
// A destructuring binding is a promise, not a branch, so a mismatch is an error
// rather than a fall-through. That is the difference between `let` and `let assert`
// in the examples, and making it an error here means the destructuring case does
// not need a second implementation.
pub fn (mut m Machine) match_clause(subject vlip.NodeId, pattern vlip.NodeId) vlip.NodeId {
	fail := m.node_of('error', [m.string_node('pattern did not match'), m.call_node(
		m.sym_node('format'), [m.string_node('~a does not match ~a'), subject, pattern])])
	return m.node_of('match', [subject, m.list_of([pattern, m.sym_node('nil')]),
		m.list_of([m.sym_node('_'), fail])])
}

// let* => nested single-binding lets, so each value sees the previous name.
//
// The obvious version passes 1 as the starting index, treating `binds_at` as a
// count of forms already consumed. It is not: `binds_at` indexes
// `kids[1]`'s children, the binding group, so it must start at 0. Starting at 1
// silently DROPPED the first binding -- `(let* ([a 1] [b (+ a 1)]) b)` compiled to
// `(let ([b (+ a 1)]) b)`, whose `a` is then genuinely unbound in the enclosing
// scope. That is why the failure read as "unbound identifier: a" and was
// misdiagnosed for a while as the `[...]`-in-two-positions problem.
pub fn (mut m Machine) transform_let_star(kids []vlip.NodeId) vlip.NodeId {
	return m.transform_let_star_at(kids, 0)
}

fn (mut m Machine) transform_let_star_at(kids []vlip.NodeId, binds_at int) vlip.NodeId {
	binds := m.arena.kids(kids[1])
	if binds_at >= binds.len {
		return m.make_begin(kids[2..])
	}
	inner := m.transform_let_star_at(kids, binds_at + 1)
	mut one := []vlip.NodeId{}
	one << binds[binds_at]
	mut items := []vlip.NodeId{}
	items << m.sym_node('let')
	items << m.list_of(one)
	items << inner
	return m.list_of(items)
}

// letrec => every name is visible to every value, so all names are bound to nil
// first and then assigned.
// letrec needs the names in scope BEFORE their values are evaluated, so the
// values can see each other. Binding them as lambda parameters does that:
//
//   (letrec ([a A] [b B]) body)
//     => ((lambda (a b) (set! a A) (set! b B) body...) #f #f)
//
// The parameters start as #f placeholders. The earlier version instead
// `(set! a nil)` in the ENCLOSING scope, which required the name to already
// exist: `(letrec ([e ...] [o ...]) ...)` failed with "cannot set unbound
// identifier" unless `e` happened to be defined globally first, and it leaked
// every letrec binding into the global frame.
pub fn (mut m Machine) transform_letrec(kids []vlip.NodeId) vlip.NodeId {
	binds := m.arena.kids(kids[1])
	if binds.len == 0 {
		return m.make_begin(kids[2..])
	}
	nilq := m.arena.open(.quoted)
	m.arena.finish(nilq, [m.nil_node()])

	mut params := []vlip.NodeId{}
	mut stmts := []vlip.NodeId{}
	mut holes := []vlip.NodeId{}
	// An index loop, not `for b in binds`: V 0.5.2 emits an unresolved `NodeId`
	// in the generated C for a range loop over a []vlip.NodeId, so the alias
	// from another module has to be indexed by hand to compile.
	mut idx := 0
	for idx < binds.len {
		b := binds[idx]
		name := m.binding_name(b)
		params << name
		holes << nilq
		stmts << m.node_of('set!', [name, m.binding_value(b)])
		idx++
	}
mut bi := 2
	for bi < kids.len {
		stmts << kids[bi]
		bi++
	}
	lam := m.node_of('lambda', [m.list_of(params), m.make_begin(stmts)])
	return m.call_node(lam, holes)
}

// cond => nested ifs.
pub fn (mut m Machine) transform_cond(kids []vlip.NodeId) vlip.NodeId {
	mut items := []vlip.NodeId{}
	mut ci := 1
	for ci < kids.len {
		items << kids[ci]
		ci++
	}
	return m.cond_from(items)
}

fn (mut m Machine) cond_from(items []vlip.NodeId) vlip.NodeId {
	if items.len == 0 {
		return m.nil_node()
	}
	clause := m.arena.kids(items[0])
	if clause.len == 0 {
		return m.nil_node()
	}
	head := m.arena.node(clause[0])
	if head.tag == .sym && head.value == 'else' {
		if clause.len == 1 {
			return m.nil_node()
		}
		return m.make_begin(clause[1..])
	}
	if clause.len == 1 {
		// (cond (test)) => (let ([t test]) (if t t nil))
		t := m.sym_node('__cond_t')
		body := m.node_of('if', [t, t, m.nil_node()])
		// The lambda's PARAMETER list is (t); the binding form (t test) is what
		// goes through `let`.
		lam := m.node_of('lambda', [m.list_of([t]), body])
		return m.call_node(lam, [clause[0]])
	}
	// The `=>` marker is the SECOND element of the clause: a clause is
	// (test => proc), so test is kids[0], the marker is kids[1], and the
	// procedure is kids[2]. Checking kids[0] for `=>` never matched.
	if clause.len == 3 && m.arena.node(clause[1]).tag == .sym
		&& m.arena.node(clause[1]).value == '=>' {
		// (cond (test => proc)) => (let ([f proc]) (if test (f) rest))
		f := m.sym_node('__cond_f')
		rest := m.cond_from(items[1..])
		body := m.node_of('if', [clause[0], m.call_node(f, []vlip.NodeId{}), rest])
		// The lambda's PARAMETER list is (f). The binding form (f proc) is what
		// goes through `let`, not what a lambda takes.
		lam := m.node_of('lambda', [m.list_of([f]), body])
		return m.call_node(lam, [clause[2]])
	}
	rest := m.cond_from(items[1..])
	return m.node_of('if', [clause[0], m.make_begin(clause[1..]), rest])
}

// case => cond with `=` against the subject.
pub fn (mut m Machine) transform_case(kids []vlip.NodeId) vlip.NodeId {
subject := kids[1]
	mut items := []vlip.NodeId{}
	mut ci := 2
	for ci < kids.len {
		clause := m.arena.kids(kids[ci])
		if clause.len == 0 {
			ci++
			continue
		}
		head := m.arena.node(clause[0])
		if head.tag == .sym && head.value == 'else' {
			mut body := m.nil_node()
			if clause.len > 1 {
				body = m.make_begin(clause[1..])
			}
			items << m.list_of([m.sym_node('else'), body])
			// `else` ends the search: nothing after it can be reached, and keeping
			// it would make any later clause dead. So break, not continue.
			break
		}
		// A clause is [tests-list body...]: clause[0] holds the values to
		// compare against, and everything after it is the body. Reading the
		// body as another test value evaluated `(1 2)` as a call.
		tests := m.arena.kids(clause[0])
		if tests.len == 0 {
			ci++
			continue
		}
		mut body := m.nil_node()
		if clause.len > 1 {
			body = m.make_begin(clause[1..])
		}
		mut combined := m.call_node(m.sym_node('='), [subject, tests[0]])
		mut j := 1
		for j < tests.len {
			combined = m.node_of('or', [combined,
				m.call_node(m.sym_node('='), [subject, tests[j]])])
			j++
		}
		items << m.list_of([combined, body])
		ci++
	}
	return m.cond_from(items)
}

// loop is a named let: (loop name init body...) has the same shape as
// (let ([name init]) body...), and transform_let_at already builds the lambda
// application. Binding the name in the new frame is what makes the body able to
// refer to itself.
pub fn (mut m Machine) transform_loop(kids []vlip.NodeId) vlip.NodeId {
	// (loop name init test body...) has a DIFFERENT shape from let -- the name
	// and init are separate arguments, not a binding list -- so it cannot share
	// let's transform.
	//
	// It is a named let, whose standard definition is:
	//
	//   (let name ([name init]) body)
	//     =>  (letrec ([name (lambda (name) body)]) (name init))
	//
	// The inner lambda shadows `name` with itself, which is what lets the body
	// call `(name ...)` again. Without that self-binding the loop body would
	// refer to a dead binding and the first recursive call would fail.
	if kids.len < 4 {
		return m.make_begin(kids[2..])
	}
	name := kids[1]
	init := kids[2]
	test := kids[3]

	// `(loop i 0 ...)` names the variable `i`, and the loop function needs a
	// different name, or the body's `(f i)` would resolve `f` to the integer
	// parameter rather than the closure.
	fnname := m.sym_node(m.fresh('loop'))

	// The body has to advance the variable AND call itself, otherwise the
	// transform runs the body exactly once and returns. Both go at the end of
	// the body, and the call is in tail position of the lambda, so TCO still
	// holds: a million iterations use one frame.
	mut stmts := []vlip.NodeId{}
	mut bi := 4
	for bi < kids.len {
		stmts << kids[bi]
		bi++
	}
	stmts << m.node_of('set!', [name, m.call_node(m.sym_node('+'), [name,
		m.int_node(1)])])
	stmts << m.call_node(fnname, [name])
	body := m.make_begin(stmts)

	// (lambda (name) (if test body nil))
	inner := m.node_of('if', [test, body, m.nil_node()])
	lam := m.node_of('lambda', [m.list_of([name]), inner])

	// (letrec ([f lam]) (f init))
	bindform := m.list_of([fnname, lam])
	letrec := m.node_of('letrec', [m.list_of([bindform]), m.call_node(fnname, [init])])
	return letrec
}

// dotimes => (loop i 0 (< i n) body...)
pub fn (mut m Machine) transform_dotimes(kids []vlip.NodeId) !vlip.NodeId {
	if kids.len < 3 {
		return error('dotimes needs a loop variable and a count')
	}
	loopvar := m.arena.node(kids[1])
	if loopvar.tag != .sym {
		return error('dotimes needs a symbol as its loop variable, got ${printer.write_datum(m.arena, kids[1])}')
	}
	lt := m.call_node(m.sym_node('<'), [kids[1], kids[2]])
	mut items := []vlip.NodeId{}
	items << kids[1]
	items << m.int_node(0)
	items << lt
	mut i := 3
	for i < kids.len {
		items << kids[i]
		i++
	}
	return m.node_of('loop', items)
}

// binding_name extracts the name of a binding form: either a bare symbol or the
// head of (name expr). A lambda parameter list needs the NAME, not the form, so
// let has to map each binding through this before building its lambda.
//
// vlip accepts both (name expr) and [name expr] as the binding form, because
// `[...]` is a VECTOR here and the documentation and examples write it that way.
// Checking only for `.list` silently passed the whole vector through as a
// parameter name, which surfaced as "lambda parameters must be symbols".
fn (mut m Machine) is_binding_form(b vlip.NodeId) bool {
	tag := m.arena.node(b).tag
	return tag == .list || tag == .vector
}

pub fn (mut m Machine) binding_name(b vlip.NodeId) vlip.NodeId {
	if m.is_binding_form(b) {
		k := m.arena.kids(b)
		if k.len > 0 {
			return k[0]
		}
	}
	return b
}


// binding_value extracts the value expression of a binding form.
pub fn (mut m Machine) binding_value(b vlip.NodeId) vlip.NodeId {
	if m.is_binding_form(b) {
		k := m.arena.kids(b)
		if k.len > 1 {
			return k[1]
		}
	}
	return b
}
