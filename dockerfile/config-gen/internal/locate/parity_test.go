package locate_test

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/locate"
	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/schema"
	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// failLeaf refuses whatever it is given, so the library wraps the refusal
// in a ParseError carrying the position it stored for that key path.
type failLeaf struct{}

func (*failLeaf) UnmarshalTOML(any) error { return errors.New("locate oracle: planted leaf") }

// libraryLine is the line BurntSushi itself reports for path. The file is
// decoded into Primitives, each table on the path is decoded into
// Primitives again with md.PrimitiveDecode (the last element holding the
// path's next component where the table is an array of tables), and a failLeaf is decoded at the path, so
// the library wraps the refusal in a ParseError carrying the position it
// stored for that key path. Any key name works, the empty one included.
// For a path written more than once the library keeps only the last
// occurrence. The file is decoded once, by primitives, and every path of
// it is looked up from that one decode: decoding it again per path costs
// the file's length times its key count, which on the 108,951-byte
// large_tables.toml fixture (base#1469) made this test the slowest in
// the race gate.
func libraryLine(t *testing.T, src []byte) func(path toml.Key) int {
	t.Helper()
	var root map[string]toml.Primitive
	md, err := toml.Decode(string(src), &root)
	if err != nil {
		t.Fatalf("decode into Primitives: %v", err)
	}
	return func(path toml.Key) int {
		t.Helper()
		return plantedLine(t, md, root, path)
	}
}

// plantedLine decodes a failLeaf at path from root, the Primitives md
// decoded the file into, and returns the line of the ParseError the
// library wraps the refusal in.
func plantedLine(t *testing.T, md toml.MetaData, root map[string]toml.Primitive, path toml.Key) int {
	t.Helper()
	cur := root
	var err error
	for i, name := range path[:len(path)-1] {
		p, ok := cur[name]
		if !ok {
			t.Fatalf("planted leaf at %s: no %q on the path", path, name)
		}
		var next map[string]toml.Primitive
		if md.Type(path[:i+1]...) == "ArrayHash" {
			// The path goes on in the last element that holds its next
			// component, which is not always the last element:
			// `[[aot]] [aot.sub] [[aot]]` writes aot.sub in the first
			// (base#1469: the s1 fixture aot_subtable.toml).
			var elems []map[string]toml.Primitive
			err = md.PrimitiveDecode(p, &elems)
			for j := len(elems) - 1; err == nil && j >= 0; j-- {
				if _, ok := elems[j][path[i+1]]; ok {
					next = elems[j]
					break
				}
			}
		} else {
			err = md.PrimitiveDecode(p, &next)
		}
		if err != nil || next == nil {
			t.Fatalf("planted leaf at %s: decode %q: %v", path, name, err)
		}
		cur = next
	}
	err = md.PrimitiveDecode(cur[path[len(path)-1]], &failLeaf{})
	var pe toml.ParseError
	if !errors.As(err, &pe) {
		t.Fatalf("planted leaf at %s: err = %v, want a toml.ParseError", path, err)
	}
	if pe.LastKey != path.String() {
		t.Fatalf("planted leaf at %s: ParseError.LastKey = %q, want the planted path", path, pe.LastKey)
	}
	return pe.Position.Line
}

// under reports whether k lies strictly under p, by whole components.
func under(k, p []string) bool {
	return len(k) > len(p) && reflect.DeepEqual(k[:len(p)], p)
}

// TestIndexOccurrenceParity checks the locator against the library on
// every corpus TOML file, at any depth (base#1442 AC "every corpus file").
// The scope is locate.CorpusTOML, a listing of the corpus tree, so no file
// is left out by a pattern; the test asserts the scope holds the s1 seed,
// a file under corpus/s6/sections/ and every file the one- and two-level
// slice globs match.
//
// A file the library decodes is compared key by key with the library's
// own positions. The library repeats a path in Keys() once per
// occurrence, in document order, and stores one position per path: the
// last occurrence's. So (a) the (path, ordinal) sequence of Entries()
// minus implicit occurrences equals that of md.Keys() minus the paths
// inside an inline value; (b) a path written once is Found by the unique
// lookup at the library's line; (c) a path written more than once is
// Repeated, and the last of its occurrences is at the library's line.
//
// A file the library refuses with a toml.ParseError is indexed without a
// panic, and schema.Decode's one refusal is conf_toml_parse_failed at the
// ParseError's line. Both branches must be taken at least once, so the
// scope cannot silently lose either kind of file. Every expected line
// comes from the library, never from this package.
func TestIndexOccurrenceParity(t *testing.T) {
	files := locate.CorpusTOML(t)
	scope := map[string]bool{}
	sections := 0
	for _, f := range files {
		scope[f] = true
		if strings.Contains(filepath.ToSlash(f), "/corpus/s6/sections/") {
			sections++
		}
	}
	for _, f := range testcorpus.Glob(t, "corpus/s1/seed.toml") {
		if !scope[f] {
			t.Errorf("scope lacks %s", f)
		}
	}
	if sections == 0 {
		t.Errorf("scope has no file under corpus/s6/sections/: %q", files)
	}
	for _, pattern := range []string{"corpus/s*/*.toml", "corpus/s*/*/*.toml"} {
		for _, f := range testcorpus.Glob(t, pattern) {
			if !scope[f] {
				t.Errorf("scope lacks %s, matched by %s", f, pattern)
			}
		}
	}

	decoded, refused := 0, 0
	for _, file := range files {
		t.Run(file, func(t *testing.T) {
			src, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			md, err := toml.Decode(string(src), new(map[string]any))
			if err != nil {
				var pe toml.ParseError
				if !errors.As(err, &pe) {
					t.Fatalf("library error %v is not a toml.ParseError", err)
				}
				refused++
				parseBranch(t, src, pe)
				return
			}
			decoded++
			m := locate.Index(src)

			var inline [][]string
			var got []string
			for _, o := range m.Entries() {
				if o.Inline {
					inline = append(inline, o.Path)
				}
				if o.Implicit {
					continue
				}
				k := toml.Key(o.Path).String()
				got = append(got, fmt.Sprintf("%s#%d", k, o.Ordinal))
			}

			var want []string
			var keys []toml.Key
			count := map[string]int{}
		next:
			for _, k := range md.Keys() {
				for _, p := range inline {
					if under(k, p) {
						continue next
					}
				}
				want = append(want, fmt.Sprintf("%s#%d", k, count[k.String()]))
				if count[k.String()] == 0 {
					keys = append(keys, k)
				}
				count[k.String()]++
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("Entries() (path#ordinal) =\n  %q\nwant md.Keys() =\n  %q", got, want)
			}

			isInline := func(k toml.Key) bool {
				for _, p := range inline {
					if reflect.DeepEqual([]string(k), p) {
						return true
					}
				}
				return false
			}
			libLine := libraryLine(t, src)
			for _, k := range keys {
				lib := libLine(k)
				typ := md.Type(k...)
				table := typ == "ArrayHash" || (typ == "Hash" && !isInline(k))
				var occ locate.Occurrence
				var lk locate.Lookup
				var all []locate.Occurrence
				if table {
					occ, lk = m.Table(k)
					all = m.Tables(k)
				} else {
					occ, lk = m.Key(k)
					all = m.Keys(k)
				}
				line := func(o locate.Occurrence) int {
					if table {
						return o.KeyLine
					}
					return o.ValueEndLine
				}
				switch n := count[k.String()]; {
				case n == 1:
					if lk != locate.Found {
						t.Errorf("%s (written once): lookup = %v, want Found", k, lk)
					} else if line(occ) != lib {
						t.Errorf("%s: line = %d, want the library's %d", k, line(occ), lib)
					}
				default:
					if lk != locate.Repeated {
						t.Errorf("%s (written %d times): lookup = %v, want Repeated", k, n, lk)
					}
					if len(all) != n {
						t.Errorf("%s: %d occurrences, want %d", k, len(all), n)
					} else if last := all[n-1]; line(last) != lib {
						t.Errorf("%s: last occurrence line = %d, want the library's %d", k, line(last), lib)
					}
				}
			}
		})
	}
	if decoded == 0 || refused == 0 {
		t.Errorf("corpus files the library decodes = %d, refuses = %d; want both above zero", decoded, refused)
	}
}

// parseBranch checks one file the library refuses with pe: the locator
// indexes it without a panic, and schema.Decode refuses it once, as
// conf_toml_parse_failed at the library's line.
func parseBranch(t *testing.T, src []byte, pe toml.ParseError) {
	t.Helper()
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("Index panicked on a file the library refused (%v)", r)
			}
		}()
		locate.Index(src)
	}()
	cfg, refusals := schema.Decode(src)
	if cfg != nil || len(refusals) != 1 {
		t.Fatalf("Decode = %v, %+v; want no Config and one refusal", cfg, refusals)
	}
	if r := refusals[0]; r.Event != "conf_toml_parse_failed" || r.Line != pe.Position.Line {
		t.Errorf("refusal = %s at line %d, want conf_toml_parse_failed at the library's line %d", r.Event, r.Line, pe.Position.Line)
	}
}
