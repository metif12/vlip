module main

/* The M3 gate: proper tail calls.
 *
 * These are the properties the whole design rests on. Applying a closure must
 * NOT push a continuation frame, so a tail call -- including MUTUAL recursion --
 * is a loop iteration rather than a stack mutation. Steel needs a separate
 * TCOJMP opcode for this and still ships SELFTAILCALLNOARITY.
 *
 * Every depth here is large enough that a machine without real TCO would either
 * overflow or grow its continuation stack visibly.
 */

import time
import os
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
		println('ok   ${label} => ${text}  (steps=${m.steps}, kont=${m.kstack.len})')
	} else {
		println('FAIL ${label}: expected ${expected}, got ${text}')
	}
}

fn main() {
	// 1. self tail call, 1,000,000 deep
	check('self tail call 1e6', '
		(define (cd n acc)
		  (if (= n 0) acc (cd (- n 1) (+ acc 1))))
		(cd 1000000 0)', '1000000')

	// 2. MUTUAL tail recursion. This is what separates a real trampoline from
	//    the cheaper hack of only special-casing self-calls.
	check('mutual tail call 2e4', '
		(define (ping n) (if (= n 0) (quote pong) (pong (- n 1))))
		(define (pong n) (if (= n 0) (quote ping) (ping (- n 1))))
		(ping 20000)', 'pong')

	// 3. tail position in a derived form (cond desugars to nested ifs)
	check('tail in cond 1e5', '
		(define (cd n acc)
		  (cond [(= n 0) acc]
		        [else (cd (- n 1) (+ acc 1))]))
		(cd 100000 0)', '100000')

	// 4. tail position in a let body
	check('tail in let', '
		(define (cd n acc)
		  (if (= n 0) acc (let ([m (- n 1)]) (cd m (+ acc 1)))))
		(cd 50000 0)', '50000')

	// 5. non-tail recursion still works
	check('non-tail fib', '
		(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
		(fib 20)', '6765')

	// 6. derived forms give the right answers
	check('when', '(when #t 1)', '1')
	check('when-false', '(when #f 1)', 'nil')
	check('unless', '(unless #f 2)', '2')
	check('cond-arrow', '(cond [(= 1 2) => (fn [] 0)] [else 7])', '7')
	check('case', '(case 5 [(1 2) 10] [(4 5 6) 20] [else 30])', '20')
	check('loop', '(loop i 0 (< i 5) (print i)) 7', '7')
	check('dotimes', '(dotimes i 3 (print i)) 8', '8')
	check('and-short', '(and 1 #f 3)', '#f')
	check('and-value', '(and 1 2 3)', '3')
	check('or-value', "(or #f #f 7)", '7')
	check('let*', '(let* ([a 1] [b (+ a 1)]) b)', '2')
	check('letrec', '(letrec ([e (lambda (n) (if (= n 0) #t (o (- n 1))))] [o (lambda (n) (if (= n 0) #f (e (- n 1))))]) (e 10))', '#t')
	check('rest-param', '(define (f a . r) r)(f 1 2 3)', '(2 3)')
	check('table-callable', '(:a {:a 1})', '1')
	check('tail-in-or', '
		(define (find n)
		  (or (and (= n 3) n) (if (> n 0) (find (- n 1)) 0)))
		(find 20000)', '3')

	// 7. deep non-tail recursion must fail loudly, never silently corrupt
	res := reader.read_all('(define (f n) (+ 1 (f n)))(f 10000000)')
	mut m := machine.new_machine(&res.arena)
	m.run(res.forms) or {
		println('ok   deep non-tail rejected: ${err.msg()}')
		return
	}
	println('FAIL deep non-tail recursion was NOT rejected')
}
