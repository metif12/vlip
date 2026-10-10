# blip for Visual Studio Code

blip language support: syntax highlighting, snippets, and reader diagnostics
from the blip language server. The grammar follows the reader
(`vlib/blip/reader/mod.v`) rather than a generic Lisp grammar, so it highlights
the tokens this implementation of blip actually accepts.

## Install from source

Needs a blip executable on `PATH`. Build it with:

```sh
v -cc gcc -o blip.exe blip.v
```

Then build the extension:

```sh
cd editors\vscode
npm install
npm run compile
```

`npm run compile` runs `tsc -p .` and writes `out/extension.js`. To iterate,
run `npm run watch` instead. Press `F5` in VS Code to open a window with the
extension loaded.

## Packaging

`vsce package` needs a `publisher` in `package.json`, which is deliberately
left out until one is chosen. Set it before packaging, or pass `--publisher`
on the command line.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `blip.server.command` | `blip` | Path or command name of the blip executable. |
| `blip.server.args` | `["lsp"]` | Arguments passed to it. The language server is the `lsp` subcommand. |

The extension starts `blip lsp` over stdio when a `.lip` file is opened. There
are no other settings, because the server reads no others: it answers
`initialize` with diagnostics only, so no setting is forwarded to it with
`workspace/didChangeConfiguration`.

## What the server does today

The server in `vlib/blip/lsp/mod.v` publishes reader diagnostics for files it
has seen. That means unbalanced brackets, unterminated strings and bar symbols,
bad hex characters, and rationals with a zero denominator. Everything else a
language server could offer -- completion, hover, definitions, formatting -- is
not in the server yet, so this extension does not pretend to have it either.

Run `blip: Restart blip Language Server` from the command palette to restart it
after changing `blip.server.command` or rebuilding blip. The
`blip Language Server` output channel holds the client log.

## Grammar notes

The TextMate grammar covers exactly what `reader/mod.v` reads:

- `;` line comments and `#| ... |#` block comments, which nest.
- `#;` datum comments, which skip exactly one following form. Only the `#;` is
  scoped as a comment; the form it skips is still highlighted as code.
- Strings with the escapes the reader folds: `\n`, `\t`, `\r`, `\0`, `\\`, `\"`.
  Any other escape is passed through by the reader, so the grammar leaves it in
  string scope rather than marking it invalid.
- Character literals `#\a`, `#\newline`, `#\space`, `#\n`, `#\x41`. The named
  forms are the ones `read_character` knows: `newline`, `linefeed`, `tab`,
  `space`, `return`, `carriage-return`, `backspace`, `escape`, `null`, `nul`,
  `alpha`.
- `#t` and `#f`, and `nil` when it stands alone -- `nil?` is the primitive and
  stays a symbol.
- Numbers: decimal integers, floats, rationals `a/b`, and `0x`, `0b`, `0o`
  radix forms, each with an optional sign. `.5` and `-.5` are floats.
- `:keyword` symbols, and `#:name` the labelled-argument and struct-option
  spelling `#:mutable`, `#:opaque`, `#:catch`.
- `|...|` bar symbols, which may contain spaces and delimiters, and the
  operators that begin with a bar: `|>`, `||`, `|*>`.
- `'`, `` ` ``, `,`, `,@`, and `@` in front of a bracket for a mutable
  collection.

The special forms are highlighted only in head position, so a binding or a
parameter that happens to be named `if` stays a symbol. The list is the
`special_form` list in `vlib/blip/machine/mod.v`. `let-assert` is absent from
the grammar because the form that works is `(let assert ...)`.

## License

MIT. See [LICENSE](./LICENSE).
