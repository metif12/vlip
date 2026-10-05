# Contributing to vlip

Thanks for looking. This file is short on ceremony and specific about the things
that will otherwise waste your afternoon.

vlip is early. The reader and the machine run real programs, tail calls are
real, and the six programs in `examples/` are the specification the interpreter
is written against. Three documented things do not work yet, and they are named
in the README, in `tests/tail_calls.v`, and in `docs/010-roadmap.md` rather than
quietly missing.

## Branches

```
main   stable. Only releases come from here. Protected: no direct pushes.
dev      integration. Where pull requests land.
<topic>  a branch off dev, named after what it does
```

- Branch off `dev`, not `main`.
- Open the pull request against `dev`.
- `dev` is merged into `main` when a milestone's gate is met, and that merge is
  what a release is cut from.
- A release is a tag on `main` (`v0.2.0`), pushed deliberately. `.github/workflows/release.yml`
  builds and verifies on the tag; a manual run of that workflow builds and
  verifies but never publishes, so a dry run cannot create a release by accident.

Why two long-lived branches rather than one: `main` is what someone can depend
on, so it has to move only when something is genuinely finished. With one branch,
every half-finished interpreter is the thing people install.

## Build and test

Requires V 0.5.2, specifically **vlang/v main at the commit pinned in
`.github/workflows/ci.yml`**. That is not pedantry — the `0.5.2` release build
resolves `vlib.vlip.*` against V's own standard library and reports every module
in this repository as an unknown function, for files that exist and compile
locally. See section 7.1a of `docs/010-roadmap.md`.

On Linux, `v` defaults to its experimental V3 compiler and silently falls back
to the established one, which resolves modules differently again. If you get a
wall of `unknown function` errors on files that build fine, set this first:

```sh
export V_MACOS_V3_NO_FALLBACK=1
```

Always pass `-cc gcc`. The default C backend fails on this checkout, and CI uses
the same flag so the two cannot drift apart.

```sh
v -cc gcc -o vlip.exe vlip.v                  # the CLI
.\vlip.exe examples\01_basics.lip

v -cc gcc -o tools\tail.exe tests\tail_calls.v && .\tools\tail.exe
v -cc gcc -o tools\nt.exe   tests\non_tail.v   && .\tools\nt.exe
v -cc gcc -o tools\lf.exe   tests\loop_forms.v && .\tools\lf.exe

v -cc gcc -o reader_probe.exe reader_probe.v
.\reader_probe.exe examples\*.lip
```

All three suites must print no `FAIL` line and the reader probe must report zero
diagnostics. The runners do not set a non-zero exit code yet, which is why CI
greps for `FAIL` — see the roadmap. Turning `panic` into a returned error is the
first item on the list and will fix that properly.

## Adding to the interpreter

- **Test first, in the shape that would have caught the bug.** `tests/non_tail.v`
  exists because every tail-call test passed while `(fib 20)` returned `-360`.
  The regression cases are the ones that separate your bug from the plausible
  alternatives; write those.
- **A comment earns its place by explaining a non-obvious choice.** Several in
  `machine/mod.v` explain why the obvious version is wrong, because I wrote the
  obvious version first and it was wrong. Do the same.
- **Do not paper over a V quirk without saying so.** The index loops and the
  `NodeId` workarounds are load-bearing and platform-dependent. If you remove one
  because the compiler was fixed, remove its comment in the same commit.

## The website

The site is generated. Do not edit anything in `site_out/`, and do not add
hand-written HTML to `site/`.

```sh
v -cc gcc -o sitegen.exe tools\sitegen.v
.\sitegen.exe
```

- Page structure lives in `tools/sitegen.v`, as V data.
- All user-visible text lives in `site/i18n/<code>.json`, as a flat
  `{"key": "text"}` map. English is the reference; every other language falls
  back to it.
- A block with any untranslated key is labelled as untranslated in the output.
  That is deliberate: a partially translated page must say so rather than quietly
  mixing two languages.

### Adding a language

1. Add it to `langs()` in `tools/sitegen.v`, with `dir: 'rtl'` for a
   right-to-left script.
2. Copy `site/i18n/en.json` to `site/i18n/<code>.json` and translate the values.
   Leave the keys alone — the generator uses them as identifiers.
3. Run `sitegen` and check the summary: it prints the key count and how many
   blocks fall back to English.
4. Commit both files. CI fails if any expected language directory is missing or
   empty.

A partial translation is genuinely useful. The generator handles it, labels it,
and a reader is better served by a half-Persian page that admits it than by no
Persian page.

## Reporting a bug

Include the V version (`v version` — the build hash matters), the platform, the
smallest program that shows it, and what you expected. A non-tail recursion bug
report is worth much more with the `(fib 20)` result and the continuation depth
at the end.

## Licence

MIT.
