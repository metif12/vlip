module main

// blip: run a .lip file, or start a REPL.
//
//   blip                 a REPL
//   blip repl            the same REPL, for symmetry with `run`
//   blip run file.lip    evaluate a file
//   blip run a.lip b.lip evaluate several, in order, in one machine
//   blip file.lip        shorthand for `blip run file.lip`
//   blip test file.lip   evaluate and check the `;=>` expectations in comments
//
// No arguments starts a REPL because the CLI already requires a file for
// anything else, so the default costs nothing and is the thing a person wants
// most often once the language is installed.

import os
import vlib.blip
import vlib.blip.host
import vlib.blip.lsp
import vlib.blip.machine
import vlib.blip.printer
import vlib.blip.reader
import vlib.blip.repl

// exit_code ends the process with a status. This V version has no os.exit; the
// exit function is a builtin, but it is shadowed here so the intent is clear at
// every call site.
fn exit_code(code int) {
	exit(code)
}

fn usage() {
	eprintln('usage: blip | blip repl | blip run <file.lip> ... | blip file.lip | blip lsp')
}

// run_files evaluates files IN ORDER IN ONE MACHINE.
//
// One machine, not one per file, is the difference between `blip run prelude.lip
// program.lip` working and reporting that everything the first file defined is
// unbound in the second.

// std_path is the standard library, loaded before every program.
//
// A language with a prelude is a language where print and string-upcase are names
// rather than something every file has to require first. The examples assume it:
// a call to parse-in is a call, and making every reader scroll past a require for
// it would be the wrong default.
//
// It is loaded into the same machine as the program, so a program can rebind any
// of it and the change is visible to a later file.
fn std_path() string {
	exe := os.executable()
	dir := os.dir(exe)
	// The binary sits in the repository root when built with the documented
	// command, and one level up when it is put in tools/ during development.
	for candidate in [os.join_path(dir, 'lib${os.path_separator}std.lip'),
		os.join_path(os.dir(dir), 'lib${os.path_separator}std.lip')] {
		if os.exists(candidate) {
			return candidate
		}
	}
	return ''
}

fn run_files(paths []string) int {
	h := &host.ConsoleHost{}
	mut m := machine.new_standalone(h)
	mut code := 0
	std := std_path()
	if std != '' {
		m.load(std) or {
			eprintln('blip: cannot load the standard library: ${err.msg()}')
			code = 1
		}
	}
	for path in paths {
		src := os.read_file(path) or {
			eprintln('blip: cannot read ${path}')
			code = 1
			continue
		}
		m.source = path
		m.run_str(src) or {
			eprintln(err.msg())
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
		eprintln('blip: cannot read ${path}')
		return 1
	}
	h := &host.ConsoleHost{}
	mut m := machine.new_standalone(h)
	m.source = path
	m.run_str(src) or {
		eprintln(err.msg())
		return 1
	}
	return 0
}

// start_repl builds a REPL with the standard library already in it. The two ways
// to start one -- bare `blip` and `blip repl` -- share it, so the two cannot end
// up with different definitions.
fn start_repl() int {
	mut r := repl.new(&host.ConsoleHost{})
	std := std_path()
	if std != '' {
		r.machine.load(std) or {
			eprintln('blip: cannot load the standard library: ${err.msg()}')
		}
	}
	return r.run()
}

fn main() {
	args := os.args[1..]
	if args.len == 0 {
		exit_code(start_repl())
	}
	match args[0] {
		'repl' {
			exit_code(start_repl())
		}
		'run' {
			if args.len < 2 {
				eprintln('blip: run needs a file')
				exit_code(2)
			}
			exit_code(run_files(args[1..]))
		}
		'lsp' {
			lsp.serve()
		}
		'test' {
			if args.len < 2 {
				eprintln('blip: test needs a file')
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
			// Allow `blip file.lip` as a shorthand for `blip run file.lip`.
			exit_code(run_files(args))
		}
	}
}