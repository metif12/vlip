module lsp

import json2
import os
import vlib.blip.reader

pub struct Position {
pub:
	line      int
	character int
}

pub struct Range {
pub:
	start Position
	end   Position
}

pub struct LspDiagnostic {
pub:
	range    Range
	message  string
	severity int
	source   string
}

pub struct PublishDiagnosticsParams {
pub:
	uri         string
	diagnostics []LspDiagnostic
}

struct PublishNotification {
	jsonrpc string = '2.0'
	method  string = 'textDocument/publishDiagnostics'
	params  PublishDiagnosticsParams
}

struct Incoming {
	method string
	params string
}

struct DidOpenDoc {
	uri         string
	text        string
	language_id ?string @[json: 'languageId']
	version     ?i64
}

struct DidOpenParams {
	text_document DidOpenDoc @[json: 'textDocument']
}

struct VersionedId {
	uri     string
	version ?i64
}

struct ContentChange {
	text         string
	range        ?string
	range_length ?i64 @[json: 'rangeLength']
}

struct DidChangeParams {
	text_document   VersionedId     @[json: 'textDocument']
	content_changes []ContentChange @[json: 'contentChanges']
}

struct UriOnly {
	uri string
}

struct DidCloseParams {
	text_document UriOnly @[json: 'textDocument']
}

struct DidSaveDoc {
	uri string
}

struct DidSaveParams {
	text_document DidSaveDoc @[json: 'textDocument']
	text          ?string
}

pub struct Server {
mut:
	open_files          map[string]string
	capture_output      bool
	captured_output     []string
	is_shutdown         bool
	received_initialize bool
	current_raw_id      string
}

pub fn new_test_server() Server {
	return Server{
		open_files:     map[string]string{}
		capture_output: true
	}
}

pub fn diagnose(src string) []LspDiagnostic {
	res := reader.read_all(src)
	mut out := []LspDiagnostic{}
	for d in res.diags {
		line := if d.line - 1 > 0 { d.line - 1 } else { 0 }
		ch := if d.col - 1 > 0 { d.col - 1 } else { 0 }
		out << LspDiagnostic{
			range:    Range{
				start: Position{
					line:      line
					character: ch
				}
				end:   Position{
					line:      line
					character: ch + 1
				}
			}
			message:  d.msg
			severity: 1
			source:   'blip'
		}
	}
	return out
}

pub fn (mut s Server) captured() []string {
	return s.captured_output
}

fn (mut s Server) send_framed(content string) {
	msg := 'Content-Length: ${content.len}\r\n\r\n${content}'
	if s.capture_output {
		s.captured_output << msg
		return
	}
	print(msg)
	flush_stdout()
}

fn (mut s Server) send_result(raw_id string, result_json string) {
	s.send_framed('{"jsonrpc":"2.0","id":${raw_id},"result":${result_json}}')
}

fn (mut s Server) send_error(raw_id string, code int, message string) {
	id := if raw_id == '' { 'null' } else { raw_id }
	s.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":${code},"message":${json2.encode(message)}}}')
}

fn (mut s Server) publish(uri string, diags []LspDiagnostic) {
	n := PublishNotification{
		params: PublishDiagnosticsParams{
			uri:         uri
			diagnostics: diags
		}
	}
	s.send_framed(json2.encode(n))
}

fn extract_raw_id(content string) ?string {
	key := '"id"'
	idx := content.index(key) or { return none }
	mut i := idx + key.len
	for i < content.len && (content[i] == ` ` || content[i] == `\t` || content[i] == `\n` || content[i] == `\r` || content[i] == `:`) {
		i++
	}
	if i >= content.len {
		return none
	}
	if content[i] == `"` {
		mut j := i + 1
		for j < content.len {
			if content[j] == `\\` {
				j += 2
				continue
			}
			if content[j] == `"` {
				return content[i..j + 1]
			}
			j++
		}
		return none
	}
	mut j := i
	for j < content.len && content[j] != `,` && content[j] != `}` && content[j] != ` ` && content[j] != `\t` && content[j] != `\n` && content[j] != `\r` {
		j++
	}
	tok := content[i..j].trim_space()
	if tok == '' {
		return none
	}
	return tok
}

pub fn (mut s Server) handle(content string) bool {
	msg := json2.decode[Incoming](content) or { return false }
	method := msg.method
	raw := extract_raw_id(content) or { '' }
	s.current_raw_id = raw
	has_id := raw != ''
	if s.is_shutdown {
		if method == 'exit' {
			return true
		}
		if has_id {
			s.send_error(raw, -32600, 'Server has been shut down')
		}
		return false
	}
	if method == 'exit' {
		return true
	}
	if method == 'shutdown' {
		s.is_shutdown = true
		if has_id {
			s.send_result(raw, 'null')
		}
		return false
	}
	if !s.received_initialize && method != 'initialize' {
		if has_id {
			s.send_error(raw, -32002, 'Server not yet initialized')
		}
		return false
	}
	if method == 'initialize' {
		if s.received_initialize {
			if has_id {
				s.send_error(raw, -32600, 'Server already initialized')
			}
			return false
		}
		s.received_initialize = true
		if has_id {
			s.send_result(raw, '{"capabilities":{"textDocumentSync":{"openClose":true,"change":1}}}')
		}
		return false
	}
	if method == 'initialized' {
		return false
	}
	if method == '$/setTrace' || method == '$/cancelRequest' {
		return false
	}
	if method == 'textDocument/didOpen' {
		p := json2.decode[DidOpenParams](msg.params) or { return false }
		s.open_files[p.text_document.uri] = p.text_document.text
		s.publish(p.text_document.uri, diagnose(p.text_document.text))
		return false
	}
	if method == 'textDocument/didChange' {
		p := json2.decode[DidChangeParams](msg.params) or { return false }
		if p.content_changes.len > 0 {
			text := p.content_changes.last().text
			s.open_files[p.text_document.uri] = text
			s.publish(p.text_document.uri, diagnose(text))
		}
		return false
	}
	if method == 'textDocument/didClose' {
		p := json2.decode[DidCloseParams](msg.params) or { return false }
		s.open_files.delete(p.text_document.uri)
		s.publish(p.text_document.uri, []LspDiagnostic{})
		return false
	}
	if method == 'textDocument/didSave' {
		p := json2.decode[DidSaveParams](msg.params) or { return false }
		if t := s.open_files[p.text_document.uri] {
			s.publish(p.text_document.uri, diagnose(t))
		} else if txt := p.text {
			s.publish(p.text_document.uri, diagnose(txt))
		}
		return false
	}
	if has_id {
		s.send_error(raw, -32601, 'Method not found: ${method}')
	}
	return false
}

struct StdinReader {
	fd int
mut:
	buf []u8
	off int
	len int
}

fn (mut r StdinReader) fill() bool {
	if r.buf.len == 0 {
		r.buf = []u8{len: 65536}
	}
	data, n := os.fd_read(r.fd, r.buf.len)
	if n <= 0 {
		return false
	}
	r.len = n
	r.off = 0
	for i in 0 .. n {
		r.buf[i] = data[i]
	}
	return true
}

fn (mut r StdinReader) read_byte() ?u8 {
	if r.off >= r.len {
		if !r.fill() {
			return none
		}
	}
	b := r.buf[r.off]
	r.off++
	return b
}

fn (mut r StdinReader) read_line() ?string {
	mut out := []u8{}
	for {
		b := r.read_byte() or { return none }
		if b == `\n` {
			break
		}
		out << b
	}
	mut s := out.bytestr()
	if s.ends_with('\r') {
		s = s[..s.len - 1]
	}
	return s
}

fn (mut r StdinReader) read_exact(n int) ?string {
	mut out := []u8{cap: n}
	for out.len < n {
		if r.off >= r.len {
			if !r.fill() {
				return none
			}
		}
		need := n - out.len
		avail := r.len - r.off
		take := if need < avail { need } else { avail }
		out << r.buf[r.off..r.off + take]
		r.off += take
	}
	return out.bytestr()
}

fn read_request(mut r StdinReader) ?string {
	mut length := -1
	for {
		line := r.read_line() or { return none }
		t := line.trim_space()
		if t == '' {
			break
		}
		low := t.to_lower()
		if low.starts_with('content-length:') {
			length = t.all_after(':').trim_space().int()
		}
	}
	if length < 0 {
		return ''
	}
	return r.read_exact(length)
}

pub fn serve() {
	mut s := Server{
		open_files: map[string]string{}
	}
	mut r := StdinReader{
		fd: 0
	}
	for {
		content := read_request(mut r) or { break }
		if content == '' {
			continue
		}
		if s.handle(content) {
			break
		}
	}
}
