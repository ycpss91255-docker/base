package schema

import (
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// homeRow is one row of corpus/s7/s7_array_homes.tsv: an array home the
// shell writers name, its numbered prefix and its all-empty entry.
type homeRow struct {
	path   string
	prefix string
	empty  string
}

// readHomeRows reads corpus/s7/s7_array_homes.tsv.
func readHomeRows(t *testing.T) []homeRow {
	t.Helper()
	paths := testcorpus.Glob(t, "corpus/s7/s7_array_homes.tsv")
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	var rows []homeRow
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 3 {
			t.Fatalf("s7_array_homes.tsv line %d has %d fields, want 3: %q", i+1, len(f), line)
		}
		rows = append(rows, homeRow{f[0], f[1], strings.ReplaceAll(f[2], `\n`, "\n")})
	}
	if len(rows) == 0 {
		t.Fatal("s7_array_homes.tsv names no array home")
	}
	return rows
}

// The array homes are derived from the schema: schema.Homes(), the
// legacy `[[devices]]` spelling aside, names exactly the homes the shell
// writers name, each with the writers' numbered prefix, and every one of
// them refuses an entry without its field and keeps an empty one -- the
// port of toml_bridge_spec.bats "every array home refuses an entry
// without its field and keeps an empty one" (base#1309) over Homes()
// rather than a typed-out list (base#1443, design r1 cycle 9). An entry
// carrying only `zz` is refused as conf_entry_no_gating_field, a plain
// string where a table belongs as conf_entry_not_table; a field-less
// block is one cleared entry, and the block of all-empty fields one
// entry that is not cleared.
//
// Expected values: the home list, prefixes and all-empty bodies are
// what `_conf_toml_aot_section` over SCHEMA_SECTIONS and
// `_conf_toml_aot_fields` of "" (dist/script/docker/lib/conf.sh) print,
// written into s7_array_homes.tsv; main's toml_bridge.py `--kv` gives,
// for every home, rc 1 "carries none of the fields it is read from" for
// `zz`, rc 1 "is 'x', not a table" for the string, and rc 0 with the
// one row `<section> <prefix>_1 ""` for both empty bodies (scratchpad
// s7c8-bridge.out); each refusal is at the home's path.
func TestHomesAreTheWritersHomesAndEachJudgesItsEntries(t *testing.T) {
	rows := readHomeRows(t)

	var got []homeRow
	for _, h := range Homes() {
		if h.Legacy {
			continue
		}
		got = append(got, homeRow{path: strings.Join(h.Path, "."), prefix: h.Spec.Prefix})
	}
	var want []homeRow
	for _, r := range rows {
		want = append(want, homeRow{path: r.path, prefix: r.prefix})
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Homes() = %v, want the writers' homes %v", got, want)
	}

	for _, r := range rows {
		t.Run(r.path, func(t *testing.T) {
			path := strings.Split(r.path, ".")
			leaf := path[len(path)-1]
			str := r.path + ` = ["x"]` + "\n"
			if len(path) > 1 {
				str = "[" + path[0] + "]\n" + leaf + ` = ["x"]` + "\n"
			}
			for _, c := range []struct {
				name  string
				body  string
				event string
			}{
				{"zz", "[[" + r.path + "]]\nzz = \"x\"\n", "conf_entry_no_gating_field"},
				{"string", str, "conf_entry_not_table"},
			} {
				_, refusals := Decode([]byte(c.body))
				if len(refusals) != 1 {
					t.Errorf("%s: Decode(%q) refusals = %+v, want exactly one", c.name, c.body, refusals)
					continue
				}
				rf := refusals[0]
				if rf.Event != c.event || !reflect.DeepEqual(rf.Path, path) {
					t.Errorf("%s: refusal = {%s %q}, want {%s %q}", c.name, rf.Event, rf.Path, c.event, path)
				}
			}

			for _, c := range []struct {
				name    string
				body    string
				cleared bool
			}{
				{"cleared", "[[" + r.path + "]]\n", true},
				{"all-empty", "[[" + r.path + "]]\n" + r.empty + "\n", false},
			} {
				cfg, refusals := Decode([]byte(c.body))
				if len(refusals) != 0 {
					t.Errorf("%s: Decode(%q) refusals = %+v, want none", c.name, c.body, refusals)
					continue
				}
				fam, ok := cfg.Arrays[r.path]
				if !ok || len(fam.Entries) != 1 {
					t.Errorf("%s: Arrays[%s] = %+v, want one entry", c.name, r.path, fam)
					continue
				}
				if fam.Entries[0].Cleared() != c.cleared {
					t.Errorf("%s: Cleared() = %v, want %v", c.name, fam.Entries[0].Cleared(), c.cleared)
				}
			}
		})
	}
}
