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

Milestone **M0** — representation and skeleton. The compiler pipeline is not
written yet; this stage settles the runtime value representation, which turned
out to be constrained by the host language rather than by taste.

| | |
|---|---|
| `docs/000-vlip-design.md` | the design document: motivation, language, architecture, trade-offs, comparisons |
| `src/vlip/value.v` | the runtime `Value` representation |
| `src/gc_probe.v` | regression probe: payloads must survive the GC |
| `src/bench_value.v` | representation benchmark |
| `src/probe_phases.v` | per-phase timings |
| `src/probe_fnptr.v` | function-pointer call overhead |

## Build and test

Requires V 0.5.2 (the v3-line compiler).

```sh
v -prod -o gc_probe.exe src/gc_probe.v && ./gc_probe.exe     # must print OK
v -prod -o bench_value.exe src/bench_value.v && ./bench_value.exe
v -prod -o probe_phases.exe src/probe_phases.v && ./probe_phases.exe
v -prod -o probe_fnptr.exe src/probe_fnptr.v && ./probe_fnptr.exe
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
| M0 | skeleton, `Value` representation, benchmarks — **in progress** |
| M1 | reader: lexer and S-expression parser, spans, collected diagnostics |
| M2 | values, printer, `equal?`, `hash` |
| M3 | CEK machine — gate: 1M-call `fib`, 100k-deep `reverse`, no silent stack overflow |
| M4 | special forms, core forms, ~40 primitives |
| M5 | macros: `defmacro`, `gensym`, quasiquote, `macex1`/`macex` |
| M6 | modules: `require`/`provide`, `only-in`, `prefix-in`, `for-syntax` |
| M7 | standard library written in vlip |
| M8 | ergonomics: `match`, `match*`, `use`, pipes, labelled args, `Result`, opaque types — gate: a real 300-line program with no macros |
| M9 | tooling: REPL, span-carrying errors, formatter, `assert` as doc-tests |
| M10 | contracts and optional erased annotations |

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