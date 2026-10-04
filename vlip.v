module main

// vlip: run a .lip file.
//
//   vlip run examples/01_basics.lip
//   vlip repl

import os
import vlib.vlip
import vlib.vlip.machine
import vlib.vlip.printer
import vlib.vlip.reader

// exit_code ends the process with a status. This V version has no os.exit; the
// exit function is a builtin, but it is shadowed here so the intent is clear at
// every call site.
fn exit_code(code int) {
	exit(code)
}

fn run_file(path string) int {
	src := os.read_file(path) or {
		eprintln('vlip: cannot read ${path}')
		return 1
	}
	res := reader.read_all(src)
	for d in res.diags {
		eprintln(d.render(path))
	}
	if res.diags.len > 0 {
		eprintln('vlip: ${res.diags.len} read errors in ${path}')
		return 1
	}
	mut m := machine.new_machine(&res.arena)
	m.run(res.forms) or {
		eprintln('vlip: ${path}: ${err.msg()}')
		return 1
	}
	return 0
}

fn main() {
	args := os.args[1..]
	if args.len == 0 {
		eprintln('usage: vlip run <file.lip> ... | vlip repl')
		return
	}
	match args[0] {
		'run' {
			if args.len < 2 {
				eprintln('vlip: run needs a file')
				return
			}
			mut code := 0
			for f in args[1..] {
				r := run_file(f)
				if r != 0 {
					code = r
				}
			}
			if code != 0 {
				exit_code(code)
			}
		}
		'repl' {
			repl()
		}
		else {
			// Allow `vlip file.lip` as a shorthand for `vlip run file.lip`.
			for f in args {
				r := run_file(f)
				if r != 0 {
					exit_code(r)
				}
			}
		}
	}
}

fn repl() {
	src := 'vlip repl is not wired up yet; use `vlip run <file.lip>'
	println(src)
}
