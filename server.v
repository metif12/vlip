module main

import veb
import vlib.blip.machine
import vlib.blip.host

struct App {
	veb.StaticHandler
}

struct Context {
	veb.Context
}

struct RunResponse {
pub:
	output string @[json: 'output']
	error  string @[json: 'error']
	ran    bool   @[json: 'ran']
}

const max_body_bytes = 256 * 1024

fn main() {
	mut app := &App{}
	app.static_mime_types['.ps1'] = 'text/plain'
	app.static_mime_types['.sh'] = 'text/plain'
	app.handle_static('site', true) or { eprintln('static: ${err.msg()}') }
	veb.run[App, Context](mut app, 8080)
}

@[get]
pub fn (mut app App) index(mut ctx Context) veb.Result {
	return ctx.redirect('/playground.html', typ: .found)
}

@['/api/run'; post]
pub fn (mut app App) api_run(mut ctx Context) veb.Result {
	if reason := too_big(&ctx.Context) {
		return ctx.json(RunResponse{
			error: reason
		})
	}

	code := ctx.form['code'] or { '' }
	mut h := host.new_capture()
	mut m := machine.new_standalone(h)
	m.src_text = code
	m.run_str(code) or {
		return ctx.json(RunResponse{
			output: h.lines().join('\n'),
			error:  err.msg(),
			ran:    false,
		})
	}
	return ctx.json(RunResponse{
		output: h.lines().join('\n'),
		ran:    true,
	})
}

fn too_big(ctx &veb.Context) ?string {
	length := (ctx.get_header(.content_length) or { '0' }).int()
	if length > max_body_bytes {
		return 'That request is too large.'
	}
	return none
}
