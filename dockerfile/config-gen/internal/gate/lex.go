package gate

import "regexp"

// barePattern matches the bare token (bare key, number, boolean, date or
// time) at the start of its input. A full date followed by a space and a
// digit takes the space and the run after it too, so that a local
// datetime with a space delimiter is one token.
var barePattern = regexp.MustCompile(`^(?:\d{4}-\d{2}-\d{2} \d[0-9A-Za-z_+.:-]*|[0-9A-Za-z_+.:-]+)`)

// timePattern matches a time written as HH:MM without the seconds the
// TOML 1.0 partial-time requires (TOML 1.1 only, base#1850): a local
// time, or the time after a full date and its `T`, `t` or space
// delimiter, with no `:` or digit after the minutes.
var timePattern = regexp.MustCompile(`^(?:\d{4}-\d{2}-\d{2}[Tt ])?\d{2}:\d{2}(?:$|[^:0-9])`)

// dateRule reports whether tok, a bare token outside any string or
// comment, is a time without seconds; see timePattern.
func dateRule(tok []byte) bool {
	return timePattern.Match(tok)
}

// yearZeroPattern matches a token that starts with a full date (YYYY-MM-DD)
// whose year is 0000.
var yearZeroPattern = regexp.MustCompile(`^0000-\d{2}-\d{2}`)

// yearZero reports whether tok, a bare value token, is a date-bearing
// value whose year is 0000, which tomllib refuses (it builds a
// datetime.date, whose range starts at year 1) and BurntSushi v1.6.0
// accepts (base#1851).
func yearZero(tok []byte) bool {
	return yearZeroPattern.Match(tok)
}
