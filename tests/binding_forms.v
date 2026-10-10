module main

/*
 * The binding-form suite: `let`, `let*`, `letrec`, rest parameters, and the two
 * things every one of them can get wrong -- shadowing, and leaking into the
 * global frame.
 *
 * This file exists because the `let*` bug spent a long time misdiagnosed. The
 * reported cause was that `[...]` is a vector literal in value position and a
 * binding group in form position, and that the reader does not record which
 * reading applies. That was wrong: `let` with bracket bindings had always worked,
 * because the head symbol already tells the machine what `kids[1]` means.
 *
 * The real cause was an off-by-one -- `transform_let_star` started its recursion
 * at binding 1 instead of binding 0, so it silently DROPPED the first binding.
 * `(let* ([a 1] [b (+ a 1)]) b)` compiled to `(let ([b (+ a 1)]) b)` and then
 * failed with "unbound identifier: a", which looks exactly like a scoping bug and
 * is not one. The rest-parameter bug was the mirror image: `.` was parsed as an
 * ordinary parameter named ".", so `(f 1 2 3)` bound the rest name to `3`.
 *
 * The rule these tests pin down, stated once:
 *
 *   `[...]` is resolved by POSITION, not by a reader flag. In the second slot of
 *   `let`/`let*`/`letrec` it is a binding group; everywhere else it is a vector
 *   literal. Both spellings of a binding group work -- `[a 1]` and `(a 1)` --
 *   because the examples and the documentation disagree about which to use and
 *   the examples win.
 *
 * Every depth here is shallow. Binding bugs are logical, not stack-depth bugs;
 * a deep recursion in this file would only measure Boehm collection cost (see
 * the note in tests/tail_calls.v) and hide the actual assertion.
 */

import vlib.blip
import vlib.blip.machine
import vlib.blip.printer
import vlib.blip.reader

// Suite exists only because V script mode requires every definition to precede
// every statement, so a module-level `mut fails := 0` would push the functions
// below it into "code". A counter needs somewhere to live; this is it.
struct Suite {
mut:
	fails int
}

fn (mut s Suite) fail(label string, msg string) {
	s.fails++
	println('FAIL ${label}: ${msg}')
}

// check evaluates src and compares the printer's rendering of the result with
// expected. kont is asserted to be zero for every check: a binding form that
// leaves a frame behind is a bug even when the value is right.
fn (mut s Suite) check(label string, src string, expected string) {
	res := reader.read_all(src)
	if res.diags.len > 0 {
		s.fail(label, '${res.diags.len} read errors: ${res.diags[0].render(label)}')
		return
	}
	mut m := machine.new_machine(&res.arena)
	got := m.run(res.forms) or {
		s.fail(label, 'error: ${err.msg()}')
		return
	}
	text := printer.write(got)
	if text != expected {
		s.fail(label, 'expected ${expected}, got ${text}')
		return
	}
	if m.kstack.len != 0 {
		s.fail(label, 'expected kont=0 at the end, got kont=${m.kstack.len}')
		return
	}
	println('ok   ${label} => ${text}')
}

// check_err asserts that src FAILS, and that the message mentions want. The
// mention is the assertion: an interpreter that reports the wrong failure is
// just as broken as one that succeeds, and "returns an error" alone would accept
// a crash with an empty message. An empty `want` means "any message".
fn (mut s Suite) check_err(label string, src string, want string) {
	res := reader.read_all(src)
	if res.diags.len > 0 {
		s.fail(label, '${res.diags.len} read errors')
		return
	}
	mut m := machine.new_machine(&res.arena)
	m.run(res.forms) or {
		msg := err.msg()
		if want != '' && !msg.contains(want) {
			s.fail(label, 'error message does not mention "${want}": ${msg}')
			return
		}
		println('ok   ${label} => error: ${msg}')
		return
	}
	s.fail(label, 'expected an error${if want == '' { '' } else { ' mentioning "${want}"' }}, got a value')
}

fn main() {
	mut s := Suite{}
	// ---- let: simultaneous, both spellings -----------------------------
	// A binding group is written with brackets or with parentheses. Both reach
	// transform_let, which only ever looks at kids[1] of the form, so the head
	// symbol -- not the reader -- decides how to read it.
	s.check('let brackets', '(let ([a 1] [b 2]) (+ a b))', '3')
	s.check('let parens', '(let ((a 1) (b 2)) (+ a b))', '3')
	s.check('let single bracket', '(let ([a 1]) a)', '1')
	s.check('let single paren', '(let ((a 1)) a)', '1')
	s.check('let empty', '(let () 7)', '7')
	s.check('let body is a sequence', '(let ([a 1]) (print a) (+ a 10))', '11')
	s.check('let value is an expression', '(let ([a (+ 1 2)]) a)', '3')
	s.check('let value is a call', '(let ([a (max 3 4)]) a)', '4')
	// The nested vector is a vector literal, because it is in a value position:
	// this is the `[...]` ambiguity, resolved by position.
	s.check('let binding a vector', '(let ([a [1 2]]) (vector-length a))', '2')
	s.check('let vector key', '(let ([a {:k 1}]) (get a :k))', '1')

	// Simultaneous `let` genuinely cannot see its siblings. This is correct
	// Scheme, and it is asserted here so a "helpful" future change that makes
	// let* out of let fails a test rather than passing review.
	s.check_err('let does not see siblings', '(let ([a 1] [b (+ a 1)]) b)', 'unbound identifier: a')

	// ---- let*: sequential ---------------------------------------------
	s.check('let* sees previous', '(let* ([a 1] [b (+ a 1)]) b)', '2')
	s.check('let* parens', '(let* ((a 1) (b (+ a 1))) b)', '2')
	s.check('let* single', '(let* ([a 5]) a)', '5')
	s.check('let* empty', '(let* () 8)', '8')
	s.check('let* three deep', '(let* ([a 1] [b (+ a 10)] [c (+ b 100)]) (+ a b c))', '123')
	// The bug this file was written for: the first binding was dropped, so `a`
	// resolved in the enclosing scope. With a global `a` present the old code
	// silently read THAT value instead of failing, which is worse.
	s.check('let* does not read the global',
		'(define a 99) (let* ([a 1] [b (+ a 1)]) (+ a b))', '3')
	s.check('let* body sees every binding',
		'(let* ([a 1] [b 2] [c 3]) (+ a b c))', '6')

	// ---- letrec -------------------------------------------------------
	s.check('letrec single', '(letrec ([a 1]) a)', '1')
	s.check('letrec self reference',
		'(letrec ([f (lambda (n) (if (= n 0) 1 (* n (f (- n 1)))))]) (f 5))', '120')
	s.check('letrec mutual',
		'(letrec ([e (lambda (n) (if (= n 0) #t (o (- n 1))))]
		          [o (lambda (n) (if (= n 0) #f (e (- n 1))))])
		   (e 20))', '#t')
// A letrec value may refer to a LATER name -- that is why letrec is not
	// defined in terms of let -- but the initialisations run left to right, so a
	// forward reference sees the placeholder. Scheme leaves this order
	// unspecified; stating it is better than leaving a reader to assume.
	s.check('letrec forward reference sees the placeholder',
		'(letrec ([a b] [b 42]) a)', 'nil')
	s.check('letrec forward reference still works self-referentially',
		'(letrec ([a (lambda () a)]) (a))', '#<closure>')

	s.check('letrec empty', '(letrec () 3)', '3')

	// ---- no leaking into the global frame ------------------------------
	// Each of these is checked twice: once for the right answer inside, and
	// once by showing the name is still unbound afterwards. The second half is
	// the one that catches the earlier `(set! a nil)`-in-the-enclosing-scope
	// letrec, which defined the names globally as a side effect.
	s.check('let does not leak', '(let ([leaky 1]) leaky) 1', '1')
	s.check('a let binding shadows rather than overwrites a global',
		'(define g1 0) (let ([g1 1]) g1) g1', '0')
	s.check_err('let binding is gone', '(let ([leaky 1]) leaky) leaky', 'unbound identifier: leaky')
	s.check_err('let* binding is gone', '(let* ([leaky 1]) leaky) leaky', 'unbound identifier: leaky')
	s.check_err('letrec binding is gone', '(letrec ([leaky 1]) leaky) leaky', 'unbound identifier: leaky')
	// The global `g1` defined above must still be 0, not 1.
	s.check('let did not overwrite a global', '(define g1 0) (let ([g1 1]) g1) g1', '0')

	// ---- shadowing ----------------------------------------------------
	s.check('shadow inside let', '(define x 1) (let ([x 2]) x) x', '1')
	s.check('shadow inside let*', '(define x 1) (let* ([x 2]) x) x', '1')
	s.check('shadow is restored after a call',
		'(define x 1) (define (f) 99) (let ([x 2]) (f)) x', '1')
	s.check('inner let shadows outer let',
		'(let ([a 1]) (let ([a 2]) (let ([a 3]) a)) a)', '1')
	s.check('closure captures lexically, not dynamically',
		'(define x 1) (define (f) x) (let ([x 2]) (f))', '1')
	// A closure created inside a let keeps that let alive.
	s.check('closure keeps its captured binding',
		'(define (mk) (let ([n 41]) (fn [] (+ n 1)))) (define g (mk)) (g)', '42')
	// A parameter shadows a global, and the global is untouched.
	s.check('parameter shadows a global',
		'(define car 5) (define (f car) car) (+ (f 1) car)', '6')
	// A binding can shadow a primitive name; the primitive is still reachable
	// outside it.
	s.check('let shadows a primitive', '(let ([car 5]) car) (car (list 7 8))', '7')
	// Each SIBLING argument is evaluated in the caller's scope. This is the
	// "restore the environment before each remaining subform" invariant, which
	// every tail-call test is blind to and which silently corrupts sibling
	// arguments when broken.
	s.check('sibling arguments keep their own scope',
		'(define (f a) 0) (let ([a 1] [b 2]) (+ (f a) b))', '2')
	s.check('sibling arguments in a begin keep their own scope',
		'(define (g x) 0) (+ (let ([y 1]) (g y)) (let ([y 5]) y))', '5')

	// ---- rest parameters -----------------------------------------------
	s.check('rest collects', '(define (f a . r) r) (f 1 2 3)', '(2 3)')
	s.check('rest may be empty', '(define (f a . r) r) (f 1)', '()')
	s.check('rest alone', '(define (f . r) r) (f 1 2 3)', '(1 2 3)')
	s.check('rest in a lambda', '((fn [a . r] r) 1 2 3)', '(2 3)')
	s.check('rest in a let-bound lambda', '(let ([f (fn (a . r) (list a r))]) (f 1 2 3))', '(1 (2 3))')
	// The rest list is a real list, so it composes with the rest of the library.
	s.check('rest is a list', '(define (f . r) (cdr r)) (f 1 2 3)', '(2 3)')
	// `rest` is an ordinary name unless a dot introduces it. A magic-name
	// implementation makes this function silently variadic.
	s.check('rest as a plain name', '(define (g rest) rest) (g 7)', '7')
	s.check_err('rest as a plain name is still fixed-arity', '(define (g rest) rest) (g 7 8)', 'expected 1 argument')
	s.check_err('too few arguments for a rest function', '(define (f a b . r) r) (f 1)', 'expected at least 2')
	s.check_err('duplicate parameter', '(define (f a a) a)', 'named twice')
	s.check_err('dot must be last', '(define (f a . b c) b)', 'last parameter')
	s.check_err('non-symbol parameter', '(define (f 1) f)', 'not a name')

	// ---- tail position -------------------------------------------------
	// Every binding form has to leave the closing form in tail position, or the
	// loop below stops being a loop. kont=0 is asserted by `check`.
	s.check('loop in a let body',
		'(define (cd n acc) (if (= n 0) acc (let ([m (- n 1)]) (cd m (+ acc 1)))))
		 (cd 100000 0)', '100000')
	s.check('loop in a let* body',
		'(define (cd n acc) (if (= n 0) acc (let* ([m (- n 1)]) (cd m (+ acc 1)))))
		 (cd 50000 0)', '50000')
	s.check('loop in a letrec body',
		'(define (cd n acc) (if (= n 0) acc (letrec ([m (- n 1)]) (cd m (+ acc 1)))))
		 (cd 50000 0)', '50000')
	s.check('loop with a rest function',
		'(define (cd n . r) (if (= n 0) (car r) (cd (- n 1) (+ (car r) 1))))
		 (cd 100000 0)', '100000')

	// ---- other binding-form failures are errors, not panics -------------
	// An embedded interpreter that kills the host on bad input is not
	// embeddable, so every one of these has to come back as an error value.
	s.check_err('apply a non-function', '(5 1)', 'not a function')
	s.check_err('apply a keyword to nothing', '(:a)', '1 argument')
	s.check_err('look a key up in an integer', '(1 :a)', 'not a function')
	s.check_err('set an unbound name', '(set! nope 1)', 'unbound identifier')
	s.check_err('dotimes without a symbol', '(dotimes 3 (print 1))', 'symbol as its loop variable')
	s.check_err('unbound identifier', '(nope 1)', 'unbound identifier')
	s.check_err('a binding value sees the enclosing scope, not the new one',
		'(let ([a 1] [b (a 2)]) b)', 'unbound identifier: a')

	// ---- (error ...) raises an error VALUE, it does not panic ----------
	// `(panic "x")`-style input used to unwind through the embedding host and
	// kill it. Every one of these has to come back as an `err` the caller can
	// inspect, which is the whole gate on "errors become values".
	// `error` BUILDS an error value; `raise` throws one. They are separate because
	// `(raise (error "area: unknown shape ~a" shape))` reads as one expression.
	// `error` used to abort on the spot, which made `raise` unreachable.
	s.check('error builds a value', '(error "boom")', '(err "boom")')
	s.check_err('raise raises', '(raise (error "boom"))', 'boom')
	s.check('format inside error', '(error "at ~a" 99)', '(err "at 99")')
	s.check_err('unknown primitive', '(nope 1)', 'unbound identifier')
	s.check_err('car of an integer', '(car 1)', 'expects a pair')
	s.check_err('vector-ref out of range', '(vector-ref [1 2] 9)', 'out of range')
	s.check_err('division by zero', '(/ 1 0)', 'division by zero')
	s.check_err('compare incompatible', '(< 1 "a")', 'cannot compare')
	s.check_err('add a string', '(+ 1 "a")', 'expects an integer')

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		return
	}
	println('binding forms: all checks passed')
}
