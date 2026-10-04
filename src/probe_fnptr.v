module main

import time
import vlip

const n = 1_000_000

// Is calling through a `fn () i64` variable catastrophically slower than calling
// the same function directly? If so, that matters a lot: a Lisp VM stores
// closures in Values, so every primitive call goes through a function pointer.

fn work() i64 {
	mut lst := vlip.nil()
	for i in 0 .. n {
		lst = vlip.cons(vlip.integer(i64(i)), lst)
	}
	mut sum := i64(0)
	mut cur := lst
	for cur.tag == .pair {
		p := cur.as_pair()
		sum += p.car.as_int()
		cur = p.cdr
	}
	return sum
}

fn main() {
	// direct
	s0 := time.now()
	a := work()
	s1 := time.now()
	println('direct call : ${s1 - s0} ms (${a})')

	// through a function pointer
	f := work
	s2 := time.now()
	b := f()
	s3 := time.now()
	println('via fn ptr  : ${s3 - s2} ms (${b})')

	// through a fn pointer stored in a struct field
	holder := FnHolder{
		f: work
	}
	s4 := time.now()
	c := holder.f()
	s5 := time.now()
	println('via struct  : ${s5 - s4} ms (${c})')

	assert a == b && b == c
}

struct FnHolder {
	f fn () i64
}