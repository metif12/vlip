module main

import time
import vlip

fn main() {
	mut lst := vlip.nil()
	s0 := time.now()
	for i in 0 .. 1000000 {
		lst = vlip.cons(vlip.integer(i64(i)), lst)
	}
	s1 := time.now()
	println('build 1M cons: ${s1 - s0} ms')

	mut sum := i64(0)
	mut cur := lst
	s2 := time.now()
	for cur.tag == .pair {
		p := cur.as_pair()
		sum += p.car.as_int()
		cur = p.cdr
	}
	s3 := time.now()
	println('walk 1M: ${s3 - s2} ms  sum=${sum}')

	mut acc := vlip.integer(0)
	s4 := time.now()
	for i in 0 .. 1000000 {
		acc.i += i64(i)
	}
	s5 := time.now()
	println('arith 1M: ${s5 - s4} ms  sum=${acc.as_int()}')

	mut k := 0
	s6 := time.now()
	for i in 0 .. 1000000 {
		if vlip.integer(i64(i)).truthy() {
			k++
		}
	}
	s7 := time.now()
	println('truthy 1M: ${s7 - s6} ms  k=${k}')
}