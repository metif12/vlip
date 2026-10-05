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
import vlib.vlip.prims
import vlib.vlip.printer
import vlib.vlip.reader

@[flag]
enum Ctl {
	eval_form
	return_value
}

pub struct Machine {
pub mut:
	arena     &reader.Arena
	kstack    []vlip.Kont
	globals   vlip.EnvId
	envs       vlip.EnvArena
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
}

pub fn new_machine(a &reader.Arena) &Machine {
	// The reference fields (arena, globals, env) must be initialised inside an
	// unsafe block.
	mut m := unsafe {
		&Machine{
			arena:   a
			kstack:  []vlip.Kont{}
			envs:    vlip.EnvArena{}
			globals: vlip.no_env
			env:     vlip.no_env
			prims:   prims.table()
		}
	}
	// The global environment must be a real frame, not `no_env`: `no_env` is the
	// null env, and a `define` into it dereferences nil. Getting this wrong
	// crashes on the first `(define ...)` with no diagnostic.
	m.globals = m.envs.new_env(vlip.no_env)
	m.env = m.globals
	return m
}

// ---------------------------------------------------------------- the loop

// run evaluates top-level forms in order and returns the last value.
pub fn (mut m Machine) run(forms []vlip.NodeId) !vlip.Value {
	mut last := vlip.nil_value()
	for f in forms {
		m.form = f
		m.env = m.globals
		m.ctl = .eval_form
		last = m.drive()!
	}
	return last
}

// eval_one evaluates a single form, for the REPL.
pub fn (mut m Machine) eval_one(f vlip.NodeId) !vlip.Value {
	m.form = f
	m.env = m.globals
	m.ctl = .eval_form
	return m.drive()
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
		match m.ctl {
			.eval_form {
				m.step_eval()!
			}
			.return_value {
				if !m.step_return() {
					return m.val
				}
			}
			else {
				panic('machine: unknown control state ${m.ctl}')
			}
		}
	}
}

// fatal renders an abort message. Used where continuing would be worse than
// stopping: an unbound identifier in a compiled program is a bug, not a
// recoverable condition.
fn (m &Machine) fatal(msg string) string {
	return msg
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

fn (mut m Machine) err(msg string) ! {
	return error(msg)
}

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
				m.val = vlip.nil_value()
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
	if name in m.prims {
		m.val = vlip.new_prim(name)
		m.ret()
		return
	}
	return m.err('unbound identifier: ${name}')
}

fn (mut m Machine) eval_list(id vlip.NodeId, kids []vlip.NodeId) ! {
	head := m.arena.node(kids[0])
	if head.tag == .sym {
		if special_form(head.value) {
			return m.eval_special(head.value, id, kids)
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

// ----------------------------------------------------------------- RETURN

// step_return handles one value coming back. It returns false when the
// continuation stack is empty, which is the machine's answer.
fn (mut m Machine) step_return() bool {
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
				m.apply_all(all)
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
				m.apply_all(k.acc)
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
			m.envs.define(m.env, k.name, m.val)
			m.val = vlip.symbol(k.name)
			m.ret()
		}
		.set_k {
			if !m.envs.set(m.env, k.name, m.val) {

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
		else {
			// .done is never pushed, so reaching it means the machine is broken.
			panic('machine: unexpected continuation ${k.tag}')
		}
	}
	return true
}

// -------------------------------------------------------------- application

fn (mut m Machine) apply_all(all_in []vlip.Value) {
	mut all := all_in.clone()
	callee := all[0]
	mut args := []vlip.Value{}
	for i in 1 .. all.len {
		args << all[i]
	}
	match callee.tag {
		.closure {
			m.call_closure(callee.as_closure(), args)
		}
		.primitive {
			m.call_primitive(callee.as_string(), args)
		}
		.table, .buffer {
			if args.len != 1 {
				panic('a table used as a function takes 1 argument, got ')
			}
			if !(args[0].tag in [.keyword, .string]) {
				panic('a table lookup needs a keyword, got ')
			}
			m.val = callee.as_table().get(args[0].as_string())
			m.ret()
		}
		else {
			panic('cannot apply : not a function')
		}
	}
}

fn (mut m Machine) call_closure(c &vlip.Closure, args []vlip.Value) {
	// A trailing `rest` parameter collects the remaining arguments.
	if c.params.len > 0 && c.params[c.params.len - 1] == 'rest' {
		fixed := c.params[..c.params.len - 1]
		if args.len < fixed.len {
			panic(': expected at least  arguments, got ')
		}
		frame := m.envs.new_env(c.env)
		mut i := 0
		for i < fixed.len {
			m.envs.define(frame, fixed[i], args[i])
			i++
		}
		m.envs.define(frame, 'rest', vlip.list_from(args[fixed.len..]))
		m.env = frame
		m.goto(c.body)
		return
	}
	if args.len != c.arity {
		panic('${c.name}: expected ${c.arity} arguments, got ${args.len}')
	}
	frame := m.envs.new_env(c.env)
	mut i := 0
	for i < c.params.len {
		m.envs.define(frame, c.params[i], args[i])
		i++
	}
	m.env = frame
	// TAIL CALL: no continuation pushed. The body runs with whatever remains,
	// so recursion in tail position does not grow the stack.
	m.goto(c.body)
}

// format_args renders a format string plus its arguments. Only ~a (any value) is
// supported, because that is all the examples use; adding ~s or ~d later is a
// change in one place.
fn format_args(args []vlip.Value) string {
	if args.len == 0 {
		return ''
	}
	fm := args[0].as_string()
	mut out := []u8{}
	mut i := 0
	mut next := 1
	for i < fm.len {
		c := fm[i]
		if c == u8(126) && i + 1 < fm.len && fm[i + 1] == u8(97) {
			if next < args.len {
				out << printer.write(args[next]).bytes()
				next++
			}
			i += 2
			continue
		}
		out << c
		i++
	}
	return out.bytestr()
}

fn (mut m Machine) call_primitive(name string, args []vlip.Value) {
	// Builtins that need to call back into the interpreter are handled here
	// rather than through the plain-function table.
	match name {
		'apply' {
			if args.len < 2 {
				panic(m.fatal('apply expects at least 2 arguments'))
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
			m.apply_all(all)
			return
		}
		'error' {
			panic(m.fatal('error: ${format_args(args)}'))
		}
		'format' {
			m.val = vlip.string(format_args(args))
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
		else {}
	}
	f := m.prims[name] or {
		panic(m.fatal('unknown primitive: ${name}'))
	}
	mut call_args := []vlip.Value{}
	for a in args {
		call_args << a
	}
	res := f(call_args) or {
		panic(m.fatal('${name}: ${err.msg()}'))
	}
	m.val = res
	m.ret()
}
// ------------------------------------------------------------ special forms

pub fn special_form(name string) bool {
	return name in ['quote', 'if', 'define', 'set!', 'lambda', 'fn', 'begin', 'let', 'let*', 'letrec', 'and', 'or', 'when', 'unless', 'cond', 'case', 'loop', 'dotimes']
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
				return m.err('if needs a test, a consequent, and optionally an alternative')
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
		'set!' {
			target := m.arena.node(kids[1])
			if target.tag != .sym {
				return m.err('set! needs a name')
			}
	mut nf := m.kont(.set_k)
	nf.name = target.value
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
			m.goto(m.transform_let(kids))
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
			m.goto(m.transform_dotimes(kids))
		}
		else {
			return m.err('unimplemented special form: ${name}')
		}
	}
}

fn (mut m Machine) eval_define(kids []vlip.NodeId) ! {
	target := m.arena.node(kids[1])
	if target.tag == .sym {
	mut nf := m.kont(.define_k)
	nf.name = target.value
	m.push(nf)
		m.goto(kids[2])
		return
	}
	if target.tag == .list {
		sig := m.arena.kids(kids[1])
		if sig.len == 0 || m.arena.node(sig[0]).tag != .sym {
			return m.err('define needs a name')
		}
		fname := m.arena.node(sig[0]).value
		mut params := []string{}
		mut i := 1
		for i < sig.len {
			part := m.arena.node(sig[i])
			if part.tag == .sym {
				params << part.value
			} else if part.tag == .list {
				// (struct Point x: px y: py) destructuring parameter
				return m.err('destructuring parameters are not implemented yet')
			} else {
				return m.err('bad parameter in ${fname}')
			}
			i++
		}
		// The body is the forms AFTER the (name . params) signature, so it is
		// kids[2..] -- not sig[1..], which is the parameter list.
		body := m.make_begin(kids[2..])
		m.envs.define(m.env, fname, vlip.new_closure(params, body, m.env, fname))
		m.val = vlip.symbol(fname)
		m.ret()
		return
	}
	return m.err('define needs a name or a (name . params) list')
}

fn (mut m Machine) eval_lambda(kids []vlip.NodeId) ! {
	mut params := []string{}
	plist := m.arena.kids(kids[1])
	mut i := 0
	for i < plist.len {
		part := m.arena.node(plist[i])
		if part.tag == .sym {
			params << part.value
		} else {
			return m.err('lambda parameters must be symbols')
		}
		i++
	}
	body := m.make_begin(kids[2..])
	m.val = vlip.new_closure(params, body, m.env, 'lambda')
	m.ret()
}
// ------------------------------------------------------------- arena helpers

// fresh builds a name no source program can contain, for the helper function
// that `loop` compiles to. The loop variable doubles as the loop function's own
// name in user code -- `(loop i 0 ...)` names both `i` -- so the body's
// recursive call would otherwise resolve `i` to the integer parameter instead of
// the closure.
pub fn (mut m Machine) fresh(base string) string {
	m.gensym++
	return base + '.' + m.gensym.str()
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

// node_of builds a list headed by the named symbol, followed by `tail`.
pub fn (mut m Machine) node_of(head string, tail []vlip.NodeId) vlip.NodeId {
	mut items := []vlip.NodeId{}
	items << m.sym_node(head)
	for t in tail {
		items << t
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
		.list {
			mut items := []vlip.Value{}
			for k in kids {
				items << built[k]
			}
			return vlip.list_from(items)
		}
		.vector {
			mut items := []vlip.Value{}
			for k in kids {
				items << built[k]
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
			for k in kids {
				items << built[k]
			}
			return vlip.Value{
				tag: .array
				payload: &vlip.Vector{
					tag:  .array
					data: items
				}
			}
		}
		else { return vlip.nil_value() }
	}
}

// quasi_to_value builds a form ready to be handed to a macro: an unquote is
// evaluated now, everything else becomes a literal.
pub fn (mut m Machine) quasi_to_value(id vlip.NodeId) vlip.Value {
	d := m.arena.node(id)
	if d.tag == .unquote || d.tag == .unquote_splice {
		inner := m.arena.kids(id)[0]
		return m.eval_one(inner) or { vlip.nil_value() }
	}
	return m.datum_to_value(id)
}

// --------------------------------------------------------- the transformers
//
// Every derived form is rewritten into core forms here rather than given its
// own continuation type. The core stays small, and each derived form inherits
// tail-call behaviour for free.

// let => ((lambda (a b) body) e1 e2). The values are evaluated in the enclosing
// scope, which is exactly let semantics, and the result is an ordinary
// application so it needs no new continuation.
pub fn (mut m Machine) transform_let(kids []vlip.NodeId) vlip.NodeId {
	binds := m.arena.kids(kids[1])
	if binds.len == 0 {
		return m.make_begin(kids[2..])
	}
	mut params := []vlip.NodeId{}
	mut args := []vlip.NodeId{}
	mut i := 0
	for i < binds.len {
		params << m.binding_name(binds[i])
		args << m.binding_value(binds[i])
		i++
	}
	lam := m.node_of('lambda', [m.list_of(params), m.make_begin(kids[2..])])
	return m.call_node(lam, args)
}

// let* => nested single-binding lets, so each value sees the previous name.
pub fn (mut m Machine) transform_let_star(kids []vlip.NodeId) vlip.NodeId {
	return m.transform_let_star_at(kids, 1)
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
	for b in kids[2..] {
		stmts << b
	}
	lam := m.node_of('lambda', [m.list_of(params), m.make_begin(stmts)])
	return m.call_node(lam, holes)
}

// cond => nested ifs.
pub fn (mut m Machine) transform_cond(kids []vlip.NodeId) vlip.NodeId {
	mut items := []vlip.NodeId{}
	for c in kids[1..] {
		items << c
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
	for c in kids[2..] {
		clause := m.arena.kids(c)
		if clause.len == 0 {
			continue
		}
		head := m.arena.node(clause[0])
		if head.tag == .sym && head.value == 'else' {
			mut body := m.nil_node()
			if clause.len > 1 {
				body = m.make_begin(clause[1..])
			}
			items << m.list_of([m.sym_node('else'), body])
			continue
		}
		// A clause is [tests-list body...]: clause[0] holds the values to
		// compare against, and everything after it is the body. Reading the
		// body as another test value evaluated `(1 2)` as a call.
		tests := m.arena.kids(clause[0])
		if tests.len == 0 {
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
pub fn (mut m Machine) transform_dotimes(kids []vlip.NodeId) vlip.NodeId {
	loopvar := m.arena.node(kids[1])
	if loopvar.tag != .sym {

	}
	lt := m.call_node(m.sym_node('<'), [kids[1], kids[2]])
	mut items := []vlip.NodeId{}
	items << kids[1]
	items << m.int_node(0)
	items << lt
	for b in kids[3..] {
		items << b
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
