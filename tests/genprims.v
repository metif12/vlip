module main

// The generated-prims gate: every prim tools/genprims.vsh emits gets its
// value checked here, so a regen that silently changes semantics -- a new V
// behind the same signature -- fails loudly instead of shipping.
//
// Exact float equality is used throughout, and only where the answer is
// designed to be exact (sin 0, cos 0, powers of ten). Anything computed is
// asserted by type instead.

import vlib.blip.host
import vlib.blip.machine
import vlib.blip.printer

struct Suite {
mut:
	fails int
}

fn (mut s Suite) fail(label string, msg string) {
	s.fails++
	println('FAIL ${label}: ${msg}')
}

fn (mut s Suite) ok(label string, detail string) {
	println('ok   ${label} => ${detail}')
}

fn (mut s Suite) record(label string, passed bool, good string, bad string) bool {
	if passed {
		s.ok(label, good)
	} else {
		s.fail(label, bad)
	}
	return passed
}

// ev evaluates one form and renders the value, or the error prefixed so a
// failure to evaluate reads as a value mismatch rather than a crash.
fn ev(mut m machine.Machine, src string) string {
	v := m.run_str(src) or { return 'ERROR: ${err.msg()}' }
	return printer.write(v)
}

fn (mut s Suite) values(mut m machine.Machine) {
	cases := [
		['(math-sin 0)', '0.0'],
		['(math-cos 0)', '1.0'],
		['(math-floor 2.7)', '2.0'],
		['(math-factorial 5)', '120.0'],
		['(math-log10 100)', '2.0'],
		['(math-exp 0)', '1.0'],
		['(math-log 1)', '0.0'],
	]
	for c in cases {
		got := ev(mut m, c[0])
		s.record('gen ${c[0]}', got == c[1], '${c[0]} is ${c[1]}', '${c[0]} gave ${got}')
	}
	// An integer flows into a float prim: the numeric tower, not an error.
	s.record('gen int into float prim', ev(mut m, '(float? (math-sin 1))') == '#t',
		'(math-sin 1) is a float', ev(mut m, '(math-sin 1)'))
}

fn (mut s Suite) errors(mut m machine.Machine) {
	arity := ev(mut m, '(math-sin)')
	s.record('gen arity error', arity.contains('expects 1 argument'),
		'zero args reported', arity)
	typ := ev(mut m, '(math-sin "x")')
	s.record('gen type error', typ.contains('expects a number'), 'a string reported', typ)
	// sincos returns a tuple upstream, so it is skipped: still unbound here.
	unbound := ev(mut m, '(math-sincos 0)')
	s.record('gen skipped stays unbound', unbound.contains('unbound identifier'),
		'sincos unbound', unbound)
}

fn main() {
	mut s := Suite{}
	h := host.new_capture()
	mut m := machine.new_standalone(h)
	s.values(mut m)
	s.errors(mut m)

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		return
	}
	println('genprims: all checks passed')
}