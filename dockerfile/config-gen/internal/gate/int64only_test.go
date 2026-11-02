package gate

import (
	"bytes"
	"errors"
	"math/big"
	"regexp"
	"strings"

	"github.com/BurntSushi/toml"
)

// intLiteral is the TOML 1.0 ABNF integer: decimal with an optional sign,
// or an unsigned 0x/0o/0b form, `_` only between digits.
var intLiteral = regexp.MustCompile(`^(?:[+-]?(?:0|[1-9](?:_?[0-9])*)|0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*|0o[0-7](?:_?[0-7])*|0b[01](?:_?[01])*)$`)

var (
	int64Min = big.NewInt(0).Lsh(big.NewInt(-1), 63)
	int64Max = big.NewInt(0).Sub(big.NewInt(0).Lsh(big.NewInt(1), 63), big.NewInt(1))
)

// int64Only reports whether err, BurntSushi's refusal of src, is only the
// differential's tolerated disagreement (base#1441):
// every refusal is a value-position integer literal outside int64, and
// with each such literal replaced by 0 the decode succeeds. It reads the
// error's byte span only, never its message.
func int64Only(src []byte, err error) bool {
	if bytes.HasPrefix(src, []byte("\xEF\xBB\xBF")) {
		return false
	}
	cur := append([]byte(nil), src...)
	last := -1
	for err != nil {
		var pe toml.ParseError
		if !errors.As(err, &pe) {
			return false
		}
		start, end := pe.Position.Start, pe.Position.Start+pe.Position.Len
		if start <= last || start < 0 || pe.Position.Len <= 0 || end > len(cur) {
			return false
		}
		tok := string(cur[start:end])
		if !outOfInt64(tok) || !valuePosition(cur, start, end) {
			return false
		}
		cur = splice(cur, start, end, "0")
		last = start
		err = decode(cur)
	}
	return last >= 0
}

// outOfInt64 reports whether tok is a TOML integer literal whose value is
// below -2^63 or above 2^63-1.
func outOfInt64(tok string) bool {
	if !intLiteral.MatchString(tok) {
		return false
	}
	digits, base := strings.ReplaceAll(tok, "_", ""), 10
	switch {
	case strings.HasPrefix(digits, "0x"):
		digits, base = digits[2:], 16
	case strings.HasPrefix(digits, "0o"):
		digits, base = digits[2:], 8
	case strings.HasPrefix(digits, "0b"):
		digits, base = digits[2:], 2
	}
	n, ok := new(big.Int).SetString(strings.TrimPrefix(digits, "+"), base)
	return ok && (n.Cmp(int64Min) < 0 || n.Cmp(int64Max) > 0)
}

// valuePosition reports whether the span [start, end) of src sits where a
// value goes: putting `[]` (a value, never a key) there raises no error
// at start.
func valuePosition(src []byte, start, end int) bool {
	var pe toml.ParseError
	if err := decode(splice(src, start, end, "[]")); errors.As(err, &pe) && pe.Position.Start == start {
		return false
	}
	return true
}

func splice(src []byte, start, end int, with string) []byte {
	out := append([]byte(nil), src[:start]...)
	out = append(out, with...)
	return append(out, src[end:]...)
}

func decode(src []byte) error {
	var v map[string]any
	_, err := toml.Decode(string(src), &v)
	return err
}
