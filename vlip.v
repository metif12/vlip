module main

// vlip: run a .lip file, or start a REPL.
//
//   vlip                 a REPL
//   vlip repl            the same REPL, for symmetry with `run`
//   vlip run file.lip    evaluate a file
//   vlip run a.lip b.lip evaluate several, in order, in one machine
//   vlip file.lip        shorthand for `vlip run file.lip`
//   vlip test file.lip   evaluate and check the `;=>` expectations in comments
//
// No arguments starts a REPL because the CLI already requires a file for
// anything else, so the default costs nothing and is the thing a person wants
// most often once the language is installed.

import os
import vlib.vlip
import vlib.vlip.host
import vlib.vlip.machine
import vlib.vlip.printer
import vlib.vlip.reader
import vlib.vlip.repl

// exit_code ends the process with a status. This V version has no os.exit; the
// exit function is a builtin, but it is shadowed here so the intent is clear at
// every call site.
fn exit_code(code int) {
	exit(code)
}

fn usage() {
	eprintln('usage: vlip | vlip repl | vlip run <file.lip> ... | vlip file.lip')
}

// run_files evaluates files IN ORDER IN ONE MACHINE.
//
// One machine, not one per file, is the difference between `vlip run prelude.lip
// program.lip` working and reporting that everything the first file defined is
// unbound in the second.
fn run_files(paths []string) int {
	h := &host.ConsoleHost{}
	mut m := machine.new_standalone(h)
	mut code := 0
	for path in paths {
		src := os.read_file(path) or {
			eprintln('vlip: cannot read ${path}')
			code = 1
			continue
		}
		// run_str reads into the MACHINE's arena, which is the only arena the
		// machine can evaluate a NodeId from. Reading into a fresh one per file
		// and handing the forms over is the shape this code had first, and it
		// read arbitrary memory without crashing -- the run above returned 0 for
		// every file.
		m.source = path
		m.run_str(src) or {
			eprintln('vlip: ${path}: ${err.msg()}')
			code = 1
		}
	}
	return code
}

// test_file evaluates a file. The `;=>` expectations are checked by
// tests/examples_run.v, which has the reader open; the CLI only answers "does it
// run to completion".
fn test_file(path string) int {
	src := os.read_file(path) or {
		eprintln('vlip: cannot read ${path}')
		return 1
	}
	h := &host.ConsoleHost{}
	mut m := machine.new_standalone(h)
	m.source = path
	m.run_str(src) or {
		eprintln('vlip: ${path}: ${err.msg()}')
		return 1
	}
	return 0
}

fn main() {
	args := os.args[1..]
	if args.len == 0 {
		mut r := repl.new(&host.ConsoleHost{})
		exit_code(r.run())
	}
	match args[0] {
		'repl' {
			mut r := repl.new(&host.ConsoleHost{})
			exit_code(r.run())
		}
		'run' {
			if args.len < 2 {
				eprintln('vlip: run needs a file')
				exit_code(2)
			}
			exit_code(run_files(args[1..]))
		}
		'test' {
			if args.len < 2 {
				eprintln('vlip: test needs a file')
				exit_code(2)
			}
			mut code := 0
			for f in args[1..] {
				if test_file(f) != 0 {
					code = 1
				}
			}
			exit_code(code)
		}
		'-h', '--help', 'help' {
			usage()
		}
		else {
			// Allow `vlip file.lip` as a shorthand for `vlip run file.lip`.
			exit_code(run_files(args))
		}
	}
}