package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// s7Verdict is one row of corpus/s7/s7_verdicts.tsv: a fixture, the
// verdict `config-gen check` gives it, and for a refuse or a
// differs:<exception> row the one frame's event, line, column and key.
type s7Verdict struct {
	line    int
	verdict string
	frame   []string // event, line, col, key
}

// readS7Verdicts reads the shared S7 verdict manifest, keyed by fixture.
// The bats half (test/bats/unit/config_gen_s7_verdicts_spec.bats) holds
// each row's verdict, event and key to the bridge's own output and its
// apply column to apply's per-layer checks, so the rows are the shell's
// word and not this package's (base#1443 review round 3 finding 1).
func readS7Verdicts(t *testing.T) map[string]s7Verdict {
	t.Helper()
	paths := testcorpus.Glob(t, "corpus/s7/s7_verdicts.tsv")
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatalf("read %s: %v", paths[0], err)
	}
	rows := map[string]s7Verdict{}
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 7 {
			t.Fatalf("%s:%d: want 7 fields: %q", paths[0], i+1, line)
		}
		if _, dup := rows[f[0]]; dup {
			t.Fatalf("%s:%d: a second row for %s", paths[0], i+1, f[0])
		}
		rows[f[0]] = s7Verdict{line: i + 1, verdict: f[1], frame: f[2:6]}
	}
	return rows
}

// `config-gen check` on every corpus/s7 fixture gives the verdict the
// shared manifest s7_verdicts.tsv states for it, through runCheck's five
// points of the refusal-test contract (base#1395 plan, "Every refusal
// test asserts five things"; base#1443 review round 1 finding 1): status
// 1, empty stdout and stderr wholly frames naming the fixture as the
// file, and the event, line, column and key of the one frame, whose
// display text is the text check_test.go states for its event. A refuse
// row and a differs:<exception> row, one the bridge reads and the
// generator refuses on purpose, give that frame; an accept row gives
// status 0 and no frame. Every fixture needs exactly one row and every
// row its fixture, so a fixture added without a verdict fails here, as
// does a rule that reports its refusal at another position, key or text
// (base#1443 review round 3 finding 1).
func TestCheckS7Corpus(t *testing.T) {
	rows := readS7Verdicts(t)
	seen := map[string]bool{}
	for _, path := range testcorpus.Glob(t, "corpus/s7/*.toml") {
		base := filepath.Base(path)
		seen[base] = true
		t.Run(base, func(t *testing.T) {
			row, ok := rows[base]
			if !ok {
				t.Fatalf("%s has no row in s7_verdicts.tsv", base)
			}

			status, fr := runCheck(t, path)

			switch {
			case row.verdict == "accept":
				if status != 0 || len(fr) != 0 {
					t.Fatalf("tsv line %d: check = %d, frames %q; want 0 and no frame", row.line, status, fr)
				}
			case row.verdict == "refuse" || strings.HasPrefix(row.verdict, "differs:"):
				if status != 1 || len(fr) != 1 {
					t.Fatalf("tsv line %d: check = %d, frames %q; want 1 and one frame", row.line, status, fr)
				}
				if got := []string{fr[0][2], fr[0][4], fr[0][5], fr[0][6]}; !reflect.DeepEqual(got, row.frame) {
					t.Errorf("tsv line %d: frame (event line col key) = %q, want %q", row.line, got, row.frame)
				}
			default:
				t.Fatalf("tsv line %d: verdict %q is not accept, refuse or differs:<exception>", row.line, row.verdict)
			}
		})
	}
	for base, row := range rows {
		if !seen[base] {
			t.Errorf("tsv line %d names %s, which is no corpus/s7 file", row.line, base)
		}
	}
}
