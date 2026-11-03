package main

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// readSectionRows reads corpus/s6/s6_sections.tsv into the rows it
// expects per file basename: "event line key", or none for a "-" row.
func readSectionRows(t *testing.T) map[string][]string {
	t.Helper()
	paths := testcorpus.Glob(t, "corpus/s6/s6_sections.tsv")
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{}
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 5 {
			t.Fatalf("%s:%d: %d fields, want 5: %q", paths[0], i+1, len(f), line)
		}
		if f[4] != "shell" && f[4] != "spec" {
			t.Fatalf("%s:%d: source %q, want shell or spec", paths[0], i+1, f[4])
		}
		rows := want[f[0]]
		if f[1] != "-" {
			rows = append(rows, f[1]+" "+f[2]+" "+f[3])
		}
		want[f[0]] = rows
	}
	return want
}

// `config-gen check` on every corpus/s6/sections/ file gives exactly the
// refusals s6_sections.tsv lists for it (base#1442 AC "Unknown keys",
// review round 3 finding 1). A table is judged by the section text the
// shell gets for it, as _setup_known_section judges it: `[logging.""]` is
// the text `logging.`, an unknown table, while `["logging.web"]` and
// `[logging.web.x]` name a service. Every table text under an unknown
// one is reported too (`[foo.bar]` is foo and foo.bar), anything under a
// `["stage:<name>"]` table is not judged, and an empty array is judged by
// the row its first entry would take: `[security] cap_drop = []` is
// security.cap_drop_1, known, and `[deploy] args = []` is deploy.arg_1,
// an unknown key. The source=shell rows are what the real
// _setup_conf_check_known reports for the same files
// (config_gen_schema_values_spec.bats), so the table is the shell's word.
func TestCheckSectionsCorpus(t *testing.T) {
	want := readSectionRows(t)
	seen := map[string]bool{}
	for _, path := range testcorpus.Glob(t, "corpus/s6/sections/*.toml") {
		base := filepath.Base(path)
		seen[base] = true
		t.Run(base, func(t *testing.T) {
			rows, ok := want[base]
			if !ok {
				t.Fatalf("s6_sections.tsv has no row for %s", base)
			}
			status, fr := runCheck(t, path)
			var got []string
			for _, f := range fr {
				got = append(got, f[2]+" "+f[4]+" "+f[6])
			}
			sort.Strings(got)
			sorted := append([]string(nil), rows...)
			sort.Strings(sorted)
			if !reflect.DeepEqual(got, sorted) {
				t.Errorf("check frames (event line key) = %q, want %q", got, sorted)
			}
			if wantStatus := map[bool]int{true: 0, false: 1}[len(rows) == 0]; status != wantStatus {
				t.Errorf("check = %d, want %d", status, wantStatus)
			}
		})
	}
	for base := range want {
		if !seen[base] {
			t.Errorf("s6_sections.tsv names %s, which is no corpus/s6/sections/ file", base)
		}
	}
}
