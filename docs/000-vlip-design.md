- Topic Name: `vlip`
- Start Date: 2026-10-04
- Status: Draft (not an official V RFC — see "Placement")

# Summary

**vlip** is a Lisp dialect implemented in V, designed so that ordinary programs
are written *without macros*, while macros remain available for the cases that
genuinely need them.

It takes S-expressions and a Racket-shaped surface, and adds three things
modern Lisps have each solved independently and no single one language has
combined: **atomic multi-subject pattern matching** (`match*`), **callback-based
`use`** for keeping call chains flat, and **opaque types** as the encapsulation
mechanism. Execution is a CEK-style machine with an explicit heap stack, which
gives proper tail calls today and fibers later with no redesign.

There is no static type system in v1. Type information exists as optional,
erased annotations plus runtime contracts, and both are opt-in per program.

# Motivation

Three problems, each of which costs a working Lisper real productivity.

**1. Pattern matching in a Lisp is either missing or a pile of nesting.**
Racket has the richest pattern grammar in existence and its own documentation
warns that a `match` "may destructure the input multiple times, and may evaluate
expressions embedded in patterns such as `(app expr pat)` in arbitrary order, or
multiple times." Matching two values at once — the single most common case when
you are destructuring a result — requires nesting one `match` inside another, and
nesting is what makes Lisp code unreadable in the first place.

**2. Error handling either explodes the indentation or loses the stack.**
Gleam proved that `Result` without `use` is unusable past three levels. Janet
proved that one primitive (fibers) can serve as exceptions, generators, green
threads, coroutines, and an event loop. Steel shipped `Result` *and* exceptions
*and* futures *and* async, and its issue tracker shows the cost: embedding
complaints about not being able to get a stack trace out of a raised error
(#413), and about VM startup cost that makes per-test VMs "cumbersome" (#692).

**3. Dynamic languages have no cheap encapsulation story.**
Common Lisp solved this with the CLOS metaobject protocol — a decade of work
with negligible adoption. Steel's answer is `methods.rkt`, which defines `impl`
and `def-method` but is **not in the active prelude**, so it is almost certainly
unreachable; issue #651 asks whether an `impl` macro should be created, implying
it does not exist. Gleam solved it with opaque types: a type is public, its
constructors are private, and invariants are enforced by smart constructors. In
a Lisp this is pure export metadata — roughly fifty lines.

The common failure mode behind all three is **abstraction implemented as
control-flow nesting**, which is the one thing a Lisp should not have to pay.

# Guide-level explanation

## The shape of a program

```scheme
; line comment
#| nestable #| block |# comment |#

(provide greet)                          ; export

(define (greet name visits)
  (format "Hello ~a, you are visitor ~a." name visits))

(greet "Ada" 42)                         ; => "Hello Ada, you are visitor 42."
```

That is the whole ceremony. `provide` is optional; everything else is
mechanical. Note that `greet` is `define`, not `defn` — a `(define (f . args) . body)`
shorthand, as in Racket and Scheme.

## Data

Six literals cover almost everything:

```scheme
42          ; exact integer (fixnum, promoting to bignum)
3.14        ; float
1/2         ; exact rational
#\a         ; character          #\newline
#t          ; true               "hi"        ; string
'#(1 2 3)   ; bytes
```

Only `#f` is false. `0`, `""`, `()` and `nil` are all true — as in Scheme and
Clojure, and unlike Ruby and JavaScript.

Collections are distinguished by their brackets, not by a predicate:

```scheme
'(1 2 3)       ; list        — cons cells, the universal sequence
[1 2 3]        ; vector      — dense, indexable, immutable
@(1 2 3)       ; array       — dense, mutable
{:a 1 :b 2}    ; table       — hash map, immutable
@{:a 1}        ; buffer      — hash map, mutable
```

The `@` prefix is Janet's (`vlib`-verified) and it is a good idea: it makes
mutability visible at a glance without a single type annotation.

## Control flow

```scheme
(when ready?  (launch))                   ; body may be empty => returns nil
(unless ready? (launch))

(cond [(= n 1) 'one]
      [(= n 2) 'two]
      [else   'many])

(case n
  [(1 2)   'low]
  [(3 4 5) 'mid]
  [else    'high])                        ; => on integers, uses =

(loop i 0 (< i 10)                       ; named let, the loop form
  (print i))

(dotimes i 3 (print i))                  ; zero to n-1
```

`loop` is named `let`, and `dotimes` exists because counting loops are the most
common loop and nobody should write `(< i 3)` again.

## Pattern matching

`match` destructures one value. `match*` destructures **several at once,
atomically** — all patterns in a clause must match, or the clause is skipped
without any of them taking effect.

```scheme
(match* (list (car xs) (lookup tbl (car xs)))
  [(_ nothing)        'missing]
  [(nil v)            'empty-list]
  [(sym v)            (ok sym v)])
```

Compare with what the same thing costs elsewhere:

```scheme
;; Racket — nested match
(match (list a b)
  [(list x nothing) 'missing]
  [(list nil v)     'empty-list]
  [(list sym v)     (ok sym v)])

;; Gleam — nested use + Result plumbing
case lookup(tbl, a) {
  Error(_) -> ... four more nested cases ...
  Ok(nil)  -> ...
  Ok(v)    -> ...
}
```

Patterns: literals, `_`, bindings, `(list p ...)`, `(cons h t)`, `(vector a b)`,
`(struct Point x: px y: py)`, `(and p ...)`, `(or p ...)`, comparison forms like
`(>= n 10)`, `...` rest, `#:when` guards, `else`.

`match*` is the highest-leverage single feature in the language. It is Racket's
best idea and almost nobody outside Racket has it.

When a pattern is genuinely partial, say so rather than adding a noise clause:

```scheme
(let assert [(struct Point x: px) p]     ; crashes with a clear message if not
  (* px px))
```

## Keeping chains flat

```scheme
;; `use` runs a body with values bound — indentation stays flat
(use (open "notes.txt")
  (for-each read-line it)
  (count-nonblank))

;; pipelines thread values through
(->> text (string-split " ") (map string-downcase) frequencies)
(->  point (rect:width) (* 2))              ; thread-first
(->> rows (filter valid?) (sort-by score) (take 10))

;; `|>` is dual-mode, and can tap the pipeline for debugging
(area n |> area)
(n |> string-pad-start(3))
(->> text |> echo |> string-split(" ") |> echo (map len) (sum))
```

`|> echo` is Gleam's sleeper feature and it is free: a value in a pipeline can
be inspected without restructuring the pipeline.

## Results

Errors that a caller might reasonably handle are **values**, not throws:

```scheme
(define (parse-port text)
  (match* (split-once text ':')
    [(list k v)
      (let ([key (string-trim k)] [val (string-trim v)])
        (cond (empty? key) (err 'missing-key)
              (empty? val) (err 'missing-value)
              (else       (ok [key val]))))]
    [_ (err 'malformed)]))

(parse-port "port: 8080")     ; => (ok ["port" "8080"])
(parse-port "nonsense")       ; => (err malformed)
```

The combinator set is fixed and deliberately small, and laziness is visible in
the name:

```scheme
(map-result r double)
(unwrap-or r 0)
(lazy-unwrap r (fn () { 0 }))     ; thunk — only runs on (err _)
(try-result r double)             ; monadic bind
```

`lazy-unwrap` exists because in a Lisp every argument is evaluated eagerly, so
the eager variant of every combinator is a trap waiting for a slow call.

## Labelled arguments

```scheme
(define (render #:width [w 80] #:height [h 24] title body)
  ...)

(render #:title "hi" body "there")     ; defaults fill in the rest
(render #:width 100 body "x" title "y")
```

Arguments stay positional underneath, so this is pure sugar — but it is the
single most effective fix for Lisp's argument-order readability problem, and it
survives reordering, which an `assoc`-based convention does not.

## Every value is callable

Tables and structs are functions:

```scheme
(get tbl :a)         ; ordinary
(:a tbl)             ; same thing, shorter
```

This is Janet's rule and it deletes a lot of `(get m k)` noise for free.

## Structs, and hiding their constructors

```scheme
(struct Point (x y))
(Point 1 2)                  ; => (Point 1 2)
(p.x)                        ; field access (see "Reference-level")
(let [q p] (q.x := 5))       ; mutable only if #:mutable

(struct PositiveInt (n) #:opaque)
```

`#:opaque` exports the type name but not the constructor. Only smart constructors
can make one, so `PositiveInt`'s invariant is enforced by the module system —
with no class system, no interfaces, and no multiple inheritance.

```scheme
(define (positive-int n)
  (if (> n 0) (ok (PositiveInt n)) (err 'not-positive)))
```

## Exceptions, for the cases that are bugs

```scheme
(try (open "config")
  #:catch [(err 'not-found) (default-config)]
  #:finally [close handle])

(raise (error "bad index ~a" i))     ; not a value; aborts
```

Both mechanisms, deliberately. `Result` for things a caller should handle;
exceptions for invariant violations. Neither alone is sufficient, and half a
design serves neither.

## Typing, such as it is

Untyped code pays nothing. Two opt-in layers exist:

```scheme
(define/contract (halve x)
  (->/c even?)                    ; Racket-style, checked on call
  (/ x 2))

(define (add (x int) (y int)) int  ; erased annotation, checked by `vlip check`
  (+ x y))
```

The annotation is erased before execution. `vlip check` is a separate command
that reports mismatches; running the program never does.

## Modules

```scheme
(require "util.vl")
(require (only-in "http.vl" get post))
(require (prefix-in db: "db.vl"))
(require (for-syntax "macros.vl"))

(provide (struct-out Point) fetch)
```

Resolution is file-relative (`./x.vl` means "next to the current file", never
"in the working directory"), and each module has a canonical key so `x.vl` and
`./x.vl` are recognized as one module.

# Reference-level explanation

## Placement

This document uses the `vlang/rfcs` template for structure but is **not** a
proposal to change V. It describes a separate language that happens to be
implemented in V. It should live in its own repository; the RFC process
described in `vlang/rfcs/README.md` governs changes to V itself and a separate
dialect should not enter that queue.

## Compilation pipeline

Five stages, each a separate pass with its own IR. There is no fused
expansion/lowering loop.

```
source ─▶ reader ─▶ Datum ─▶ expander ─▶ Core ─▶ analyzer ─▶ Program ─▶ machine
          spans        flat      macros     flat      resolve    CEK loop
```

- **reader** — text to `Datum`, a flat node arena. Collects diagnostics rather
  than throwing (the pattern in `vlib/v/scanner/scanner.v:15-24`).
- **expander** — macros, `syntax-rules`/`defmacro`, hygiene resolution.
  Produces `Core`.
- **analyzer** — name resolution to indices, arity checks, capture analysis.
  Produces `Program`, in which the hot loop contains no symbols at all.
- **machine** — a CEK-style loop over `Program`.

`Core` is deliberately tiny — the target is roughly 14 forms, matching the set
Steel converged on. Everything else is a macro.

## Why staged, when Steel's fused pipeline works

Steel's pipeline interleaves macro expansion and lowering in a loop, which in
practice is a pass cluster of roughly 301 KB (`compiler/passes/analysis.rs`) plus
126 KB of module machinery, and it re-runs analysis after most individual passes
rather than computing it once. It works, but it is where its open bugs live:
hygiene is wrong for nested templates with ellipsis (#706 — `(3 3 3)` where Chez
gives `(1 2 3)`), macros escape `provide` scoping (#645), and a redefinition of
an exported function can crash (#485).

Staging costs an extra materialization per pass. In exchange, each stage has one
job, is independently testable, and a wrong expansion can be inspected with
`macex1` instead of inferred from a downstream crash.

## Representation: the flat arena

`Datum`, `Core` and `Program` are all flat node arenas, copying the layout V's
own compiler uses in `vlib/v/flat/flat.v`:

```v
pub type NodeId = i32
pub struct Node { mut: value string; children_start i32; children_count i32; kind NodeKind; ... }
nodes    []Node
children []NodeId
```

This is not an aesthetic preference. Children live in one shared `[]NodeId`
slice addressed by `(children_start, children_count)`, so building a million-node
program performs no per-node allocation, and `enum NodeKind as u8` lets the hot
dispatcher switch on a single byte — the same trick `flat.v:50` uses across its
95 variants.

## Representation: `Value`

This is the decision that most affects whether the language is usable, and it is
deliberately **not** the obvious one.

V compiles sum types to a boxed `{int typ; union {T*}}` layout
(`vlib/v/gen/c/interface.v:9-27`). V's own interpreter therefore models runtime
values as a sum type (`vlib/v/eval/eval.v:9-21`). That is correct for a compiler
walking a large AST. It is wrong for a Lisp, where *every integer is a `Value`*:
one heap allocation and one pointer chase per scalar, in the innermost loop.

This turned out to be decided by the language rather than by measurement, so this
section now records findings rather than a proposal. All four were verified on
V 0.5.2 (the v3-line compiler) by the programs in `src/`.

**Finding 1 — a boxed sum type cannot represent a pair.** A variant struct
holding the sum type by value is rejected outright:

```v
struct cons_v { head int
               tail Lst }
// error: invalid recursive struct `cons_v`
```

A Lisp's cons cell is recursive by definition, so the boxed sum type would need
a second layer of indirection — an allocation *on top of* the boxing.

**Finding 2 — a sum-type variant field cannot be initialised from a local at
all.** No loop, no recursion, nothing unusual:

```v
x := 7
v := cons_v{head: x}
// error: `x` evaluated but not used
```

A plain non-sum struct with the identical shape compiles and runs, so this is
sum-type specific. Possibly a checker bug, and worth reporting upstream, but it
is a blocker today. This alone rules out the representation V would hand us for
free.

**Finding 3 — a `voidptr` field is not a GC root.** This was the original design
(`o voidptr` holding `&Pair`), and it silently corrupted programs. Measured with
`src/gc_probe.v`: build a 2,000,000-cell cons chain, churn the heap with 200,000
allocations, then walk it. **25 cells survived.** V derives GC roots from typed
fields; a `voidptr` does not declare what it points at.

The fix is that the payload must be a *typed* reference:

```v
pub interface Payload {
	payload_tag() Tag // the method is required; see Finding 4
}

pub struct Pair { tag Tag
                  car Value
                  cdr Value }

@[direct_array_access]
pub struct Value { mut:
                  tag     Tag
                  i       i64
                  f       f64
                  payload Payload }
```

Scalars store `none` and still allocate nothing; payloads are reachable because
an interface field is a real root. Same probe, after the change:
**2,000,000 / 2,000,000 cells, sum exactly correct.**

**Finding 4 — a method-less marker interface holding a struct is broken.** It
compiles, then dies with `invalid memory access` in both dev and `-prod` builds.
Adding one method fixes it, so `Payload` keeps `payload_tag()`. This is worth
remembering for any V interface used as a tagged union.

Note `@[packed]` is also absent: packing forces byte alignment, which misaligns
the pointer inside the interface field.

Exhaustiveness checking remains available where it is free: V enforces
non-exhaustive `match` on sum types, enums and bools at compile time
(`vlib/v/types/checker_tail_stmt.v:1930-2017`), so the *compiler's own* AST
dispatchers get checked exhaustiveness even though `Value` is a struct.

**Open: packed struct versus plain interface for `Value`.** With the payload
behind an interface, the packed struct is structurally close to just using an
interface for everything. `src/bench_value.v` measures the interface version at
roughly **2x faster** on a mixed 1M-iteration workload (~35 ms versus ~71 ms,
identical checksums) — plausibly because the packed struct carries a separate
`tag` word that is redundant with the interface's own type tag. That result is
not yet trusted: the harness took three wrong measurements before being
corrected, including a 1000x unit error from coercing a `time.Duration` to
nanoseconds. Re-validate before acting on it. Note that the interface version
boxes every scalar, which the packed struct does not, so the two should be
compared on integer-heavy workloads separately rather than lumped together.

## The machine: CEK with an explicit stack

The machine keeps its stack in a plain `[]Value` and its control state in
`C`/`E`/`K`. This is chosen over bytecode for three reasons.

1. **Fibers become free later.** Because the stack is an ordinary heap array,
   capturing it to make a fiber requires no representation change and no new
   calling convention. This is the entire basis on which vlip can grow fibers
   without a redesign.
2. **No serializer, no codegen, no versioning.** There is no bytecode format to
   version, no instruction encoder to be correct, and no
   "disassemble the bytecode" debugging story. `vlip ast` prints the
   `Program` IR and that is genuinely the whole program.
3. **Proper tail calls are structural.** A tail call is a loop iteration, not a
   stack mutation. Steel needed a dedicated `TCOJMP` opcode and still ships
   `SELFTAILCALLNOARITY`; Janet needed a distinct `tcall`. Here it is a `continue`.

Full tail-call elimination includes **mutual** recursion, not just self-calls.
Self-tail-only was considered and rejected: Steel's `SelfTailCall(depth)` codegen
shows how much complexity leaks in from partial treatment.

The cost is honest: a CEK loop moves more state per call than a bytecode
dispatcher, so raw throughput will be lower than a mature bytecode VM on
tight numeric loops. That is accepted, and revisited only against measurements.

## Memory: arenas, then the host GC

Compilation uses `-prealloc` scoped arenas, one per stage, released between
stages. V documents this mode as suited to "short lived, single-threaded,
batch-like programs (like compilers)" (`doc/docs.md:6366-6367`) and implements
them in `vlib/builtin/prealloc.c.v` with 16 MB blocks plus
`prealloc_scope_begin`/`prealloc_scope_end`.

Runtime `Value`s and pair cells use Boehm or `vgc` (`vlib/v/driver/gc.v:6-20`),
with `-gc none` available for embedded deployments that would rather manage
memory themselves.

Two decisions carried over from V's own compiler:

- **No generics.** `vlib/v/pref/pref.v:57` skips monomorphization when building
  V itself. vlip does the same. This keeps rebuild times low and avoids V's
  known-lossy parallel monomorphizer (`driver.v`, `should_parallel_monomorphize`,
  which is off by default precisely because it drops results).
- **No macros in the host language.** V has neither macros nor `@[vgen]`. The
  code-generator need is met with `@[params]`+`@[required]` structs and template
  functions, the way `vlib/build/build.v:30-96` does it.

## Macro system, v1

Non-hygienic by default, with `gensym`, quasiquote, and `macex1`/`macex` for
inspection. This is Janet's documented position: its manual walks through
`max1` (double evaluation), `max2` (fixes that, but accidentally captures the
caller's `x`), `max3` (`gensym`), and `max4` (`with-syms`), then states plainly
that "programmer diligence is required."

vlip makes those exact failures **tests**, including the `max2` capture bug, so
the sharp edge is demonstrated rather than described.

`syntax-case` and `syntax` objects are deferred. When added they are opt-in per
macro, not per program. This is the one place vlip knowingly starts weaker than
Racket, on the grounds that a macro language nobody can learn is worse than one
whose footguns are documented.

## Features deliberately excluded from v1

Each of these is a real idea that is nonetheless wrong for a first version.

- **`eval` as the primary extension mechanism.** It forfeits arity checking, tail
  position analysis, and macro debugging. Every mature Lisp has moved to
  macro-as-compiler-function.
- **Common Lisp packages** (`foo::bar`, package locks, two-argument
  `find-symbol`). Clojure's namespaced maps replaced them and were strictly
  better.
- **CLOS.** Take multimethods and `call-next-method`; skip method combination
  qualifiers and the metaobject protocol.
- **Regex-first text processing.** Ship regex as a library; make PEGs the
  built-in parser generator.
- **Deep recursion as the default.** Stack depth is a property of the program,
  and tail calls are the answer, not a bigger stack.
- **Infix.** SRFI-105 curly infix is a fine idea and an unnecessary one. It
  costs a reader mode and buys nothing a `match` or a good macro cannot.
- **A self-hosted compiler.** Writing the standard library in vlip proves the
  language works. Compiling the compiler in itself is a later project, not a
  prerequisite, and Liu's L0 demonstrates the trick is available when wanted.

# Drawbacks

- **No static types in v1.** Optional annotations plus `vlip check` is a real
  answer, and it is a worse answer than Gleam's for programs that want the
  compiler to catch their mistakes. Programs that want that should use Gleam.
- **Slower than a mature bytecode VM** on tight loops, accepted in exchange for
  fibers-later and the absence of a codegen stage.
- **Non-hygienic macros.** A real class of bug that Racket users have never had
  to think about.
- **A second language to learn.** The pitch must survive that. It does only if
  the ergonomics genuinely deliver, which is why M8 has a hard gate: write a
  real ~300-line program without writing a macro. If that is impossible, the
  design has failed regardless of how good the VM is.
- **No `let-syntax`** until it exists; Steel has shipped without it and treats it
  as the last R5RS gap.
- **The `Value` representation may need `unsafe`.** Mitigated by confining it to
  one file, not eliminated.
- **`|>` and `->>` coexisting** is redundant sugar. Accepted because both spellings
  are already muscle memory for different communities, and dropping one would
  make the language feel foreign to half its likely users.

# Rationale and alternatives

**Why a Lisp at all, in 2026?** Because the surface is the cheapest possible
notation for the part of programming that is about transformation, and a
language that is pleasant to *transform* is pleasant to embed. vlip is aimed
first at being embedded in V applications as a configuration and scripting
layer, which is the position Janet occupies well and the one Steel's embedding
complaints (#413, #425, #692) show is underserved.

**Why not just use Steel?** Steel is a fine language and this is not a claim to
replace it. The reasons to build separately: it is Rust, so it cannot be
embedded in a V program without a C ABI; its hygiene is known-broken (#706); its
JIT has four recent miscompilation reports (#678, #680, #671, #656); its
super-instruction machinery is disabled behind `_USE_SUPER_INSTRUCTIONS = false`
with `todo!()` in the opcode width function; and a request for `impl`/`def-method`
(#651) suggests its object system is not actually reachable.

**Why not Janet?** Janet is the closest thing to the design and a better
project. The reasons to differ: Janet is C, not embeddable in V; Janet is
deliberately anti-macro and its manual's own caveat is that programmer diligence
is required; and its module system, while excellent, is oriented at Janet's own
`jpm`.

**Why not Fennel or Hy?** Both are excellent proof that a Lisp can be embedded in
a host language. Neither should be the identity of the language, because every
abstraction leaks the host's types, error model, and module system, and the host
wins every design argument. Fennel's single-`fn`-macro discipline is worth
stealing on its own.

**Why a CEK machine instead of bytecode?** Bytecode is faster and Steel proves
it works. The trade is made in favor of a machine whose stack is a heap array,
because that is what makes the fiber feature possible later without touching the
representation. A design that cannot cheaply become concurrent usually never
does.

**Why not just use Gleam?** Because Gleam has no macros, no exceptions, and no
`eval` — a deliberate, coherent choice for a statically typed language with a
compiler to back it up. A dynamic language that bans exceptions and has no type
checker just produces runtime panics with no exhaustiveness safety net. vlip
takes Gleam's *ergonomics* (`use`, labelled arguments, `Result` naming, opaque
types, `|>`) and none of its *prohibitions*.

**Impact of doing nothing:** the status quo is that anyone wanting Steel's
approach in V writes it themselves, and anyone wanting Gleam's ergonomics uses
Gleam and gives up macros.

# Prior art

**Steel** (Rust, `mattwparas/steel`, v0.8.3) is the closest relative and the
source of most of the pipeline shape. Verified directly from source: it is a
bytecode VM with no AST interpreter; the core AST is 14 node types; runtime
values are a 44-variant tagged enum; lists are persistent chunked structures
rather than cons cells; GC is reference counting plus mark-and-sweep with a
thread-biased `BiasedRc`; modules are Racket-style with a `.scm`/`.rkt`
split-brain over extensions and a `cog.scm` Scheme manifest. Two lessons
adopted and one not:

- *Adopted:* the last-use move optimization (`MOVEREADLOCAL`) — moving a
  refcounted local on its final use instead of copying it — which Steel reports
  as taking a 100k-element list reverse from 123 ms to 23 ms. vlip takes the
  idea and implements it later, once benchmarks justify it.
- *Adopted:* Racket-style `require`/`provide` with `only-in`, `prefix-in`, and
  `for-syntax`.
- *Rejected:* the fused expansion/lowering loop, for the reasons above.

**Racket** contributes `match*` and atomic multi-subject matching, `syntax-case`
and syntax objects, higher-order contracts, and the module system shape. Its
documented warning that match may re-evaluate subexpressions is adopted
verbatim into the vlip manual.

**Janet** contributes fibers, PEGs as a data-structure DSL, callable tables and
structs, the `@` mutable-collection prefix, table prototypes, the module system
as data (`module/paths`/`module/loaders`/`module/cache`, canonical keys, `./` vs
`/` vs `@`), `def`-is-constant versus `var`-is-mutable, and the honest unhygienic
macro documentation.

**Gleam** contributes `use`, dual-mode `|>` with `echo`, labelled arguments with
external/internal label split, the `Result` combinator naming discipline
including the `lazy_` prefix, `let assert`, opaque types with smart constructors,
and `assert`-as-documentation.

**Clojure** contributes transducers, the persistent-vector and HAMT data
structures, namespaced maps in place of CL packages, and protocols and
multimethods.

**Common Lisp** contributes multiple values and the advisory generic-function
idea. CLOS, conditions and restarts are declined.

**Other:** Nix for lazy evaluation and the demonstration that a build can be a
pure function of its inputs. Liu's L0/L1/L2/L3 bootstrap for the technique of
growing a compiler from a seed. Emacs Lisp for namespace-scoped dynamic bindings.
Uiua for the implicit-stack idea, and as a standing reminder that glyph
notation is superb for array math and terrible as a general-purpose notation.

# Unresolved questions

- **One `Node` type per stage, or distinct `Datum`/`Core`/`Program` types?**
  One type is simpler and matches `vlib/v/flat`; separate types make
  stage-mixing a compile error. Leaning toward one type for `Datum` and `Core`,
  with `Program` distinct because it is the one that must be tight.
- **Is the exhaustive-`match` checker a warning or an error by default?** Leaning
  warning by default, error under `#:strict`, so dynamic programs are not
  bricked by a static check they did not ask for.
- **Does `(p.x := 5)` earn its syntax, or should field access stay a function?**
  Leaning yes, because the field-name-to-accessor convention makes it a macro
  rather than core syntax, and it reads well.
- **Should `Value` be `int`-wide or `i64`-wide on 32-bit targets?** Fixnum
  width interacts with the integer tower's promotion rules.
- **Peak memory for a large program's `Program` IR.** With arenas released per
  stage this should be bounded, but the bound is unmeasured.

# Future possibilities

- **Fibers.** The reason the stack is a heap array. Yields exceptions, generators,
  green threads, coroutines, and an event loop from one primitive, with
  structured concurrency via trap masks as Janet does.
- **`syntax-case` and hygiene** as an opt-in layer over the existing `defmacro`.
- **A static checker** built on the erased annotations: bidirectional inference,
  exhaustiveness as an error, and an LSP that reports real types.
- **Parallelism.** Fibers are cooperative and do not help CPU-bound work; a
  thread pool over independent `Program`s is a separate feature.
- **A bytecode backend** for hot inner loops, compiled from the same `Program`
  IR, selected per function. The staged pipeline makes this additive rather than
  a rewrite — which is the main practical payoff of not fusing the passes.
- **Self-hosting.** The L0 trick, once the language stops moving.
- **PEGs as the built-in parser generator**, so that regex is a library rather
  than a builtin.

---

## Appendix A: syntax comparison

The same program in each language. Pipes are common to all of them; the
differences are in everything else.

**Top three word frequencies.**

```scheme
;; vlip
(define (top-words text n)
  (->> (string-split text " ")
       (keep string-not-blank?)
       (map string-downcase)
       frequencies
       (sort-by (fn (e) (- (get e 1))) #:reverse true)
       (take n)))
```

```racket
;; Racket
(define (top-words text n)
  (->> (string-split text " ")
       (filter string-not-blank?)
       (map string-downcase)
       frequencies
       (sort (lambda (a b) (> (cdr a) (cdr b))))
       (take n)))
```

```clojure
;; Clojure
(defn top-words [text n]
  (->> (str/split text #" ")
       (remove str/blank?)
       (map str/lower-case)
       (frequencies)
       (sort-by (comp - val))
       (take n)))
```

```janet
;; Janet
(defn top-words [text n]
  (->> (string/split " " text)
       (filter string/not-blank?)
       (map string/ascii-lower)
       (frequencies)
       (sort-by (fn [e] (- (e 1))))
       (take n)))
```

```gleam
// Gleam
pub fn top_words(text: String, n: Int) -> List(#(String, Int)) {
  text
  |> string.split(" ")
  |> list.filter(fn(s) { s != "" })
  |> list.map(string.lowercase)
  |> frequencies
  |> list.sort(fn(a, b) { int.compare(b.1, a.1) })
  |> list.take(n)
}
```

**The case vlip is actually for: two values, destructured once.**

```scheme
;; vlip — one match, one clause list
(match* (list (fetch key) (validate key))
  [(val nil)  (ok val)]
  [(nil _)    (err 'no-such-key)]
  [(_ err)   (err err)])
```

```racket
;; Racket — nested
(match (fetch key)
  [val (match (validate key)
     [(void)  (ok val)]
     [err    (err err)])]
  [no-such-key (err 'no-such-key)])
```

```gleam
// Gleam — nested use
case fetch(key) {
  Error(no_such_key) -> Error(NilKey)
  Ok(val) ->
    case validate(key) {
      Error(err) -> Error(err)
      Ok(Nil)    -> Ok(val)
    }
}
```

**Reading a tagged result.**

```scheme
;; vlip
(define (greet env)
  (match* (lookup-env env "USER")
    [(and s (not= s "")) s]
    [""                    "anonymous"]
    [_                    "unset"]))
```

```scheme
;; Racket — cond + match, three levels
(define (greet env)
  (define v (lookup-env env "USER"))
  (cond [(equal? v "") "anonymous"]
        [else
         (match v
           [(? string? s) s]
           [_ "unset"])]))
```

**Callbacks without nesting.**

```scheme
;; vlip
(use (with-open "data.csv")
  (csv-read it)
  (rows count))
```

```racket
;; Racket — let/ec gymnastics
(let/ec exit
  (call-with-input-file "data.csv"
    (lambda (in) (exit (csv-read in)))
    #:after close))
```

```scheme
;; Steel — same problem, via a contract on the port
(define (rows)
  (with-open "data.csv" (lambda (port) ...)))
```

## Appendix B: feature comparison

| | **vlip** | Steel | Gleam | Janet | Racket | Clojure | Hy | Fennel |
|---|---|---|---|---|---|---|---|---|
| Host | V | Rust | BEAM | C | Racket/C | JVM | Python | Lua |
| Typing | optional, erased | **none** | full, static | none | optional | optional | dynamic | dynamic |
| Static exhaustiveness | planned | no | **yes** | no | no | no | no | no |
| Tail calls | **full, incl. mutual** | self + some | yes | yes | yes | no | no (host) | no (host) |
| Atomic multi-subject match | **`match*`** | no | no | no | **`match*`** | no | no | no |
| `use` / flat callbacks | **yes** | no | **yes** | `protect` | `let/ec` | no | no | no |
| Macros | unhygienic + `gensym` | 4 mechanisms | **none** | unhygienic | **`syntax-case`** | unhygienic | yes | yes |
| Errors | `Result` **and** raise | `Result` + raise | `Result` only | fibers | raise + contracts | raise + ex-info | raise | `pcall` |
| Concurrency | fibers planned | threads + async | processes | **fibers now** | threads | futures | threads | coroutines |
| Encapsulation | **opaque types** | `impl` (unreachable) | opaque types | prototypes | modules | protocols | — | metatables |
| Numeric tower | int/float/rational/bignum | same + complex | int/float | int/float/rational | exact | int/bigint | Python | Lua |
| Mutation | `@` prefix | `mutable` structs | none | `@` prefix | boxes | atoms | Python | native |
| Text parsing | PEGs planned | built-in | none built-in | **PEGs only** | regex + PEG | regex | Python | patterns |
| Self-hosted | no | dormant `.rkt` | n/a | C bootstrap | **yes** | no | no | no |
| Every value callable | planned | partial | no | **yes** | partial | partial | no | no |
| Numeric operators split | no | no | **`+.` vs `+`** | no | no | no | no | no |

Rows marked **bold** are the ones where the language is the reference
implementation, and rows where vlip is best are the point of the exercise.

## Appendix C: what vlip borrows, and from where

| Idea | From | Milestone |
|---|---|---|
| Flat node arena, `u8` node kinds | V's own `vlib/v/flat` | M1 |
| Staged passes with distinct IRs | *this RFC*, against Steel | M1–M4 |
| CEK machine with heap stack | Janet (fiber rationale) | M3 |
| Scoped `-prealloc` arenas | V's compiler | M0 |
| No generics | V's compiler (`pref.v:57`) | M0 |
| `match`, `let assert`, guards | Racket, Gleam | M8 |
| **`match*`** | **Racket** | **M8** |
| Contracts `define/contract`, `->/c` | Racket, Steel | M10 |
| `use` | **Gleam** | M8 |
| dual-mode `\|>`, `echo` tap | **Gleam** | M8 |
| labelled args, `lazy_` naming | **Gleam** | M8 |
| opaque types | **Gleam** | M8 |
| callable tables, `@` mutable | Janet | M8 |
| `gensym` + `macex1`, unhygienic base | Janet | M5 |
| module system as data, canonical keys | Janet | M6 |
| last-use move (`MOVEREADLOCAL`) | Steel | post-M8 |
| transducers | Clojure | post-M8 |
| PEGs instead of builtin regex | Janet | post-M8 |
| span-carrying diagnostics | Steel (`codespan` rendering) | M9 |