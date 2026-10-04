module main

// Can a sum-type variant be built by constructing empty and then assigning?
// If not, continuations must be a single tagged struct, not a sum type.

struct Kont {
	halt
	if_k
	seq_k
}

struct halt {}

struct if_k {
mut:
	tested bool
	outcome int
}

struct seq_k {
mut:
	remaining int
	outcome int
}

fn main() {
	x := 7
	y := 9

	// construct then assign
	a := if_k{}
	a.outcome = x
	a.tested = true

	b := seq_k{}
	b.remaining = y
	b.outcome = x

	println('a.outcome=${a.outcome} b.remaining=${b.remaining} b.outcome=${b.outcome}')

	// and as a slice element
	konts := [Kont(a), Kont(b)]
	println('slice len=${konts.len}')

	// and with a field set at construction time
	c := if_k{tested: true, outcome: x}
	println('c.outcome=${c.outcome}')
}
