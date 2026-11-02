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

// A module file no mapping rule covers (not Go, not under any testdata/,
// not go.mod, go.sum, .golangci.yml or a coverage-floors.d fragment) is
// refused as unmapped, naming the manifest path, even beside a mapped
// file. The expected lines are the issue's event id with file= spelled
// as literals.
func TestMapRefusesAnUnmappedFile(t *testing.T) {
	body, err := os.ReadFile("testdata/golist-testcorpus.json")
	if err != nil {
		t.Fatal(err)
	}
	pkgs, err := DecodeList(body)
	if err != nil {
		t.Fatalf("DecodeList: %v", err)
	}
	cases := []struct {
		name     string
		manifest string
		want     string
	}{
		{"notes.txt at the module root", header + "A\tdockerfile/config-gen/notes.txt\n",
			"cg_event config_gen_mutation_unmapped file=dockerfile/config-gen/notes.txt"},
		{"a shell script in a gates directory", header + "M\tdockerfile/config-gen/gates/coverage.sh\n",
			"cg_event config_gen_mutation_unmapped file=dockerfile/config-gen/gates/coverage.sh"},
		{"a README beside a package's Go files", header + "M\tdockerfile/config-gen/internal/c/README.md\n",
			"cg_event config_gen_mutation_unmapped file=dockerfile/config-gen/internal/c/README.md"},
		{"beside a mapped Go file", header +
			"M\tdockerfile/config-gen/internal/c/c.go\nA\tdockerfile/config-gen/notes.txt\n",
			"cg_event config_gen_mutation_unmapped file=dockerfile/config-gen/notes.txt"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := Map(c.manifest, fixtureModule, pkgs)
			if err == nil {
				t.Fatalf("Map returned no error, want %q", c.want)
			}
			if got := err.Error(); got != c.want {
				t.Errorf("Map error = %q, want %q", got, c.want)
			}
		})
	}
}

// A deleted Go path (a D line, or the old side of an R line) maps to its
// directory's package while the head tree still holds a package there,
// and is otherwise recorded as removed: no target, no refusal. The new
// side of a rename maps as an add, so a package move targets the new
// package and records the old one as removed. internal/zzgone and
// internal/zzold are not packages of the fixture (see the comment above
// TestMapRootTestdataTargetsTestcorpusImporters); internal/b and
// internal/c are. The expected lists are spelled from that comment.
func TestMapDeletesAndRenames(t *testing.T) {
	body, err := os.ReadFile("testdata/golist-testcorpus.json")
	if err != nil {
		t.Fatal(err)
	}
	pkgs, err := DecodeList(body)
	if err != nil {
		t.Fatalf("DecodeList: %v", err)
	}
	cases := []struct {
		name        string
		manifest    string
		wantTargets []string
		wantRemoved []string
	}{
		{"a deleted file whose package is left", header + "D\tdockerfile/config-gen/internal/c/old.go\n",
			[]string{"internal/c"}, []string{}},
		{"a deleted package", header + "D\tdockerfile/config-gen/internal/zzgone/zzgone.go\n",
			[]string{}, []string{"internal/zzgone"}},
		{"a deleted package of two files, recorded once", header +
			"D\tdockerfile/config-gen/internal/zzgone/zzgone.go\nD\tdockerfile/config-gen/internal/zzgone/zzgone_test.go\n",
			[]string{}, []string{"internal/zzgone"}},
		{"a rename inside one package", header + "R100\tdockerfile/config-gen/internal/c/old.go\tdockerfile/config-gen/internal/c/new.go\n",
			[]string{"internal/c"}, []string{}},
		{"a file moved between two packages that are left", header +
			"R100\tdockerfile/config-gen/internal/c/x.go\tdockerfile/config-gen/internal/b/x.go\n",
			[]string{"internal/b", "internal/c"}, []string{}},
		{"a package move", header +
			"R100\tdockerfile/config-gen/internal/zzold/b.go\tdockerfile/config-gen/internal/b/b.go\n" +
			"R100\tdockerfile/config-gen/internal/zzold/b_test.go\tdockerfile/config-gen/internal/b/b_test.go\n",
			[]string{"internal/b"}, []string{"internal/zzold"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := Map(c.manifest, fixtureModule, pkgs)
			if err != nil {
				t.Fatalf("Map: %v", err)
			}
			if !reflect.DeepEqual(got.Targets, c.wantTargets) {
				t.Errorf("Map targets = %q, want %q", got.Targets, c.wantTargets)
			}
			if !reflect.DeepEqual(got.Removed, c.wantRemoved) {
				t.Errorf("Map removed = %q, want %q", got.Removed, c.wantRemoved)
			}
		})
	}
}

// A manifest path the producer wrote C-quoted (it holds a control byte, a
// double quote or a backslash; config_gen_mutation_lang.sh _cgm_quote)
// maps as the raw path it reads back to. Each manifest line below is
// spelled the way _cgm_quote spells it (a `"` as \", a backslash as \\, a
// tab as \t). The expected lists are spelled from the fixture comment
// above TestMapRootTestdataTargetsTestcorpusImporters, as for the
// unquoted forms of the same paths.
func TestMapReadsQuotedPaths(t *testing.T) {
	body, err := os.ReadFile("testdata/golist-testcorpus.json")
	if err != nil {
		t.Fatal(err)
	}
	pkgs, err := DecodeList(body)
	if err != nil {
		t.Fatalf("DecodeList: %v", err)
	}
	cases := []struct {
		name     string
		manifest string
		want     []string
	}{
		{"a quoted root testdata file", header + "A\t\"dockerfile/config-gen/testdata/zznames/zz\\\"q.txt\"\n",
			[]string{"internal/b", "internal/d", "internal/testcorpus"}},
		{"a quoted file in a package's own testdata", header + "M\t\"dockerfile/config-gen/internal/c/testdata/a\\\\b.txt\"\n",
			[]string{"internal/c"}},
		{"a quoted Go file", header + "A\t\"dockerfile/config-gen/internal/c/zz\\tq.go\"\n",
			[]string{"internal/c"}},
		{"a quoted new side of a rename", header +
			"R100\tdockerfile/config-gen/internal/c/old.go\t\"dockerfile/config-gen/internal/b/zz\\\"q.go\"\n",
			[]string{"internal/b", "internal/c"}},
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

// The producer's no-change marker (config_gen_mutation_targets.sh
// _CGM_NONE, `none: no-go-change`) stands alone after the header. Beside
// a record it is refused, whichever side it is on and whatever the record
// maps to. The expected line is the event id and reason the design
// (base#1467, design r1 §2) names, spelled as a literal.
func TestMapRefusesTheMarkerBesideLines(t *testing.T) {
	body, err := os.ReadFile("testdata/golist-testcorpus.json")
	if err != nil {
		t.Fatal(err)
	}
	pkgs, err := DecodeList(body)
	if err != nil {
		t.Fatalf("DecodeList: %v", err)
	}
	const want = "cg_event config_gen_mutation_manifest_invalid reason=marker_beside_lines"
	cases := []struct {
		name     string
		manifest string
	}{
		{"the marker before a Go record", header + "none: no-go-change\nM\tdockerfile/config-gen/internal/c/c.go\n"},
		{"the marker after a Go record", header + "M\tdockerfile/config-gen/internal/c/c.go\nnone: no-go-change\n"},
		{"the marker beside a root testdata record", header +
			"none: no-go-change\nA\tdockerfile/config-gen/testdata/corpus/s1/c.txt\n"},
		{"the marker beside a deleted package", header +
			"D\tdockerfile/config-gen/internal/zzgone/zzgone.go\nnone: no-go-change\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := Map(c.manifest, fixtureModule, pkgs)
			if err == nil {
				t.Fatalf("Map returned %+v and no error, want %q", got, want)
			}
			if err.Error() != want {
				t.Errorf("Map error = %q, want %q", err.Error(), want)
			}
		})
	}
}

// The producer writes either at least one record or the no-change marker
// after the header (config_gen_mutation_targets.sh: with no line the
// marker is written). A manifest that holds neither, only its header and
// perhaps blank lines, is refused rather than read as nothing to test. The
// expected line is the event id and reason the design (base#1467, design
// r1 §2) names, spelled as a literal.
func TestMapRefusesAManifestWithNoRecordAndNoMarker(t *testing.T) {
	body, err := os.ReadFile("testdata/golist-testcorpus.json")
	if err != nil {
		t.Fatal(err)
	}
	pkgs, err := DecodeList(body)
	if err != nil {
		t.Fatalf("DecodeList: %v", err)
	}
	const want = "cg_event config_gen_mutation_manifest_invalid reason=empty_manifest"
	cases := []struct {
		name     string
		manifest string
	}{
		{"the header alone", header},
		{"the header without its newline", strings.TrimSuffix(header, "\n")},
		{"the header and blank lines", header + "\n\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := Map(c.manifest, fixtureModule, pkgs)
			if err == nil {
				t.Fatalf("Map returned %+v and no error, want %q", got, want)
			}
			if err.Error() != want {
				t.Errorf("Map error = %q, want %q", err.Error(), want)
			}
		})
	}
}

// unquote reads a control byte the producer writes as \ooo back to that
// byte, and returns a spelling that does not read back as written (the
// admission gate, config_gen_admit.sh _cga_record, refuses such a
// manifest before the mutation gate reads it).
func TestUnquoteOctalAndUnreadable(t *testing.T) {
	cases := []struct{ in, want string }{
		{`"a\001b.go"`, "a\x01b.go"},
		{`"a\qb.go"`, `"a\qb.go"`},
	}
	for _, c := range cases {
		if got := unquote(c.in); got != c.want {
			t.Errorf("unquote(%q) = %q, want %q", c.in, got, c.want)
		}
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
