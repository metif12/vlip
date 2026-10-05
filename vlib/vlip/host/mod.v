module host

// Host is everything vlip needs from the world outside itself.
//
// It exists because "print to stdout" is the one thing that stops an interpreter
// being embeddable. A host that wants the program's output has no way to take it,
// so the interpreter prints and the host never sees it; the obvious workaround --
// the embedder shells out and scrapes -- throws away every other reason to embed:
// the machine's state, its limits, and its step count.
//
// Two rules for implementations:
//
//  1. Nothing here may panic. A host method that fails turns into a returned
//     error, because the whole point of the interface is that a bad program is a
//     value rather than a dead process.
//  2. `host_load` returns SOURCE. It does not evaluate. The machine evaluates it,
//     in itself, so definitions cross the file boundary. A host that ran the
//     file would create a second machine and nothing the file defined would be
//     visible -- which is the bug this shape exists to prevent.
//
// The four methods are the ones the roadmap lists. Resist adding more: each one is
// a capability every embedder has to implement, and a fifth method would turn a
// two-method toy into an interface nobody wants to satisfy.

// The rules and the reason they exist are above; this file only needs os.
import os

pub interface Host {
	// host_print writes one line. The newline is the host's business; the
	// machine does not add one.
	host_print(s string)
	// host_write writes text verbatim, with no newline added. Used for the REPL
	// prompt, where a newline before the next read would be wrong.
	host_write(s string)
	// host_read_line returns the next line, or none at end of input.
	host_read_line() ?string
	// host_load returns the source text of a path, or an error.
	host_load(path string) !string
}

// ConsoleHost is the default: the real terminal, the real filesystem. It is a
// struct rather than a set of free functions so a second implementation in a test
// can be a few lines rather than a mock framework.
pub struct ConsoleHost {}

pub fn (c &ConsoleHost) host_print(s string) {
	println(s)
}

pub fn (c &ConsoleHost) host_write(s string) {
	print(s)
}

pub fn (c &ConsoleHost) host_read_line() ?string {
	return os.get_line()
}

pub fn (c &ConsoleHost) host_load(path string) !string {
	return os.read_file(path)
}

// CaptureHost collects output instead of writing it, and answers reads and loads
// from lists supplied by the test. This is the type that makes a golden test
// possible without spawning a process, and it is the reason the interface is
// four methods rather than one.
//
// The mutable state below is behind a pointer and every write to it is inside an
// `unsafe` block. That is forced by V, not chosen. A V interface method has an
// IMMUTABLE receiver -- the checker offers `(mut h &CaptureHost)` and there is no
// `(mut &T)` receiver -- and an immutable receiver cannot assign into a map it
// holds either: "field state of struct &CaptureHost is immutable", with no
// method-call spelling available because `map.set` is private in this V version.
//
// The alternative was rejected: a stateless CaptureHost, with the golden test
// spawning a real process and scraping its stdout. That makes every REPL check
// cost a process spawn, and the REPL is where all the interesting behaviour is.
pub struct CaptureState_ {
pub mut:
	out   []string
	raw   string
	in    []string
	files map[string]string
}

pub struct CaptureHost {
	state &CaptureState_
}

pub fn new_capture() &CaptureHost {
	return &CaptureHost{
		state: &CaptureState_{
			out:   []string{}
			raw:   ''
			in:    []string{}
			files: map[string]string{}
		}
	}
}

// lines is what a golden test compares against: the printed lines, in order, with
// no prompt mixed in.
pub fn (h &CaptureHost) lines() []string {
	return h.state.out
}

// transcript is everything written, prompts included.
pub fn (h &CaptureHost) transcript() string {
	return h.state.raw
}

// give_file scripts a file to load, which is how the REPL's `,l` is tested
// without a filesystem.
pub fn (h &CaptureHost) give_file(path string, src string) {
	unsafe {
		h.state.files[path] = src
	}
}

// give_input queues lines for host_read_line.
pub fn (h &CaptureHost) give_input(lines []string) {
	unsafe {
		for line in lines {
			h.state.in << line
		}
	}
}

pub fn (h &CaptureHost) host_print(s string) {
	unsafe {
		h.state.out << s
		h.state.raw += s + '\n'
	}
}

// host_write buffers into the transcript but not into `out`: a prompt is not
// output. Mixing the two would make a golden test assert on its own prompt.
pub fn (h &CaptureHost) host_write(s string) {
	unsafe {
		h.state.raw += s
	}
}

pub fn (h &CaptureHost) host_read_line() ?string {
	unsafe {
		if h.state.in.len == 0 {
			return none
		}
		first := h.state.in[0]
		h.state.in = h.state.in[1..]
		return first
	}
}

pub fn (h &CaptureHost) host_load(path string) !string {
	if path in h.state.files {
		return h.state.files[path]
	}
	return error('no such file in the capture host: ${path}')
}
