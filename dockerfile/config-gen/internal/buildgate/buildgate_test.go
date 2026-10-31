package buildgate

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The ratchet's events (base#1465). Every rule sits beside its no-fire
// twin; the boundaries are worked by hand in integer tenths:
//
//	floor 89.9 (899) is too_low, 90.0 (900) and 100.0 (1000) are not;
//	with floor F = 95.0 on 1000 statements, measured 94.9 (949 covered) is
//	below, 95.9 (959) passes, 96.0 (960) is stale.

const mod = "example.com/m"

// write puts files under dir; a name ending in / is a directory.
func write(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	for name, body := range files {
		p := filepath.Join(dir, name)
		if strings.HasSuffix(name, "/") {
			if err := os.MkdirAll(p, 0o755); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// ratchet runs Ratchet over a fresh tree: fragments under floors.d (nil:
// no directory), the base file's content, and measured lines.
func ratchet(t *testing.T, frags map[string]string, base string, measured string) []string {
	t.Helper()
	dir := t.TempDir()
	floors := filepath.Join(dir, "floors.d")
	if frags != nil {
		if err := os.Mkdir(floors, 0o755); err != nil {
			t.Fatal(err)
		}
		write(t, floors, frags)
	}
	write(t, dir, map[string]string{"base": base, "measured": measured})
	events, err := Ratchet(filepath.Join(dir, "measured"), floors, filepath.Join(dir, "base"), mod)
	if err != nil {
		t.Fatalf("Ratchet: %v", err)
	}
	out := make([]string, 0, len(events))
	for _, e := range events {
		out = append(out, e.String())
	}
	return out
}

func m(pkg string, stmts, covered int) string {
	p := mod
	if pkg != "." {
		p = mod + "/" + pkg
	}
	return p + "\t" + strconv.Itoa(stmts) + "\t" + strconv.Itoa(covered) + "\n"
}

func TestRatchet(t *testing.T) {
	const ev = "cg_event config_gen_coverage_"
	cases := []struct {
		name     string
		frags    map[string]string
		base     string
		measured string
		want     []string
	}{
		{"green", map[string]string{"s1e.txt": "a 95.0\n"}, "absent\n", m("a", 1000, 955), nil},
		{"floor 89.9 is too_low", map[string]string{"s1e.txt": "a 89.9\n"}, "absent\n", m("a", 1000, 899),
			[]string{ev + "floor_too_low pkg=a floor=89.9"}},
		{"floor 90.0 is not too_low", map[string]string{"s1e.txt": "a 90.0\n"}, "absent\n", m("a", 1000, 900), nil},
		{"floor 100.0 is not too_low", map[string]string{"s1e.txt": "a 100.0\n"}, "absent\n", m("a", 7, 7), nil},
		{"F-0.1 is below", map[string]string{"s1e.txt": "a 95.0\n"}, "absent\n", m("a", 1000, 949),
			[]string{ev + "floor_below pkg=a measured=94.9 floor=95.0"}},
		{"F+0.9 passes", map[string]string{"s1e.txt": "a 95.0\n"}, "absent\n", m("a", 1000, 959), nil},
		{"F+1.0 is stale", map[string]string{"s1e.txt": "a 95.0\n"}, "absent\n", m("a", 1000, 960),
			[]string{ev + "floor_stale pkg=a measured=96.0 floor=95.0"}},
		{"a measured package with no entry is missing", map[string]string{"s1e.txt": "a 95.0\n"}, "absent\n",
			m("a", 1000, 955) + m("b", 10, 10), []string{ev + "floor_missing pkg=b"}},
		{"an entry for no package is an orphan", map[string]string{"s1e.txt": "a 95.0\nz 95.0\n"}, "absent\n",
			m("a", 1000, 955), []string{ev + "floor_orphan pkg=z file=s1e.txt"}},
		{"a package in two fragments is a duplicate naming both", map[string]string{"s1e.txt": "a 95.0\n", "s1g.txt": "a 95.0\n"},
			"absent\n", m("a", 1000, 955), []string{ev + "floor_duplicate pkg=a file=s1e.txt other=s1g.txt"}},
		{"a fragment name that is not <slice>.txt", map[string]string{"s1e.txt": "a 95.0\n", "S1G.txt": ""}, "absent\n",
			m("a", 1000, 955), []string{ev + "fragment_invalid file=S1G.txt reason=name"}},
		{"a stray directory in the floors directory", map[string]string{"s1e.txt": "a 95.0\n", "x.txt/": ""}, "absent\n",
			m("a", 1000, 955), []string{ev + "fragment_invalid file=x.txt reason=not_file"}},
		{"a fragment line that is not pkg floor", map[string]string{"s1e.txt": "# c\n\na 95.0\nb 95\n"}, "absent\n",
			m("a", 1000, 955), []string{ev + "fragment_invalid file=s1e.txt line=4 reason=line"}},
		{"floor 100.1 is no floor", map[string]string{"s1e.txt": "a 100.1\n"}, "absent\n",
			m("a", 1000, 955), []string{ev + "fragment_invalid file=s1e.txt line=1 reason=line", ev + "floor_missing pkg=a"}},
		{"none on a package with statements", map[string]string{"s1e.txt": "a none\n"}, "absent\n", m("a", 3, 3),
			[]string{ev + "floor_none_misuse pkg=a reason=none_with_statements"}},
		{"none on a package with no statements passes", map[string]string{"s1e.txt": "a none\n"}, "absent\n", m("a", 0, 0), nil},
		{"a package with no statements not marked none", map[string]string{"s1e.txt": "a 95.0\n"}, "absent\n", m("a", 0, 0),
			[]string{ev + "floor_none_misuse pkg=a reason=no_statements_without_none"}},
		{"a floor lower than the base's is lowered", map[string]string{"s1e.txt": "a 95.0\n"}, "a 95.1\n", m("a", 1000, 955),
			[]string{ev + "floor_lowered pkg=a floor=95.0 base=95.1"}},
		{"a floor equal to the base's is not lowered", map[string]string{"s1e.txt": "a 95.0\n"}, "a 95.0\n", m("a", 1000, 955), nil},
		{"moving an entry between fragments is neither lowered nor dropped", map[string]string{"s1g.txt": "a 95.0\n"},
			"a 95.0\n", m("a", 1000, 955), nil},
		{"a base entry gone from the head while its package stays is dropped", map[string]string{"s1e.txt": "a 95.0\n"},
			"a 95.0\nb 95.0\n", m("a", 1000, 955) + m("b", 10, 10), []string{ev + "floor_dropped pkg=b"}},
		{"a base entry whose package is gone is not dropped", map[string]string{"s1e.txt": "a 95.0\n"},
			"a 95.0\nb 95.0\n", m("a", 1000, 955), nil},
		{"a deleted floors directory while the base has one", nil, "a 95.0\n", m("a", 1000, 955),
			[]string{ev + "floors_dir_deleted"}},
		{"no floors directory and an absent base: every package is missing", nil, "absent\n", m(".", 1, 1),
			[]string{ev + "floor_missing pkg=."}},
		{"a base line that is not pkg floor", map[string]string{"s1e.txt": "a 95.0\n"}, "a 95\n", m("a", 1000, 955),
			[]string{ev + "floors_base_invalid reason=line"}},
		{"a base listing one package twice", map[string]string{"s1e.txt": "a 95.0\n"}, "a 95.0\na 95.0\n", m("a", 1000, 955),
			[]string{ev + "floors_base_invalid reason=duplicate"}},
		{"events are ordered by package", map[string]string{"s1e.txt": "b 95.0\nc 89.0\n"}, "absent\n",
			m("a", 1, 1) + m("b", 1000, 900) + m("c", 100, 100),
			[]string{ev + "floor_missing pkg=a", ev + "floor_below pkg=b measured=90.0 floor=95.0",
				ev + "floor_too_low pkg=c floor=89.0", ev + "floor_stale pkg=c measured=100.0 floor=89.0"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ratchet(t, c.frags, c.base, c.measured)
			if strings.Join(got, "\n") != strings.Join(c.want, "\n") {
				t.Errorf("events:\n got %q\nwant %q", got, c.want)
			}
		})
	}
}

func TestRatchetBaseMissing(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, map[string]string{"floors.d/s1e.txt": "a 95.0\n", "measured": m("a", 1000, 955)})
	events, err := Ratchet(filepath.Join(dir, "measured"), filepath.Join(dir, "floors.d"), filepath.Join(dir, "nobase"), mod)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].String() != "cg_event config_gen_coverage_floors_base_invalid reason=unreadable" {
		t.Errorf("events = %v", events)
	}
}

func TestRatchetMeasuredInvalid(t *testing.T) {
	for name, measured := range map[string]string{
		"missing file":      "",
		"another module":    "other.com/x\t1\t1\n",
		"three fields only": mod + "\t1\n",
		"not a number":      mod + "\tx\t1\n",
		"covered > stmts":   mod + "\t1\t2\n",
	} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			write(t, dir, map[string]string{"floors.d/s1e.txt": ". 95.0\n", "base": "absent\n"})
			if measured != "" {
				write(t, dir, map[string]string{"measured": measured})
			}
			if _, err := Ratchet(filepath.Join(dir, "measured"), filepath.Join(dir, "floors.d"), filepath.Join(dir, "base"), mod); err == nil {
				t.Error("Ratchet accepted the measured file")
			}
		})
	}
}

func TestRatchetFloorsUnreadable(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, map[string]string{"floors.d": "a file, not a directory", "base": "absent\n", "measured": m("a", 1, 1)})
	if _, err := Ratchet(filepath.Join(dir, "measured"), filepath.Join(dir, "floors.d"), filepath.Join(dir, "base"), mod); err == nil {
		t.Error("Ratchet accepted a floors path that is a file")
	}
}

func TestEventEncodesValues(t *testing.T) {
	e := Event{ID: "coverage_fragment_invalid", Attrs: [][2]string{{"file", "a b%\xc3\xa9"}, {"reason", "name"}}}
	if got, want := e.String(), "cg_event config_gen_coverage_fragment_invalid file=a%20b%25%C3%A9 reason=name"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}
