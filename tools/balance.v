import os

// Counts brace nesting while ignoring char literals, strings and comments, so
// "unexpected token }" can be traced to a real imbalance rather than guessed at.
const (
	bt = u8(96)
	sq = u8(39)
)

path := os.args[1]
mut src := os.read_file(path) or { panic('cannot read') }

mut depth := 0
mut i := 0
mut line := 1
mut in_line_comment := false

for i < src.len {
	c := src[i]
	if in_line_comment {
		if c == `\n` {
			in_line_comment = false
			line++
		}
		i++
		continue
	}
	if c == `'` && i + 1 < src.len {
		// char literal, unless it's an apostrophe inside a symbol/name
		if i + 2 < src.len && src[i + 2] == `'` {
			i += 3
			continue
		}
		// backtick char literal
	}
	if c == bt {
		i += 2
		continue
	}
	if c == sq {
		i++
		continue
	}
	if c == `"` {
		i++
		for i < src.len && src[i] != `"` {
			if src[i] == `\\` {
				i++
			}
			i++
		}
		i++
		continue
	}
	if c == `/` && i + 1 < src.len && src[i + 1] == `/` {
		in_line_comment = true
		i += 2
		continue
	}
	if c == `{` {
		depth++
	} else if c == `}` {
		depth--
		if depth < 0 {
			println('line ${line}: depth went NEGATIVE here')
			return
		}
	}
	if c == `\n` {
		line++
	}
	i++
}
println('final depth = ${depth} (0 means balanced)')