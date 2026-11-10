package tables

import (
	"bytes"
	"errors"
	"os"
	"reflect"
	"testing"

	"github.com/BurntSushi/toml"

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

// A key-value whose last key part is "" and whose context is not empty --
// `a."" = []`, `"" = []` under `[a]`, a `""` member of an inline table or
// of an array-of-tables element -- is refused with an *EmptyNameError that
// names that key, deepest member first for a chain of such parts. On these
// inputs the parser files the value's type at the parent's path: measured
// against the bridge's `toml_bridge.py --tables`, the valid ones printed
// different bytes or lost tables, and the invalid ones (a duplicate key
// after the `""` line) were accepted while the bridge refused them
// (base#1469). A `""` key at the root, a table named `""` and a dotted key
// through `""` are typed at their own path and keep the bridge's bytes.
func TestEmitRefusesEmptyNameValueBelowRoot(t *testing.T) {
	refused := []struct {
		name string
		src  string
		key  []string
	}{
		{"c1", "a.k = {}\na.\"\" = []\na.x = 1\n", []string{"a", ""}},
		{"c2", "\"\".k = {}\n\"\".\"\" = []\n\"\".x = 1\n", []string{"", ""}},
		{"c3", "[t]\na.k = {}\na.\"\" = []\na.x = 1\n", []string{"t", "a", ""}},
		{"c5", "a.k = 1\na.\"\" = []\na.y = 2\na.k = 3\n", []string{"a", ""}},
		{"d1", "a.\"\" = []\na.y = 1\na.\"\" = []\n", []string{"a", ""}},
		{"r3a", "[a]\n\"\" = []\n[a.b]\n", []string{"a", ""}},
		{"r3b", "[\"\"]\n\"\" = []\n", []string{"", ""}},
		{"d2", "[a]\n\"\" = {}\n[a.b]\n", []string{"a", ""}},
		{"c7", "a = { k = {}, \"\" = [], x = 1 }\n", []string{"a", ""}},
		{"c9", "[[t]]\na.k = {}\na.\"\" = []\na.x = 1\n", []string{"t", "a", ""}},
		{"d3", "a.\"\".\"\" = 1\n", []string{"a", "", ""}},
		{"d4", "[[t]]\n\"\" = []\n[t.b]\n[c]\n", []string{"t", ""}},
		{"d5", "x = [{ \"\" = 1 }]\n[y]\n", []string{"x", ""}},
	}
	for _, tc := range refused {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Emit([]byte(tc.src))
			var en *EmptyNameError
			if !errors.As(err, &en) {
				t.Fatalf("Emit = %q, %v; want an *EmptyNameError", got, err)
			}
			if got != nil {
				t.Fatalf("Emit output = %q, want nil with the error", got)
			}
			if !reflect.DeepEqual([]string(en.Key), tc.key) {
				t.Fatalf("EmptyNameError.Key = %q, want %q", []string(en.Key), tc.key)
			}
			want := "key " + toml.Key(tc.key).String() +
				`: a key-value named "" below the root is not supported (base#1565)`
			if err.Error() != want {
				t.Fatalf("Error() = %q, want %q", err.Error(), want)
			}
		})
	}

	accepted := []struct {
		name string
		src  string
		want string
	}{
		{"k1", "\"\" = []\n", "\n"},
		{"k2", "[a.\"\"]\nq = 1\n", "a\na.\n"},
		{"k3", "[a]\n\"\".x = 1\n", "a\na.\n"},
		{"k4", "[\"\"]\narr = [1]\n", "\narr\n"},
		{"k5", "[a]\nx = []\n", "a\n"},
	}
	for _, tc := range accepted {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Emit([]byte(tc.src))
			if err != nil {
				t.Fatalf("Emit: unexpected error %v", err)
			}
			if string(got) != tc.want {
				t.Fatalf("Emit = %q, want the bridge's %q", got, tc.want)
			}
		})
	}
}
