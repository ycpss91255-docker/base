package gate

import (
	"errors"
	"testing"
)

// definedTwice are documents that define a key path a second time, each
// with the refusal Check returns (base#1851): the reason, and the line and
// column of the first byte of the key or header that breaks the rule,
// counted by hand. The first rows put a plain duplicate after each token
// form the table pass must read past (a CRLF line ending, comments, the
// four string forms with quotes and line endings inside, a datetime with
// a space delimiter, nested arrays, quoted and spaced keys), so a pass
// that misreads one stops early and misses the duplicate. The rest hold
// each table rule: a dotted key through a value or a header's table, a
// header over a value, a dotted-key table or a header's table, and a key
// repeated inside an inline table at any depth.
var definedTwice = []struct {
	name, src string
	line, col int
	reason    Reason
}{
	{"key", "a = 1\na = 2\n", 2, 1, ReasonDuplicate},
	{"crlf", "a = 1\r\na = 2\r\n", 2, 1, ReasonDuplicate},
	{"comments-no-final-lf", "# c\na = 1 # c\n\n  a = 2", 4, 3, ReasonDuplicate},
	{"ml-basic", "a = \"\"\"\nx = 1\n\"\"\"\nx = 1\nx = 2\n", 5, 1, ReasonDuplicate},
	{"ml-literal-close5", "a = '''\nx = 1\n'''''\nx = 1\nx = 2\n", 5, 1, ReasonDuplicate},
	{"basic-escaped-quote", "a = \"x\\\"y\"\na = 2\n", 2, 1, ReasonDuplicate},
	{"literal-backslash", "a = 'c:\\'\na = 2\n", 2, 1, ReasonDuplicate},
	{"datetime-space", "a = 1979-05-27 07:32:00\na = 2\n", 2, 1, ReasonDuplicate},
	{"arrays", "a = [\n  1, # c\n  [2], {b = 3},\n]\na = 2\n", 5, 1, ReasonDuplicate},
	{"basic-key", "\"a\" = 1\na = 2\n", 2, 1, ReasonDuplicate},
	{"basic-key-escape", "\"\\u0061\" = 1\na = 2\n", 2, 1, ReasonDuplicate},
	{"spaced-dotted-key", "a . b = 1\na.b = 2\n", 2, 1, ReasonDuplicate},
	{"aot-header-close", "[[a]]\n[[a]]\nb = 1\nb = 2\n", 4, 1, ReasonDuplicate},
	{"dotted-through-scalar", "a = 1\na.b = 2\n", 2, 1, ReasonDuplicate},
	{"dotted-through-inline", "a = {b = 1}\na.c = 2\n", 2, 1, ReasonDuplicate},
	{"dotted-through-header", "[x.y]\n[x]\ny.z = 1\n", 3, 1, ReasonRedefine},
	{"header-over-dotted", "a.b = 1\n[a]\n", 2, 1, ReasonRedefine},
	{"header-through-scalar", "a = 1\n[a.b]\n", 2, 1, ReasonDuplicate},
	{"header-through-inline", "a = {}\n[a.b]\n", 2, 1, ReasonRedefine},
	{"aot-through-inline", "a = {}\n[[a.b]]\n", 2, 1, ReasonDuplicate},
	{"header-through-array", "a = []\n[a.b]\n", 2, 1, ReasonRedefine},
	{"aot-over-table", "[a]\n[[a]]\n", 2, 1, ReasonDuplicate},
	{"header-twice", "[ a . b ]\n[a.b]\n", 2, 1, ReasonRedefine},
	{"header-over-aot", "[[a]]\n[a]\n", 2, 1, ReasonRedefine},
	{"header-over-inline", "a = {}\n[a]\n", 2, 1, ReasonRedefine},
	{"header-over-array", "a = []\n[a]\n", 2, 1, ReasonRedefine},
	{"header-over-scalar", "a = 1\n[a]\n", 2, 1, ReasonDuplicate},
	{"inline-dotted-through-scalar", "a = {b = 1, b.c = 2}\n", 1, 13, ReasonDuplicate},
	{"inline-in-inline", "a = {b = {c = 1, c = 2}}\n", 1, 18, ReasonDuplicate},
	{"inline-in-array", "a = [{b = 1, b = 2}]\n", 1, 14, ReasonDuplicate},
}

// Check refuses every definedTwice row with its reason at its byte.
func TestCheckRefusesKeyPathDefinedTwice(t *testing.T) {
	for _, tc := range definedTwice {
		var r *Refusal
		if err := Check("t.toml", []byte(tc.src)); !errors.As(err, &r) {
			t.Errorf("%s: Check(%q) = %v, want *Refusal", tc.name, tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Reason != tc.reason {
			t.Errorf("%s: Check(%q) Refusal = {%q %d %d %v}, want {\"t.toml\" %d %d %v}",
				tc.name, tc.src, r.File, r.Line, r.Col, r.Reason, tc.line, tc.col, tc.reason)
		}
	}
}

// Check returns nil on documents whose paths are each defined once
// (base#1851): a dotted-key table extended by more dotted keys, a table
// defined after its subtable, a subtable of an array of tables, a key
// repeated in another array-of-tables element or another table, a dotted
// key inside an inline table extended there, a literal key that holds
// escape or quote bytes (a literal string decodes nothing), and a
// document that ends in a blank or with no final line ending.
func TestCheckAcceptsKeyPathsDefinedOnce(t *testing.T) {
	for _, src := range []string{
		"a.b = 1\na.c = 2\n",
		"[a.b]\n[a]\n",
		"[[a]]\n[a.b]\n",
		"[[a]]\nb = 1\n[[a]]\nb = 2\n",
		"[a]\nb = 1\n[c]\nb = 1\n",
		"a = {b.c = 1, b.d = 2}\n",
		"'\\u0061' = 1\na = 2\n",
		"'\"a\"' = 1\na = 2\n",
		"a = {}\nb = []\nc = 1 ",
		"a = 1\nb = 2",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
}
