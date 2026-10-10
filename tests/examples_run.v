module main

// The example suite: run every examples/*.lip file and check its output.
//
// The examples are the specification. Each one ends with a marker line --
// "basics ok", "data ok", "match ok", "errors ok", "pipelines ok",
// "modules ok" -- and the `;=>` comments along the way record what each form
// is supposed to produce. This file runs them and asserts the markers, which
// is the cheapest gate that catches a regression in any of the six.
//
// The output is captured through the machine's own `out` slice rather than
// through the host, so the test does not depend on stdout being line-buffered
// or on the host being a console.
//
// Every file is run in a FRESH machine. A shared machine would let a leak from
// one example satisfy an assertion in the next, and the whole point of the
// suite is that each example stands alone.

import os
import vlib.blip
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

// run_example evaluates one file and returns everything it printed.
//
// The standard library is loaded first, exactly as `blip run` does, because the
// examples call parse-in and connect without defining them. The capture host
// only serves files that have been put into it, so the library is read from
// disk here and handed over.
//
// The module files examples/lib/*.vl are loaded too, because 06_modules
// requires them and `require` goes through the host.
fn run_example(path string) !string {
	src := os.read_file(path) or {
		return error('cannot read ${path}')
	}
	h := host.new_capture()
	for f in ['lib/std.lip', 'examples/lib/geometry.vl', 'examples/lib/text.vl'] {
		body := os.read_file(f) or {
			return error('cannot read ${f}')
		}
		h.give_file(f, body)
	}
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

// check_example runs one file and asserts that its output contains want.
fn (mut s Suite) check_example(label string, path string, want string) {
	out := run_example(path) or {
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

	// The six examples, in the order they are meant to be read. Each one builds
	// on the previous: 01 is the language, 02 is data, 03 is match, 04 is
	// errors, 05 is macros and pipes, 06 is modules.
	s.check_example('01_basics', 'examples/01_basics.lip', 'basics ok')
	s.check_example('02_data', 'examples/02_data.lip', 'data ok')
	s.check_example('03_match', 'examples/03_match.lip', 'match ok')
	s.check_example('04_errors', 'examples/04_errors.lip', 'errors ok')
	s.check_example('05_pipelines', 'examples/05_pipelines.lip', 'pipelines ok')
	s.check_example('06_modules', 'examples/06_modules.lip', 'modules ok')

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		return
	}
	println('examples: all checks passed')
}
