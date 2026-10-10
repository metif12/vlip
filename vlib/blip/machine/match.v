module machine

import vlib.blip
import vlib.blip.prims
import vlib.blip.reader

// Pattern matching.
//
// This file is separate from mod.v because it is the only part of the evaluator
// that is a recursive descent over the pattern rather than a loop over the
// continuation stack, and mixing the two shapes in one file makes both harder to
// read.
//
// The design decision worth stating: `match` is a real continuation tag, not a
// transform to nested `if`s. A transform would need a `pattern?` predicate that
// also BINDS, which means generating a fresh name per binder per clause and
// threading those names through -- and every clause would carry a frame whether or
// not it matched, so a `match` in tail position would stop being a tail call. The
// frame is one push per `match`, popped as soon as a clause matches.

// Bind is one name the pattern captured.
pub struct Bind {
pub:
	name string
	val  blip.Value
}

// Matched is the result of trying one pattern against one subject.
pub struct Matched {
pub:
	ok    bool
	binds []Bind
}

// pattern_name_for gives the head of a pattern list, or '' when it is not a list.
fn (m &Machine) pattern_head(p blip.NodeId) string {
	d := m.arena.node(p)
	if d.tag != .list {
		return ''
	}
	kids := m.arena.kids(p)
	if kids.len == 0 {
		return ''
	}
	h := m.arena.node(kids[0])
	if h.tag != .sym {
		return ''
	}
	return h.value
}

// match_pattern tries `pat` against `subject` and returns the names it captured.
//
// `depth` bounds the recursion. A cyclic structure matched against a recursive
// pattern -- `(define (p (cons h t)) p)` and then matching `(cons a p)` -- would
// otherwise run forever, and a pattern matcher's job is not to hang.
fn (mut m Machine) match_pattern(pat blip.NodeId, subject blip.Value) !Matched {
	return m.match_at(pat, subject, 0)
}

fn (mut m Machine) match_at(pat blip.NodeId, subject blip.Value, depth int) !Matched {
	if depth > 40 {
		return error('pattern nested more than 40 deep')
	}
	d := m.arena.node(pat)
	match d.tag {
		.sym {
			if d.value == '_' {
				return Matched{
					ok: true
				}
			}
			if d.value == 'else' {
				return Matched{
					ok: true
				}
			}
			return Matched{
				ok:    true
				binds: [Bind{
					name: d.value
					val:  subject
				}]
			}
		}
		.kw {
			return Matched{
				ok: prims.value_eq(subject, blip.keyword(d.value))
			}
		}
		.int, .float, .str, .bool, .char, .rat {
			return Matched{
				ok: literal_eq(d, subject)
			}
		}
		.nil {
			return Matched{
				ok: subject.is_empty_seq()
			}
		}
		.vector {
			kids := m.arena.kids(pat)
			if subject.tag != .vector {
				return Matched{
					ok: false
				}
			}
			data := subject.as_vector().data
			if data.len != kids.len {
				return Matched{
					ok: false
				}
			}
			mut binds := []Bind{}
			mut i := 0
			for i < kids.len {
				sub := m.match_at(kids[i], data[i], depth + 1)!
				if !sub.ok {
					return Matched{
						ok: false
					}
				}
				binds << sub.binds
				i++
			}
			return Matched{
				ok:    true
				binds: binds
			}
		}
		.table {
			return m.match_table_at(pat, subject, depth)
		}
		.list {
			return m.match_list_at(pat, subject, depth)
		}
		else {
			return Matched{
				ok: false
			}
		}
	}
}

// literal_eq compares a literal datum with a runtime value.
fn literal_eq(d &reader.Datum, v blip.Value) bool {
	return prims.value_eq(datum_literal(d), v)
}

// datum_literal turns a leaf datum into the value it denotes. Shared with the
// reader's semantics for `quote`, and deliberately duplicating a little logic
// rather than reaching into `assemble`, which is a method on Machine and needs a
// whole machine to call.
fn datum_literal(d &reader.Datum) blip.Value {
	match d.tag {
		.nil { return blip.nil_value() }
		.bool { return blip.boolean(d.i != 0) }
		.int { return blip.integer(d.i) }
		.float { return blip.float(d.f) }
		.char { return blip.rune(u32(d.i)) }
		.str { return blip.string(d.value) }
		.sym { return blip.symbol(d.value) }
		.kw { return blip.keyword(d.value) }
		else { return blip.nil_value() }
	}
}

// match_list_at handles every list-shaped pattern: the named forms, the predicate
// form, the positional form, and `cons`.
fn (mut m Machine) match_list_at(pat blip.NodeId, subject blip.Value, depth int) !Matched {
	kids := m.arena.kids(pat)
	if kids.len == 0 {
		return Matched{
			ok: subject.is_empty_seq()
		}
	}
	head := m.pattern_head(pat)
	match head {
		'and' {
			mut binds := []Bind{}
			mut i := 1
			for i < kids.len {
				sub := m.match_at(kids[i], subject, depth + 1)!
				if !sub.ok {
					return Matched{
						ok: false
					}
				}
				binds << sub.binds
				i++
			}
			return Matched{
				ok:    true
				binds: binds
			}
		}
		'or' {
			// The FIRST matching alternative wins, and so its bindings. Collecting
			// bindings from every alternative would be meaningless: two branches of
			// an `or` cannot both bind the same name to different values.
			mut i := 1
			for i < kids.len {
				sub := m.match_at(kids[i], subject, depth + 1)!
				if sub.ok {
					return sub
				}
				i++
			}
			return Matched{
				ok: false
			}
		}
		'cons' {
			if subject.tag != .pair {
				return Matched{
					ok: false
				}
			}
			mut binds := []Bind{}
			mut i := 1
			for i < kids.len {
				sub := m.match_at(kids[i], subject.as_pair().car, depth + 1)!
				if !sub.ok {
					return Matched{
						ok: false
					}
				}
				binds << sub.binds
				i++
			}
			sub := m.match_at(kids[kids.len - 1], subject.as_pair().cdr, depth + 1)!
			if !sub.ok {
				return Matched{
					ok: false
				}
			}
			binds << sub.binds
			return Matched{
				ok:    true
				binds: binds
			}
		}
		'list', 'vector' {
			items := prims.seq(subject) or {
				return Matched{
					ok: false
				}
			}
			rest := kids[1..]
			if rest.len == 0 || m.is_wildcard(rest[rest.len - 1]) {
				if rest.len - 1 != items.len {
					return Matched{
						ok: false
					}
				}
			} else if rest.len != items.len {
				return Matched{
					ok: false
				}
			}
			mut binds := []Bind{}
			mut i := 0
			for i < rest.len {
				want := items[i]
				if m.is_wildcard(rest[i]) {
					i++
					continue
				}
				sub := m.match_at(rest[i], want, depth + 1)!
				if !sub.ok {
					return Matched{
						ok: false
					}
				}
				binds << sub.binds
				i++
			}
			return Matched{
				ok:    true
				binds: binds
			}
		}
		'struct' {
			return m.match_struct_at(pat, subject, depth)
		}
		'' {
			// A list whose head is not a symbol is an ordinary positional pattern.
			return m.positional(kids, subject, depth)
		}
		else {
			// `(>= 100)`, `(and odd? ...)`: a call to a known procedure, matched by
			// its result. Recognising it by NAME rather than by "is it bound" is
			// deliberate: `match` on a user-supplied name would otherwise silently
			// become a comparison, and `(list 1 2)` has to stay a list pattern.
			if !pattern_predicate(head) {
				return m.positional(kids, subject, depth)
			}
			mut call := []blip.Value{}
			call << subject
			mut i := 1
			for i < kids.len {
				call << datum_literal(m.arena.node(kids[i]))
				i++
			}
			mut f := m.prims[head] or {
				return error('match: ${head} is not a known procedure, and a pattern list needs a known head')
			}
			res := f(call) or {
				return error('match: ${head} failed: ${err.msg()}')
			}
			return Matched{
				ok: res.truthy()
			}
		}
	}
}

fn (mut m Machine) positional(kids []blip.NodeId, subject blip.Value, depth int) !Matched {
	return m.match_list_tail(kids, subject, depth)
}

// match_list_tail is the positional matcher shared by `(list a b)` and a bare
// `(a b)`. The last sub-pattern may be a binding symbol, which then takes the
// WHOLE remaining tail rather than one element -- that is what makes
// `(list 1 rest)` bind `rest` to `(2 3)`.
fn (mut m Machine) match_list_tail(kids []blip.NodeId, subject blip.Value, depth int) !Matched {
	items := prims.seq(subject) or {
		return Matched{
			ok: false
		}
	}
	rest := kids[1..]
	mut binds := []Bind{}
	mut i := 0
	for i < rest.len {
		if i == rest.len - 1 && m.is_capturing_tail(rest[i]) {
			mut tail := blip.empty_list()
			if items.len > i {
				tail = blip.list_from(items[i..])
			}
			sub := m.match_at(rest[i], tail, depth + 1)!
			if !sub.ok {
				return Matched{
					ok: false
				}
			}
			binds << sub.binds
			i++
			continue
		}
		if i >= items.len {
			return Matched{
				ok: false
			}
		}
		sub := m.match_at(rest[i], items[i], depth + 1)!
		if !sub.ok {
			return Matched{
				ok: false
			}
		}
		binds << sub.binds
		i++
	}
	return Matched{
		ok:    true
		binds: binds
	}
}

fn (mut m Machine) match_table_at(pat blip.NodeId, subject blip.Value, depth int) !Matched {
	if !(subject.tag in [.table, .buffer, .struct_]) {
		return Matched{
			ok: false
		}
	}
	kids := m.arena.kids(pat)
	mut tbl := subject.as_table()
	mut binds := []Bind{}
	mut i := 0
	for i + 1 < kids.len {
		key := m.arena.node(kids[i])
		mut k := ''
		if key.tag == .kw {
			k = key.value
		} else if key.tag == .str || key.tag == .sym {
			k = key.value
		} else {
			return error('match: a table pattern needs keyword keys')
		}
		if !tbl.has(k) {
			return Matched{
				ok: false
			}
		}
		sub := m.match_at(kids[i + 1], tbl.get(k), depth + 1)!
		if !sub.ok {
			return Matched{
				ok: false
			}
		}
		binds << sub.binds
		i += 2
	}
	return Matched{
		ok:    true
		binds: binds
	}
}

fn (mut m Machine) match_struct_at(pat blip.NodeId, subject blip.Value, depth int) !Matched {
	kids := m.arena.kids(pat)
	if kids.len < 2 {
		return error('match: (struct Name field: p ...) needs a name and at least one field')
	}
	name_node := m.arena.node(kids[1])
	if name_node.tag != .sym {
		return error('match: a struct pattern needs a struct name')
	}
	if subject.tag != .struct_ {
		return Matched{
			ok: false
		}
	}
	s := subject.as_struct()
	if s.name != name_node.value {
		return Matched{
			ok: false
		}
	}
	mut binds := []Bind{}
	mut i := 2
	for i < kids.len {
		d := m.arena.node(kids[i])
		// `x: pattern`. The reader gives `x:` as a SYMBOL ending in a colon, not
		// as a keyword, because a bare colon is not a reader sigil -- only `#:` is.
		// A keyword is accepted too so that `(struct Point #:x px)` works.
		mut field := ''
		if d.tag == .kw {
			field = d.value
		} else if d.tag == .sym && d.value.ends_with(':') {
			field = d.value[..d.value.len - 1]
		} else {
			return error('match: a struct pattern field must be written field: pattern')
		}
		if !s.has(field) {
			return Matched{
				ok: false
			}
		}
		if i + 1 >= kids.len {
			return error('match: field ${field} has no pattern')
		}
		sub := m.match_at(kids[i + 1], s.get(field), depth + 1)!
		if !sub.ok {
			return Matched{
				ok: false
			}
		}
		binds << sub.binds
		i += 2
	}
	return Matched{
		ok:    true
		binds: binds
	}
}

// is_wildcard: `_`, which matches anything and binds nothing.
fn (m &Machine) is_wildcard(n blip.NodeId) bool {
	d := m.arena.node(n)
	return d.tag == .sym && d.value == '_'
}

// is_capturing_tail: a bare symbol in the last position of a list pattern, which
// captures the rest of the list rather than one element.
fn (m &Machine) is_capturing_tail(n blip.NodeId) bool {
	d := m.arena.node(n)
	return d.tag == .sym && d.value != '_'
}

// pattern_predicate is the set of names a list pattern may use as a test. It is a
// list rather than "anything bound to a primitive" so that `match` cannot change
// meaning because someone defined a function named `list` or `vector`.
pub fn pattern_predicate(name string) bool {
	return name in [
		'<', '>', '<=', '>=', '=', 'not=', 'eq?',
		'zero?', 'even?', 'odd?', 'positive?', 'negative?',
		'list?', 'pair?', 'vector?', 'table?', 'array?', 'string?', 'symbol?',
		'keyword?', 'integer?', 'float?', 'number?', 'boolean?', 'rune?',
		'nil?', 'null?', 'function?',
	]
}