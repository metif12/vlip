module main

import vlib.vlip
import vlib.vlip.machine
import vlib.vlip.printer
import vlib.vlip.reader

fn check(label string, src string, want string) {
	res := reader.read_all(src)
	if res.diags.len > 0 {
		println('FAIL ${label}: read')
		return
	}
	mut m := machine.new_machine(&res.arena)
	v := m.run(res.forms) or {
		println('FAIL ${label}: ${err.msg()}')
		return
	}
	got := printer.write(v)
	if got == want {
		println('ok   ${label} => ${got}  kont=${m.kstack.len}')
	} else {
		println('FAIL ${label}: want ${want}, got ${got}')
	}
}

fn main() {
	check('loop-never', '(loop i 0 #f 7)', 'nil')
	check('loop-sum', '(define s 0)(loop i 0 (< i 5) (set! s (+ s i))) s', '10')
	check('loop-outer-set', '(define s 0)(loop i 0 (< i 5) (set! s (+ s i))) s', '10')
	check('loop-big', '(define s 0)(loop i 0 (< i 20000) (set! s (+ s i))) s', '199990000')
	check('dotimes', '(define s 0)(dotimes i 5 (set! s (+ s i))) s', '10')
	check('letrec', '(letrec ([e (lambda (n) (if (= n 0) #t (o (- n 1))))] [o (lambda (n) (if (= n 0) #f (e (- n 1))))]) (e 10))', '#t')
	check('letrec-shadow', '(letrec ([x 1]) (let ([x 2]) x))', '2')
	check('letrec-no-leak', '(define x 9)(letrec ([x 1]) x)', '1')
}