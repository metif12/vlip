module main

/* Non-tail calls, and the environment bug that hid inside one.
 *
 * `Kont` once had no environment field, so after a call returned, the machine
 * kept evaluating the remaining arguments in the CALLEE's frame. Every tail-call
 * test passed anyway, because a tail call never returns to a frame that still
 * has an argument left to evaluate. The tell was that one nested call per
 * operator position was fine and two were not:
 *
 *   (+ (fib (- n 1)) (fib (- n 2)))
 *
 * evaluated (- n 2) with n taken from fib's own frame, so (fib 2) was 0 and
 * (fib 10) was 55 - off by a sign on the subtraction. These cases exist so that
 * regression cannot come back unnoticed.
 */

import vlib.vlip
import vlib.vlip.machine
import vlib.vlip.printer
import vlib.vlip.reader

fn check(label string, src string, expected string) {
	res := reader.read_all(src)
	if res.diags.len > 0 {
		println('FAIL ${label}: ${res.diags.len} read errors')
		return
	}
	mut m := machine.new_machine(&res.arena)
	got := m.run(res.forms) or {
		println('FAIL ${label}: ${err.msg()}')
		return
	}
	text := printer.write(got)
	if text == expected {
		println('ok   ${label} => ${text}  (kont=${m.kstack.len})')
	} else {
		println('FAIL ${label}: expected ${expected}, got ${text}')
	}
}

const fib = '(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))'

fn main() {
	check('nested one-arg', '(define (g n) (if (< n 1) 0 (+ 1 (g (- n 1)))))(g 5)', '5')
	check('nested two-args', fib + '(fib 2)', '1')
	check('nested three-args', fib + '(fib 3)', '2')
	check('nested five-args', fib + '(fib 5)', '5')
	check('nested ten-args', fib + '(fib 10)', '55')
	check('nested twenty-args', fib + '(fib 20)', '6765')

	// The two shapes that proved it was an environment bug and not an argument
	// counting bug: same number of nested calls, different nesting.
	check('sibling independent', '(define (a) 1)(define (b) 2)(+ (a) (b))', '3')
	check('sibling shadowing', '(define (a n) n)(+ (a 1) (a 2))', '3')

	// An argument must be evaluated in the CALLER's scope even when an earlier
	// sibling left a frame behind.
	check('arg in caller scope', '(define x 10)(define (f) 99)(+ x (f))', '109')
	check('arg after shadow', '(define x 10)(define (f x) x)(let ([x 1]) (+ (f 5) x))', '6')
}