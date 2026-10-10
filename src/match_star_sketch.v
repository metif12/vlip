// Would blip's `match*` actually work? A design that cannot implement its own
// headline feature is not a design.
//
// match* is a macro over `match` + quasiquote, desugaring through temporaries.
// This file is a sketch of what
//
//   (match* (e1 e2 e3) [p1 p2 p3 body] [p4 body2] ...)
//
// must desugar to, in order to confirm the claim that the sugar needs no new
// core syntax. It is NOT the real expander.
module main

//   (let ([t1 e1] [t2 e2])
//     (cond
//       [(and (pattern? t1 p1) (pattern? t2 p2)) (let ([pv1 p1] [pv2 p2]) body)]
//       [p4 (let ([pv4 p4]) body2)]))       ; short clause: ignores t3
//
// This is what Racket's match* does. The load-bearing property is that every
// subject is evaluated EXACTLY ONCE, before any pattern is tested. Binding to
// temporaries is what buys that, and it is why match* is a macro rather than a
// special form.
//
// Each obligation below is a place a naive implementation breaks. They are the
// spec for the M8 tests, not decoration.

//  1. Clause arity must be checked at expansion time. A 2-pattern clause
//     against 3 subjects is a compile error, never a silent runtime miss.
//  2. `=>` must expand to a fresh test-and-retry that still evaluates each
//     subject only once.
//  3. A short clause (`p4` against 3 subjects) must bind the listed positions
//     and ignore the remainder.
//  4. `#:when` guards must see every binding from every pattern in the clause.
//  5. Temporaries must be hygienic: two expansions of match* in one body cannot
//     collide. This is precisely what Steel gets wrong (issue #706: nested
//     syntax-rules templates with ellipsis produce (3 3 3) instead of (1 2 3)).
//     blip v1 macros are unhygienic, so match* internals MUST use gensym and
//     MUST NOT be reachable from user code.

fn main() {
	println('match* desugaring: expressible with existing core forms')
	println('unverified until M3 (single-evaluation) and M5 (gensym) exist')
}