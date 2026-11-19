package gate

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
)

// FuzzCheck holds Check to its contract on any input (base#1850): no
// panic; the same input gives the same result twice; a refusal is a
// *Refusal whose Line:Col names a byte inside the input. suffixProperty
// appends each forbidden suffix to the input and requires a nil Check to
// mean the decoder refuses the whole document. prefixProperty puts each
// prefix the decoder strips (parse.go:47-51) before the input and
// requires a ReasonBOM refusal at 1:1. The seeds are every TOML file
// under testdata/forms plus a literal for each refusal class and the
// UTF-16 byte order mark rows.
func FuzzCheck(f *testing.F) {
	err := filepath.WalkDir(filepath.Join("testdata", "forms"), func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".toml") {
			return err
		}
		src, err := os.ReadFile(p)
		if err == nil {
			f.Add(src)
		}
		return err
	})
	if err != nil {
		f.Fatal(err)
	}
	for _, s := range []string{
		"a = \"x\\e\"\n",
		"a = \"x\\x41\"\n",
		"a = \"\"\"a\" \\x41\"\"\"\n",
		"a = '''x''''\nb = \"\\e\"\n",
		"a = {b = 1,\n}\n",
		"a = {b = 1, }\n",
		"a = 07:32\n",
		"a = [ # c\n  07:32\n]\n",
		"\xEF\xBB\xBFa = 1\n",
		"\xFF\xFEa = 1\n",
		"\xFE\xFFa = 1\n",
		"\xFF\xFE",
		"a = 1\n\xFF\xFEb = 2\n",
		"a = '\xFF\xFE'\n",
		"a = '''\xFF\xFE'''\n",
		"# \xFE\xFF\na = 1\n",
	} {
		f.Add([]byte(s))
	}
	suffixControls(f)
	f.Fuzz(func(t *testing.T, src []byte) {
		suffixProperty(t, src)
		prefixProperty(t, src)
		err := Check("f.toml", src)
		if again := Check("f.toml", src); errString(err) != errString(again) {
			t.Fatalf("Check gave %q, then %q", errString(err), errString(again))
		}
		if err != nil {
			var r *Refusal
			if !errors.As(err, &r) {
				t.Fatalf("Check() = %T %v, want *Refusal", err, err)
			}
			if !inside(src, r.Line, r.Col) {
				t.Fatalf("Refusal at %d:%d names no byte of the %d-byte input", r.Line, r.Col, len(src))
			}
		}
	})
}

// forbiddenSuffixes are one statement each of the refused forms that
// BurntSushi v1.6.0 accepts on its own: a `\e` escape, an inline table's
// trailing comma and a line ending inside an inline table (base#1850).
// Each starts with a line ending, so it opens a new statement after any
// input that ends outside a string.
var forbiddenSuffixes = []string{
	"\nzz = \"\\e\"\n",
	"\nzz = {x = 1,}\n",
	"\nzz = {\nx = 1}\n",
}

// suffixControls fails the fuzz target unless each forbidden suffix, on
// its own, is a document BurntSushi decodes and Check turns away, and
// each prefix in bomPrefixes followed by a plain key is a document
// BurntSushi decodes. A decoder bump that starts refusing one fails here
// instead of making a property hold vacuously.
func suffixControls(f *testing.F) {
	for _, s := range forbiddenSuffixes {
		var v map[string]any
		if _, err := toml.Decode(s, &v); err != nil {
			f.Fatalf("toml.Decode(%q) = %v, want nil: the suffix no longer tests the gate", s, err)
		}
		if Check("s.toml", []byte(s)) == nil {
			f.Fatalf("Check(%q) = nil, want a refusal", s)
		}
	}
	for _, p := range bomPrefixes {
		s := string(p) + "a = 1\n"
		var v map[string]any
		if _, err := toml.Decode(s, &v); err != nil {
			f.Fatalf("toml.Decode(%q) = %v, want nil: the prefix no longer tests the gate", s, err)
		}
	}
}

// suffixProperty appends each forbidden suffix to src. When Check accepts
// the result, the decoder must refuse it: BurntSushi accepts the suffix
// on its own, so a nil Check holds only when src makes the whole document
// invalid. A reader that misreads a quote in src, and so reads the suffix
// as string content, breaks this on an input whose document is otherwise
// valid.
func suffixProperty(t *testing.T, src []byte) {
	t.Helper()
	for _, s := range forbiddenSuffixes {
		doc := append(bytes.Clone(src), s...)
		if Check("f.toml", doc) != nil {
			continue
		}
		var v map[string]any
		if _, err := toml.Decode(string(doc), &v); err == nil {
			t.Fatalf("Check(%q) = nil and BurntSushi decodes it: the suffix %q went unrefused", doc, s)
		}
	}
}

// prefixProperty puts each of the three prefixes the decoder strips
// before src and requires a ReasonBOM refusal at 1:1, whatever follows.
// The prefixes are written out here, not read from bomPrefixes, so a gate
// list that drops one fails.
func prefixProperty(t *testing.T, src []byte) {
	t.Helper()
	for _, p := range []string{"\xEF\xBB\xBF", "\xFF\xFE", "\xFE\xFF"} {
		doc := append([]byte(p), src...)
		var r *Refusal
		if err := Check("f.toml", doc); !errors.As(err, &r) || r.Line != 1 || r.Col != 1 || r.Reason != ReasonBOM {
			t.Fatalf("Check(%q) = %v, want a ReasonBOM refusal at 1:1", doc, err)
		}
	}
}

// errString is err's text, or "" for nil.
func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// inside reports whether 1-based line and byte column col name a byte of
// src that is not past the end of its line.
func inside(src []byte, line, col int) bool {
	if line < 1 || col < 1 {
		return false
	}
	start := 0
	for n := 1; n < line; n++ {
		i := bytes.IndexByte(src[start:], '\n')
		if i < 0 {
			return false
		}
		start += i + 1
	}
	off := start + col - 1
	return off < len(src) && bytes.IndexByte(src[start:off], '\n') < 0
}
