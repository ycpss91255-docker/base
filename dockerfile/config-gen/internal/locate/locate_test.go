package locate

import (
	"errors"
	"fmt"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// failLeaf refuses whatever it is given, so the library wraps the refusal
// in a ParseError carrying the position it stored for that key path.
type failLeaf struct{}

func (*failLeaf) UnmarshalTOML(any) error { return errors.New("locate oracle: planted leaf") }

// libraryLine is the line BurntSushi itself reports for path: a failLeaf is
// planted at path through a struct type built with reflect.StructOf (one
// single-field struct per component, a slice where the parent is an array
// table), and the line is read from the ParseError. For a path written
// more than once the library keeps only the last occurrence.
func libraryLine(t *testing.T, src []byte, md toml.MetaData, path toml.Key) int {
	t.Helper()
	typ := reflect.TypeOf((*failLeaf)(nil))
	for i := len(path) - 1; i >= 0; i-- {
		name := path[i]
		if name == "-" || strings.Contains(name, ",") {
			t.Fatalf("key %q cannot be named in a toml struct tag; pick another corpus key", name)
		}
		st := reflect.StructOf([]reflect.StructField{{
			Name: "F",
			Type: typ,
			Tag:  reflect.StructTag("toml:" + strconv.Quote(name)),
		}})
		typ = st
		if i > 0 && md.Type(path[:i]...) == "ArrayHash" {
			typ = reflect.SliceOf(st)
		}
	}
	_, err := toml.Decode(string(src), reflect.New(typ).Interface())
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
// every corpus/s6 file (base#1442). The library repeats a path in Keys()
// once per occurrence, in document order, and stores one position per
// path: the last occurrence's. So (a) the (path, ordinal) sequence of
// Entries() minus implicit occurrences equals that of md.Keys() minus the
// paths inside an inline value; (b) a path written once is Found by the
// unique lookup at the library's line; (c) a path written more than once
// is Repeated, and the last of its occurrences is at the library's line.
// Every expected line comes from the library, never from this package.
func TestIndexOccurrenceParity(t *testing.T) {
	for _, file := range testcorpus.Glob(t, "corpus/s6/*.toml") {
		t.Run(file, func(t *testing.T) {
			src, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			md, err := toml.Decode(string(src), new(map[string]any))
			if err != nil {
				t.Fatalf("library refused the corpus file: %v", err)
			}
			m := Index(src)

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
			for _, k := range keys {
				lib := libraryLine(t, src, md, k)
				typ := md.Type(k...)
				table := typ == "ArrayHash" || (typ == "Hash" && !isInline(k))
				var occ Occurrence
				var lk Lookup
				var all []Occurrence
				if table {
					occ, lk = m.Table(k)
					all = m.Tables(k)
				} else {
					occ, lk = m.Key(k)
					all = m.Keys(k)
				}
				line := func(o Occurrence) int {
					if table {
						return o.KeyLine
					}
					return o.ValueEndLine
				}
				switch n := count[k.String()]; {
				case n == 1:
					if lk != Found {
						t.Errorf("%s (written once): lookup = %v, want Found", k, lk)
					} else if line(occ) != lib {
						t.Errorf("%s: line = %d, want the library's %d", k, line(occ), lib)
					}
				default:
					if lk != Repeated {
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
}

// corpusFile reads the one corpus/s6 file named base through testcorpus.
func corpusFile(t *testing.T, base string) []byte {
	t.Helper()
	files := testcorpus.Glob(t, "corpus/s6/"+base)
	src, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	return src
}

// occLines returns each occurrence's KeyLine and Ordinal, in order.
func occLines(all []Occurrence) (lines, ordinals []int) {
	for _, o := range all {
		lines = append(lines, o.KeyLine)
		ordinals = append(ordinals, o.Ordinal)
	}
	return lines, ordinals
}

// TestIndexRepeatedOccurrences checks the earlier occurrences of a path
// written more than once, which the library cannot report (it keeps only
// the last position), so every expected line is counted by hand from the
// fixture text (base#1442). An explicit table stays one occurrence when a
// later array-table header lies under it, and an inline array is one
// occurrence with nothing inside it indexed.
func TestIndexRepeatedOccurrences(t *testing.T) {
	t.Run("s6_loc_aot.toml", func(t *testing.T) {
		m := Index(corpusFile(t, "s6_loc_aot.toml"))
		vol := []string{"volumes"}
		src := []string{"volumes", "source"}

		lines, ords := occLines(m.Tables(vol))
		if !reflect.DeepEqual(lines, []int{1, 4, 7}) || !reflect.DeepEqual(ords, []int{0, 1, 2}) {
			t.Errorf("Tables(volumes) lines=%v ordinals=%v, want [1 4 7] [0 1 2]", lines, ords)
		}
		lines, _ = occLines(m.Keys(src))
		if !reflect.DeepEqual(lines, []int{2, 5, 8}) {
			t.Errorf("Keys(volumes.source) lines=%v, want [2 5 8]", lines)
		}
		if _, lk := m.Table(vol); lk != Repeated {
			t.Errorf("Table(volumes) = %v, want Repeated", lk)
		}
		if _, lk := m.Key(src); lk != Repeated {
			t.Errorf("Key(volumes.source) = %v, want Repeated", lk)
		}
		var seq []string
		for _, o := range m.Entries() {
			seq = append(seq, fmt.Sprintf("%s#%d", toml.Key(o.Path), o.Ordinal))
		}
		want := []string{"volumes#0", "volumes.source#0", "volumes#1", "volumes.source#1", "volumes#2", "volumes.source#2"}
		if !reflect.DeepEqual(seq, want) {
			t.Errorf("Entries() = %q, want %q", seq, want)
		}
	})

	t.Run("s6_loc_aot_nested.toml", func(t *testing.T) {
		m := Index(corpusFile(t, "s6_loc_aot_nested.toml"))
		if o, lk := m.Table([]string{"devices"}); lk != Found || o.KeyLine != 1 {
			t.Errorf("Table(devices) = %v line %d, want Found line 1 (all: %+v)", lk, o.KeyLine, m.Tables([]string{"devices"}))
		}
		if o, lk := m.Key([]string{"devices", "device_1"}); lk != Found || o.KeyLine != 2 {
			t.Errorf("Key(devices.device_1) = %v line %d, want Found line 2", lk, o.KeyLine)
		}
		if lines, _ := occLines(m.Tables([]string{"devices", "bindings"})); !reflect.DeepEqual(lines, []int{4, 7}) {
			t.Errorf("Tables(devices.bindings) lines=%v, want [4 7]", lines)
		}
		if lines, _ := occLines(m.Keys([]string{"devices", "bindings", "path"})); !reflect.DeepEqual(lines, []int{5, 8}) {
			t.Errorf("Keys(devices.bindings.path) lines=%v, want [5 8]", lines)
		}
	})

	t.Run("s6_loc_inline_aot.toml", func(t *testing.T) {
		m := Index(corpusFile(t, "s6_loc_inline_aot.toml"))
		all := m.Keys([]string{"volumes"})
		if len(all) != 1 || !all[0].Inline || all[0].KeyLine != 1 {
			t.Errorf("Keys(volumes) = %+v, want one Inline occurrence on line 1", all)
		}
		if n := len(m.Keys([]string{"volumes", "source"})); n != 0 {
			t.Errorf("Keys(volumes.source): %d occurrences, want none", n)
		}
	})
}
