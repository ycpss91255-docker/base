package buildgate

import (
	"reflect"
	"strings"
	"testing"
)

// The mutation gate's inputs (base#1467).

const header = "base=a head=b dirty=yes context=pr\n"

func TestTargets(t *testing.T) {
	cases := []struct {
		name     string
		manifest string
		want     []string
	}{
		{"an unstaged test edit", header + "M\tdockerfile/config-gen/internal/zzmut/zzmut_test.go\n",
			[]string{"internal/zzmut"}},
		{"the module root", header + "A\tdockerfile/config-gen/x.go\n", []string{"."}},
		{"two files of one package and another, unsorted", header +
			"M\tdockerfile/config-gen/internal/b/b.go\nA\tdockerfile/config-gen/internal/a/a.go\nM\tdockerfile/config-gen/internal/b/b_test.go\n",
			[]string{"internal/a", "internal/b"}},
		{"both paths of a rename", header + "R100\tdockerfile/config-gen/internal/a/a.go\tdockerfile/config-gen/internal/b/a.go\n",
			[]string{"internal/a", "internal/b"}},
		{"a file that is not Go", header + "M\tdockerfile/config-gen/go.mod\n", []string{}},
		{"a Go file outside the module", header + "M\tdockerfile/other/x.go\n", []string{}},
		{"the no-change marker", header + "none: no-go-change\n", []string{}},
		{"a header that names a Go path", "M\tdockerfile/config-gen/x.go\n", []string{}},
		{"nothing at all", "", []string{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Targets(c.manifest); !reflect.DeepEqual(got, c.want) {
				t.Errorf("Targets = %q, want %q", got, c.want)
			}
		})
	}
}

// statuses is a gremlins report holding one mutation per status.
func statuses(s ...string) string {
	var b strings.Builder
	b.WriteString(`{"go_module":"example.com/m","files":[{"file_name":"a.go","mutations":[`)
	for i, st := range s {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"type":"CONDITIONALS_NEGATION","status":"` + st + `","line":1,"column":1}`)
	}
	b.WriteString(`]}],"test_efficacy":100}`)
	return b.String()
}

func TestEfficacy(t *testing.T) {
	cases := []struct {
		name   string
		report string
		want   int
		err    bool
	}{
		{"every mutant killed", statuses("KILLED", "KILLED"), 1000, false},
		{"every mutant lived, whatever test_efficacy says", statuses("LIVED", "LIVED"), 0, false},
		{"one of two", statuses("KILLED", "LIVED"), 500, false},
		{"two of three, truncated", statuses("KILLED", "LIVED", "KILLED"), 666, false},
		{"nine of ten", statuses("KILLED", "KILLED", "KILLED", "KILLED", "KILLED", "KILLED", "KILLED", "KILLED", "KILLED", "LIVED"), 900, false},
		{"another status counts for neither", statuses("KILLED", "NOT COVERED"), 1000, false},
		{"no KILLED or LIVED mutant", statuses("NOT COVERED"), 0, true},
		{"no mutation", `{"files":[]}`, 0, true},
		{"not JSON", "x", 0, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := Efficacy([]byte(c.report))
			if (err != nil) != c.err {
				t.Fatalf("Efficacy error %v, want error %v", err, c.err)
			}
			if got != c.want {
				t.Errorf("Efficacy = %d, want %d", got, c.want)
			}
		})
	}
}
