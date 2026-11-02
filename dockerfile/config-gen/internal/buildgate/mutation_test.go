package buildgate

import (
	"os"
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

// testdata/golist-testcorpus.json is the live output of
// `go list -json=ImportPath,ForTest,Standard,Deps -test -deps ./...`
// (go1.27.2) over a fixture module with this module's path:
// internal/testcorpus (with a test), internal/helper (imports testcorpus,
// no test), internal/b (imports helper, with a test), internal/d (only
// its external d_test imports testcorpus), internal/c (no import, with a
// test) and cmd/x (imports helper, no test). In that output the .test
// packages whose Deps hold testcorpus, or its own test variant, are b.test,
// d.test and testcorpus.test.
const fixtureModule = "github.com/ycpss91255-docker/base/dockerfile/config-gen"

func TestMapRootTestdataTargetsTestcorpusImporters(t *testing.T) {
	body, err := os.ReadFile("testdata/golist-testcorpus.json")
	if err != nil {
		t.Fatal(err)
	}
	pkgs, err := DecodeList(body)
	if err != nil {
		t.Fatalf("DecodeList: %v", err)
	}
	want := []string{"internal/b", "internal/d", "internal/testcorpus"}
	cases := []struct {
		name     string
		manifest string
	}{
		{"a modified golden file", header + "M\tdockerfile/config-gen/testdata/golden/s1/seed.golden\n"},
		{"a new corpus file", header + "A\tdockerfile/config-gen/testdata/corpus/s1/c.txt\n"},
		{"two root testdata files", header +
			"M\tdockerfile/config-gen/testdata/c.txt\nA\tdockerfile/config-gen/testdata/golden/s1/zz.golden\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := Map(c.manifest, fixtureModule, pkgs)
			if err != nil {
				t.Fatalf("Map: %v", err)
			}
			if !reflect.DeepEqual(got.Targets, want) {
				t.Errorf("Map targets = %q, want %q", got.Targets, want)
			}
		})
	}
}

// A module file that is not Go maps to the packages whose build or test
// it can change: a file under a package's own testdata/ to that package,
// and go.mod, go.sum or .golangci.yml to every package of the module. The
// expected lists are the fixture's packages as the comment above names
// them (six, tested or not), not derived from the fixture by code.
func TestMapNonGoModuleFilesTargetTheirPackages(t *testing.T) {
	body, err := os.ReadFile("testdata/golist-testcorpus.json")
	if err != nil {
		t.Fatal(err)
	}
	pkgs, err := DecodeList(body)
	if err != nil {
		t.Fatalf("DecodeList: %v", err)
	}
	every := []string{"cmd/x", "internal/b", "internal/c", "internal/d", "internal/helper", "internal/testcorpus"}
	cases := []struct {
		name     string
		manifest string
		want     []string
	}{
		{"a file in a package's own testdata", header + "M\tdockerfile/config-gen/internal/c/testdata/in.txt\n",
			[]string{"internal/c"}},
		{"a nested file in a package's own testdata", header + "A\tdockerfile/config-gen/internal/c/testdata/s1/in.txt\n",
			[]string{"internal/c"}},
		{"go.mod", header + "M\tdockerfile/config-gen/go.mod\n", every},
		{"go.sum", header + "M\tdockerfile/config-gen/go.sum\n", every},
		{".golangci.yml", header + "M\tdockerfile/config-gen/.golangci.yml\n", every},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := Map(c.manifest, fixtureModule, pkgs)
			if err != nil {
				t.Fatalf("Map: %v", err)
			}
			if !reflect.DeepEqual(got.Targets, c.want) {
				t.Errorf("Map targets = %q, want %q", got.Targets, c.want)
			}
		})
	}
}

// Map keeps Targets' rule: a Go file maps to its own directory, with no
// package list needed.
func TestMapGoFileTargetsItsDirectory(t *testing.T) {
	got, err := Map(header+"M\tdockerfile/config-gen/internal/c/c.go\n", fixtureModule, nil)
	if err != nil {
		t.Fatalf("Map: %v", err)
	}
	if want := []string{"internal/c"}; !reflect.DeepEqual(got.Targets, want) {
		t.Errorf("Map targets = %q, want %q", got.Targets, want)
	}
}

// DecodeList refuses a body that is not concatenated JSON records.
func TestDecodeListRefusesBadJSON(t *testing.T) {
	if _, err := DecodeList([]byte("{\"ImportPath\": ")); err == nil {
		t.Error("DecodeList of a truncated record returned no error")
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
