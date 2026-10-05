module main

// Exercises the reader against the real example files and prints the parsed
// shape, so the reader can be checked before the machine exists.
//
// The walk is an explicit worklist rather than a recursive call: V 0.5.2
// mis-reports "X evaluated but not used" for a variable that is only used as an
// argument to a recursive call inside a for-loop body, and the real error (if
// any) is reported a line later, which makes the diagnostic useless. An
// explicit stack is not worse here -- it is what the CEK machine will do anyway.

import os
import vlib.vlip
import vlib.vlip.reader

struct Frame {
	id    reader.NodeId
	depth int
}

fn indent(n int) string {
	// V has no string repetition, so build it by hand.
	mut buf := []u8{}
	mut i := 0
	for i < n {
		buf << '  '.bytes()
		i++
	}
	return buf.bytestr()
}

fn main() {
	files := os.args[1..]
	if files.len == 0 {
		println('usage: reader_probe <file.lip> ...')
		exit(2)
	}
	mut total_diags := 0
	mut unreadable := 0
	for f in files {
		src := os.read_file(f) or {
			// Counting this as a failure is the whole point. An earlier version
			// printed "cannot read" and carried on, then reported ALL FILES
			// PARSED for zero files -- a green CI run that had checked nothing.
			unreadable++
			println('cannot read ${f}')
			continue
		}
		res := reader.read_all(src)
		total_diags += res.diags.len
		for d in res.diags {
			println('  DIAG ${d.render(f)}')
		}
		println('${f}: ${res.forms.len} forms, ${res.arena.count()} nodes, ${res.diags.len} diagnostics')

		mut lines := []string{}
		mut stack := []Frame{}
		for form in res.forms {
			stack << Frame{
				id:    form
				depth: 1
			}
		}
		// Pop until empty: an explicit post-order-ish walk.
		for stack.len > 0 {
			frame := stack[stack.len - 1]
			stack = stack[..stack.len - 1]
			d := res.arena.node(frame.id)
			ind := indent(frame.depth)
			if d.tag.is_collection() {
				kids := res.arena.kids(frame.id)
				lines << '${ind}${d.tag} ${kids.len} items'
				mut k := kids.len - 1
				for k >= 0 {
					stack << Frame{
						id:    kids[k]
						depth: frame.depth + 1
					}
					k--
				}
			} else {
				lines << '${ind}${d.tag} ${d.value} ${d.i} ${d.f}'
			}
		}

		limit := if lines.len > 60 {
			60
		} else {
			lines.len
		}
		for line in lines[..limit] {
			println(line)
		}
		if lines.len > limit {
			more := lines.len - limit
			println('  ... ${more} more lines')
		}
		println('')
	}
	if unreadable > 0 {
		println('${unreadable} file(s) could not be read; nothing was verified')
		exit(2)
	}
	if total_diags == 0 {
		println('ALL FILES PARSED, zero diagnostics')
		exit(0)
	}
	println('${total_diags} diagnostics')
	exit(1)
}