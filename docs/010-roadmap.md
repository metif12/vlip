# vlip roadmap: embedding, REPL, and the self-hosted website

Status: proposed. Written before the interpreter runs all six example programs,
so it records intent, not achievement.

## 1. Naming

The working name `vlip` is fine but reads as an abbreviation rather than a word,
and it says nothing about what the project is. Before the repository goes public
the name should be worth typing.

Recommendation: **Vlam** - V + lambda.

- Four letters, no vowel clusters, unambiguous to pronounce.
- Names the one idea the project is actually about: closures with real tail
  calls.
- `vlib/vlam`, `vlam.v`, `vlip` -> `vlam` is a mechanical rename, and doing it
  now costs one commit rather than a public rename later.

Alternatives, in order: **Vexpr** (V + expression, more descriptive, less
memorable), **Vlip** (keep, zero cost), **Vela** (prettier, says nothing about
Lisp).

The rename touches `v.mod`, `vlib/vlip/**`, `vlip.v`, `README.md`,
`docs/000-vlip-design.md`, and every `import vlib.vlip.*`. Nothing in the design
depends on the current spelling.

## 2. Embedding: can vlip be embedded, and what does it take?

Yes, and it is closer than it looks. The machine is already a library rather than
a program:

- `vlib/vlip/machine` holds no global state. Everything lives on `Machine`.
- `reader.read_all(src) !ReadResult` and `machine.run(forms) !Value` are the only
  entry points.
- `Machine.max_steps` and `Machine.max_kont` are fields, so a host can bound
  untrusted code.
- `Machine.out []string` already collects `print` output instead of writing to
  stdout, which is exactly what an embedder needs.

What is still missing, in the order it blocks real use:

1. **Stop panicking.** This is the blocker. `call_closure` panics on an arity
   mismatch, `apply_all` panics when the callee is not a function, and
   `transform_dotimes` panics on a bad loop variable. A panic unwinds through
   the host's stack and kills the host process. Every one of these must become a
   returned `MachineError`. An embedded interpreter that can take down the
   process that embedded it is not embeddable.
2. **A host interface.** vlip needs `print`, `read-line`, and `load` from its
   embedder rather than from `os`. Define
   ```v
   pub interface Host {
       host_print(s string)
       host_read_line() ?string
       host_load(path string) !string
       host_write(s string)
   }
   ```
   with `ConsoleHost` as the default. This is what makes the REPL and the tests
   possible without spawning a process.
3. **One-call evaluation.** `run_str(src string) !Value` that parses and evaluates
   in a single call, so an embedder does not have to hold an `Arena` alive.
4. **Many sources, one machine.** `use` needs to load and evaluate a file into
   the *running* machine, not a fresh one, or definitions cannot cross a module
   boundary.
5. **Host-registered primitives.** `m.prims['http-get'] = my_fn` already works
   structurally; it needs a typed wrapper and a documented contract.

### Embedding from Lua, specifically

V has no Lua binding in the standard library, so the route is the C FFI. Bind
`lua_State*`, then register one C-callable function:

```c
int vlip_eval(lua_State *L) {
    // arg 1: source string, arg 2: opaque *VlipInterp
    // push (ok, value_or_error_message) and return 2
}
```

Practical consequences to plan for:

- vlip values must cross into Lua as Lua values. Table this explicitly; the
  honest mapping is number/string/bool/nil directly, lists as Lua tables,
  closures as functions that re-enter the interpreter (with a step budget, or a
  Lua coroutine per call).
- Errors must arrive as Lua errors, not panics. This is the same fix as (1).
- The REPL's `,t` load facility becomes the embedding test: a Lua script that
  drives vlip and a vlip script that drives Lua should exercise the same
  surface.

## 3. REPL

`vlip` with no arguments starts a REPL. Without arguments is the right default:
the CLI already requires a file, so bare `vlip` is free.

Requirements:

- **One persistent machine.** Definitions must accumulate across lines, which the
  `run(forms)` shape already allows but nothing currently exercises.
- **Multi-line input.** Buffer until the paren/bracket/brace depth returns to
  zero and no reader string is open. The reader already knows how to report that
  it needs more input; expose it as a distinct "incomplete" result rather than an
  error, so the REPL can keep reading.
- **Error recovery.** A failed form must not end the session. This forces the
  no-panic rule from section 2 before the REPL is worth having.
- **Load and reload.** `,l path.lip` evaluates a file into the current machine;
  `,r` reloads the last file. This is how you iterate on a program without
  restarting.
- **History on the command line**, not in the interpreter, so it works when stdin
  is a pipe.
- **Golden tests.** The REPL must be testable without a terminal: pipe a script
  into stdin, compare stdout to a fixture. That is only possible once reading
  goes through `Host.host_read_line`.
- **A useful prompt.** Show the current namespace depth so a stuck paren is
  obvious: `vlam:1> ` becomes `vlam:2> ` while a form is open.

## 4. Real programs worth writing in vlip

Ordered by what each one proves. The point is not the program, it is the part of
the language it forces into existence.

| Program | What it forces into existence | Size |
| --- | --- | --- |
| Brainfuck interpreter | Embedding: a vlip program driving another machine | ~60 lines |
| JSON parse + emit | `Result`, error propagation, strings, recursion | ~200 lines |
| CSV to table | vectors, tables, destructuring, file I/O | ~120 lines |
| Markdown to HTML | lists, higher-order functions, string building | ~250 lines |
| Pratt parser for a toy language | `match*`, structs, mutual recursion | ~400 lines |
| Commit-message linter | real I/O, exit codes, a CLI shape worth copying | ~150 lines |
| **The vlip website generator** | the whole language plus the veb bridge | the final phase |

The Brainfuck interpreter is first on purpose: it is the smallest program that
requires the interpreter to start another interpreter, so it is the honest test
of section 2. If vlip can run a Brainfuck interpreter, it can be embedded.

The commit-message linter is on the list because it is the first program anyone
would actually install, and a language nobody runs is not a language.

## 5. Final phase: the website, written in vlip, exposing vlib so veb works

Target: the project website is generated by vlip programs, served through V's
`veb` templates and router, with vlip able to register handlers that veb routes
to. The site is then both the documentation and the proof.

The hard part is the bridge, and it should be stated precisely. `veb` is a
V-native template-and-routing library: it wants V `fn` values with V signatures.
vlip wants its own closures over `[]vlip.Value`. Two options:

1. **vlip calls veb** (easy, one direction). vlip programs get
   `veb.html.escape`, `veb.render`, and friends as primitives. The site logic is
   vlip; the templates stay `.html` files handled by veb. This gets the site
   running quickly and is the right first step.
2. **veb calls vlip** (hard, the other direction). A vlip closure becomes a veb
   handler. Requires a trampoline: keep a machine parked with a continuation that
   is waiting to receive the request value, and hand veb a V function that
   resumes it. This is real green continuations, and it is the interesting half.

Do (1) first and ship the site. Then attempt (2) behind an adapter, because (2)
is where the embedding story is actually proven: if a V HTTP server can route a
request into a vlip closure and get a response back, vlip is embedded in the
strongest sense available.

### Site structure

```
site/
  build.lip          entry point: reads content, emits pages
  content/*.md       pages, one file per route
  layout.html        veb template
  vlib/vlip/host/    the veb bridge (section 2 + option 1)
.github/workflows/pages.yml
```

The site must satisfy the same bar as the interpreter: no dead links, no
placeholder text, and every code sample on it actually run by CI. A language
site whose examples do not run is the most common way a language project dies.

## 6. Ordering

1. No panics anywhere; errors are values.
2. `Host` interface, `run_str`, multi-source `use`.
3. REPL, with golden tests.
4. `match`, `match*`, structs, modules - the rest of the examples.
5. Brainfuck interpreter, then JSON - the embedding proof.
6. Rename to Vlam, if the name is agreed, before anything public ships.
7. Website: vlip calls veb (option 1), generate and deploy.
8. veb calls vlip (option 2), if the continuation work is worth it.
9. Make the repository public at step 7, not before: the site should exist
   before the URL does.
