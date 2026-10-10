# blip roadmap: embedding, REPL, and the self-hosted website

Status: proposed. Written before the interpreter runs all six example programs,
so it records intent, not achievement.

## 1. Naming

The working name `blip` is fine but reads as an abbreviation rather than a word,
and it says nothing about what the project is. Before the repository goes public
the name should be worth typing.

Recommendation: **Vlam** - V + lambda.

- Four letters, no vowel clusters, unambiguous to pronounce.
- Names the one idea the project is actually about: closures with real tail
  calls.
- `vlib/vlam`, `vlam.v`, `blip` -> `vlam` is a mechanical rename, and doing it
  now costs one commit rather than a public rename later.

Alternatives, in order: **Vexpr** (V + expression, more descriptive, less
memorable), **Blip** (keep, zero cost), **Vela** (prettier, says nothing about
Lisp).

The rename touches `v.mod`, `vlib/blip/**`, `blip.v`, `README.md`,
`docs/000-blip-design.md`, and every `import vlib.blip.*`. Nothing in the design
depends on the current spelling.

## 2. Embedding: can blip be embedded, and what does it take?

Yes, and it is closer than it looks. The machine is already a library rather than
a program:

- `vlib/blip/machine` holds no global state. Everything lives on `Machine`.
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
2. **A host interface.** blip needs `print`, `read-line`, and `load` from its
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
int blip_eval(lua_State *L) {
    // arg 1: source string, arg 2: opaque *BlipInterp
    // push (ok, value_or_error_message) and return 2
}
```

Practical consequences to plan for:

- blip values must cross into Lua as Lua values. Table this explicitly; the
  honest mapping is number/string/bool/nil directly, lists as Lua tables,
  closures as functions that re-enter the interpreter (with a step budget, or a
  Lua coroutine per call).
- Errors must arrive as Lua errors, not panics. This is the same fix as (1).
- The REPL's `,t` load facility becomes the embedding test: a Lua script that
  drives blip and a blip script that drives Lua should exercise the same
  surface.

## 3. REPL

`blip` with no arguments starts a REPL. Without arguments is the right default:
the CLI already requires a file, so bare `blip` is free.

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

## 4. Real programs worth writing in blip

Ordered by what each one proves. The point is not the program, it is the part of
the language it forces into existence.

| Program | What it forces into existence | Size |
| --- | --- | --- |
| Brainfuck interpreter | Embedding: a blip program driving another machine | ~60 lines |
| JSON parse + emit | `Result`, error propagation, strings, recursion | ~200 lines |
| CSV to table | vectors, tables, destructuring, file I/O | ~120 lines |
| Markdown to HTML | lists, higher-order functions, string building | ~250 lines |
| Pratt parser for a toy language | `match*`, structs, mutual recursion | ~400 lines |
| Commit-message linter | real I/O, exit codes, a CLI shape worth copying | ~150 lines |
| **The blip website generator** | the whole language plus the veb bridge | the final phase |

The Brainfuck interpreter is first on purpose: it is the smallest program that
requires the interpreter to start another interpreter, so it is the honest test
of section 2. If blip can run a Brainfuck interpreter, it can be embedded.

The commit-message linter is on the list because it is the first program anyone
would actually install, and a language nobody runs is not a language.

## 5. Final phase: the website, written in blip, exposing vlib so veb works

Target: the project website is generated by blip programs, served through V's
`veb` templates and router, with blip able to register handlers that veb routes
to. The site is then both the documentation and the proof.

The hard part is the bridge, and it should be stated precisely. `veb` is a
V-native template-and-routing library: it wants V `fn` values with V signatures.
blip wants its own closures over `[]blip.Value`. Two options:

1. **blip calls veb** (easy, one direction). blip programs get
   `veb.html.escape`, `veb.render`, and friends as primitives. The site logic is
   blip; the templates stay `.html` files handled by veb. This gets the site
   running quickly and is the right first step.
2. **veb calls blip** (hard, the other direction). A blip closure becomes a veb
   handler. Requires a trampoline: keep a machine parked with a continuation that
   is waiting to receive the request value, and hand veb a V function that
   resumes it. This is real green continuations, and it is the interesting half.

Do (1) first and ship the site. Then attempt (2) behind an adapter, because (2)
is where the embedding story is actually proven: if a V HTTP server can route a
request into a blip closure and get a response back, blip is embedded in the
strongest sense available.

### Site structure

```
site/
  build.lip          entry point: reads content, emits pages
  content/*.md       pages, one file per route
  layout.html        veb template
  vlib/blip/host/    the veb bridge (section 2 + option 1)
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
7. Website: blip calls veb (option 1), generate and deploy.
8. veb calls blip (option 2), if the continuation work is worth it.
9. Make the repository public at step 7, not before: the site should exist
   before the URL does.
10. CLI steps that are already honest (`version`, `help`, `run`, `test`,
    `new`): cheap, alongside everything. See section 9.
11. Language server (diagnostics first) and VS Code extension (grammar,
    client, snippets): the last phase before WASM. See section 8.
12. WASM backend, with `blip build` and a client-side playground as its
    proof; `fmt`/`vet`/`doc` as their dependencies land.

## 7. Periodic work

Nothing in this section is a deliverable. All of it is upkeep, and all of it is
the kind of work that gets skipped until the day it turns into an incident. The
cadences are deliberately conservative: this project has one contributor and no
users, so the risk is wasted effort, not missed SLAs.

### 7.1 Syncing against a new V — monthly, and on every V release

This is the highest-value recurring task and the one most likely to break
silently.

**Why it is delicate.** The project does not target the `0.5.2` *release*. It
targets vlang/v **master at a pinned commit** (`V_COMMIT` in
`.github/workflows/ci.yml`), which also self-reports as `V 0.5.2` but resolves
modules differently: the release build looks `import vlib.blip.reader` up in V's
own standard library and reports every module here as an unknown function,
while the pinned build resolves it in the project's `vlib/`. Nothing in the
source changed; only the compiler did.

**Procedure.**

1. `git -C <v-install> fetch && git log --oneline HEAD..origin/master` and read
   what moved. V's changelog is not a reliable summary of what affects
   codegen.
2. Bump `V_COMMIT` in `.github/workflows/ci.yml`.
3. Run the suites **locally** against the new compiler before trusting CI:

    ```sh
    v -cc gcc -o tools\tail.exe tests\tail_calls.v       && .\tools\tail.exe
    v -cc gcc -o tools\nt.exe   tests\non_tail.v         && .\tools\nt.exe
    v -cc gcc -o tools\lf.exe   tests\loop_forms.v      && .\tools\lf.exe
    v -cc gcc -o reader_probe.exe reader_probe.v        && .\reader_probe.exe examples\*.lip
    v -cc gcc -o blip.exe blip.v
    ```

   Local first, deliberately: a compiler change that breaks the build should be
   diagnosed where it reproduces, not through a CI log.
4. Re-run the prims generator and review what moved:

    ```sh
    v run tools\genprims.vsh
    ```

    A new compiler means a new vlib, and the generator reads vlib's
    signatures straight out of it. Any rename, reorganization, or
    signature change fails here first -- that failure is the sync signal,
    not build noise. Read the "convertible but not allowlisted" report for
    newly bindable functions, bless or skip each one, and commit the
    regenerated `vlib/blip/prims/gen_*.v` files in the same change as the
    `V_COMMIT` bump so the binding and the compiler it was read from never
    drift apart. CI runs the same script with `--check` and refuses a tree
    whose generated files do not match its compiler.
5. Re-run the probes in `src/`, which are the regression net for the
   representation decisions (section 7.2).
6. If `-cc gcc` is no longer required, say so in the README and in both
   workflows at the same time. Those three places drifting apart is how a
   "works on my machine" bug gets shipped.
7. Record anything surprising in `~/.config/opencode/lessons.md`. The module
   resolution difference above cost four CI runs to characterise and is worth
   one line for the next session.

**Also check when V moves:** the `-cc gcc` requirement, `NodeId` codegen
(section 7.3), the `voidptr`-is-not-a-GC-root finding, and whether V's V3
compiler has become the default on Linux, since that changes which backend CI
is exercising relative to the Windows development machine.

### 7.1a Which V actually ran — check this before debugging anything else

Two things about the V installation are invisible in a passing build and very
visible in a failing one. Both have already cost CI runs here.

**The compiler is not the version.** `vlang/v` master and the `0.5.2` release
both print `V 0.5.2`. The build hash after it is what distinguishes them
(`0137eb5` here). Pin `V_COMMIT` and read `v version` in the log.

**The compiler may not be the one you think, per platform.** On macOS, Linux and
BSD, `v` tries the experimental **V3** compiler by default and *silently falls
back* to the established compiler when V3 declines the program. The two resolve
module paths differently: the established compiler looks up
`import vlib.blip.reader` in V's own standard library and reports every module
in this repository as an unknown function — for files that exist, and that
compile and pass locally from the same commit.

That is the whole story behind four consecutive red CI runs that all reported
the same "unknown function" errors on a codebase that was fine.

- `V_MACOS_V3_NO_FALLBACK=1` stops the fallback, so a Linux runner behaves like
  the Windows development machine. Set in `.github/workflows/ci.yml`.
- `-old-compiler` forces the established compiler. Do **not** reach for it to
  "fix" this: it produces the module errors directly, and it also rejects
  `drive()` in `vlib/blip/machine/mod.v` for a missing return after an infinite
  `for`, which the compiler V3 accepts.
- `v help build-c` documents `-old-compiler` and the related flags.

Rule: when a build fails on files that compile locally from the same commit,
suspect the toolchain before the code, and print `v version` before reading
anything else.

### 7.2 Re-running the representation probes — with every compiler sync

`src/gc_probe.v`, `src/bench_value.v`, `src/probe_phases.v` and
`src/probe_fnptr.v` exist to catch the host-language facts the whole `Value`
design rests on. They are cheap and they are the only warning before a
representation change becomes a memory-corruption bug.

Treat a change in these as a design event, not a benchmark update:

| Probe | What a change means |
|---|---|
| `gc_probe.v` | the payload is no longer a GC root, or the collector changed. `Value` must be redesigned before anything else is built on it. |
| `bench_value.v` | the inline-vs-boxed trade-off has moved; re-open section M0 of `docs/000-blip-design.md`. |
| `probe_phases.v` | a pipeline phase is no longer paying for itself. |
| `probe_fnptr.v` | primitive dispatch got slower; affects the `call_primitive` fast path. |

Do **not** "fix" a probe to make it pass. These programs assert host-language
facts; when one fails, the fact changed and the code above it is what has to
move.

### 7.3 Watching for V codegen bugs — continuous

V 0.5.2 miscompiles two things this codebase leans on, both found by hitting
them rather than by reading a changelog:

- `for x in slice` where the element type is a type alias from another module
  emits an unresolved type name into the generated C. `vlib/blip/machine/mod.v`
  works around it with an index loop in `transform_letrec`.
- Interpolating a `[]blip.NodeId` into a string emits the same unresolved name.
  The AST-dumping probes were rewritten to avoid it.

When either is fixed upstream, the workaround should be removed in the same
change that removes the comment explaining it. A workaround with no comment
becomes folklore; a comment with no workaround becomes a lie.

### 7.4 Keeping the two `vlib`s apart — continuous

There are two different things called `vlib` in this repository, and conflating
them has already cost time:

- **V's standard library**, reached as `@vlib`, which lives in the V
  installation.
- **This project's modules**, in `vlib/blip/` at the repository root, imported
  as `vlib.blip.*`.

If the project is renamed (section 1), rename the directory in the same commit
that renames the module references, and update `.gitignore`, which already has a
comment explaining that `vlib/blip/` is deliberately *not* ignored. Keep that
comment accurate.

### 7.5 Keeping the known-broken list honest — every milestone

Three things were listed as failing in the README, the test suite and this
document: `let*`, rest parameters, callable keywords. All three are fixed and the
notes are gone; a list of known failures is only useful while it is true, and the
failure mode is silent — nobody reads a stale "known broken" note and concludes
the bug is fixed.

What replaced the notes is `tests/binding_forms.v`, which asserts the behaviour
rather than describing the failure. The root cause was also not what the notes
claimed. It went on for a while as a design question — `[...]` being a vector
literal in a value position and a binding group in a form position — when it was
two ordinary parser bugs:

- `transform_let_star` started its recursion at binding index 1 instead of 0, so
  it silently dropped the first binding. `(let* ([a 1] [b (+ a 1)]) b)` compiled to
  `(let ([b (+ a 1)]) b)`, and the resulting "unbound identifier: a" looks exactly
  like a scoping bug.
- `.` in a parameter list was appended as an ordinary parameter named `.`, so
  `(define (f a . r) r)` had arity 3 and `(f 1 2 3)` bound `r` to `3`.

The lesson generalises: a bug report that explains *why* a symptom appears is
usually a hypothesis, not a finding. Reproduce the symptom, then read the code
path.

So, per milestone:

1. Fix it and delete the note in the same commit. A note describing a fixed bug
   is worse than no note.
2. Re-run the suites and confirm no `FAIL` line survives.
3. Update the site. It carries the same list, in `site/index.html`, and it is the
   copy a visitor will read.
4. `docs/000-blip-design.md` claims some behaviour the machine does not yet
   have. Reconcile it with reality rather than leaving the design document as
   an aspiration that quietly diverges.

### 7.6 Housekeeping — quarterly

- **Actions versions.** The Pages run already warns that `actions/checkout@v4`,
  `actions/configure-pages@v5` and `actions/upload-artifact@v4` target Node 20
  and are being forced onto Node 24. Bump them when the majors move.
- **Prune scratch files.** `tools/*.exe`, `out*.txt` and ad-hoc `tests/dbg_*.v`
  probes accumulate during debugging. The ones that earned their place are
  `tests/non_tail.v` and `tests/loop_forms.v`; anything still named `dbg_` is
  disposable.
- **Tag milestones.** M0 through M10 in `README.md` are the release vocabulary.
  Tag the commit that satisfies each gate so the tags mean something.
- **Dependencies.** `v.mod` declares none, and that is worth keeping: every one
  added is a licence to track and a version to re-test on each V sync. If that
  changes, record why.
- **The site.** `site/index.html` is hand-written until the final phase. Its
  claims — the tail-call table, the "verified" list — are checked by CI against
  the real suite, so a number in it cannot rot unnoticed. Keep that property when
  the site becomes generated.

### 7.7 Turning this section into tracked work

This document is a checklist, not a scheduler. When more than one person
contributes, each numbered item above should become an issue, recurring on the
cadence stated, with the procedure pasted into the issue body so it survives
without this file.

## 8. Language server and VS Code extension: the last phase before WASM

An editor that reports errors as you type is what turns blip from a project
you visit into a language you use. It comes after the website and
immediately before the WASM compiler phase: the binary, the REPL, and the
site all exist by then, so the server has something to wrap, and the
playground stays server-backed until WASM removes the round trip.

Both halves are reuse, not invention. The checkouts sit next to this one
(`../vls`, `../vscode-vlang`), and what transfers is the shape, not the
analysis.

### 8.1 The server, after `vls`

`vls` is a JSON-RPC-over-stdio server in V (`main.v` owns the loop,
`lsp.v` the protocol, `handlers.v` the dispatch, `diagnostics_scheduler.v`
the debouncing). That skeleton transfers almost verbatim: framing,
capabilities negotiation, `textDocument/didOpen` + `didChange` tracking,
and `textDocument/publishDiagnostics` are protocol work, and protocol work
does not care what language is on the other side. Copy the shape,
including the test hooks -- `vls` captures outbound messages instead of
writing them, which is what makes its `lsp_test.v` and `integration_test.v`
possible without a client, the same trick the REPL golden test uses.

What does NOT transfer is a single line of analysis: `index.v` and
`expression_types.v` know V's modules, structs, and inference. blip's
analysis is its own, and it starts embarrassingly small, because the
reader already reports diagnostics with line and column (that was the
error-format work): open file -> `read_forms` -> diags become LSP
diagnostics with ranges. That alone is a useful v1. Everything after it --
hover, go-to-definition, completion -- reads data the machine already
holds (scopes, envs, arenas), and each one is a separate milestone, not
part of "the language server" as a single deliverable.

### 8.2 The extension, after `vscode-vlang`

The extension is configuration plus a client. `vscode-vlang` shows both:
`package.json` contributes `languages`, `grammars`, and `snippets`;
`syntaxes/v.tmLanguage.json` is the TextMate grammar;
`language-configuration.json` declares brackets and comments;
`src/langserver.ts` launches the server over stdio with configurable
command and args and forwards settings via `didChangeConfiguration`.

For blip: a new language id, a grammar seeded from `v.tmLanguage.json`
(S-expressions with `;`-comments and `"..."` strings are a weekend grammar
next to V's), the bracket/comment configuration copied, a client shaped
like `langserver.ts` pointing at `blip lsp` (see section 9), and a
snippets file for the special forms. Deliberately out of v1: tasks,
debugging, and coverage -- `vscode-vlang` has `vTasks.ts` and a debugger
because V needs them; blip does not, until it does.

### 8.3 The bar

The same bar as everything else: the server is driven over stdio
in-process and its diagnostics diffed against fixtures. A language server
whose errors disagree with `blip run` is worse than none, so the fixtures
and the `read_forms` diagnostics share one source of positions.

## 9. A CLI shaped like `v`'s

`blip.v` today parses "run this file" and not much else. The target is the
`v` command surface reduced to what blip can honor: `cmd/v/v.v` holds the
dispatch table (`run`, `build`, `test`, `fmt`, `vet`, `doc`, `new`,
`version`, `help`), and the shape -- one binary, subcommands, `--help`
everywhere -- transfers directly.

Mapped onto blip, in the order each becomes honest:

1. `version`, `help` -- mechanical, now.
2. `run` -- what exists today, kept as the default when no subcommand is
   given (bare `blip` already means the REPL).
3. `test` -- run the `_run.v` gates over files and report markers. The two
   suites already define the convention; the subcommand is the runner
   around them.
4. `lsp` -- serve the language server over stdio. This is what the
   extension launches (section 8); it exists as soon as the server does.
5. `fmt` -- blocked on a decision, not on code: the reader keeps no trivia
   (comments, blank lines), so a formatter is either a pretty-printer from
   the arena, which normalizes everything, or reader work to keep trivia
   first. Say which before writing it.
6. `vet` -- the linter hook. The commit-message linter (section 4) is its
   first real client; until then it reports nothing.
7. `doc` -- generated from doc comments the way the site will need them
   (section 5 wants generated pages; one extractor serves both).
8. `new` -- scaffold a `main.lip` plus a test gate. Small, and the first
   thing a newcomer runs.
9. `build` -- only meaningful with a backend to build to, so it waits for
   the WASM phase: `blip build` emitting a `.wasm` module is the point
   where the CLI stops being a runner and becomes a compiler driver.

What does not transfer: flags with no meaning yet. `v` has forty; blip
gets each one when a feature needs it, not when the table looks thin.

