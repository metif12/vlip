module main

// Option B for continuations: one tagged struct instead of a sum type.
// The tag selects which fields are live. This sidesteps V's sum-type field
// initialisation bug entirely and keeps push/pop cheap.

@[flag]
enum KontTag {
	done
	if_k
	seq_k
	app_fn
	app_arg
	define
	set
}

struct Kont {
mut:
	tag KontTag
	// shared
	datum  int // node id in the arena
	env    int // environment id
	// if_k / seq_k: which child we are on
	slot   int
	count  int
	// app_arg: accumulated arguments
	acc    []int
	// define: the name being bound
	name   string
}

fn main() {
	// every field set at construction, from locals -- no sum type involved
	x := 7
	name := 'foo'
	mut k := Kont{
		tag:   .if_k
		datum: x
		env:   0
		slot:  1
		count: 2
		name:  name
	}
	println('k.tag=${k.tag} datum=${k.datum} name=${k.name}')

	mut acc := []int{}
	acc << x
	acc << 1
	k2 := Kont{
		tag:   .app_arg
		datum: x
		acc:   acc
	}
	println('k2.tag=${k2.tag} acc=${k2.acc}')

	// push/pop on a stack of them
	mut stack := []Kont{}
	stack << k
	stack << k2
	println('stack len=${stack.len} top=${stack[stack.len - 1].tag}')
	top := stack[stack.len - 1]
	stack = stack[..stack.len - 1]
	println('after pop len=${stack.len} popped=${top.tag}')
}