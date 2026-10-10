#!/usr/bin/env -S v run

import net.http
import os
import time

fn main() {
	build := os.execute('v -cc gcc -o server.exe server.v')
	if build.exit_code != 0 {
		eprintln(build.output)
		exit(1)
	}
	println('build ok')

	exe := os.join_path(os.getwd(), 'server.exe')
	mut p := os.new_process(exe)
	t := spawn p.run()
	time.sleep(3 * time.second)

	mut fails := 0

	resp := http.post_form('http://localhost:8080/api/run', {
		'code': '(print "hello, world")'
	}) or {
		eprintln('api/run unreachable: ${err.msg()}')
		p.signal_kill()
		t.wait()
		exit(1)
	}
	if resp.body.contains('hello, world') && resp.body.contains('"ran":true') {
		println('api/run ok: ${resp.body}')
	} else {
		eprintln('api/run BAD: ${resp.body}')
		fails++
	}

	page := http.get('http://localhost:8080/playground.html') or {
		eprintln('playground.html unreachable: ${err.msg()}')
		p.signal_kill()
		t.wait()
		exit(1)
	}
	if page.status_code == 200 && page.body.contains('blip playground') {
		println('playground.html ok: ${page.body.len} bytes')
	} else {
		eprintln('playground.html BAD: status=${page.status_code}')
		fails++
	}

	bad := http.post_form('http://localhost:8080/api/run', {
		'code': '(car 1)'
	}) or {
		eprintln('api/run error case unreachable: ${err.msg()}')
		p.signal_kill()
		t.wait()
		exit(1)
	}
	if bad.body.contains('car expects a pair') {
		println('error case ok: ${bad.body}')
	} else {
		eprintln('error case BAD: ${bad.body}')
		fails++
	}

	p.signal_kill()
	t.wait()
	if fails > 0 {
		exit(1)
	}
	println('playground: all checks passed')
}
