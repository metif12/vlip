module repl

// The REPL: one persistent machine, reading through a Host.
//
// It lives in the library rather than in vlip.v for one reason -- every behaviour
// worth testing here needs a Host, and without the interface that means a
// subprocess and a scraped stdout. With it, the whole REPL can be driven from a
// test by handing it lines and reading back what it printed.
//
// Four properties this has, each of which was a bug or a missing feature first:
//
//   * One machine for the session. Definitions accumulate, which is the entire
//     point: a REPL that starts a fresh machine per line cannot define anything.
//   * Multi-line input. A form that is not finished yet is INCOMPLETE, not
//     broken, and the session keeps reading. The reader reports the two
//     separately for exactly this.
//   * Error recovery. A bad form prints one line and the session continues. This
//     is only possible because no failure panics; see the errors-are-values work
//     in machine/mod.v.
//   * `,l` loads a file into the RUNNING machine, so a definition made in the
//     REPL is still there afterwards and one made in the file is there before.

import vlib.vlip
import vlib.vlip.host
import vlib.vlip.machine
import vlib.vlip.printer
import vlib.vlip.reader

pub struct Repl {
pub mut:
	machine   &machine.Machine
	host      host.Host
	buffer    string
	last_file string
	done      bool
	// quiet suppresses the echoed value of a form, for a batch run that wants
	// only what the program printed.
	quiet bool
}

pub fn new(h host.Host) &Repl {
	return &Repl{
		machine: machine.new_standalone(h)
		host:    h
		buffer:  ''
	}
}

// new_with_machine drives a machine somebody else made. A host that wants two
// REPLs -- a UI and a script, say -- gets two machines and neither can see the
// other's definitions.
pub fn new_with_machine(m &machine.Machine, h host.Host) &Repl {
	return &Repl{
		machine: m
		host:    h
		buffer:  ''
	}
}

// prompt shows how deep the current form is. It is `vlip:1> ` at the top level
// and `vlip:2> ` while a bracket is open, which is the difference between "my
// program is stuck" and "the REPL is waiting for me to type another line".
pub fn prompt(buffer string) string {
	d := reader.depth(buffer)
	if d.n > 0 {
		return 'vlip:${d.n + 1}> '
	}
	if d.in_string {
		return 'vlip"> '
	}
	return 'vlip:1> '
}

// is_open reports whether the buffer is waiting for more input. It is the same
// scan the prompt uses, and deliberately not the reader's own `incomplete`
// diagnostic: a stray closing bracket reports a real syntax error, which the
// session must reject rather than wait on.
fn is_open(buffer string) bool {
	d := reader.depth(buffer)
	return d.n > 0 || d.in_string
}

// feed runs one complete chunk of input, as if the user had typed it and pressed
// Enter. It returns the number of top-level forms evaluated.
//
// Separated from run() so a test can drive the REPL without a line-reading loop,
// and so `,l` on a file's contents is the same code path as typing them.
fn (mut r Repl) feed(line string) !int {
	r.buffer += line + '\n'
	// A bare command is only a command when nothing is pending. Inside an open
	// form, `,q` is far more likely to be a symbol than a request.
	if r.buffer.count('\n') == 1 && line.starts_with(',') {
		cmd := r.buffer
		// The buffer MUST be cleared here. It is not: leaving it means the next
		// line is appended to `,l lib.vl`, and the two are then evaluated as a
		// single list -- so `,l` runs twice, once with the following line as an
		// argument, and the REPL reports "unbound identifier" for a file it had
		// just loaded.
		r.buffer = ''
		return r.command(cmd.trim_space())
	}
	if is_open(r.buffer) {
		return 0
	}
	src := r.buffer
	r.buffer = ''
	return r.evaluate(src)
}

// evaluate parses a complete chunk and runs it.
//
// TWO parses, into two arenas, on purpose. The first goes into a scratch arena and
// is used only for its diagnostics -- an incomplete or broken form must be
// reported without leaving a single node in the machine. The second goes into the
// machine's own arena, because a NodeId means nothing without the arena it was
// allocated from: evaluating forms read into the scratch arena against the
// machine's arena reads arbitrary memory, and does not reliably crash.
//
// Reading once into the machine's arena and discarding on failure was the obvious
// version. It leaves partial nodes behind on every unfinished line, which for a
// twenty-line form is twenty partial copies of it.
fn (mut r Repl) evaluate(src string) !int {
	mut probe := &reader.Arena{}
	pres := probe.read_forms(src)
	if pres.diags.len > 0 {
		d := pres.diags[0]
		r.host.host_print('${d.line}:${d.col}: ${d.msg}')
		return 0
	}
	res := r.machine.arena.read_forms(src)
	mut n := 0
	mut i := 0
	for i < res.forms.len {
		v := r.machine.eval_one(res.forms[i]) or {
			r.host.host_print('error: ${err.msg()}')
			i++
			// A form that fails does not abort the ones after it. That is the
			// whole difference between a REPL and `vlip run`.
			continue
		}
		if !r.quiet {
			r.host.host_print(printer.write(v))
		}
		n++
		i++
	}
	return n
}

// command handles a `,`-prefixed line. It returns 0 because a command evaluates
// nothing.
fn (mut r Repl) command(line string) !int {
	parts := line.trim_space().split(' ')
	name := parts[0]
	match name {
		',q', ',quit' {
			r.done = true
		}
		',h', ',help' {
			r.host.host_print('commands: ,l PATH load a file   ,r reload it   ,h help   ,q quit')
		}
		',l' {
			if parts.len < 2 {
				r.host.host_print('error: ,l needs a path')
				return 0
			}
			r.load_path(parts[1].trim_space())
		}
		',r' {
			if r.last_file == '' {
				r.host.host_print('error: nothing loaded yet')
				return 0
			}
			r.load_path(r.last_file)
		}
		'' {}
		else {
			r.host.host_print('error: unknown command ${name}')
		}
	}
	return 0
}

// load_path loads a file into this machine and remembers it for `,r`.
fn (mut r Repl) load_path(path string) {
	r.machine.load(path) or {
		r.host.host_print('error: ${err.msg()}')
		return
	}
	r.last_file = path
	r.host.host_print('loaded ${path}')
}

// run is the read-eval-print loop. It returns the process exit code.
pub fn (mut r Repl) run() int {
	r.host.host_print('vlip 0.1.0 -- ,h for commands, ,q to leave')
	for {
		r.host.host_write(prompt(r.buffer))
		line := r.host.host_read_line() or {
			// End of input. A newline first, because the prompt was written
			// without one and the shell prompt would otherwise continue it.
			r.host.host_write('\n')
			break
		}
		if r.done {
			break
		}
		r.feed(line) or {}
	}
	return 0
}

// ---- batch entry --------------------------------------------------------

// run_lines drives a REPL over a list of lines and returns what it printed. This
// is the in-process half of the golden test: the same loop, without a subprocess.
pub fn (mut r Repl) run_lines(lines []string) {
	for line in lines {
		if r.done {
			break
		}
		r.feed(line) or {}
	}
}