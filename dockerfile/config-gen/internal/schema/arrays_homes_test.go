package schema

import (
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// homeFixture is one row of corpus/s7/s7_array_homes.tsv: a home's
// numbered prefix, its all-empty and populated entry bodies, and whether
// the shell writers produce it (`writer`) or only the bridge reads it
// (`legacy`).
type homeFixture struct {
	path   string
	prefix string
	empty  string
	full   string
	kind   string
}

// readHomeFixtures reads corpus/s7/s7_array_homes.tsv in row order.
func readHomeFixtures(t *testing.T) []homeFixture {
	t.Helper()
	paths := testcorpus.Glob(t, "corpus/s7/s7_array_homes.tsv")
	if len(paths) != 1 {
		t.Fatalf("Glob = %v, want s7_array_homes.tsv", paths)
	}
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	var rows []homeFixture
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 5 || (f[4] != "writer" && f[4] != "legacy") {
			t.Fatalf("s7_array_homes.tsv line %d = %q, want path, prefix, empty, full and writer|legacy", i+1, line)
		}
		unescape := func(s string) string { return strings.ReplaceAll(s, `\n`, "\n") }
		rows = append(rows, homeFixture{f[0], f[1], unescape(f[2]), unescape(f[3]), f[4]})
	}
	if len(rows) == 0 {
		t.Fatal("s7_array_homes.tsv names no array home")
	}
	return rows
}

// fixtureFor is the fixture row of the home at path, failing the test
// when the fixtures have none: a home the schema gains is not judged
// until its expected bodies are written down.
func fixtureFor(t *testing.T, rows []homeFixture, path string) homeFixture {
	t.Helper()
	for _, r := range rows {
		if r.path == path {
			return r
		}
	}
	t.Fatalf("Homes() names %s, which s7_array_homes.tsv has no fixture row for", path)
	return homeFixture{}
}

// fieldsOf parses a fixture body of `name = "text"` lines into the
// key and string text of each line, in written order -- read off the
// fixture bytes, not from Decode.
func fieldsOf(t *testing.T, body string) [][2]string {
	t.Helper()
	var out [][2]string
	for _, line := range strings.Split(body, "\n") {
		name, quoted, ok := strings.Cut(line, " = ")
		text, err := strconv.Unquote(quoted)
		if !ok || err != nil {
			t.Fatalf("fixture line %q is not name = \"text\"", line)
		}
		out = append(out, [2]string{name, text})
	}
	return out
}

// entryFields is the key and string text of each field of e, failing the
// test on a field that is not a string scalar.
func entryFields(t *testing.T, e Entry) [][2]string {
	t.Helper()
	var out [][2]string
	for _, f := range e.Fields {
		if f.Value.Kind != VScalar || f.Value.Scalar.Kind != KindString {
			t.Fatalf("field %s = %+v, want a string scalar", f.Key, f.Value)
		}
		out = append(out, [2]string{f.Key, f.Value.Scalar.Text})
	}
	return out
}

// homePath is h's path joined with ".", the path its fixture is keyed by.
func homePath(h Home) string { return strings.Join(h.Path, ".") }

// The schema's homes are the writers' homes and the legacy one: the
// homes of Homes() the shell writers produce are exactly the fixture's
// `writer` rows, in their order, each with the writers' numbered prefix,
// and its legacy homes are the `legacy` rows (base#1443, design r1 cycle
// 9). The judging of each home is in the two tests below, which iterate
// Homes() itself.
//
// Expected values: the `writer` rows are what `_conf_toml_aot_section`
// over SCHEMA_SECTIONS prints (dist/script/docker/lib/conf.sh,
// scratchpad r1/homes.out); the `legacy` row is the bridge's _ARRAY_SPEC
// "devices" key, which no writer names.
func TestHomesAreTheWritersHomesAndTheLegacyOne(t *testing.T) {
	rows := readHomeFixtures(t)

	got := map[string][][2]string{}
	for _, h := range Homes() {
		kind := "writer"
		if h.Legacy {
			kind = "legacy"
		}
		got[kind] = append(got[kind], [2]string{homePath(h), h.Spec.Prefix})
	}
	want := map[string][][2]string{}
	for _, r := range rows {
		want[r.kind] = append(want[r.kind], [2]string{r.path, r.prefix})
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Homes() = %v, want the fixture's homes %v", got, want)
	}
}

// Every home of Homes() refuses an entry without its field and keeps an
// empty one -- the port of toml_bridge_spec.bats "every array home
// refuses an entry without its field and keeps an empty one" (base#1309)
// over the schema's own home list, so a home added to the schema is
// judged by having been added (base#1443 review round 1 findings 2 and
// 3). An entry carrying only `zz` is refused as
// conf_entry_no_gating_field and a plain string where a table belongs as
// conf_entry_not_table, each at the home's path and as entry 1. A
// field-less block is one cleared entry with no field; the block of
// all-empty fields is one entry, not cleared, carrying exactly the
// fixture's fields, each an empty string.
//
// Expected values: the fixture rows (s7_array_homes.tsv); main's
// toml_bridge.py `--kv` gives, for every home, the legacy `[[devices]]`
// included, rc 1 "carries none of the fields it is read from" for `zz`,
// rc 1 "is 'x', not a table" for the string, and rc 0 with the one row
// `<section> <prefix>_1 ""` for both empty bodies (scratchpad
// s7c8-bridge.out, r1/bridge.out).
func TestEveryHomeRefusesAnEntryWithoutItsFieldAndKeepsAnEmptyOne(t *testing.T) {
	rows := readHomeFixtures(t)
	homes := Homes()
	if len(homes) == 0 {
		t.Fatal("Homes() is empty")
	}
	seen := map[string]bool{}
	for _, h := range homes {
		path := homePath(h)
		seen[path] = true
		r := fixtureFor(t, rows, path)
		t.Run(path, func(t *testing.T) {
			leaf := h.Path[len(h.Path)-1]
			str := path + ` = ["x"]` + "\n"
			if len(h.Path) > 1 {
				str = "[" + strings.Join(h.Path[:len(h.Path)-1], ".") + "]\n" + leaf + ` = ["x"]` + "\n"
			}
			for _, c := range []struct {
				name  string
				body  string
				event string
			}{
				{"zz", "[[" + path + "]]\nzz = \"x\"\n", "conf_entry_no_gating_field"},
				{"string", str, "conf_entry_not_table"},
			} {
				_, refusals := Decode([]byte(c.body))
				if len(refusals) != 1 {
					t.Errorf("%s: Decode(%q) refusals = %+v, want exactly one", c.name, c.body, refusals)
					continue
				}
				rf := refusals[0]
				if rf.Event != c.event || !reflect.DeepEqual(rf.Path, h.Path) || rf.Entry != 1 || rf.Field != "" {
					t.Errorf("%s: refusal = %+v, want {%s %q entry 1}", c.name, rf, c.event, h.Path)
				}
			}

			for _, c := range []struct {
				name string
				body string
				want [][2]string
			}{
				{"cleared", "[[" + path + "]]\n", nil},
				{"all-empty", "[[" + path + "]]\n" + r.empty + "\n", fieldsOf(t, r.empty)},
			} {
				cfg, refusals := Decode([]byte(c.body))
				if len(refusals) != 0 {
					t.Errorf("%s: Decode(%q) refusals = %+v, want none", c.name, c.body, refusals)
					continue
				}
				fam, ok := cfg.Arrays[path]
				if !ok || fam.State != Set || len(fam.Entries) != 1 {
					t.Errorf("%s: Arrays[%s] = %+v, want a Set family of one entry", c.name, path, fam)
					continue
				}
				e := fam.Entries[0]
				if e.Cleared() != (c.want == nil) {
					t.Errorf("%s: Cleared() = %v, want %v", c.name, e.Cleared(), c.want == nil)
				}
				for _, f := range c.want {
					if f[1] != "" {
						t.Fatalf("%s: fixture field %s = %q, want the all-empty text", c.name, f[0], f[1])
					}
				}
				if got := entryFields(t, e); !reflect.DeepEqual(got, c.want) {
					t.Errorf("%s: fields = %q, want %q", c.name, got, c.want)
				}
			}
		})
	}
	for _, r := range rows {
		if !seen[r.path] {
			t.Errorf("s7_array_homes.tsv has a row for %s, which Homes() does not name", r.path)
		}
	}
}

// Every home of Homes() accepts its populated entry, the writers'
// spelling of a value carrying every separator, field for field, and
// refuses the same entry with one field its family does not read beside
// it, once, as conf_entry_unknown_field at that field -- the port of
// toml_bridge_spec.bats "every array home refuses an entry with an
// unknown field beside its own" (base#1313) over the schema's own home
// list (base#1443 review round 1 finding 3).
//
// Expected values: the fixture rows (s7_array_homes.tsv); main's
// toml_bridge.py `--kv` gives rc 0 and `<section> <prefix>_1 a=b:c:d`
// for every populated body, the legacy `[[devices]]` included, and rc 1
// "entry 1 of <path> carries zz, which its family does not read" with
// `zz = "x"` beside it (scratchpad r1/bridge.out).
func TestEveryHomeRefusesAnUnknownFieldBesideItsOwn(t *testing.T) {
	rows := readHomeFixtures(t)
	homes := Homes()
	if len(homes) == 0 {
		t.Fatal("Homes() is empty")
	}
	for _, h := range homes {
		path := homePath(h)
		r := fixtureFor(t, rows, path)
		t.Run(path, func(t *testing.T) {
			body := "[[" + path + "]]\n" + r.full + "\n"
			cfg, refusals := Decode([]byte(body))
			if len(refusals) != 0 {
				t.Fatalf("Decode(%q) refusals = %+v, want none", body, refusals)
			}
			fam := cfg.Arrays[path]
			if fam.State != Set || len(fam.Entries) != 1 {
				t.Fatalf("Arrays[%s] = %+v, want a Set family of one entry", path, fam)
			}
			if got, want := entryFields(t, fam.Entries[0]), fieldsOf(t, r.full); !reflect.DeepEqual(got, want) {
				t.Errorf("fields = %q, want %q", got, want)
			}

			body += "zz = \"x\"\n"
			_, refusals = Decode([]byte(body))
			if len(refusals) != 1 {
				t.Fatalf("Decode(%q) refusals = %+v, want exactly one", body, refusals)
			}
			rf := refusals[0]
			wantPath := append(append([]string{}, h.Path...), "zz")
			if rf.Event != "conf_entry_unknown_field" || !reflect.DeepEqual(rf.Path, wantPath) || rf.Entry != 1 || rf.Field != "zz" {
				t.Errorf("refusal = %+v, want {conf_entry_unknown_field %q entry 1 field zz}", rf, wantPath)
			}
			if wantLine := strings.Count(body, "\n"); rf.Line != wantLine {
				t.Errorf("refusal line = %d, want %d, the line zz is written on", rf.Line, wantLine)
			}
		})
	}
}
