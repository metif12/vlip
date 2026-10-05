# vlip

A Lisp dialect implemented in V, designed so that ordinary programs are written
**without macros** — while macros remain available for the cases that genuinely
need them.

S-expressions and a Racket-shaped surface, plus three things modern Lisps have
each solved separately and no single language has combined:

- **`match*`** — atomic multi-subject pattern matching (from Racket). Match two
  values at once without nesting one `match` inside another.
- **`use`** — callback capture that keeps chains flat instead of staircasing the
  indentation (from Gleam).
- **Opaque types** — encapsulation by export metadata, with no class system, no
  interfaces, and no multiple inheritance (from Gleam).

Execution is a CEK-style machine with an explicit heap stack, which gives proper
tail calls today and fibers later with no redesign.

There is no static type system in v1. Type information exists as optional, erased
annotations plus runtime contracts, and both are opt-in per program.

## Status

Milestone **M3** — the CEK machine runs real programs with real tail calls.
The reader parses all six example programs; the machine evaluates closures,
arithmetic, branching, `loop`, `dotimes`, `letrec`, `cond` and `case`.

| | |
|---|---|
| `docs/000-vlip-design.md` | the design document: motivation, language, architecture, trade-offs, comparisons |
| `docs/010-roadmap.md` | embedding, the REPL, the example programs to write, and the veb final phase |
| `vlib/vlip/` | the implementation: value representation, reader, printer, machine, primitives |
| `examples/` | the six programs that define the syntax; all parse |
| `tests/tail_calls.v` | tail-call and derived-form suite (17 passing) |
| `tests/non_tail.v` | non-tail sibling calls, the case the environment bug hid in |
| `tests/loop_forms.v` | `loop`, `dotimes` and `letrec` |

Not working yet, and named in `docs/010-roadmap.md`: `let*`, rest parameters,
and callable keywords. `let*` fails because `[...]` is a vector literal in value
position and a binding group in form position, and the reader does not yet mark
which reading applies.

### Verified

```text
ok   self tail call 1e6 => 1000000  (steps=28000020, kont=0)
ok   mutual tail call 2e4 => pong   (steps=400020,  kont=0)
ok   tail in cond 1e5 => 100000     (steps=2900021,  kont=0)
ok   non-tail fib => 6765           (steps=503488,   kont=0)
ok   loop => 7                      (steps=185,      kont=0)
```

A stack depth of `0` at the end of a million tail calls is the whole point: the
frame in tail position is reused rather than pushed.

## Build and test

Requires V 0.5.2 (the v3-line compiler). Use `-cc gcc`: the default C backend
fails on this checkout, and CI uses the same flag.

```sh
v -cc gcc -o vlip.exe vlip.v                       # the CLI
.\vlip.exe examples\01_basics.lip

v -cc gcc -o tools\tail.exe tests\tail_calls.v     # the suite
.\tools\tail.exe

v -cc gcc -o reader_probe.exe reader_probe.v       # every example parses
.\reader_probe.exe examples\*.lip
```

## Four findings from M0

All verified on V 0.5.2 by the programs in `src/`. These are the reason the
`Value` representation looks the way it does.

1. **A boxed sum type cannot represent a pair.** `struct cons_v { tail Lst }`
   is rejected as `invalid recursive struct`. A cons cell is recursive by
   definition, so the representation V would give us for free does not work.

2. **A sum-type variant field cannot be initialised from a local.** `x := 7` then
   `cons_v{head: x}` gives `error: x evaluated but not used` — no loop or
   recursion involved. A plain non-sum struct with the same shape is fine.

3. **A `voidptr` field is not a GC root.** The original design stored payloads
   behind `o voidptr`, and it silently corrupted programs: a 2,000,000-cell cons
   chain walked **25 cells** after heap churn. `Value.payload` is therefore a
   typed `Payload` interface, which the GC does track. Same probe after the fix:
   2,000,000 / 2,000,000, sum exactly correct.

4. **A method-less marker interface holding a struct is broken.** It compiles,
   then dies with `invalid memory access` in dev and `-prod` alike. `Payload`
   carries one method for this reason.

Findings 1 and 2 are worth reporting upstream to the V project.

## Roadmap

| # | Deliverable |
|---|---|
| M0 | skeleton, `Value` representation, benchmarks — **done** |
| M1 | reader: lexer and S-expression parser, spans, collected diagnostics — **done** |
| M2 | values, printer, `equal?`, `hash` — **mostly done** |
| M3 | CEK machine — gate: 1M-call `fib`, 100k-deep `reverse`, no silent stack overflow — **tail-call gate passed** |
| M4 | special forms, core forms, ~40 primitives — **in progress** |
| M5 | macros: `defmacro`, `gensym`, quasiquote, `macex1`/`macex` |
| M6 | modules: `require`/`provide`, `only-in`, `prefix-in`, `for-syntax` |
| M7 | standard library written in vlip |
| M8 | ergonomics: `match`, `match*`, `use`, pipes, labelled args, `Result`, opaque types — gate: a real 300-line program with no macros |
| M9 | tooling: REPL, span-carrying errors, formatter, `assert` as doc-tests |
| M10 | contracts and optional erased annotations |

The embedding plan, the REPL design, the example programs worth writing, and the
veb-backed final phase are in `docs/010-roadmap.md`. The ordering there differs
from this table in one respect: **errors become values before macros do.** A
panic inside an embedded interpreter unwinds through the host and kills it, so
that has to be true before anything can call vlip from V, and certainly before
Lua.

Section 7 of that document is the upkeep checklist: syncing against a new V,
re-running the representation probes, and keeping the known-broken list honest.
The compiler sync is the one that matters most, because this project does not
target the `0.5.2` release — it targets vlang/v master at the commit pinned in
`.github/workflows/ci.yml`, which resolves `vlib.vlip.*` against the project's
own modules where the release build resolves it against V's standard library.

## Design notes worth knowing

- **The value representation was decided by the host language, not by taste.** The
  design document originally promised a three-way benchmark. Measurement turned
  out to be beside the point: two of the three candidates cannot be written at
  all on V 0.5.2.
- **`v -warn-about-allocs` and `-prealloc` arenas** are used from the start; V
  documents the latter as intended for compilers.
- **No generics.** V's own compiler skips monomorphization when building itself
  (`vlib/v/pref/pref.v:57`) for build speed; vlip does the same.
- **The benchmark harness is not yet trustworthy.** It produced three wrong
  numbers before being fixed, including a 1000x unit error from coercing a
  `time.Duration` into nanoseconds. Treat its output as provisional.