module main

// The programs gate: run every programs/*.lip file and check its output.
//
// The examples are the specification; the programs are the proof. Each one
// ends with a marker line -- "brainfuck ok", "json ok" -- and this file runs
// them and asserts the markers, the same cheap gate examples_run.v uses.
//
// Every file runs in a FRESH machine, for the same reason: a shared machine
// would let a leak from one program satisfy an assertion in the next.
//
// Programs differ from examples in one way that matters here: they do real
// I/O. Brainfuck's `,` command reads a line, so the capture host answers
// end-of-input (read-char yields 0 on EOF, which is also what a terminal
// gives). The hello-world program never reads, but the gate must not hang
// if a future program does.

import os
import vlib.blip.host
import vlib.blip.machine

struct Suite {
mut:
	fails int
}

fn (mut s Suite) fail(label string, msg string) {
	s.fails++
	println('FAIL ${label}: ${msg}')
}

// run_program evaluates one file and returns everything it printed.
//
// The standard library is loaded first, exactly as `blip run` does, because
// programs assume the prelude without defining it.
fn run_program(path string) !string {
	src := os.read_file(path) or {
		return error('cannot read ${path}')
	}
	h := host.new_capture()
	std := os.read_file('lib/std.lip') or {
		return error('cannot read lib/std.lip')
	}
	h.give_file('lib/std.lip', std)
	mut m := machine.new_standalone(h)
	m.load('lib/std.lip') or {
		return error('cannot load the standard library: ${err.msg()}')
	}
	m.source = path
	m.run_str(src) or {
		return error('${err.msg()}')
	}
	mut out := ''
	for line in m.out {
		out += line
		out += '\n'
	}
	return out
}

// check_program runs one file and asserts that its output contains want.
fn (mut s Suite) check_program(label string, path string, want string) {
	out := run_program(path) or {
		s.fail(label, err.msg())
		return
	}
	if !out.contains(want) {
		s.fail(label, 'output does not contain "${want}":\n${out}')
		return
	}
	println('ok   ${label}')
}

fn main() {
	mut s := Suite{}

	s.check_program('brainfuck', 'programs/brainfuck.lip', 'brainfuck ok')
	s.check_program('json', 'programs/json.lip', 'json ok')

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		return
	}
	println('programs: all checks passed')
}