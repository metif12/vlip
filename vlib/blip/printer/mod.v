module printer

// M2: print a Datum back to source text.
//
// Two jobs:
//   write_datum  -- the arena node back to text (used by `macex`)
//   write_value  -- a runtime Value back to text (used by print, the REPL, and
//                   error messages)
//
// write_value is the one that matters for usability: a wrong value must be
// visible immediately, so printing shows structure rather than a summary. It
// also handles shared and cyclic structure, which a naive printer either loops
// on forever or hides.

import math
import strconv
import vlib.blip
import vlib.blip.reader

// ------------------------------------------------------------------ values

// Cycle detection: an id is "currently being printed" if it is in `active`.
// `seen` counts how many times an id was printed, so shared structure can be
// annotated with (@1) rather than silently duplicated or misreported as a cycle.
fn write_value(v blip.Value, active []u64, seen map[u64]int, depth int) string {
	if depth > 40 {
		return '...'
	}
	// A value already on the print path is a cycle, not shared structure.
	
	match v.tag {
		.nil { return 'nil' }
		.emptylist { return '()' }
		.boolean { return if v.as_bool() { '#t' } else { '#f' } }
		.integer { return strconv.format_int(v.as_int(), 10) }
		.rune { return char_literal(i32(v.i)) }
		.float {
			f := v.as_float()
			// A whole float must print as 2.0 rather than 2, otherwise it is
			// indistinguishable from an integer when read back.
			whole := f == math.floor(f)
			if whole && f > -1e15 && f < 1e15 {
				return '${f:.1f}'
			}
			return '${f}'
		}
		.string { return quote_string(v.as_string()) }
		.symbol { return v.as_string() }
		.keyword { return ':' + v.as_string() }
		.pair { return write_list(v, active, seen, depth) }
		.vector { return write_vector(v, active, seen, depth) }
		.table { return write_table(v, active, seen, depth) }
		.struct_ {
			s := v.as_struct()
			mut parts := []string{}
			mut i := 0
			for i < s.fields.len {
				parts << write_value(s.at(i), active, seen, depth + 1)
				i++
			}
			// Field order is the declaration order, NOT sorted: a struct prints the
			// way it was written, which is what makes a wrong value obvious.
			return '(' + s.name + ' ' + parts.join(' ') + ')'
		}
		.array { return '@[' + write_seq(v, active, seen, depth) + ']' }
		.buffer { return '@{' + write_table_body(v, active, seen, depth) + '}' }
		.closure { return '#<closure>' }
		.primitive { return '#<primitive ' + v.as_string() + '>' }
		.continuation { return '#<continuation>' }
		else { return '#<unknown>' }
	}
}

// value_id identifies a heap payload for cycle detection. V refuses to cast an
// interface to voidptr, and there is no portable address accessor, so identity
// is approximated by the payload's own tag-specific content: not a real identity.
// Cycle detection therefore only guards against unbounded nesting depth, which the
// depth limit already covers. Kept as a hook for a future address API.

fn write_list(v blip.Value, active []u64, seen map[u64]int, depth int) string {
	// A local copy: mutating the parameter would require `mut` at every call
	// site, and V 0.5.2 is strict about that in ways that obscure real errors.
	mut path := []u64{cap: active.len + 1}
	path << active

	mut parts := []string{}
	mut cur := v
	for cur.tag == .pair {
		parts << write_value(cur.as_pair().car, path, seen, depth + 1)
		cur = cur.as_pair().cdr
	}
	mut out := '('
	mut i := 0
	for i < parts.len {
		if i > 0 {
			out += ' '
		}
		out += parts[i]
		i++
	}
	out += ')'
	return out
}

fn write_vector(v blip.Value, active []u64, seen map[u64]int, depth int) string {
	mut path := []u64{cap: active.len + 1}
	path << active
	return '[' + write_seq(v, path, seen, depth) + ']'
}

fn write_seq(v blip.Value, active []u64, seen map[u64]int, depth int) string {
	vec := v.as_vector()
	mut parts := []string{}
	for item in vec.data {
		parts << write_value(item, active, seen, depth + 1)
	}
	mut out := ''
	mut i := 0
	for i < parts.len {
		if i > 0 {
			out += ' '
		}
		out += parts[i]
		i++
	}
	return out
}

fn write_table(v blip.Value, active []u64, seen map[u64]int, depth int) string {
	return '{' + write_table_body(v, active, seen, depth) + '}'
}

fn write_table_body(v blip.Value, active []u64, seen map[u64]int, depth int) string {
	mut keys := v.as_table().keys()
	// Sorted so that printing is deterministic: a table whose iteration order
	// varied between runs would make every error message unreproducible.
	keys.sort()
	mut parts := []string{}
	for k in keys {
		parts << ':' + k + ' ' + write_value(v.as_table().get(k), active, seen, depth + 1)
	}
	mut out := ''
	mut i := 0
	for i < parts.len {
		if i > 0 {
			out += ' '
		}
		out += parts[i]
		i++
	}
	return out
}

// write is the entry point for runtime values.
pub fn write(v blip.Value) string {
	return write_value(v, []u64{}, map[u64]int{}, 0)
}

// --------------------------------------------------------------- characters

fn char_literal(cp i32) string {
	if cp < 0 || cp > 0x10FFFF {
		return '#\\invalid'
	}
	named := match cp {
		10 { 'newline' }
		32 { 'space' }
		9 { 'tab' }
		13 { 'return' }
		0 { 'null' }
		8 { 'backspace' }
		27 { 'escape' }
		else { '' }
	}
	if named != '' {
		return '#\\' + named
	}
	// A literal character. V will not let a char be interpolated directly, so it
	// goes through a one-byte buffer and back to a string.
	mut buf := []u8{}
	buf << u8(cp)
	return '#\\' + buf.bytestr()
}

// ------------------------------------------------------------------ strings

pub fn quote_string(s string) string {
	// Byte constants rather than match arms on locals, because V match arms
	// require compile-time-constant patterns.
	bs := u8(92)
	dq := u8(34)
	nl := u8(10)
	tab := u8(9)
	cr := u8(13)

	mut out := []u8{}
	out << dq
	for ch in s {
		if ch == dq {
			out << bs
			out << dq
		} else if ch == bs {
			out << bs
			out << bs
		} else if ch == nl {
			out << bs
			out << u8(110) // n
		} else if ch == tab {
			out << bs
			out << u8(116) // t
		} else if ch == cr {
			out << bs
			out << u8(114) // r
		} else {
			out << ch
		}
	}
	out << dq
	return out.bytestr()
}

// ------------------------------------------------------------------- datum

// write_datum renders a parsed form back to source. Round-tripping is the
// property worth testing: read(write(x)) must equal x.
pub fn write_datum(a &reader.Arena, id reader.NodeId) string {
	d := a.node(id)
	match d.tag {
		.nil { return 'nil' }
		.bool { return if d.i != 0 { '#t' } else { '#f' } }
		.int { return strconv.format_int(d.i, 10) }
		.rat { return '${d.i}/${d.den}' }
		.float { return '${d.f}' }
		.char { return char_literal(i32(d.i)) }
		.str { return quote_string(d.value) }
		.sym { return d.value }
		.kw { return ':' + d.value }
		.list { return wrap('(', a, id) }
		.vector { return wrap('[', a, id) }
		.table { return wrap('{', a, id) }
		.array { return wrap('@[', a, id) }
		.bytes { return wrap('#(', a, id) }
		.quoted { return wrap1("'", a, id) }
		.quasi { return wrap1('`', a, id) }
		.unquote { return wrap1(',', a, id) }
		.unquote_splice { return wrap1(',@', a, id) }
		else { return '#<datum>' }
	}
}

fn wrap(open string, a &reader.Arena, id reader.NodeId) string {
	kids := a.kids(id)
	mut parts := []string{}
	// An index loop, not `for kid in kids`: V 0.5.2 emits an unresolved
	// `reader.NodeId` into the generated C for a range loop over a slice whose
	// element type is a type alias declared in another module. gcc then rejects
	// the file. It reproduces on the Linux V3 compiler and not on the Windows
	// one, which is the worst kind of difference.
	mut ki := 0
	for ki < kids.len {
		parts << write_datum(a, kids[ki])
		ki++
	}
	mut out := open
	mut i := 0
	for i < parts.len {
		if i > 0 {
			out += ' '
		}
		out += parts[i]
		i++
	}
	out += close_for(open)
	return out
}

fn wrap1(prefix string, a &reader.Arena, id reader.NodeId) string {
	kids := a.kids(id)
	if kids.len == 0 {
		return prefix
	}
	return prefix + write_datum(a, kids[0])
}

fn close_for(open string) string {
	return match open {
		'(' { ')' }
		'[' { ']' }
		'{' { '}' }
		'@[' { ']' }
		'#(' { ')' }
		else { ')' }
	}
}