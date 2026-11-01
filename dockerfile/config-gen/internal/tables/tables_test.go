package tables

import (
	"bytes"
	"os"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// readCorpus reads the one corpus file pattern names.
func readCorpus(t *testing.T, pattern string) []byte {
	t.Helper()
	paths := testcorpus.Glob(t, pattern)
	if len(paths) != 1 {
		t.Fatalf("pattern %q matched %d files, want 1: %q", pattern, len(paths), paths)
	}
	b, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatalf("read %s: %v", paths[0], err)
	}
	return b
}

// An implicit parent is listed before its first child, and a later
// subtable of it joins its group rather than following the next table:
// `[a.b] [c] [a.d]` lists a, a.b, a.d, c (base#1469). The parser's flat
// key order would give a.b, c, a.d with no `a`. The want bytes are the
// bridge's `toml_bridge.py --tables` output on the same file, captured
// into the golden.
func TestEmitListsImplicitParentBeforeItsChildren(t *testing.T) {
	src := readCorpus(t, "corpus/s1/implicit_parent_order.toml")
	want := readCorpus(t, "golden/s1/implicit_parent_order.golden")

	got, err := Emit(src)
	if err != nil {
		t.Fatalf("Emit: unexpected error %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("Emit = %q, want the bridge golden %q", got, want)
	}
}

// A table's path is the parser's key parts joined with `.`, so only real
// tables are listed and a dot inside a quoted key never starts a new
// level: a dotted key `net.host.name = "x"` declares the tables srv.net
// and srv.net.host but its leaf is a value, `["a.b"]` is one table named
// `a.b` beside a separate `[a]`, and tables declared out of order still
// group under their parent (base#1469). The want bytes are the bridge's
// `toml_bridge.py --tables` output on each file, captured into the golden.
func TestEmitJoinsKeyPartsWithoutResplitting(t *testing.T) {
	for _, name := range []string{"dotted_keys", "quoted_dot", "interleaved"} {
		t.Run(name, func(t *testing.T) {
			src := readCorpus(t, "corpus/s1/"+name+".toml")
			want := readCorpus(t, "golden/s1/"+name+".golden")

			got, err := Emit(src)
			if err != nil {
				t.Fatalf("Emit: unexpected error %v", err)
			}
			if !bytes.Equal(got, want) {
				t.Fatalf("Emit = %q, want the bridge golden %q", got, want)
			}
		})
	}
}
