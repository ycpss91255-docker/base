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

// offsetPattern matches a token that starts with an offset datetime (a
// full date, a `T`, `t` or space delimiter and a time with seconds),
// capturing the offset's sign, hour and minute.
var offsetPattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?([+-])(\d{2}):(\d{2})`)

// offsetOutOfRange reports whether tok, a bare token, is an offset
// datetime whose offset hour is above 23 or whose offset minute is above
// 59, which tomllib refuses at the sign and BurntSushi v1.6.0 accepts
// (base#1851); at is the sign's offset in tok.
func offsetOutOfRange(tok []byte) (at int, ok bool) {
	m := offsetPattern.FindSubmatchIndex(tok)
	if m == nil {
		return 0, false
	}
	hour, minute := tok[m[4]:m[5]], tok[m[6]:m[7]]
	return m[2], hour[0] > '2' || (hour[0] == '2' && hour[1] > '3') || minute[0] > '5'
}
