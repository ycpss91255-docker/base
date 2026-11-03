package main

import (
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// s7ExpectPrefix starts the one comment line each corpus/s7 fixture
// states its own expected verdict on. The corpus rule of the base#1395
// plan is that readers discover fixtures by globbing and that no index or
// manifest file lists them, so a fixture carries its verdict itself and
// adding one touches no other file (base#1443 review round 4 finding 1).
const s7ExpectPrefix = "# expect: "

// s7Verdict is a fixture's `# expect:` line: the verdict `config-gen
// check` gives it, and for a refuse or a differs:<exception> verdict the
// one frame's event, line, column and key. Its apply field is read by
// the bats half (config_gen_s7_verdicts_spec.bats) only.
type s7Verdict struct {
	verdict string
	frame   []string // event, line, col, key
}

// readS7Expect reads the one `# expect: name=value ...` line of the
// fixture at path. Every verdict names apply; a refuse or differs:<x>
// verdict also names event, line, col and key, and an accept verdict
// names none of them. A fixture with no such line or two of them, or a
// field that is not one name=value of that set, fails the test.
func readS7Expect(t *testing.T, path string) s7Verdict {
	t.Helper()
	base := filepath.Base(path)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var lines []string
	for _, line := range strings.Split(string(data), "\n") {
		if rest, ok := strings.CutPrefix(line, s7ExpectPrefix); ok {
			lines = append(lines, rest)
		}
	}
	if len(lines) != 1 {
		t.Fatalf("%s carries %d %q lines, want exactly one", base, len(lines), s7ExpectPrefix)
	}
	got := map[string]string{}
	for _, field := range strings.Fields(lines[0]) {
		name, value, ok := strings.Cut(field, "=")
		if _, dup := got[name]; !ok || dup || value == "" {
			t.Fatalf("%s: expect field %q is not one name=value", base, field)
		}
		got[name] = value
	}
	want := []string{"apply", "verdict"}
	switch v := got["verdict"]; {
	case v == "refuse" || strings.HasPrefix(v, "differs:"):
		want = []string{"apply", "col", "event", "key", "line", "verdict"}
	case v != "accept":
		t.Fatalf("%s: verdict %q is not accept, refuse or differs:<exception>", base, v)
	}
	if have := slices.Sorted(maps.Keys(got)); !slices.Equal(have, want) {
		t.Fatalf("%s: expect names %q, want %q for verdict %s", base, have, want, got["verdict"])
	}
	v := s7Verdict{verdict: got["verdict"]}
	if v.verdict != "accept" {
		v.frame = []string{got["event"], got["line"], got["col"], got["key"]}
	}
	return v
}

// `config-gen check` on every corpus/s7 fixture gives the verdict the
// fixture's own `# expect:` line states, through runCheck's five points
// of the refusal-test contract (base#1395 plan, "Every refusal test
// asserts five things"; base#1443 review round 1 finding 1): status 1,
// empty stdout and stderr wholly frames naming the fixture as the file,
// and the event, line, column and key of the one frame, whose display
// text is the text check_test.go states for its event. A refuse verdict
// and a differs:<exception> one, a fixture the bridge reads and the
// generator refuses on purpose, give that frame; an accept verdict gives
// status 0 and no frame. The bats half holds the same line to the
// bridge's own output (base#1443 review round 3 finding 1), and a fixture
// without the line fails both halves (review round 4 finding 1).
func TestCheckS7Corpus(t *testing.T) {
	paths := testcorpus.Glob(t, "corpus/s7/*.toml")
	if len(paths) == 0 {
		t.Fatal("corpus/s7 holds no fixture")
	}
	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			want := readS7Expect(t, path)

			status, fr := runCheck(t, path)

			if want.verdict == "accept" {
				if status != 0 || len(fr) != 0 {
					t.Fatalf("check = %d, frames %q; want 0 and no frame", status, fr)
				}
				return
			}
			if status != 1 || len(fr) != 1 {
				t.Fatalf("check = %d, frames %q; want 1 and one frame", status, fr)
			}
			if got := []string{fr[0][2], fr[0][4], fr[0][5], fr[0][6]}; !reflect.DeepEqual(got, want.frame) {
				t.Errorf("frame (event line col key) = %q, want %q", got, want.frame)
			}
		})
	}
}

// No file of corpus/s7 but a fixture names a corpus/s7 fixture: the
// corpus rule of the base#1395 plan forbids an index or manifest that
// lists the fixtures, since adding one must touch no shared file
// (base#1443 review round 4 finding 1).
func TestS7CorpusListsNoFixture(t *testing.T) {
	fixtures := testcorpus.Glob(t, "corpus/s7/*.toml")
	for _, other := range testcorpus.Glob(t, "corpus/s7/*") {
		if strings.HasSuffix(other, ".toml") {
			continue
		}
		data, err := os.ReadFile(other)
		if err != nil {
			t.Fatalf("read %s: %v", other, err)
		}
		for _, f := range fixtures {
			if strings.Contains(string(data), filepath.Base(f)) {
				t.Errorf("%s names the fixture %s: no file may list the corpus fixtures", filepath.Base(other), filepath.Base(f))
			}
		}
	}
}
