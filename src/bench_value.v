module main

// M0 gate: which `Value` layout does vlip use?
//
// The design doc framed this as "boxed sum type vs packed tagged struct vs raw
// union, measure and decide". Measurement turned out to be beside the point:
// two of the three cannot be written at all on V 0.5.2.
//
// A) BOXED SUM TYPE -- excluded, twice over.
//
//    A1. A variant struct holding the sum type by value is rejected outright:
//
//         struct cons_v { head int
//                          tail Lst }
//         error: invalid recursive struct `cons_v`
//
//        A Lisp's cons cell is recursive by definition, so a boxed sum type
//        cannot represent a pair without a second layer of indirection -- an
//        allocation on top of the boxing.
//
//    A2. Worse, a sum-type variant field cannot be initialised from a local at
//        all. No loop, no recursion, nothing unusual:
//
//         x := 7
//         v := cons_v{head: x}
//         error: `x` evaluated but not used
//
//        A plain non-sum struct with the identical shape compiles and runs, so
//        this is sum-type specific. Possibly a checker bug -- worth reporting
//        upstream -- but either way it is a blocker today.
//
// C) RAW V UNION -- excluded.
//
//    V allows exactly one initialised field per union construction, so a union
//    cannot hold a tag *and* a payload:
//
//         union U { tag T
//                   i   i64 }
//         U{tag: .integer, i: 5}
//         error: union `U` can have only one field initialised
//
//    Getting a tag plus payload means wrapping both in one struct, which is
//    just the packed struct with extra `unsafe` on every member read (V also
//    makes union fields immutable and requires unsafe to read any of them).
//
// B) PACKED TAGGED STRUCT -- chosen, by elimination. src/vlip/value.v.
//
// What is left worth measuring is B against the other idiomatic V option for a
// dynamic value: an interface. So that is what this benchmarks.
//
// Verified on V 0.5.2, the v3-line compiler in this checkout. Re-check A2 and C
// against upstream V 0.4.x before treating them as settled.
//
// Run:  v -prod -o bench_value.exe src/bench_value.v && bench_value.exe

import time
import vlip

const n = 1_000_000

fn main() {
	println('vlip M0 -- Value representation gate')
	println('A boxed sum type: EXCLUDED (cannot init recursive pair / cannot init field from local)')
	println('C raw V union:    EXCLUDED (cannot hold tag and payload in one value)')
	println('')
	println('B packed struct vs D interface-based Value')
	println('n = ${n}\n')

	packed := bench('B packed struct', workload_packed)
	ifaced := bench('D interface', workload_interface)

	println('')
	if packed < ifaced {
		println('packed struct wins: ${f64(ifaced) / f64(packed):.2}x faster than interface')
	} else {
		println('interface wins: ${f64(packed) / f64(ifaced):.2}x faster than packed struct')
	}
}

fn bench(label string, f fn () i64) i64 {
	mut best := i64(9223372036854775807)
	mut checksum := i64(0)
	for _ in 0 .. 3 {
		start := time.now() // microseconds; time.ticks() is not ns on Windows
		checksum = f()
		elapsed := time.now() - start
		println("   start=${start} end=${time.now()} elapsed=${elapsed}")
		if elapsed < best {
			best = elapsed
		}
	}
	println('${label}: ${best} ms  (best of 3)  checksum=${checksum}')
	return best
}

// time.now() returns MILLISECONDS on this V 0.5.2 Windows build, not
// microseconds. Verified by calibrating against time.sleep: a 500ms sleep
// returns a delta of 501. Dividing by 1000 here made every figure 1000x wrong
// and produced an impossible 20-hour "runtime" for a 1M-iteration loop.

// ---- B: packed tagged struct -----------------------------------------------
// src/vlip/value.v. Scalars inline in typed fields; heap payloads behind a
// voidptr. 32 bytes for any datum.

fn workload_packed() i64 {
	mut sum := vlip.integer(0)
	for i in 0 .. n {
		sum.i += i64(i)
	}
	mut lst := vlip.nil()
	for i in 0 .. n {
		lst = vlip.cons(vlip.integer(i64(i)), lst)
	}
	mut s := i64(0)
	mut cur := lst
	mut walked := 0
	for cur.tag == .pair {
		s += cur.as_pair().car.as_int()
		cur = cur.as_pair().cdr
		walked++
	}
	mut k := 0
	for i in 0 .. n {
		if vlip.integer(i64(i)).truthy() {
			k++
		}
	}

	assert s > 0 && k > 0
	return sum.as_int() + s + i64(k)
}

// ---- D: interface-based Value ----------------------------------------------
// The idiomatic V alternative, and what V's own eval.Value is shaped like
// (vlib/v/eval/eval.v:9-21). Dispatch is a switch on an int tag
// (vlib/v/gen/c/interface.v:1978), so the interesting cost is boxing: every
// value that reaches an interface becomes a heap object.
//
// All accessors are interface methods rather than smart casts, so no `is` is
// needed in the hot loop and the two candidates do the same work.

pub interface Dyn {
	as_int() i64
	truthy() bool
	is_pair() bool
	head() Dyn
	tail() Dyn
}

struct DynInt {
	i i64
}

fn (d &DynInt) as_int() i64 {
	return d.i
}

fn (d &DynInt) truthy() bool {
	return true
}

fn (d &DynInt) is_pair() bool {
	return false
}

fn (d &DynInt) head() Dyn {
	return d
}

fn (d &DynInt) tail() Dyn {
	return d
}

struct DynNil {}

fn (d DynNil) as_int() i64 {
	return 0
}

fn (d DynNil) truthy() bool {
	return true
}

fn (d DynNil) is_pair() bool {
	return false
}

fn (d DynNil) head() Dyn {
	return d
}

fn (d DynNil) tail() Dyn {
	return d
}

struct DynPair {
	car Dyn
	cdr Dyn
}

fn (p &DynPair) as_int() i64 {
	return 0
}

fn (p &DynPair) truthy() bool {
	return true
}

fn (p &DynPair) is_pair() bool {
	return true
}

fn (p &DynPair) head() Dyn {
	return p.car
}

fn (p &DynPair) tail() Dyn {
	return p.cdr
}

fn workload_interface() i64 {
	mut sum := i64(0)
	for i in 0 .. n {
		sum += (DynInt{
			i: i64(i)
		}).as_int()
	}
	mut lst := Dyn(DynNil{})
	for i in 0 .. n {
		lst = &DynPair{
			car: &DynInt{
				i: i64(i)
			}
			cdr: lst
		}
	}
mut s := i64(0)
	mut cur := lst
	for cur.is_pair() {
		s += cur.head().as_int()
		cur = cur.tail()
	}
	mut k := 0
	for i in 0 .. n {
		if (&DynInt{
			i: i64(i)
		}).truthy() {
			k++
		}
	}
	assert s > 0 && k > 0
	return sum + s + i64(k)
}