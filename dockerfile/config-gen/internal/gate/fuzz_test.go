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

// FuzzCheck holds Check and Normalize to their contract on any input
// (base#1441 seam 3): no panic; the same input gives the same result
// twice; a refusal is a *Refusal whose Line:Col names a byte inside the
// input; and when Check returns nil, Normalize keeps the input's length
// and every CR and LF at its offset, so a decoder's line and column still
// index the input. When Check accepts a document BurntSushi also
// decodes, dupProperty adds known duplicates to it and Check itself must
// refuse each with the duplicate class's text (base#1441 redesign r3 R9).
// Separately, suffixProperty appends each forbidden suffix to the input
// and requires a nil Check to mean the decoder refuses the whole
// document (base#1441 redesign r2 R6).
// The seeds are every TOML file under testdata/forms and
// testdata/toml-test plus a few literals for each refusal class; `go
// test` runs them, and the test stage's fuzz gate searches from them for
// 60 s.
func FuzzCheck(f *testing.F) {
	for _, dir := range []string{"forms", "toml-test"} {
		err := filepath.WalkDir(filepath.Join("testdata", dir), func(p string, d fs.DirEntry, err error) error {
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
	}
	for _, s := range []string{
		"a = \"x\\e\"\n",
		"a = \"\"\"a\" \\x41\"\"\"\n",
		"a = {b = 1,\n}\n",
		"a = {b = 1, }\n",
		"a = 07:32\n",
		"\xEF\xBB\xBFa = 1\n",
		"a = 1\na = 2\n",
		"a.b = 1\n[a.b]\n",
		"a = 2021-01-01T00:00:00+24:00\n",
		"a = [ # c\n 0000-01-01\n]\n",
		"a = " + strings.Repeat("[", 600) + "\n",
		"a = 1e999\nb = [-1e999]\n",
		"a = []\n[[a]]\n",
		"\"a\\u0000b\" = 1\na.b = 2\n",
	} {
		f.Add([]byte(s))
	}
	suffixControls(f)
	f.Fuzz(func(t *testing.T, src []byte) {
		suffixProperty(t, src)
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
			return
		}
		norm := Normalize(src)
		if len(norm) != len(src) {
			t.Fatalf("Normalize changed the length %d -> %d", len(src), len(norm))
		}
		for i, c := range src {
			if (c == '\n' || c == '\r') && norm[i] != c {
				t.Fatalf("Normalize changed the line ending byte at offset %d", i)
			}
		}
		dupProperty(t, src)
	})
}

// forbiddenSuffixes are one statement each of the refused forms that
// BurntSushi v1.6.0 accepts on its own: a `\e` escape, an inline table's
// trailing comma, a line ending inside an inline table, and a year-zero
// date (base#1441 redesign r2 R6). Each starts with a line ending, so it
// opens a new statement after any input that ends outside a string.
var forbiddenSuffixes = []string{
	"\nzz = \"\\e\"\n",
	"\nzz = {x = 1,}\n",
	"\nzz = {\nx = 1}\n",
	"\nzz = 0000-01-01\n",
}

// suffixControls fails the fuzz target unless each forbidden suffix, on
// its own, is a document BurntSushi decodes and Check turns away. The
// suffix property holds only while the decoder accepts what the gate
// must refuse, so a decoder bump that starts refusing a suffix fails
// here instead of making the property hold vacuously.
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
}

// suffixProperty appends each forbidden suffix to src. When Check accepts
// the result, the decoder must refuse it: BurntSushi accepts the suffix
// on its own, so a nil Check holds only when src makes the whole document
// invalid. A reader that misreads a quote in src, and so reads the suffix
// as string content, breaks this on an input whose document is otherwise
// valid. It says nothing about where Check stops on src: an src the
// decoder refuses passes with or without the suffix. It judges decoder
// verdicts only; dupProperty classifies duplicates.
func suffixProperty(t *testing.T, src []byte) {
	t.Helper()
	for _, s := range forbiddenSuffixes {
		doc := append(bytes.Clone(src), s...)
		if Check("f.toml", doc) != nil {
			continue
		}
		var v map[string]any
		if _, err := toml.Decode(string(Normalize(doc)), &v); err == nil {
			t.Fatalf("Check(%q) = nil and BurntSushi decodes it: the suffix %q went unrefused", doc, s)
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
