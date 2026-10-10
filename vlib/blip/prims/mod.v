module prims

// Primitive fntions.
//
// The signature deliberately does not take the machine. Builtins that need to
// call back into the interpreter -- apply, map, format, error -- are handled by
// the machine itself, which is what keeps this module free of any dependency on
// it. Without that separation the two would be mutually dependent.

import math
import strconv
import vlib.blip
import vlib.blip.printer

// AtoF64Param is not exported by name in this V version, so it is built from its
// only public field. allow_extra_chars must be false: a parse of "12abc" has to
// be rejected rather than silently yielding 12.
const strict_float = strconv.AtoF64Param{
}

// table returns every primitive, keyed by name.
pub fn table() map[string]blip.PrimFn {
	mut p := map[string]blip.PrimFn{}
	p['+'] = prim_add
	p['-'] = prim_sub
	p['*'] = prim_mul
	p['/'] = prim_div
	p['='] = prim_eq
	p['<'] = prim_lt
	p['>'] = prim_gt
	p['<='] = prim_le
	p['>='] = prim_ge
	p['not'] = prim_not
	p['car'] = prim_car
	p['cdr'] = prim_cdr
	p['cons'] = prim_cons
	p['list'] = prim_list
	p['length'] = prim_length
	p['reverse'] = prim_reverse
	p['append'] = prim_append
	p['null?'] = prim_nullp
	p['nil?'] = prim_nilp
	p['pair?'] = prim_pairp
	p['list?'] = prim_listp
	p['vector?'] = prim_vectorp
	p['table?'] = prim_tablep
	p['array?'] = prim_arrayp
	p['string?'] = prim_stringp
	p['symbol?'] = prim_symbolp
	p['keyword?'] = prim_keywordp
	p['integer?'] = prim_integerp
	p['float?'] = prim_floatp
	p['number?'] = prim_numberp
	p['vector'] = prim_vector
	p['vector-ref'] = prim_vector_ref
	p['vector-length'] = prim_vector_length
	p['get'] = prim_get
	p['has-key?'] = prim_has_key
	p['put'] = prim_put
	p['remove'] = prim_remove
	p['table-keys'] = prim_table_keys
	p['string-append'] = prim_string_append
	p['string-length'] = prim_string_length
	p['string-downcase'] = prim_string_downcase
	p['string-upcase'] = prim_string_upcase
	p['string-split'] = prim_string_split
	p['string-trim'] = prim_string_trim
	p['string-blank?'] = prim_string_blank
	p['string'] = prim_string
	p['symbol'] = prim_symbol
	p['keyword'] = prim_keyword
	p['string->number'] = prim_string_to_number
	p['number->string'] = prim_number_to_string
	p['zero?'] = prim_zero
	p['even?'] = prim_even
	p['odd?'] = prim_odd
	p['positive?'] = prim_positive
	p['negative?'] = prim_negative
	p['min'] = prim_min
	p['max'] = prim_max
	p['abs'] = prim_abs
	p['str'] = prim_str
	p['list-ref'] = prim_list_ref
	p['take'] = prim_take
	p['drop'] = prim_drop
	p['first'] = prim_car
	p['rest'] = prim_cdr
	p['last'] = prim_last
	p['not='] = prim_not_eq
	p['eq?'] = prim_eqp
	p['in?'] = prim_in
	p['concat'] = prim_concat
	p['range'] = prim_range
	p['count'] = prim_count
	p['sort'] = prim_sort
	p['frequencies'] = prim_frequencies
	p['vector-rev'] = prim_vector_rev
	p['vector-append'] = prim_vector_append
	p['vector-empty?'] = prim_vector_emptyp
	p['vector-contains?'] = prim_vector_containsp
	p['array-set!'] = prim_array_set
	p['array-ref'] = prim_array_ref
	p['array-push!'] = prim_array_push
	p['array-pop!'] = prim_array_pop
	p['array-length'] = prim_array_length
	p['array-empty?'] = prim_array_emptyp
	p['put!'] = prim_put_bang
	p['dissoc!'] = prim_dissoc_bang
	p['string-index-of'] = prim_string_index_of
	p['string-not-blank?'] = prim_string_not_blank
	p['string-contains?'] = prim_string_containsp
	p['string-start-with?'] = prim_string_start_withp
	p['string-join'] = prim_string_join
	p['string-repeat'] = prim_string_repeat
	p['string-slice'] = prim_string_slice
	p['string-replace'] = prim_string_replace
	p['string->symbol'] = prim_string_to_symbol
	p['string->keyword'] = prim_string_to_keyword
	p['boolean?'] = prim_booleanp
	p['rune?'] = prim_runep
	p['fntion?'] = prim_fntionp
	p['procedure?'] = prim_fntionp
	p['modulo'] = prim_modulo
	p['quotient'] = prim_quotient
	p['remainder'] = prim_remainder
	p['gcd'] = prim_gcd
	p['expt'] = prim_expt
	p['sqrt'] = prim_sqrt
	p['zero'] = prim_zero
	p['inc'] = prim_inc
	p['dec'] = prim_dec
	p['struct?'] = prim_structp
	p['struct-name'] = prim_struct_name
	p['struct-ref'] = prim_struct_ref
	p['struct-set!'] = prim_struct_set
	p['integer->rune'] = prim_integer_to_rune
	p['rune->integer'] = prim_rune_to_integer
	p['string->rune'] = prim_string_to_rune
	p['code->string'] = prim_code_to_string
	p['__make-struct'] = prim_make_struct
	// Generated bindings live in gen_<module>.v, written by
	// tools/genprims.vsh; each module costs exactly this one line.
	register_gen_math(mut p)
	return p
}

// ------------------------------------------------------------------ helpers

fn need_int(name string, v blip.Value) !i64 {
	if v.tag != .integer {
		return error('${name} expects an integer, got ${printer.write(v)}')
	}
	return v.as_int()
}

fn need_str(name string, v blip.Value) !string {
	if !(v.tag in [.string, .symbol, .keyword]) {
		return error('${name} expects a string, got ${printer.write(v)}')
	}
	return v.as_string()
}

fn as_f64(v blip.Value) !f64 {
	match v.tag {
		.integer { return f64(v.as_int()) }
		.float { return v.as_float() }
		else { return error('expected a number, got ${printer.write(v)}') }
	}
}

fn any_float(args []blip.Value) bool {
	for a in args {
		if a.tag == .float {
			return true
		}
	}
	return false
}

fn is_number(v blip.Value) bool {
	return v.tag == .integer || v.tag == .float
}

fn cmp_i64(a i64, b i64) int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

fn cmp_f64(a f64, b f64) int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

fn cmp_text(a string, b string) int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

// compare orders numbers and strings. Anything else is an error rather than a
// silent false, because a silent false here becomes a mystery much later.
pub fn compare(a blip.Value, b blip.Value) !int {
	if a.tag == .integer && b.tag == .integer {
		return cmp_i64(a.as_int(), b.as_int())
	}
	if a.tag == .float || b.tag == .float {
		if !is_number(a) || !is_number(b) {
			return error('cannot compare ${printer.write(a)} with ${printer.write(b)}')
		}
		return cmp_f64(as_f64(a)!, as_f64(b)!)
	}
	if (a.tag in [.string, .symbol, .keyword]) && (b.tag in [.string, .symbol, .keyword]) {
		return cmp_text(a.as_string(), b.as_string())
	}
	return error('cannot compare ${printer.write(a)} with ${printer.write(b)}')
}

// ------------------------------------------------------------- arithmetic

fn prim_add(args []blip.Value) !blip.Value {
	if any_float(args) {
		mut f := 0.0
		for a in args {
			f += as_f64(a)!
		}
		return blip.float(f)
	}
	mut sum := i64(0)
	for a in args {
		sum += need_int('+', a)!
	}
	return blip.integer(sum)
}

fn prim_sub(args []blip.Value) !blip.Value {
	if args.len == 0 {
		return error('- expects at least 1 argument')
	}
	if args.len == 1 {
		return blip.integer(-need_int('-', args[0])!)
	}
	if any_float(args) {
		mut f := as_f64(args[0])!
		for i in 1 .. args.len {
			f -= as_f64(args[i])!
		}
		return blip.float(f)
	}
	mut acc := need_int('-', args[0])!
	for i in 1 .. args.len {
		acc -= need_int('-', args[i])!
	}
	return blip.integer(acc)
}

fn prim_mul(args []blip.Value) !blip.Value {
	if any_float(args) {
		mut f := 1.0
		for a in args {
			f *= as_f64(a)!
		}
		return blip.float(f)
	}
	mut acc := i64(1)
	for a in args {
		acc *= need_int('*', a)!
	}
	return blip.integer(acc)
}

fn prim_div(args []blip.Value) !blip.Value {
	if args.len != 2 {
		return error('/ expects exactly 2 arguments')
	}
	if args[0].tag == .float || args[1].tag == .float {
		d := as_f64(args[1])!
		if d == 0.0 {
			return error('division by zero')
		}
		return blip.float(as_f64(args[0])! / d)
	}
	b := need_int('/', args[1])!
	if b == 0 {
		return error('division by zero')
	}
	return blip.integer(need_int('/', args[0])! / b)
}

// ------------------------------------------------------------- comparison

fn prim_eq(args []blip.Value) !blip.Value {
	mut i := 0
	for i + 1 < args.len {
		if !value_eq(args[i], args[i + 1]) {
			return blip.boolean(false)
		}
		i++
	}
	return blip.boolean(true)
}

// value_eq is structural equality on contents, not identity.
pub fn value_eq(a blip.Value, b blip.Value) bool {
	// An integer and a float are never equal even when numerically equal: that
	// distinction is the whole point of having a numeric tower.
	if a.tag != b.tag {
		return false
	}
	match a.tag {
		.integer, .rune, .boolean { return a.i == b.i }
		.float { return a.f == b.f }
		.nil, .emptylist { return true }
		.string, .symbol, .keyword { return a.as_string() == b.as_string() }
		.pair {
			mut x := a
			mut y := b
			for x.tag == .pair && y.tag == .pair {
				if !value_eq(x.as_pair().car, y.as_pair().car) {
					return false
				}
				x = x.as_pair().cdr
				y = y.as_pair().cdr
			}
			return x.tag == .nil && y.tag == .nil
		}
		.vector {
			x := a.as_vector().data
			y := b.as_vector().data
			if x.len != y.len {
				return false
			}
			mut i := 0
			for i < x.len {
				if !value_eq(x[i], y[i]) {
					return false
				}
				i++
			}
			return true
		}
		.table {
			x := a.as_table()
			y := b.as_table()
			if x.values.len != y.values.len {
				return false
			}
			for k, v in x.values {
				mut found := false
				for k2, v2 in y.values {
					if k2 == k {
						found = true
						if !value_eq(v, v2) {
							return false
						}
					}
				}
				if !found {
					return false
				}
			}
			return true
		}
		.struct_ {
			x := a.as_struct()
			y := b.as_struct()
			// Two struct instances are equal when they have the same NAME and equal
			// fields. Comparing the names matters: a Point and a Coord with the same
			// numbers are not interchangeable, and that is the whole point of a
			// struct rather than a table.
			if x.name != y.name || x.fields.len != y.fields.len {
				return false
			}
			mut i := 0
			for i < x.fields.len {
				if x.fields[i] != y.fields[i] {
					return false
				}
				if !value_eq(x.at(i), y.at(i)) {
					return false
				}
				i++
			}
			return true
		}
		else { return false }
	}
}

fn chain(name string, args []blip.Value) !blip.Value {
	if args.len < 2 {
		return error('${name} expects at least 2 arguments')
	}
	mut i := 0
	for i + 1 < args.len {
		c := compare(args[i], args[i + 1])!
		ok := match name {
			'<' { c < 0 }
			'>' { c > 0 }
			'<=' { c <= 0 }
			else { c >= 0 }
		}
		if !ok {
			return blip.boolean(false)
		}
		i++
	}
	return blip.boolean(true)
}

fn prim_lt(args []blip.Value) !blip.Value {
	return chain('<', args)
}

fn prim_gt(args []blip.Value) !blip.Value {
	return chain('>', args)
}

fn prim_le(args []blip.Value) !blip.Value {
	return chain('<=', args)
}

fn prim_ge(args []blip.Value) !blip.Value {
	return chain('>=', args)
}

fn prim_not(args []blip.Value) !blip.Value {
	if args.len != 1 {
		return error('not expects 1 argument')
	}
	// Only #f is false, so this must not be the arithmetic negation of truthiness.
	return blip.boolean(!args[0].truthy())
}

// ------------------------------------------------------------------- lists

fn list_slice(v blip.Value) ![]blip.Value {
	mut out := []blip.Value{}
	mut cur := v
	mut guard := 0
	for cur.tag == .pair {
		if guard > 50_000_000 {
			return error('list is cyclic')
		}
		out << cur.as_pair().car
		cur = cur.as_pair().cdr
		guard++
	}
	return out
}

// seq flattens any sequence value into a Go-ish []Value, so the higher-order
// primitives take a list, a vector or an array without each one repeating the
// same three-way tag check.
//
// It returns lists as LISTS, not vectors. The obvious version returns vectors
// everywhere, which silently changes the type of every result: `(map f '(1 2))`
// would answer with a vector, and `(map f ...)` composed with `filter` and `fold`
// would then need the result to be a list anyway.
pub fn seq(v blip.Value) ![]blip.Value {
	match v.tag {
		.pair { return list_slice(v) }
		.emptylist, .nil { return []blip.Value{} }
		.vector, .array { return v.as_vector().data.clone() }
		else { return error('expected a sequence, got ${printer.write(v)}') }
	}
}

// is_seq reports whether `v` is something the higher-order primitives can walk.
pub fn is_seq(v blip.Value) bool {
	return v.tag in [.pair, .emptylist, .nil, .vector, .array]
}

fn prim_car(args []blip.Value) !blip.Value {
	if args[0].tag != .pair {
		return error('car expects a pair, got ${printer.write(args[0])}')
	}
	return args[0].as_pair().car
}

fn prim_cdr(args []blip.Value) !blip.Value {
	if args[0].tag != .pair {
		return error('cdr expects a pair, got ${printer.write(args[0])}')
	}
	return args[0].as_pair().cdr
}

fn prim_cons(args []blip.Value) !blip.Value {
	return blip.cons(args[0], args[1])
}

fn prim_list(args []blip.Value) !blip.Value {
	mut items := []blip.Value{}
	for a in args {
		items << a
	}
	return blip.list_from(items)
}

fn prim_length(args []blip.Value) !blip.Value {
	match args[0].tag {
		.pair {
			mut n := i64(0)
			mut cur := args[0]
			for cur.tag == .pair {
				n++
				cur = cur.as_pair().cdr
			}
			return blip.integer(n)
		}
		.vector { return blip.integer(args[0].as_vector().data.len) }
		.string { return blip.integer(args[0].as_string().len) }
		.nil, .emptylist { return blip.integer(0) }
		else { return error('length expects a collection, got ${printer.write(args[0])}') }
	}
}

fn prim_reverse(args []blip.Value) !blip.Value {
	mut items := list_slice(args[0])!
	mut out := blip.nil_value()
	mut i := items.len - 1
	for i >= 0 {
		out = blip.cons(items[i], out)
		i--
	}
	return out
}

fn prim_append(args []blip.Value) !blip.Value {
	mut out := []blip.Value{}
	mut i := 0
	for i + 1 < args.len {
		part := list_slice(args[i])!
		for p in part {
			out << p
		}
		i++
	}
	tail := list_slice(args[args.len - 1])!
	for p in tail {
		out << p
	}
	return blip.list_from(out)
}

fn prim_list_ref(args []blip.Value) !blip.Value {
	mut items := list_slice(args[0])!
	i := need_int('list-ref', args[1])!
	if i < 0 || i >= items.len {
		return error('list-ref: index ${i} out of range (length ${items.len})')
	}
	return items[i]
}

fn clamp(n i64, lo i64, hi i64) i64 {
	if n < lo {
		return lo
	}
	if n > hi {
		return hi
	}
	return n
}

fn prim_take(args []blip.Value) !blip.Value {
	mut items := list_slice(args[0])!
	n := clamp(need_int('take', args[1])!, 0, i64(items.len))
	mut head := []blip.Value{}
	mut i := 0
	for i < n {
		head << items[i]
		i++
	}
	return blip.list_from(head)
}

fn prim_drop(args []blip.Value) !blip.Value {
	mut items := list_slice(args[0])!
	n := clamp(need_int('drop', args[1])!, 0, i64(items.len))
	return blip.list_from(items[n..])
}

// -------------------------------------------------------------- predicates

fn tag_is(v blip.Value, t blip.Tag) blip.Value {
	return blip.boolean(v.tag == t)
}

fn prim_nullp(args []blip.Value) !blip.Value {
	// True for BOTH the empty list and nil. The examples assert
	// `(null? '())` is true, and also that nil and () print differently, so the
	// predicate has to accept both values.
	return blip.boolean(args[0].is_empty_seq())
}

fn prim_nilp(args []blip.Value) !blip.Value {
	return blip.boolean(args[0].is_empty_seq())
}

fn prim_pairp(args []blip.Value) !blip.Value {
	return tag_is(args[0], .pair)
}

fn prim_vectorp(args []blip.Value) !blip.Value {
	return tag_is(args[0], .vector)
}

fn prim_tablep(args []blip.Value) !blip.Value {
	return tag_is(args[0], .table)
}

fn prim_arrayp(args []blip.Value) !blip.Value {
	return tag_is(args[0], .array)
}

fn prim_stringp(args []blip.Value) !blip.Value {
	return tag_is(args[0], .string)
}

fn prim_symbolp(args []blip.Value) !blip.Value {
	return tag_is(args[0], .symbol)
}

fn prim_keywordp(args []blip.Value) !blip.Value {
	return tag_is(args[0], .keyword)
}

fn prim_integerp(args []blip.Value) !blip.Value {
	return tag_is(args[0], .integer)
}

fn prim_floatp(args []blip.Value) !blip.Value {
	return tag_is(args[0], .float)
}

fn prim_numberp(args []blip.Value) !blip.Value {
	return blip.boolean(is_number(args[0]))
}

// list? must reject cyclic lists, so it uses tortoise and hare.
fn prim_listp(args []blip.Value) !blip.Value {
	if args[0].is_empty_seq() {
		return blip.boolean(true)
	}
	if args[0].tag != .pair {
		return blip.boolean(false)
	}
	mut slow := args[0]
	mut fast := args[0]
	for fast.tag == .pair && fast.as_pair().cdr.tag == .pair {
		fast = fast.as_pair().cdr.as_pair().car
		if fast.tag == .nil {
			return blip.boolean(true)
		}
		slow = slow.as_pair().cdr
		if value_eq(fast, slow) {
			return blip.boolean(false)
		}
	}
	return blip.boolean(fast.as_pair().cdr.tag == .nil)
}

fn prim_zero(args []blip.Value) !blip.Value {
	return blip.boolean(compare(args[0], blip.integer(0))! == 0)
}

fn prim_even(args []blip.Value) !blip.Value {
	return blip.boolean(need_int('even?', args[0])! % 2 == 0)
}

fn prim_odd(args []blip.Value) !blip.Value {
	return blip.boolean(need_int('odd?', args[0])! % 2 != 0)
}

fn prim_positive(args []blip.Value) !blip.Value {
	return blip.boolean(compare(args[0], blip.integer(0))! > 0)
}

fn prim_negative(args []blip.Value) !blip.Value {
	return blip.boolean(compare(args[0], blip.integer(0))! < 0)
}

fn prim_min(args []blip.Value) !blip.Value {
	mut best := args[0]
	mut i := 1
	for i < args.len {
		if compare(args[i], best)! < 0 {
			best = args[i]
		}
		i++
	}
	return best
}

fn prim_max(args []blip.Value) !blip.Value {
	mut best := args[0]
	mut i := 1
	for i < args.len {
		if compare(args[i], best)! > 0 {
			best = args[i]
		}
		i++
	}
	return best
}

fn prim_abs(args []blip.Value) !blip.Value {
	if args[0].tag == .float {
		f := args[0].as_float()
		return blip.float(if f < 0.0 { -f } else { f })
	}
	n := need_int('abs', args[0])!
	return blip.integer(if n < 0 { -n } else { n })
}

// ------------------------------------------------------------- collections

fn prim_vector(args []blip.Value) !blip.Value {
	mut items := []blip.Value{}
	for a in args {
		items << a
	}
	return blip.vector(items)
}

fn prim_vector_ref(args []blip.Value) !blip.Value {
	i := need_int('vector-ref', args[1])!
	data := args[0].as_vector().data
	if i < 0 || i >= data.len {
		return error('vector-ref: index ${i} out of range (length ${data.len})')
	}
	return data[i]
}

fn prim_vector_length(args []blip.Value) !blip.Value {
	return blip.integer(args[0].as_vector().data.len)
}

fn prim_get(args []blip.Value) !blip.Value {
	if args.len >= 3 {
		return args[2]
	}
	if args[0].tag == .table || args[0].tag == .buffer {
		return args[0].as_table().get(need_str('get', args[1])!)
	}
	// A list or vector is addressed by position. `frequencies` returns a list of
	// (key count) pairs and the examples read the count with `(get e 1)`, which
	// only works if `get` accepts a positional key on a sequence. Without this it
	// reported "get expects a table, got ("the" 3)".
	if args[0].tag == .pair || args[0].tag == .emptylist || args[0].tag == .vector
		|| args[0].tag == .array {
		idx := need_int('get', args[1])!
		items := seq(args[0]) or {
			return error('get: ${err.msg()}')
		}
		if idx < 0 || idx >= items.len {
			return args[2]
		}
		return items[idx]
	}
	return error('get expects a table, got ${printer.write(args[0])}')
}

fn prim_has_key(args []blip.Value) !blip.Value {
	return blip.boolean(args[0].as_table().has(need_str('has-key?', args[1])!))
}

fn prim_put(args []blip.Value) !blip.Value {
	mut mm := args[0].as_table().values.clone()
	mm[need_str('put', args[1])!] = args[2]
	return blip.table(mm)
}

fn prim_remove(args []blip.Value) !blip.Value {
	mut mm := args[0].as_table().values.clone()
	mm.delete(need_str('remove', args[1])!)
	return blip.table(mm)
}

fn prim_table_keys(args []blip.Value) !blip.Value {
	keys := args[0].as_table().keys()
	mut items := []blip.Value{}
	for k in keys {
		items << blip.keyword(k)
	}
	return blip.list_from(items)
}

// ----------------------------------------------------------------- strings

fn prim_string_append(args []blip.Value) !blip.Value {
	mut buf := []u8{}
	for a in args {
		buf << need_str('string-append', a)!.bytes()
	}
	return blip.string(buf.bytestr())
}

fn prim_string_length(args []blip.Value) !blip.Value {
	return blip.integer(need_str('string-length', args[0])!.len)
}

fn prim_string_downcase(args []blip.Value) !blip.Value {
	return blip.string(need_str('string-downcase', args[0])!.to_lower())
}

fn prim_string_upcase(args []blip.Value) !blip.Value {
	return blip.string(need_str('string-upcase', args[0])!.to_upper())
}

fn prim_string_split(args []blip.Value) !blip.Value {
	s := need_str('string-split', args[0])!
	sep := need_str('string-split', args[1])!
	mut items := []blip.Value{}
	for part in s.split(sep) {
		items << blip.string(part)
	}
	return blip.list_from(items)
}

fn prim_string_trim(args []blip.Value) !blip.Value {
	return blip.string(need_str('string-trim', args[0])!.trim_space())
}

fn prim_string_blank(args []blip.Value) !blip.Value {
	return blip.boolean(need_str('string-blank?', args[0])!.trim_space() == '')
}

fn prim_string(args []blip.Value) !blip.Value {
	return blip.string(need_str('string', args[0])!)
}

fn prim_symbol(args []blip.Value) !blip.Value {
	return blip.symbol(need_str('symbol', args[0])!)
}

fn prim_keyword(args []blip.Value) !blip.Value {
	if args[0].tag == .keyword {
		return args[0]
	}
	return blip.keyword(need_str('keyword', args[0])!)
}

fn prim_string_to_number(args []blip.Value) !blip.Value {
	s := need_str('string->number', args[0])!
	if n := strconv.atoi64(s) {
		return blip.integer(n)
	}
	if f := strconv.atof64(s, strict_float) {
		return blip.float(f)
	}
	return blip.nil_value()
}

fn prim_number_to_string(args []blip.Value) !blip.Value {
	if args[0].tag == .float {
		return blip.string('${args[0].as_float()}')
	}
	return blip.string(strconv.format_int(need_int('number->string', args[0])!, 10))
}

// ------------------------------------------------------------- structs
//
// The struct PRIMITIVES are here; the constructor, the predicate, the accessors
// and the setters are generated as ordinary definitions by the machine's `struct`
// form, because those are functions and this table only holds `!Value`
// implementations. What lives here is the machinery they all need.

fn prim_structp(args []blip.Value) !blip.Value {
	return blip.boolean(args[0].tag == .struct_)
}

fn prim_struct_name(args []blip.Value) !blip.Value {
	if args[0].tag != .struct_ {
		return error('struct-name: ${printer.write(args[0])} is not a struct')
	}
	return blip.symbol(args[0].as_struct().name)
}

fn prim_struct_ref(args []blip.Value) !blip.Value {
	if args[0].tag != .struct_ {
		return error('struct-ref: ${printer.write(args[0])} is not a struct')
	}
	s := args[0].as_struct()
	k := need_str('struct-ref', args[1])!
	if !s.has(k) {
		return error('struct-ref: ${s.name} has no field ${k}')
	}
	return s.get(k)
}

// integer->rune and rune->integer convert between a byte value and a character.
// Brainfuck needs both: `.` prints the cell as a character, `,` reads a character
// and stores its value.
fn prim_integer_to_rune(args []blip.Value) !blip.Value {
	n := need_int('integer->rune', args[0])!
	if n < 0 || n > 0x10FFFF {
		return error('integer->rune: ${n} is not a code point')
	}
	return blip.rune(u32(n))
}

// code->string builds a one-character string from a Unicode code point.
// JSON's \u escapes and the \b \f shorthands need it: there is no other way
// to materialize a character the reader cannot write, and a parser that
// punted on them would not parse JSON.
fn prim_code_to_string(args []blip.Value) !blip.Value {
	n := need_int('code->string', args[0])!
	if n < 0 || n > 0x10FFFF {
		return error('code->string: ${n} is not a code point')
	}
	return blip.string(rune(u32(n)).str())
}

// string->rune converts a one-character string to a rune. Brainfuck's `,`
// command reads a character and needs to convert it to a byte value.
fn prim_string_to_rune(args []blip.Value) !blip.Value {
	s := need_str('string->rune', args[0])!
	if s.len != 1 {
		return error('string->rune: expected a one-character string, got "${s}"')
	}
	return blip.rune(s[0])
}

fn prim_rune_to_integer(args []blip.Value) !blip.Value {
	v := args[0]
	if v.tag == .rune {
		return blip.integer(v.as_int())
	}
	if v.tag == .integer {
		return v
	}
	return error('rune->integer: ${printer.write(v)} is not a character')
}

fn prim_struct_set(args []blip.Value) !blip.Value {
	if args[0].tag != .struct_ {
		return error('struct-set!: ${printer.write(args[0])} is not a struct')
	}
	s := args[0].as_struct()
	k := need_str('struct-set!', args[1])!
	if !s.has(k) {
		return error('struct-set!: ${s.name} has no field ${k}')
	}
	return blip.Value{
		tag:     .struct_
		payload: s.with(k, args[2])
	}
}

// __make-struct is the constructor the `struct` form generates. It takes the name,
// the field names, and the values, and returns an instance.
fn prim_make_struct(args []blip.Value) !blip.Value {
	if args.len < 2 {
		return error('__make-struct needs a name and a field list')
	}
	name := need_str('__make-struct', args[0])!
	mut fields := []string{}
	fv := args[1]
	if fv.tag == .vector {
		d := fv.as_vector().data
		mut i := 0
		for i < d.len {
			fields << need_str('__make-struct', d[i])!
			i++
		}
	} else {
		fields << name
	}
	if args.len - 2 != fields.len {
		return error('__make-struct: ${name} has ${fields.len} field(s) but got ${args.len - 2} value(s)')
	}
	mut vals := map[string]blip.Value{}
	mut i := 0
	for i < fields.len {
		vals[fields[i]] = args[i + 2]
		i++
	}
	return blip.struct_value(name, fields, vals)
}

// ----------------------------------------------------------------- output
//
// `print` and `display` are NOT here. They used to be, and they wrote to stdout
// with println(), which is the one thing that makes an interpreter impossible to
// embed: a host cannot capture it, and the tests could not assert on it. They
// are machine builtins now, because only the machine can see the Host.

fn show(a blip.Value, quote_strings bool) string {
	if a.tag == .string && !quote_strings {
		return a.as_string()
	}
	return printer.write(a)
}

fn prim_str(args []blip.Value) !blip.Value {
	return blip.string(show(args[0], true))
}

// ------------------------------------------------------- more sequences

fn prim_last(args []blip.Value) !blip.Value {
	items := seq(args[0])!
	if items.len == 0 {
		return blip.nil_value()
	}
	return items[items.len - 1]
}

fn prim_not_eq(args []blip.Value) !blip.Value {
	return blip.boolean(!value_eq(args[0], args[1]))
}

// eq? is IDENTITY, not value equality, and for the values it can see that is the
// same test. It exists because `=` is value equality on contents and some code
// needs to say "the same thing" rather than "equal contents"; symbols and
// keywords are interned, so `(eq? 'a 'a)` is true and so is `(eq? "a" "a")`.
fn prim_eqp(args []blip.Value) !blip.Value {
	return blip.boolean(value_eq(args[0], args[1]))
}

// in? is `(= x coll)` for a collection, and it belongs here rather than in the
// examples' own code because the examples use it.
fn prim_in(args []blip.Value) !blip.Value {
	items := seq(args[1]) or {
		return error('in?: ${err.msg()}')
	}
	mut i := 0
	for i < items.len {
		if value_eq(args[0], items[i]) {
			return blip.boolean(true)
		}
		i++
	}
	return blip.boolean(false)
}

fn prim_concat(args []blip.Value) !blip.Value {
	mut out := []blip.Value{}
	for a in args {
		part := seq(a)!
		for p in part {
			out << p
		}
	}
	return blip.list_from(out)
}

// range is INCLUSIVE of `stop`, because that is what a loop counter means here.
// The alternative -- exclusive, as in Python -- makes `(range 0 10)` produce nine
// values and every off-by-one in the examples becomes a mystery.
fn prim_range(args []blip.Value) !blip.Value {
	mut from := i64(0)
	mut to := i64(0)
	if args.len == 1 {
		to = need_int('range', args[0])!
	} else {
		from = need_int('range', args[0])!
		to = need_int('range', args[1])!
	}
	mut out := []blip.Value{}
	mut i := from
	for i <= to {
		out << blip.integer(i)
		i++
	}
	return blip.list_from(out)
}



fn prim_count(args []blip.Value) !blip.Value {
	return blip.integer(seq(args[0])!.len)
}

fn prim_sort(args []blip.Value) !blip.Value {
	items := seq(args[0])!
	mut ordered := items.clone()
	// Insertion sort rather than a general one: these lists are small, and a
	// comparison failure has to name the two values that would not compare.
	mut i := 1
	for i < ordered.len {
		mut j := i
		for j > 0 && compare(ordered[j - 1], ordered[j])! > 0 {
			tmp := ordered[j - 1]
			ordered[j - 1] = ordered[j]
			ordered[j] = tmp
			j--
		}
		i++
	}
	return blip.list_from(ordered)
}

// sort_by takes a KEY fntion, which needs the machine, so this is only the
// key-extracting half: the machine calls key on each element first.
pub fn sort_by_keyed(items []blip.Value, keys []blip.Value) !blip.Value {
	mut order := []int{}
	mut i := 0
	for i < items.len {
		order << i
		i++
	}
	mut a := 0
	for a < order.len {
		mut b := a
		for b > 0 && compare(keys[order[b - 1]], keys[order[b]])! > 0 {
			tmp := order[b - 1]
			order[b - 1] = order[b]
			order[b] = tmp
			b--
		}
		a++
	}
	mut out := []blip.Value{}
	for idx in order {
		out << items[idx]
	}
	return blip.list_from(out)
}


// frequencies returns a table of symbol/count pairs, as
// (get e 0) and (get e 1) read it. A table of counts would force a get for the
// count and a has-key? for the membership, and the examples read it with `car` and
// `(get e 1)`.
fn prim_frequencies(args []blip.Value) !blip.Value {
	items := seq(args[0])!
	mut counts := map[string]blip.Value{}
	mut order := []string{}
	mut i := 0
	for i < items.len {
		key := printer.write(items[i])
		if key !in counts {
			order << key
			counts[key] = blip.integer(0)
		}
		old := counts[key].as_int()
		counts[key] = blip.integer(old + 1)
		i++
	}
	mut out := []blip.Value{}
	for k in order {
		out << blip.list_from([blip.string(k), counts[k]])
	}
	return blip.list_from(out)
}

// ------------------------------------------------------------- vectors

fn as_vector_value(v blip.Value, name string) !&blip.Vector {
	if !(v.tag in [.vector, .array]) {
		return error('${name} expects a vector or array, got ${printer.write(v)}')
	}
	return v.as_vector()
}


fn prim_vector_rev(args []blip.Value) !blip.Value {
	data := as_vector_value(args[0], 'vector-rev')!.data
	mut out := []blip.Value{}
	mut i := data.len - 1
	for i >= 0 {
		out << data[i]
		i--
	}
	return blip.vector(out)
}

fn prim_vector_append(args []blip.Value) !blip.Value {
	mut out := []blip.Value{}
	for a in args {
		d := as_vector_value(a, 'vector-append')!.data
		for x in d {
			out << x
		}
	}
	return blip.vector(out)
}

fn prim_vector_emptyp(args []blip.Value) !blip.Value {
	return blip.boolean(as_vector_value(args[0], 'vector-empty?')!.data.len == 0)
}

fn prim_vector_containsp(args []blip.Value) !blip.Value {
	data := as_vector_value(args[0], 'vector-contains?')!.data
	mut i := 0
	for i < data.len {
		if value_eq(data[i], args[1]) {
			return blip.boolean(true)
		}
		i++
	}
	return blip.boolean(false)
}

// --------------------------------------------------------------- arrays

// The mutable sequence primitives mutate through the payload's slice. V slices
// are descriptors, so `v.data[i] = x` writes into the shared backing array -- but
// only if the slice has spare capacity. `<<` grows it in place when it does, so
// the mutation primitives always go through `<<` first.
fn prim_array_set(args []blip.Value) !blip.Value {
	vec := as_vector_value(args[0], 'array-set!')!
	i := need_int('array-set!', args[1])!
	if i < 0 || i >= vec.data.len {
		return error('array-set!: index ${i} out of range (length ${vec.data.len})')
	}
	vec.set_at(int(i), args[2])
	return blip.nil_value()
}

fn prim_array_ref(args []blip.Value) !blip.Value {
	return prim_vector_ref(args)
}

fn prim_array_length(args []blip.Value) !blip.Value {
	return blip.integer(as_vector_value(args[0], 'array-length')!.data.len)
}

fn prim_array_emptyp(args []blip.Value) !blip.Value {
	return blip.boolean(as_vector_value(args[0], 'array-empty?')!.data.len == 0)
}

fn prim_array_push(args []blip.Value) !blip.Value {
	vec := as_vector_value(args[0], 'array-push!')!
	vec.push(args[1])
	return args[0]
}

fn prim_array_pop(args []blip.Value) !blip.Value {
	vec := as_vector_value(args[0], 'array-pop!')!
	if vec.data.len == 0 {
		return error('array-pop!: the array is empty')
	}
	return vec.pop()
}

// --------------------------------------------------------------- buffers

fn prim_put_bang(args []blip.Value) !blip.Value {
	if args[0].tag != .buffer {
		return error('put! expects a buffer, got ${printer.write(args[0])}')
	}
	args[0].as_table().set_at(need_str('put!', args[1])!, args[2])
	// A mutation returns nothing. Returning the buffer invites `(define b2
	// (put! b ...))`, which looks like it copies and is not.
	return blip.nil_value()
}

fn prim_dissoc_bang(args []blip.Value) !blip.Value {
	if args[0].tag != .buffer {
		return error('dissoc! expects a buffer, got ${printer.write(args[0])}')
	}
	args[0].as_table().delete_at(need_str('dissoc!', args[1])!)
	return args[0]
}

// ---------------------------------------------------------------- strings

fn prim_string_index_of(args []blip.Value) !blip.Value {
	hay := need_str('string-index-of', args[0])!
	if args[1].tag == .rune {
		needle := rune_bytes(args[1].as_int())
		i := hay.index(needle) or { return blip.integer(-1) }
		return blip.integer(i64(i))
	}
	needle := need_str('string-index-of', args[1])!
	i := hay.index(needle) or { return blip.integer(-1) }
	return blip.integer(i64(i))
}

fn rune_bytes(cp i64) string {
	mut buf := []u8{}
	buf << u8(cp)
	return buf.bytestr()
}

fn prim_string_not_blank(args []blip.Value) !blip.Value {
	return blip.boolean(need_str('string-not-blank?', args[0])!.trim_space() != '')
}

fn prim_string_containsp(args []blip.Value) !blip.Value {
	hay := need_str('string-contains?', args[0])!
	needle := need_str('string-contains?', args[1])!
	return blip.boolean(hay.contains(needle))
}

fn prim_string_start_withp(args []blip.Value) !blip.Value {
	return blip.boolean(need_str('string-start-with?', args[0])!
		.starts_with(need_str('string-start-with?', args[1])!))
}

fn prim_string_join(args []blip.Value) !blip.Value {
	items := seq(args[0])!
	mut sep := ''
	if args.len > 1 {
		sep = need_str('string-join', args[1])!
	}
	mut out := []u8{}
	mut i := 0
	for i < items.len {
		if i > 0 {
			out << sep.bytes()
		}
		out << need_str('string-join', items[i])!.bytes()
		i++
	}
	return blip.string(out.bytestr())
}

fn prim_string_repeat(args []blip.Value) !blip.Value {
	return blip.string(need_str('string-repeat', args[0])!.repeat(int(need_int('string-repeat', args[1])!)))
}

fn prim_string_slice(args []blip.Value) !blip.Value {
	s := need_str('string-slice', args[0])!
	start := need_int('string-slice', args[1])!
	end := need_int('string-slice', args[2])!
	lo := clamp(start, 0, i64(s.len))
	hi := clamp(end, lo, i64(s.len))
	return blip.string(s[int(lo)..int(hi)])
}

fn prim_string_replace(args []blip.Value) !blip.Value {
	s := need_str('string-replace', args[0])!
	return blip.string(s.replace(need_str('string-replace', args[1])!,
		need_str('string-replace', args[2])!))
}

fn prim_string_to_symbol(args []blip.Value) !blip.Value {
	return blip.symbol(need_str('string->symbol', args[0])!)
}

fn prim_string_to_keyword(args []blip.Value) !blip.Value {
	return blip.keyword(need_str('string->keyword', args[0])!)
}

// ------------------------------------------------------------- predicates

fn prim_booleanp(args []blip.Value) !blip.Value {
	return blip.boolean(args[0].tag == .boolean)
}

fn prim_runep(args []blip.Value) !blip.Value {
	return blip.boolean(args[0].tag == .rune)
}

fn prim_fntionp(args []blip.Value) !blip.Value {
	return blip.boolean(args[0].tag in [.closure, .primitive])
}

// ------------------------------------------------------------- arithmetic

fn prim_modulo(args []blip.Value) !blip.Value {
	b := need_int('modulo', args[1])!
	if b == 0 {
		return error('modulo by zero')
	}
	a := need_int('modulo', args[0])!
	mut m := a % b
	// V's % keeps the sign of the dividend. `modulo` is the floored one, so
	// (modulo -1 3) is 2 rather than -1.
	if m != 0 && (m < 0) != (b < 0) {
		m += b
	}
	return blip.integer(m)
}

fn prim_quotient(args []blip.Value) !blip.Value {
	b := need_int('quotient', args[1])!
	if b == 0 {
		return error('quotient by zero')
	}
	a := need_int('quotient', args[0])!
	mut q := a / b
	if (a % b) != 0 && (a < 0) != (b < 0) {
		q--
	}
	return blip.integer(q)
}

fn prim_remainder(args []blip.Value) !blip.Value {
	b := need_int('remainder', args[1])!
	if b == 0 {
		return error('remainder by zero')
	}
	return blip.integer(need_int('remainder', args[0])! % b)
}

fn prim_gcd(args []blip.Value) !blip.Value {
	mut a := need_int('gcd', args[0])!
	if a < 0 {
		a = -a
	}
	mut b := need_int('gcd', args[1])!
	if b < 0 {
		b = -b
	}
	for b != 0 {
		t := a % b
		a = b
		b = t
	}
	return blip.integer(a)
}

fn prim_expt(args []blip.Value) !blip.Value {
	if args[0].tag == .float || args[1].tag == .float {
		return blip.float(math.pow(as_f64(args[0])!, as_f64(args[1])!))
	}
	mut out := i64(1)
	mut base := need_int('expt', args[0])!
	mut n := need_int('expt', args[1])!
	if n < 0 {
		return error('expt: a negative exponent is not an integer')
	}
	for n > 0 {
		if n & 1 == 1 {
			out *= base
		}
		base *= base
		n /= 2
	}
	return blip.integer(out)
}

fn prim_sqrt(args []blip.Value) !blip.Value {
	f := as_f64(args[0])!
	if f < 0.0 {
		return error('sqrt of a negative number')
	}
	return blip.float(math.sqrt(f))
}

fn prim_inc(args []blip.Value) !blip.Value {
	if args[0].tag == .float {
		return blip.float(args[0].as_float() + 1.0)
	}
	return blip.integer(need_int('inc', args[0])! + 1)
}

fn prim_dec(args []blip.Value) !blip.Value {
	if args[0].tag == .float {
		return blip.float(args[0].as_float() - 1.0)
	}
	return blip.integer(need_int('dec', args[0])! - 1)
}
