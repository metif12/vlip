module main

import blip

// Regression probe for the `Value` payload representation.
//
// Finding: a `&Pair` reachable only through a `voidptr` field is NOT kept alive
// by V's Boehm GC. Measured: building a 2_000_000-cell cons chain and walking it
// reached 25 cells. V registers GC roots from typed fields; a `voidptr` does not
// declare what it points at, so the chain is collected almost immediately.
//
// This is why Value.payload is a typed `Payload` interface rather than a
// voidptr. An interface field is a real GC root, and scalars carry `none`, so
// they still cost no allocation.
//
// Run:  v -prod -o gc_probe.exe src/gc_probe.v && gc_probe.exe

const n = 2_000_000

fn build() blip.Value {
	mut lst := blip.nil()
	for i in 0 .. n {
		lst = blip.cons(blip.integer(i64(i)), lst)
	}
	return lst
}

fn walk(root blip.Value) i64 {
	mut s := i64(0)
	mut cur := root
	mut steps := 0
	for cur.tag == .pair {
		s += cur.as_pair().car.as_int()
		cur = cur.as_pair().cdr
		steps++
	}
	return s * steps // fold `steps` in so the walk cannot be optimised away
}

fn main() {
	root := build()

	// Churn the heap so anything unreachable gets collected.
	mut junk := []string{cap: 200000}
	for i in 0 .. 200000 {
		junk << 'garbage padding to force collection ${i}'
	}

	mut steps := 0
	mut s := i64(0)
	mut cur := root
	for cur.tag == .pair {
		s += cur.as_pair().car.as_int()
		cur = cur.as_pair().cdr
		steps++
	}

	expected_sum := i64(n) * i64(n - 1) / 2
	ok := steps == n && s == expected_sum
	println('walked=${steps}/${n} sum=${s} expected=${expected_sum} -> ${if ok { 'OK' } else { 'FAIL' }}')
	println('junk len=${junk.len} (heap was churned between build and walk)')
	if !ok {
		eprintln('FAIL: payloads are not being kept alive by the GC')
		return
	}
}