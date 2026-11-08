package schema

import (
	"reflect"
	"strings"
	"testing"
)

// Every home of Homes() keeps an all-empty entry written between two
// populated ones in its written position: three entries, numbered 1, 2
// and 3 on their header lines, the middle one not cleared and carrying
// exactly the fixture's all-empty fields, each an empty string, the
// outer two the populated fixture's fields (base#1443 review round 2
// finding 4). The middle entry is each of the fixture's two all-empty
// bodies in turn, the writers' spelling of "" and the one carrying every
// field its family reads (review round 4 finding 2). An entry rule that moved, merged or dropped the all-empty
// entry changes the middle entry's index, line or fields.
//
// Expected values: the fixture rows (s7_array_homes.tsv); main's
// toml_bridge.py `--kv` on each home's three-block body gives rc 0 and
// `<prefix>_1 a=b:c:d`, `<prefix>_2` empty, `<prefix>_3 a=b:c:d`, the
// legacy `[[devices]]` included, for either middle body (scratchpad
// r2/bridge.out, rr4b/allfields.sh). The header
// lines are counted from the body this test writes [lit].
func TestEveryHomeKeepsAnAllEmptyEntryInItsPosition(t *testing.T) {
	rows := readHomeFixtures(t)
	homes := Homes()
	if len(homes) == 0 {
		t.Fatal("Homes() is empty")
	}
	for _, h := range homes {
		path := homePath(h)
		r := fixtureFor(t, rows, path)
		for _, mid := range r.emptyBodies() {
			t.Run(path+"/"+mid.name, func(t *testing.T) {
				full, empty := fieldsOf(t, r.full), fieldsOf(t, mid.body)
				for _, f := range empty {
					if f[1] != "" {
						t.Fatalf("fixture field %s = %q, want the all-empty text", f[0], f[1])
					}
				}
				var body strings.Builder
				var lines []int
				for _, b := range []string{r.full, mid.body, r.full} {
					if body.Len() > 0 {
						body.WriteString("\n")
					}
					lines = append(lines, strings.Count(body.String(), "\n")+1)
					body.WriteString("[[" + path + "]]\n" + b + "\n")
				}
				cfg, refusals := Decode([]byte(body.String()))
				if len(refusals) != 0 || cfg == nil {
					t.Fatalf("Decode(%q) = %v, %+v, want a Config and no refusals", body.String(), cfg, refusals)
				}
				fam, ok := arrayAt(cfg, path)
				if !ok || fam.State != Set || len(fam.Entries) != 3 {
					t.Fatalf("Array(%s) = %+v, want a Set family of three entries", path, fam)
				}
				for i, want := range [][][2]string{full, empty, full} {
					e := fam.Entries[i]
					if e.Index != i+1 || e.Line != lines[i] {
						t.Errorf("entry %d = {Index %d, Line %d}, want {Index %d, Line %d}",
							i+1, e.Index, e.Line, i+1, lines[i])
					}
					if e.Cleared() {
						t.Errorf("entry %d is cleared, want its fields %q", i+1, want)
					}
					if got := entryFields(t, e); !reflect.DeepEqual(got, want) {
						t.Errorf("entry %d fields = %q, want %q", i+1, got, want)
					}
				}
			})
		}
	}
}
