package gate

// dateRule reads tok, a bare value token the table pass parsed (a number,
// boolean, date or time, trailing blanks excluded), as a TOML date or
// time and reports the first field tomllib refuses while BurntSushi takes
// it (base#1441): a year below 1 (tomllib builds a datetime.date, whose
// range starts at year 1), a time written as HH:MM without seconds (TOML
// 1.1 only), or an offset hour above 23 or minute above 59. at is the
// offending byte's offset within tok: the token's first byte for the year
// and the seconds, the offset's sign for the offset. ok is false when tok
// breaks none of these rules, including when it is not a date or time.
// It reads parsed value tokens only, so a key, header, string or comment
// that holds the same text never reaches it.
func dateRule(tok []byte) (at int, reason Reason, text string, ok bool) {
	if len(tok) >= 10 && digits(tok[0:4]) && tok[4] == '-' && digits(tok[5:7]) && tok[7] == '-' && digits(tok[8:10]) {
		if num(tok[0:4]) < 1 {
			return 0, ReasonDateRange, "", true
		}
		if len(tok) == 10 || (tok[10] != 'T' && tok[10] != 't' && tok[10] != ' ') {
			return 0, 0, "", false
		}
		return timeRule(tok, 11)
	}
	return timeRule(tok, 0)
}

// timeRule reads the time that starts at offset i of tok (i is 0 for a
// local time, 11 after a date and its delimiter); see dateRule. An offset
// is read only after a date.
func timeRule(tok []byte, i int) (at int, reason Reason, text string, ok bool) {
	t := tok[i:]
	if len(t) < 5 || !digits(t[0:2]) || t[2] != ':' || !digits(t[3:5]) {
		return 0, 0, "", false
	}
	if len(t) == 5 || (t[5] != ':' && !isDigit(t[5])) {
		return 0, ReasonTimeNoSeconds, "time without seconds is not TOML 1.0", true
	}
	if i == 0 || len(t) < 8 || t[5] != ':' || !digits(t[6:8]) {
		return 0, 0, "", false
	}
	j := 8
	if j < len(t) && t[j] == '.' {
		j++
		for j < len(t) && isDigit(t[j]) {
			j++
		}
	}
	off := t[j:]
	if len(off) != 6 || (off[0] != '+' && off[0] != '-') || !digits(off[1:3]) || off[3] != ':' || !digits(off[4:6]) {
		return 0, 0, "", false
	}
	switch {
	case num(off[1:3]) > 23:
		return i + j, ReasonOffsetRange, "offset hour above 23 is not TOML 1.0", true
	case num(off[4:6]) > 59:
		return i + j, ReasonOffsetRange, "offset minute above 59 is not TOML 1.0", true
	}
	return 0, 0, "", false
}

// digits reports whether b is non-empty and all ASCII digits.
func digits(b []byte) bool {
	for _, c := range b {
		if !isDigit(c) {
			return false
		}
	}
	return len(b) > 0
}

// num returns the value of b, which digits accepted.
func num(b []byte) int {
	n := 0
	for _, c := range b {
		n = n*10 + int(c-'0')
	}
	return n
}
