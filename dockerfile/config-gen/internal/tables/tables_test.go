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

// An array is a leaf of the walk: a root-level array of any kind is listed
// by its name, an array nested in a table is not listed, and the walk
// never descends into an array's elements, so a subtable or a nested
// array of tables declared inside `[[aot]]` is not listed (base#1469).
// The want bytes are the bridge's `toml_bridge.py --tables` output on each
// file, captured into the golden.
func TestEmitDoesNotDescendIntoArrays(t *testing.T) {
	for _, name := range []string{"root_array", "nested_array", "aot_subtable"} {
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

// A path is prefixed by its parent's path only when that path is non-empty,
// not whenever the key sits below the root: a table named "" prints as an
// empty line, its subtable `["".b]` prints as `b`, not `.b`, and an array
// directly under `[""]` is listed like a root-level array, because the
// bridge's walk tests the prefix string, not the depth (base#1469). The
// want bytes are the bridge's `toml_bridge.py --tables` output on each
// file, captured into the golden.
func TestEmitPrefixesByParentPathNotDepth(t *testing.T) {
	for _, name := range []string{"empty_name_parent", "empty_name_array"} {
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

// An inline table is a table, not a value: `a = { b = { c = 1 } }` lists
// a and a.b, an empty `e = {}` and one reached through a dotted key are
// listed too, a key holding a colon (`["stage:dev"]`) is one level, CRLF
// line endings give the same paths as LF, and an empty or comment-only
// file lists nothing (base#1469). The want bytes are the bridge's
// `toml_bridge.py --tables` output on each file, captured into the golden.
func TestEmitListsInlineTablesAsTables(t *testing.T) {
	for _, name := range []string{"nested_inline", "stage_dev", "crlf", "empty", "comment_only"} {
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
