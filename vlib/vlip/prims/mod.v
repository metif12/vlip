module prims

// Primitive functions.
//
// The signature deliberately does not take the machine. Builtins that need to
// call back into the interpreter -- apply, map, format, error -- are handled by
// the machine itself, which is what keeps this module free of any dependency on
// it. Without that separation the two would be mutually dependent.

import strconv
import vlib.vlip
import vlib.vlip.printer

// AtoF64Param is not exported by name in this V version, so it is built from its
// only public field. allow_extra_chars must be false: a parse of "12abc" has to
// be rejected rather than silently yielding 12.
const strict_float = strconv.AtoF64Param{
}

// table returns every primitive, keyed by name.
pub fn table() map[string]vlip.PrimFn {
	mut p := map[string]vlip.PrimFn{}
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
	p['print'] = prim_print
	p['display'] = prim_display
	p['str'] = prim_str
	p['list-ref'] = prim_list_ref
	p['take'] = prim_take
	p['drop'] = prim_drop
	p['first'] = prim_car
	p['rest'] = prim_cdr
	return p
}

// ------------------------------------------------------------------ helpers

fn need_int(name string, v vlip.Value) !i64 {
	if v.tag != .integer {
		return error('${name} expects an integer, got ${printer.write(v)}')
	}
	return v.as_int()
}

fn need_str(name string, v vlip.Value) !string {
	if !(v.tag in [.string, .symbol, .keyword]) {
		return error('${name} expects a string, got ${printer.write(v)}')
	}
	return v.as_string()
}

fn as_f64(v vlip.Value) !f64 {
	match v.tag {
		.integer { return f64(v.as_int()) }
		.float { return v.as_float() }
		else { return error('expected a number, got ${printer.write(v)}') }
	}
}

fn any_float(args []vlip.Value) bool {
	for a in args {
		if a.tag == .float {
			return true
		}
	}
	return false
}

fn is_number(v vlip.Value) bool {
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
pub fn compare(a vlip.Value, b vlip.Value) !int {
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

fn prim_add(args []vlip.Value) !vlip.Value {
	if any_float(args) {
		mut f := 0.0
		for a in args {
			f += as_f64(a)!
		}
		return vlip.float(f)
	}
	mut sum := i64(0)
	for a in args {
		sum += need_int('+', a)!
	}
	return vlip.integer(sum)
}

fn prim_sub(args []vlip.Value) !vlip.Value {
	if args.len == 0 {
		return error('- expects at least 1 argument')
	}
	if args.len == 1 {
		return vlip.integer(-need_int('-', args[0])!)
	}
	if any_float(args) {
		mut f := as_f64(args[0])!
		for i in 1 .. args.len {
			f -= as_f64(args[i])!
		}
		return vlip.float(f)
	}
	mut acc := need_int('-', args[0])!
	for i in 1 .. args.len {
		acc -= need_int('-', args[i])!
	}
	return vlip.integer(acc)
}

fn prim_mul(args []vlip.Value) !vlip.Value {
	if any_float(args) {
		mut f := 1.0
		for a in args {
			f *= as_f64(a)!
		}
		return vlip.float(f)
	}
	mut acc := i64(1)
	for a in args {
		acc *= need_int('*', a)!
	}
	return vlip.integer(acc)
}

fn prim_div(args []vlip.Value) !vlip.Value {
	if args.len != 2 {
		return error('/ expects exactly 2 arguments')
	}
	if args[0].tag == .float || args[1].tag == .float {
		d := as_f64(args[1])!
		if d == 0.0 {
			return error('division by zero')
		}
		return vlip.float(as_f64(args[0])! / d)
	}
	b := need_int('/', args[1])!
	if b == 0 {
		return error('division by zero')
	}
	return vlip.integer(need_int('/', args[0])! / b)
}

// ------------------------------------------------------------- comparison

fn prim_eq(args []vlip.Value) !vlip.Value {
	mut i := 0
	for i + 1 < args.len {
		if !value_eq(args[i], args[i + 1]) {
			return vlip.boolean(false)
		}
		i++
	}
	return vlip.boolean(true)
}

// value_eq is structural equality on contents, not identity.
pub fn value_eq(a vlip.Value, b vlip.Value) bool {
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
		else { return false }
	}
}

fn chain(name string, args []vlip.Value) !vlip.Value {
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
			return vlip.boolean(false)
		}
		i++
	}
	return vlip.boolean(true)
}

fn prim_lt(args []vlip.Value) !vlip.Value {
	return chain('<', args)
}

fn prim_gt(args []vlip.Value) !vlip.Value {
	return chain('>', args)
}

fn prim_le(args []vlip.Value) !vlip.Value {
	return chain('<=', args)
}

fn prim_ge(args []vlip.Value) !vlip.Value {
	return chain('>=', args)
}

fn prim_not(args []vlip.Value) !vlip.Value {
	if args.len != 1 {
		return error('not expects 1 argument')
	}
	// Only #f is false, so this must not be the arithmetic negation of truthiness.
	return vlip.boolean(!args[0].truthy())
}

// ------------------------------------------------------------------- lists

fn list_slice(v vlip.Value) ![]vlip.Value {
	mut out := []vlip.Value{}
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

fn prim_car(args []vlip.Value) !vlip.Value {
	if args[0].tag != .pair {
		return error('car expects a pair, got ${printer.write(args[0])}')
	}
	return args[0].as_pair().car
}

fn prim_cdr(args []vlip.Value) !vlip.Value {
	if args[0].tag != .pair {
		return error('cdr expects a pair, got ${printer.write(args[0])}')
	}
	return args[0].as_pair().cdr
}

fn prim_cons(args []vlip.Value) !vlip.Value {
	return vlip.cons(args[0], args[1])
}

fn prim_list(args []vlip.Value) !vlip.Value {
	mut items := []vlip.Value{}
	for a in args {
		items << a
	}
	return vlip.list_from(items)
}

fn prim_length(args []vlip.Value) !vlip.Value {
	match args[0].tag {
		.pair {
			mut n := i64(0)
			mut cur := args[0]
			for cur.tag == .pair {
				n++
				cur = cur.as_pair().cdr
			}
			return vlip.integer(n)
		}
		.vector { return vlip.integer(args[0].as_vector().data.len) }
		.string { return vlip.integer(args[0].as_string().len) }
		.nil, .emptylist { return vlip.integer(0) }
		else { return error('length expects a collection, got ${printer.write(args[0])}') }
	}
}

fn prim_reverse(args []vlip.Value) !vlip.Value {
	mut items := list_slice(args[0])!
	mut out := vlip.nil_value()
	mut i := items.len - 1
	for i >= 0 {
		out = vlip.cons(items[i], out)
		i--
	}
	return out
}

fn prim_append(args []vlip.Value) !vlip.Value {
	mut out := []vlip.Value{}
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
	return vlip.list_from(out)
}

fn prim_list_ref(args []vlip.Value) !vlip.Value {
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

fn prim_take(args []vlip.Value) !vlip.Value {
	mut items := list_slice(args[0])!
	n := clamp(need_int('take', args[1])!, 0, i64(items.len))
	mut head := []vlip.Value{}
	mut i := 0
	for i < n {
		head << items[i]
		i++
	}
	return vlip.list_from(head)
}

fn prim_drop(args []vlip.Value) !vlip.Value {
	mut items := list_slice(args[0])!
	n := clamp(need_int('drop', args[1])!, 0, i64(items.len))
	return vlip.list_from(items[n..])
}

// -------------------------------------------------------------- predicates

fn tag_is(v vlip.Value, t vlip.Tag) vlip.Value {
	return vlip.boolean(v.tag == t)
}

fn prim_nullp(args []vlip.Value) !vlip.Value {
	// True for BOTH the empty list and nil. The examples assert
	// `(null? '())` is true, and also that nil and () print differently, so the
	// predicate has to accept both values.
	return vlip.boolean(args[0].is_empty_seq())
}

fn prim_nilp(args []vlip.Value) !vlip.Value {
	return vlip.boolean(args[0].is_empty_seq())
}

fn prim_pairp(args []vlip.Value) !vlip.Value {
	return tag_is(args[0], .pair)
}

fn prim_vectorp(args []vlip.Value) !vlip.Value {
	return tag_is(args[0], .vector)
}

fn prim_tablep(args []vlip.Value) !vlip.Value {
	return tag_is(args[0], .table)
}

fn prim_arrayp(args []vlip.Value) !vlip.Value {
	return tag_is(args[0], .array)
}

fn prim_stringp(args []vlip.Value) !vlip.Value {
	return tag_is(args[0], .string)
}

fn prim_symbolp(args []vlip.Value) !vlip.Value {
	return tag_is(args[0], .symbol)
}

fn prim_keywordp(args []vlip.Value) !vlip.Value {
	return tag_is(args[0], .keyword)
}

fn prim_integerp(args []vlip.Value) !vlip.Value {
	return tag_is(args[0], .integer)
}

fn prim_floatp(args []vlip.Value) !vlip.Value {
	return tag_is(args[0], .float)
}

fn prim_numberp(args []vlip.Value) !vlip.Value {
	return vlip.boolean(is_number(args[0]))
}

// list? must reject cyclic lists, so it uses tortoise and hare.
fn prim_listp(args []vlip.Value) !vlip.Value {
	if args[0].is_empty_seq() {
		return vlip.boolean(true)
	}
	if args[0].tag != .pair {
		return vlip.boolean(false)
	}
	mut slow := args[0]
	mut fast := args[0]
	for fast.tag == .pair && fast.as_pair().cdr.tag == .pair {
		fast = fast.as_pair().cdr.as_pair().car
		if fast.tag == .nil {
			return vlip.boolean(true)
		}
		slow = slow.as_pair().cdr
		if value_eq(fast, slow) {
			return vlip.boolean(false)
		}
	}
	return vlip.boolean(fast.as_pair().cdr.tag == .nil)
}

fn prim_zero(args []vlip.Value) !vlip.Value {
	return vlip.boolean(compare(args[0], vlip.integer(0))! == 0)
}

fn prim_even(args []vlip.Value) !vlip.Value {
	return vlip.boolean(need_int('even?', args[0])! % 2 == 0)
}

fn prim_odd(args []vlip.Value) !vlip.Value {
	return vlip.boolean(need_int('odd?', args[0])! % 2 != 0)
}

fn prim_positive(args []vlip.Value) !vlip.Value {
	return vlip.boolean(compare(args[0], vlip.integer(0))! > 0)
}

fn prim_negative(args []vlip.Value) !vlip.Value {
	return vlip.boolean(compare(args[0], vlip.integer(0))! < 0)
}

fn prim_min(args []vlip.Value) !vlip.Value {
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

fn prim_max(args []vlip.Value) !vlip.Value {
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

fn prim_abs(args []vlip.Value) !vlip.Value {
	if args[0].tag == .float {
		f := args[0].as_float()
		return vlip.float(if f < 0.0 { -f } else { f })
	}
	n := need_int('abs', args[0])!
	return vlip.integer(if n < 0 { -n } else { n })
}

// ------------------------------------------------------------- collections

fn prim_vector(args []vlip.Value) !vlip.Value {
	mut items := []vlip.Value{}
	for a in args {
		items << a
	}
	return vlip.vector(items)
}

fn prim_vector_ref(args []vlip.Value) !vlip.Value {
	i := need_int('vector-ref', args[1])!
	data := args[0].as_vector().data
	if i < 0 || i >= data.len {
		return error('vector-ref: index ${i} out of range (length ${data.len})')
	}
	return data[i]
}

fn prim_vector_length(args []vlip.Value) !vlip.Value {
	return vlip.integer(args[0].as_vector().data.len)
}

fn prim_get(args []vlip.Value) !vlip.Value {
	if args.len >= 3 {
		return args[2]
	}
	if args[0].tag == .table || args[0].tag == .buffer {
		return args[0].as_table().get(need_str('get', args[1])!)
	}
	return error('get expects a table, got ${printer.write(args[0])}')
}

fn prim_has_key(args []vlip.Value) !vlip.Value {
	return vlip.boolean(args[0].as_table().has(need_str('has-key?', args[1])!))
}

fn prim_put(args []vlip.Value) !vlip.Value {
	mut mm := args[0].as_table().values.clone()
	mm[need_str('put', args[1])!] = args[2]
	return vlip.table(mm)
}

fn prim_remove(args []vlip.Value) !vlip.Value {
	mut mm := args[0].as_table().values.clone()
	mm.delete(need_str('remove', args[1])!)
	return vlip.table(mm)
}

fn prim_table_keys(args []vlip.Value) !vlip.Value {
	keys := args[0].as_table().keys()
	mut items := []vlip.Value{}
	for k in keys {
		items << vlip.keyword(k)
	}
	return vlip.list_from(items)
}

// ----------------------------------------------------------------- strings

fn prim_string_append(args []vlip.Value) !vlip.Value {
	mut buf := []u8{}
	for a in args {
		buf << need_str('string-append', a)!.bytes()
	}
	return vlip.string(buf.bytestr())
}

fn prim_string_length(args []vlip.Value) !vlip.Value {
	return vlip.integer(need_str('string-length', args[0])!.len)
}

fn prim_string_downcase(args []vlip.Value) !vlip.Value {
	return vlip.string(need_str('string-downcase', args[0])!.to_lower())
}

fn prim_string_upcase(args []vlip.Value) !vlip.Value {
	return vlip.string(need_str('string-upcase', args[0])!.to_upper())
}

fn prim_string_split(args []vlip.Value) !vlip.Value {
	s := need_str('string-split', args[0])!
	sep := need_str('string-split', args[1])!
	mut items := []vlip.Value{}
	for part in s.split(sep) {
		items << vlip.string(part)
	}
	return vlip.list_from(items)
}

fn prim_string_trim(args []vlip.Value) !vlip.Value {
	return vlip.string(need_str('string-trim', args[0])!.trim_space())
}

fn prim_string_blank(args []vlip.Value) !vlip.Value {
	return vlip.boolean(need_str('string-blank?', args[0])!.trim_space() == '')
}

fn prim_string(args []vlip.Value) !vlip.Value {
	return vlip.string(need_str('string', args[0])!)
}

fn prim_symbol(args []vlip.Value) !vlip.Value {
	return vlip.symbol(need_str('symbol', args[0])!)
}

fn prim_keyword(args []vlip.Value) !vlip.Value {
	if args[0].tag == .keyword {
		return args[0]
	}
	return vlip.keyword(need_str('keyword', args[0])!)
}

fn prim_string_to_number(args []vlip.Value) !vlip.Value {
	s := need_str('string->number', args[0])!
	if n := strconv.atoi64(s) {
		return vlip.integer(n)
	}
	if f := strconv.atof64(s, strict_float) {
		return vlip.float(f)
	}
	return vlip.nil_value()
}

fn prim_number_to_string(args []vlip.Value) !vlip.Value {
	if args[0].tag == .float {
		return vlip.string('${args[0].as_float()}')
	}
	return vlip.string(strconv.format_int(need_int('number->string', args[0])!, 10))
}

// ----------------------------------------------------------------- output

fn show(a vlip.Value, quote_strings bool) string {
	if a.tag == .string && !quote_strings {
		return a.as_string()
	}
	return printer.write(a)
}

fn prim_print(args []vlip.Value) !vlip.Value {
	mut buf := []u8{}
	mut i := 0
	for i < args.len {
		if i > 0 {
			buf << ` `.bytes()
		}
		buf << show(args[i], true).bytes()
		i++
	}
	println(buf.bytestr())
	return vlip.nil_value()
}

fn prim_display(args []vlip.Value) !vlip.Value {
	mut buf := []u8{}
	mut i := 0
	for i < args.len {
		if i > 0 {
			buf << ` `.bytes()
		}
		buf << show(args[i], false).bytes()
		i++
	}
	println(buf.bytestr())
	return vlip.nil_value()
}

fn prim_str(args []vlip.Value) !vlip.Value {
	return vlip.string(show(args[0], true))
}
