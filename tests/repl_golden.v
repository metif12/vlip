module main

/*
 * The REPL gate.
 *
 * Two halves, and the second is the one that matters:
 *
 *   * In-process checks driven through a CaptureHost. Fast, precise, and able to
 *     assert on individual behaviours: that a definition survives from one line to
 *     the next, that an unfinished form is INCOMPLETE rather than broken, that a
 *     bad form does not end the session.
 *   * One golden test that pipes a script into the real binary's stdin and diffs
 *     stdout against a checked-in fixture. This is the only thing that can see the
 *     prompt, the banner, the order of the writes, and anything the Host
 *     indirection got wrong.
 *
 * The fixture is tests/golden/repl.txt. It is checked in rather than regenerated
 * in place, because a golden test that writes its own expectation tests nothing.
 * When the output changes on purpose, read the new output and confirm every line
 * of it before updating the fixture -- the whole value here is that the diff is
 * small enough to read.
 */

import os
import vlib.vlip
import vlib.vlip.host
import vlib.vlip.repl

struct Suite {
mut:
	fails int
}

fn (mut s Suite) fail(label string, msg string) {
	s.fails++
	println('FAIL ${label}: ${msg}')
}

// passed is the reporting helper: it prints ok only when the check holds, and
// returns whether to carry on reporting.
fn (mut s Suite) passed(label string, ok bool, detail string, bad string) bool {
	if ok {
		println('ok   ${label} => ${detail}')
	} else {
		s.fail(label, bad)
	}
	return ok
}

// repo_root walks up from this file: tests/repl_golden.v is two levels deep.
fn repo_root() string {
	return os.dir(os.dir(@FILE))
}

$if windows {
	const exe_name = 'vlip.exe'
} $else {
	const exe_name = 'vlip'
}

fn prompt_for(buffer string) string {
	return repl.prompt(buffer)
}

fn main() {
	mut s := Suite{}
	s.definitions_persist_between_lines()
	s.an_unfinished_form_is_not_an_error()
	s.an_unfinished_string_is_not_an_error()
	s.a_bad_form_does_not_end_the_session()
	s.a_read_error_does_not_end_the_session()
	s.load_and_reload_use_the_running_machine()
	s.a_missing_load_reports_and_continues()
	s.quit_stops_reading()
	s.the_prompt_shows_the_depth()
	s.golden_stdin_to_stdout()

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		return
	}
	println('repl: all checks passed')
}

// ---- in-process checks -------------------------------------------------

fn (mut s Suite) definitions_persist_between_lines() bool {
	lines := ['(define x 41)', '(define (f) (+ x 1))', '(f)']
	h := host.new_capture()
	mut r := repl.new(h)
	r.run_lines(lines)
	want := ['x', 'f', '42']
	return s.passed('definitions persist between lines', h.lines() == want,
		'three lines, one machine', 'got ${h.lines()}, want ${want}')
}

fn (mut s Suite) an_unfinished_form_is_not_an_error() bool {
	lines := ['(define (sq x)', '  (* x x))', '(sq 7)']
	h := host.new_capture()
	mut r := repl.new(h)
	r.run_lines(lines)
	want := ['sq', '49']
	return s.passed('an unfinished form is not an error', h.lines() == want,
		'two lines for one form, then the answer', 'got ${h.lines()}, want ${want}')
}

fn (mut s Suite) an_unfinished_string_is_not_an_error() bool {
	lines := ['(display "one', ' two")']
	h := host.new_capture()
	mut r := repl.new(h)
	r.run_lines(lines)
	// The newline the two lines were joined with is INSIDE the string literal --
	// the reader accepts a literal newline there -- so the first captured line
	// contains one. What matters is that nothing errored and both halves arrived.
	got := h.lines().join('')
	ok := got.contains('one') && got.contains(' two') && !got.contains('error')
	return s.passed('an unfinished string is not an error', ok,
		'a string spanning two lines was read whole', 'got ${h.lines()}')
}

fn (mut s Suite) a_bad_form_does_not_end_the_session() bool {
	h := host.new_capture()
	mut r := repl.new(h)
	r.run_lines(['(car 1)', '(define fine 1)', 'fine'])
	got := h.lines().join('|')
	want := 'error: car: car expects a pair, got 1|fine|1'
	return s.passed('a bad form does not end the session', got == want,
		'one error, then two more forms evaluated', 'got ${got}, want ${want}')
}

fn (mut s Suite) a_read_error_does_not_end_the_session() bool {
	h := host.new_capture()
	mut r := repl.new(h)
	// A stray closing bracket is a real syntax error, not an unfinished form. The
	// session must report it rather than sit waiting for a bracket that is never
	// coming -- which is why is_open() uses a depth scan and not the reader's
	// `incomplete` diagnostic.
	r.run_lines([')', '(define fine 2)', 'fine'])
	got := h.lines().join('|')
	ok := got.ends_with('|fine|2')
	return s.passed('a read error does not end the session', ok,
		'a stray bracket was reported and the session carried on', 'got ${got}')
}

fn (mut s Suite) load_and_reload_use_the_running_machine() bool {
	h := host.new_capture()
	mut r := repl.new(h)
	h.give_file('lib.vl', '(define from-file 10)\n(define (twice n) (* 2 n))')
	r.run_lines(['(define before 1)', ',l lib.vl', '(twice from-file)', 'before', ',r'])
	got := h.lines().join('|')
	want := 'before|loaded lib.vl|20|1|loaded lib.vl'
	return s.passed('load and reload use the running machine', got == want,
		'a definition from before the load survives it, and ,r works', 'got ${got}, want ${want}')
}

fn (mut s Suite) a_missing_load_reports_and_continues() bool {
	h := host.new_capture()
	mut r := repl.new(h)
	r.run_lines([',l nope.vl', '(+ 1 1)'])
	got := h.lines().join('|')
	want := 'error: no such file in the capture host: nope.vl|2'
	return s.passed('a missing load reports and continues', got == want,
		'the error did not end the session', 'got ${got}, want ${want}')
}

fn (mut s Suite) quit_stops_reading() bool {
	h := host.new_capture()
	mut r := repl.new(h)
	r.run_lines(['(+ 1 2)', ',q', '(car 1)'])
	return s.passed('quit stops reading', h.lines() == ['3'], 'nothing after ,q was evaluated',
		'got ${h.lines()}')
}

fn (mut s Suite) the_prompt_shows_the_depth() bool {
	cases := [
		['(+ 1 2)', 'vlip:1> '],
		['(define (f x)', 'vlip:2> '],
		['(+ 1', 'vlip:2> '],
		['(print "a string', 'vlip:2> '],
		['"a string', 'vlip"> '],
		['(print "a string")', 'vlip:1> '],
		['; a comment with ( in it', 'vlip:1> '],
		['#| a block ( comment |#', 'vlip:1> '],
	]
	mut bad := ''
	for c in cases {
		got := prompt_for(c[0])
		if got != c[1] {
			bad += 'for "${c[0]}" got "${got}" want "${c[1]}"; '
		}
	}
	return s.passed('the prompt shows the depth', bad == '',
		'depth, strings and comments all read right', bad)
}

// ---- the golden half ----------------------------------------------------

fn (mut s Suite) golden_stdin_to_stdout() bool {
	root := repo_root()
	exe := os.join_path(root, exe_name)
	if !os.exists(exe) {
		s.fail('golden stdin to stdout', 'no ${exe}; build it first with `v -cc gcc -o ${exe_name} vlip.v`')
		return false
	}
	tmp := os.vtmp_dir()
	script := os.join_path(tmp, 'vlip_repl_in.txt')
	got := os.join_path(tmp, 'vlip_repl_out.txt')
	want_path := os.join_path(os.dir(@FILE), 'golden${os.path_separator}repl.txt')

	// The input is written here rather than checked in, because it is also the
	// documentation of what the session does: multi-line input, a failure, a
	// recovery, a failed load, and a quit. `,l no-such-file.vl` is here to prove
	// that a FAILED load does not end the session either.
	input := [
		'(define (greet name)',
		'  (format "hello, ~a" name))',
		'(greet "world")',
		'(car 1)',
		'(greet "again")',
		',l no-such-file.vl',
		'(greet "still here")',
		'(print "a string',
		'that spans two lines")',
		'(format "~s" "quoted here")',
		',q',
		'(print "never reached")',
		'',
	]
	os.write_file(script, input.join('\n')) or {
		s.fail('golden stdin to stdout', 'cannot write ${script}')
		return false
	}
	if os.exists(got) {
		os.rm(got) or { }
	}
	// Shell redirection rather than an API call: V's os.execute has no stdin
	// parameter, and the point of this half is that the REAL binary reads REAL
	// stdin.
	shell := '"${exe}" < "${script}" > "${got}"'
	os.system(shell)
	actual := os.read_file(got) or {
		s.fail('golden stdin to stdout', 'cannot read ${got}; the binary produced nothing')
		return false
	}
	expected := os.read_file(want_path) or {
		s.fail('golden stdin to stdout', 'missing fixture ${want_path}')
		return false
	}
	if actual == expected {
		println('ok   golden stdin to stdout => ${actual.trim_space().split('\n').len} lines match')
		return true
	}
	s.fail('golden stdin to stdout', first_difference(expected, actual))
	return false
}

// first_difference prints a small window around the first line that differs,
// because "expected N lines, got M" does not tell anyone what changed.
fn first_difference(expected string, actual string) string {
	mut elines := expected.trim_space().split('\n')
	mut alines := actual.trim_space().split('\n')
	mut i := 0
	for i < elines.len && i < alines.len {
		if elines[i] != alines[i] {
			return 'line ${i + 1}:\n  want: ${elines[i]}\n  got:  ${alines[i]}'
		}
		i++
	}
	if i < elines.len {
		return 'the fixture has ${elines.len - i} more line(s) after line ${i}; got ends at "${if i < alines.len { alines[i] } else { "" }}"\nfull output:\n${actual}'
	}
	return 'the output has ${alines.len - i} more line(s) than the fixture after line ${i}\nfull output:\n${actual}'
}