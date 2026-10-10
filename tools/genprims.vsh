#!/usr/bin/env -S v run

// tools/genprims.vsh -- generate blip primitives from vlib signatures.
//
// Reads `v ast -p` JSON for allowlisted (module, file, fn) triples,
// classifies each signature, and emits vlib/blip/prims/gen_<module>.v with
// wrapper prims plus a register_gen_<module> function. One hand-written line
// per module wires it into the table in vlib/blip/prims/mod.v.
//
// This runs on every V sync (docs/010-roadmap.md 7.1) and in CI with
// --check: an upstream rename, reorganization, or signature change fails
// loudly instead of shipping a stale binding.
//
// Design rules, all load-bearing:
//
//   * Allowlist, not bulk import. `v ast` reports no visibility, so "all pub
//     fns" is unimplementable from its JSON; curation also keeps the prim
//     table reviewable and collision-free. New upstream fns surface in the
//     "convertible but not allowlisted" report for a human to bless.
//   * Only exact, total mappings generate. Narrowing (f32), options,
//     results, and collections are recognized and reported as deferred, not
//     silently emitted; everything else is unsupported. The pilot stays on
//     proven paths, and untested template branches do not ship.
//   * Generated files are never hand-edited. The header says how to regen,
//     and --check enforces that the checked-in copy matches.

import json2
import os
import strings

// ------------------------------------------------------------------ config

// GenTarget is one vlib module to bind: the files to read (explicit, so an
// upstream reorganization fails here with a filename instead of silently
// binding nothing) and the function names to take from them.
struct GenTarget {
	module string
	files  []string
	fns    []string
}

const allowlist = [
	GenTarget{
		module: 'math'
		files:  ['floor.v', 'sin.v', 'log.v', 'exp.v', 'factorial.v']
		fns:    ['floor', 'sin', 'cos', 'log', 'log10', 'log2', 'factorial', 'exp']
	},
]

const int_types = ['i8', 'i16', 'int', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64', 'byte',
	'isize', 'usize']

// ------------------------------------------------------------------ ast

struct Param {
	name   string
	typ    string
	is_mut bool
}

struct Sig {
	name string
	ret  string
mut:
	params []Param
}

fn node_map(n json2.Any) map[string]json2.Any {
	return n.as_map()
}

fn child_list(n json2.Any) []json2.Any {
	m := node_map(n)
	return (m['children'] or { json2.Any('') }).as_array()
}

fn field_str(n json2.Any, field string) string {
	m := node_map(n)
	return (m[field] or { json2.Any('') }).str()
}

fn field_bool(n json2.Any, field string) bool {
	m := node_map(n)
	return (m[field] or { json2.Any(false) }).bool()
}

// collect_sigs returns every fn_decl in one `v ast -p` document: name,
// params in order, return type string. Bodies are ignored by construction --
// only `param` children are read.
fn collect_sigs(doc json2.Any) []Sig {
	mut out := []Sig{}
	files := (doc.as_map()['files'] or { json2.Any('') }).as_array()
	for f in files {
		for node in child_list(f) {
			if field_str(node, 'kind') != 'fn_decl' {
				continue
			}
			mut s := Sig{
				name: field_str(node, 'value')
				ret:  field_str(node, 'type')
				params: []
			}
			for c in child_list(node) {
				if field_str(c, 'kind') != 'param' {
					continue
				}
				s.params << Param{
					name:   field_str(c, 'value')
					typ:    field_str(c, 'type')
					is_mut: field_bool(c, 'is_mut')
				}
			}
			out << s
		}
	}
	return out
}

// ------------------------------------------------------------------ classify

// param_class is '' when the parameter maps exactly, else the skip reason.
fn param_class(t string) string {
	if t in int_types {
		return ''
	}
	if t == 'f64' || t == 'string' {
		return ''
	}
	if t == 'bool' {
		return 'deferred: bool params need a tag check nobody has reviewed'
	}
	if t == 'f32' {
		return 'deferred: f32 params narrow f64 silently'
	}
	if t.starts_with('?') || t.starts_with('!') || t.starts_with('[') || t.starts_with('map[') {
		return 'deferred: option/result/collection params'
	}
	return 'unsupported type: ${t}'
}

// ret_class is '' when the return maps exactly, else the skip reason.
fn ret_class(t string) string {
	if t == '' || t == 'void' {
		return ''
	}
	if t in int_types {
		return ''
	}
	if t == 'f64' || t == 'string' || t == 'bool' {
		return ''
	}
	if t == 'f32' {
		return 'deferred: f32 return widens, unreviewed'
	}
	if t.starts_with('?') || t.starts_with('!') || t.starts_with('[') || t.starts_with('map[') {
		return 'deferred: option/result/collection returns'
	}
	return 'unsupported type: ${t}'
}

// ------------------------------------------------------------------ emit

fn kebab(s string) string {
	return s.replace('_', '-')
}

// extract lines emit the argument conversions; call_args are the converted
// variable names to pass to the V call.
fn extract_lines(pname string, params []Param) (string, string) {
	mut decls := strings.new_builder(256)
	mut call_args := []string{}
	mut i := 0
	for p in params {
		v := 'a${i}'
		if p.typ == 'f64' {
			decls.write_string("\t${v} := as_f64(args[${i}]) or { return error('${pname} expects a number, got \${printer.write(args[${i}])}') }\n")
			call_args << v
		} else if p.typ in int_types {
			decls.write_string("\ta${i} := need_int('${pname}', args[${i}])!\n")
			call_args << '${p.typ}(${v})'
		} else {
			decls.write_string("\t${v} := need_str('${pname}', args[${i}])!\n")
			call_args << v
		}
		i++
	}
	return decls.str(), call_args.join(', ')
}

fn return_lines(ret string, call string) string {
	if ret == '' || ret == 'void' {
		return '\t${call}\n\treturn blip.nil_value()'
	}
	if ret == 'f64' {
		return '\treturn blip.float(${call})'
	}
	if ret in int_types {
		return '\treturn blip.integer(i64(${call}))'
	}
	if ret == 'string' {
		return '\treturn blip.string(${call})'
	}
	return '\treturn blip.boolean(${call})'
}

struct Emitted {
	pname    string
	vname    string
	sig_text string
	body     string
}

fn emit_fn(module string, s Sig) Emitted {
	pname := '${module}-' + kebab(s.name)
	decls, cargs := extract_lines(pname, s.params)
	call := '${module}.${s.name}(${cargs})'
	mut sb := strings.new_builder(512)
	sb.write_string('// ${pname} wraps ${module}.${s.name}(${param_text(s)}) ${s.ret}.\n')
	sb.write_string('fn prim_gen_${module}_${s.name}(args []blip.Value) !blip.Value {\n')
	sb.write_string("\tif args.len != ${s.params.len} {\n")
	sb.write_string("\t\treturn error('${pname} expects ${s.params.len} argument(s), got \${args.len}')\n")
	sb.write_string('\t}\n')
	sb.write_string(decls)
	sb.write_string(return_lines(s.ret, call) + '\n')
	sb.write_string('}\n')
	return Emitted{
		pname:    pname
		vname:    s.name
		sig_text: '${module}.${s.name}(${param_text(s)}) ${s.ret}'
		body:     sb.str()
	}
}

fn param_text(s Sig) string {
	mut parts := []string{}
	for p in s.params {
		parts << '${p.name} ${p.typ}'
	}
	return parts.join(', ')
}

// ------------------------------------------------------------------ driver

fn vlib_dir() string {
	// `v` on PATH is often a `.bat` wrapper one level below the real tree,
	// so walk up from every candidate until a dir holding `vlib` is found.
	mut cands := []string{}
	vexe := os.find_abs_path_of_executable('v') or { '' }
	if vexe != '' {
		cands << os.dir(vexe)
	}
	from_env := os.getenv('VEXE')
	if from_env != '' {
		cands << os.dir(from_env)
	}
	for c in cands {
		mut d := c
		for _ in 0 .. 4 {
			cand := os.join_path(d, 'vlib')
			if os.is_dir(cand) {
				return cand
			}
			d = os.dir(d)
		}
	}
	eprintln('genprims: no vlib found near `${vexe}`; set VEXE')
	exit(1)
}

fn v_version() string {
	r := os.execute('v version')
	if r.exit_code != 0 {
		return 'unknown'
	}
	return r.output.trim_space()
}

// existing_prims text-scans the hand-written table for registered names, so
// a generated name can never shadow one silently.
fn existing_prims() []string {
	mut out := []string{}
	files := os.ls('vlib/blip/prims') or { return out }
	for f in files {
		if !f.ends_with('.v') || f.starts_with('gen_') {
			continue
		}
		body := os.read_file(os.join_path('vlib/blip/prims', f)) or { continue }
		for line in body.split_into_lines() {
			trimmed := line.trim_space()
			if trimmed.starts_with("p['") {
				name := trimmed.all_after("p['").all_before("']")
				if name != '' {
					out << name
				}
			}
		}
	}
	return out
}

fn is_pub(source string, name string) bool {
	short := name.all_after_last('.')
	return source.contains('pub fn ${short}(') || source.contains('pub fn ${short}[')
}

fn main() {
	check_only := '--check' in os.args
	mut only_module := ''
	mut ai := 0
	for ai < os.args.len {
		if os.args[ai] == '--module' && ai + 1 < os.args.len {
			only_module = os.args[ai + 1]
		}
		ai++
	}
	vlib := vlib_dir()
	ver := v_version()
	known := existing_prims()
	mut fails := 0
	mut generated := map[string]string{}

	for target in allowlist {
		if only_module != '' && target.module != only_module {
			continue
		}
		mut sigs := map[string]Sig{}
		mut dupes := []string{}
		for file in target.files {
			path := os.join_path(vlib, target.module) + os.path_separator + file
			r := os.execute('v ast -p ${path}')
			if r.exit_code != 0 {
				eprintln('genprims: v ast failed on ${target.module}/${file}:')
				eprintln(r.output)
				eprintln('genprims: file moved upstream? update the allowlist files')
				fails++
				continue
			}
			doc := json2.decode[json2.Any](r.output) or {
				eprintln('genprims: bad ast json for ${path}: ${err.msg()}')
				fails++
				continue
			}
			for s in collect_sigs(doc) {
				if s.name in sigs {
					dupes << s.name
					continue
				}
				sigs[s.name] = s
			}
		}
		for d in dupes {
			eprintln('genprims: ${target.module}.${d} defined twice in the listed files; disambiguate the file list')
			fails++
		}
		mut fns := []Emitted{}
		mut skipped := []string{}
		mut missing := []string{}
		for want in target.fns {
			if want !in sigs {
				missing << want
				continue
			}
			s := sigs[want]
			if s.name.contains('.') {
				skipped << '${want}: method, needs a receiver blip cannot name'
				continue
			}
			if s.params.any(it.is_mut) {
				skipped << '${want}: mut params mutate the caller, unmappable'
				continue
			}
			mut reason := ''
			for p in s.params {
				reason = param_class(p.typ)
				if reason != '' {
					break
				}
			}
			if reason == '' {
				reason = ret_class(s.ret)
			}
			if reason != '' {
				skipped << '${want}: ${reason}'
				continue
			}
			// Visibility is textual: the AST reports no pub flag, so the
			// source itself is asked below. A private fn compiles nowhere
			// as math.name from another module.
			fns << emit_fn(target.module, s)
		}
		// pub + collision checks need file sources; re-read cheaply.
		mut pub_src := ''
		for file in target.files {
			pub_src += os.read_file(os.join_path(vlib, target.module) + os.path_separator + file) or {
				''
			}
		}
		mut kept := []Emitted{}
		for e in fns {
			if !is_pub(pub_src, e.vname) {
				eprintln('genprims: ${target.module}.${e.vname} is not pub upstream; drop it from the allowlist')
				fails++
				continue
			}
			if e.pname in known {
				eprintln('genprims: ${e.pname} collides with a hand-written prim; rename or drop it')
				fails++
				continue
			}
			kept << e
		}
		kept.sort_with_compare(fn (a &Emitted, b &Emitted) int {
			if a.pname < b.pname {
				return -1
			}
			if a.pname > b.pname {
				return 1
			}
			return 0
		})
		mut sb := strings.new_builder(4096)
		sb.write_string('// Code generated by tools/genprims.vsh from vlib/${target.module} at ${ver}.\n')
		sb.write_string('// DO NOT EDIT: rerun `v run tools/genprims.vsh` instead.\n')
		sb.write_string('// Wired into the table by one line in table(): register_gen_${target.module}(mut p).\n')
		sb.write_string('module prims\n\nimport math\nimport vlib.blip\nimport vlib.blip.printer\n\n')
		for e in kept {
			sb.write_string(e.body + '\n')
		}
		sb.write_string('fn register_gen_${target.module}(mut p map[string]blip.PrimFn) {\n')
		for e in kept {
			sb.write_string("\tp['${e.pname}'] = prim_gen_${target.module}_${e.vname}\n")
		}
		sb.write_string('}\n')
		generated['vlib/blip/prims/gen_${target.module}.v'] = sb.str()

		println('== ${target.module}: ${kept.len} prims, ${skipped.len} skipped, ${missing.len} missing')
		for e in kept {
			println('   + ${e.pname}  (${e.sig_text})')
		}
		for s in skipped {
			println('   - ${s}')
		}
		for m in missing {
			eprintln('genprims: ${target.module}.${m} not found in the AST; renamed upstream?')
			fails++
		}
		// Curation aid: convertible fns nobody allowlisted, so the sync
		// review sees what upstream added.
		mut unlisted := []string{}
		for name, s in sigs {
			if name in target.fns || name.contains('.') {
				continue
			}
			mut ok := true
			for p in s.params {
				if p.is_mut || param_class(p.typ) != '' {
					ok = false
					break
				}
			}
			if ok && ret_class(s.ret) == '' {
				unlisted << '${name}(${param_text(s)}) ${s.ret}'
			}
		}
		unlisted.sort()
		for u in unlisted {
			println('   ? convertible but not allowlisted: ${u}')
		}
	}

	if fails > 0 {
		exit(1)
	}
	// Stale files: a generated module dropped from the allowlist must not
	// linger, or --check would bless a ghost.
	mut stale := []string{}
	for f in os.ls('vlib/blip/prims') or { []string{} } {
		if f.starts_with('gen_') && f.ends_with('.v') {
			if 'vlib/blip/prims/${f}' !in generated {
				stale << f
			}
		}
	}
	if check_only {
		mut dirty := false
		for path, body in generated {
			cur := os.read_file(path) or {
				eprintln('genprims --check: missing ${path}; rerun without --check')
				dirty = true
				continue
			}
			// Line endings are not content: a CRLF checkout on Windows and
			// an LF one on Linux must both pass against the same output.
			if cur.replace('\r\n', '\n') != body {
				eprintln('genprims --check: stale ${path}; rerun without --check and review the diff')
				dirty = true
			}
		}
		for f in stale {
			eprintln('genprims --check: stale generated file vlib/blip/prims/${f}; remove it')
			dirty = true
		}
		if dirty {
			exit(1)
		}
		println('genprims --check: all generated files current')
		return
	}
	for f in stale {
		os.rm('vlib/blip/prims/${f}') or {}
		println('removed stale vlib/blip/prims/${f}')
	}
	for path, body in generated {
		os.write_file(path, body) or {
			eprintln('genprims: cannot write ${path}: ${err.msg()}')
			exit(1)
		}
		println('wrote ${path}')
	}
}
