package gate

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// noOracleMsg is the refusal for a run without the live tomllib verdicts
// (base#1851): the differential must fail closed, never pass by comparing
// against nothing.
const noOracleMsg = "no live tomllib oracle verdicts; run through just test go"

// The verdict rows must name exactly the TOML files under this package's
// testdata (base#1851): a file with no row was never asked of tomllib,
// and a row with no file is a verdict for something the differential
// cannot read. Each direction fails naming the path; the same set in
// another order passes. The rows go through the verdicts file, the seam
// TestDifferential reads, as the step writes them: `<rel>\t<verdict>\t
// <sha256>`, rel taken from dockerfile/config-gen (review round 1,
// base#1851). Both files hold "x = 1\n", so every row's digest is the
// file's and only the row set decides.
func TestOracleDifferentialHoldsRowsToTheFileSet(t *testing.T) {
	const a = "internal/gate/testdata/toml-test/valid/a.toml"
	const b = "internal/gate/testdata/toml-test/invalid/b.toml"
	dir := t.TempDir()
	path := map[string]string{a: filepath.Join(dir, "a.toml"), b: filepath.Join(dir, "b.toml")}
	for _, p := range path {
		if err := os.WriteFile(p, []byte("x = 1\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	rowA, rowB := a+"\taccept\t"+x1Digest, b+"\taccept\t"+x1Digest
	cases := []struct {
		name  string
		rows  []string
		files []string
		want  string // "" = no problem; otherwise a substring of the problems
	}{
		{"equal sets in another order", []string{rowB, rowA}, []string{a, b}, ""},
		{"missing row", []string{rowA}, []string{a, b}, "no oracle verdict row for " + b},
		{"extra row", []string{rowA, rowB}, []string{a}, "oracle verdict row for " + b + " names no testdata file"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			files := map[string]string{}
			for _, rel := range tc.files {
				files[rel] = path[rel]
			}
			_, problems := oracleDifferential(writeOracle(t, tc.rows), files, liveExpect)
			got := strings.Join(problems, "\n")
			if tc.want == "" {
				if got != "" {
					t.Fatalf("oracleDifferential(%q) problems = %q, want none", tc.rows, got)
				}
				return
			}
			if !strings.Contains(got, tc.want) {
				t.Fatalf("oracleDifferential(%q) problems = %q, want them to name %q", tc.rows, got, tc.want)
			}
		})
	}
}

// oracleFiles returns every TOML file the differential holds the gate to,
// keyed the way the oracle step keys its rows (relative to
// dockerfile/config-gen), with the path to read it from: the WalkDir set
// of this package's testdata/**/*.toml (internal/gate/<path>), and every
// shared corpus file testcorpus.Glob finds under corpus/s*/
// (testdata/corpus/<sN>/<base>, base#1851).
func oracleFiles(t *testing.T) map[string]string {
	t.Helper()
	files := map[string]string{}
	walkErr := filepath.WalkDir("testdata", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && strings.HasSuffix(p, ".toml") {
			files["internal/gate/"+filepath.ToSlash(p)] = p
		}
		return nil
	})
	if walkErr != nil {
		t.Fatal(walkErr)
	}
	for _, p := range testcorpus.Glob(t, "corpus/s*/*.toml") {
		files["testdata/corpus/"+filepath.Base(filepath.Dir(p))+"/"+filepath.Base(p)] = p
	}
	return files
}

// The path TestDifferential takes from the verdicts file to its problems
// must refuse rows that are not exactly the files, each once, before it
// compares a single verdict (review round 1, base#1851). The files here
// both decode, so a verdict comparison alone passes every row set below:
// a same-count set that repeats a.toml in b.toml's place must name the
// omitted b.toml, and a set that repeats a.toml beside b.toml must name
// the repeat. The rows go through the verdicts file, so a loader that
// dropped a repeated row before the comparison would fail here too
// (review round 2, base#1851).
func TestDifferentialRefusesRowsThatAreNotTheFiles(t *testing.T) {
	dir := t.TempDir()
	files := map[string]string{}
	for _, rel := range []string{"a.toml", "b.toml"} {
		p := filepath.Join(dir, rel)
		if err := os.WriteFile(p, []byte("x = 1\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		files[rel] = p
	}
	cases := []struct {
		name string
		rows []string
		want string // "" = no problem; otherwise a substring of the problems
	}{
		{"the files once each", []string{"a.toml\taccept\t" + x1Digest, "b.toml\taccept\t" + x1Digest}, ""},
		{"a repeated in b's place", []string{"a.toml\taccept\t" + x1Digest, "a.toml\taccept\t" + x1Digest}, "no oracle verdict row for b.toml"},
		{"a repeated beside b", []string{"a.toml\taccept\t" + x1Digest, "a.toml\taccept\t" + x1Digest, "b.toml\taccept\t" + x1Digest}, "oracle verdict row for a.toml appears more than once"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, problems := oracleDifferential(writeOracle(t, tc.rows), files, liveExpect)
			got := strings.Join(problems, "\n")
			if tc.want == "" {
				if got != "" {
					t.Fatalf("oracleDifferential(%q) problems = %q, want no problem", tc.rows, got)
				}
				return
			}
			if !strings.Contains(got, tc.want) {
				t.Fatalf("oracleDifferential(%q) problems = %q, want them to name %q", tc.rows, got, tc.want)
			}
		})
	}
}

// writeOracle writes rows, one per line, as a verdicts file and returns
// its path; no rows is an empty file.
func writeOracle(t *testing.T, rows []string) string {
	t.Helper()
	data := ""
	if len(rows) > 0 {
		data = strings.Join(rows, "\n") + "\n"
	}
	p := filepath.Join(t.TempDir(), "verdicts.tsv")
	if err := os.WriteFile(p, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// x1Digest and x2Digest are the SHA-256 of "x = 1\n" and "x = 2\n", as
// sha256sum printed them.
const (
	x1Digest = "9e26bf369911c45c243c684147b23fc9e1dcfcf257d299a1c632016a6fcd33f4"
	x2Digest = "4205c4809ab1b080fd32b6bf9640e5feaa6d1b69bf9fa684954ab710157ec141"
)

// oracleDifferential, the path TestDifferential takes from the verdicts
// file to its problems, must fail on an oracle that is not there or does
// not cover the files, before comparing a verdict (review round 2,
// base#1851): no path (CONFIG_GEN_TOML_ORACLE unset) and a path with no
// file are noOracleMsg; an empty file and a file missing b.toml's row name
// the row missing; a file with a row for c.toml, which is not one of the
// files, names that row. Both files decode, so a run that compared only
// the rows it had would pass every one of these. A row is
// `<rel>\t<verdict>\t<sha256>`, the digest of the bytes tomllib parsed: a
// row whose digest is not the file's (b.toml answered as "x = 2\n", the
// file holds "x = 1\n") is an answer about other bytes, however its
// verdict compares, and a row with no digest cannot be bound to the file.
// Both name the row. The complete file is the control: no problem, both
// rows read.
func TestOracleDifferentialRefusesAnIncompleteOracle(t *testing.T) {
	dir := t.TempDir()
	files := map[string]string{}
	for _, rel := range []string{"a.toml", "b.toml"} {
		p := filepath.Join(dir, rel)
		if err := os.WriteFile(p, []byte("x = 1\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		files[rel] = p
	}
	cases := []struct {
		name string
		path func(t *testing.T) string
		want string // "" = no problem; otherwise a substring of the problems
	}{
		{"complete", func(t *testing.T) string {
			return writeOracle(t, []string{"a.toml\taccept\t" + x1Digest, "b.toml\taccept\t" + x1Digest})
		}, ""},
		{"no path", func(*testing.T) string { return "" }, noOracleMsg},
		{"no file at the path", func(t *testing.T) string {
			return filepath.Join(t.TempDir(), "absent", "verdicts.tsv")
		}, noOracleMsg},
		{"empty file", func(t *testing.T) string { return writeOracle(t, nil) }, "no oracle verdict row for a.toml"},
		{"short file", func(t *testing.T) string {
			return writeOracle(t, []string{"a.toml\taccept\t" + x1Digest})
		}, "no oracle verdict row for b.toml"},
		{"extra row", func(t *testing.T) string {
			return writeOracle(t, []string{"a.toml\taccept\t" + x1Digest, "b.toml\taccept\t" + x1Digest, "c.toml\taccept\t" + x1Digest})
		}, "oracle verdict row for c.toml names no testdata file"},
		{"stale row", func(t *testing.T) string {
			return writeOracle(t, []string{"a.toml\taccept\t" + x1Digest, "b.toml\taccept\t" + x2Digest})
		}, "b.toml: tomllib answered on bytes with sha256 " + x2Digest + ", the file has " + x1Digest},
		{"row with no digest", func(t *testing.T) string {
			return writeOracle(t, []string{"a.toml\taccept\t" + x1Digest, "b.toml\taccept"})
		}, `oracle verdict row "b.toml\taccept" is not <rel>, <verdict> and <sha256>`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := tc.path(t)
			rows, problems := oracleDifferential(path, files, liveExpect)
			got := strings.Join(problems, "\n")
			if tc.want == "" {
				if got != "" || len(rows) != 2 {
					t.Fatalf("oracleDifferential(%q) = %q, %q; want both rows and no problem", path, rows, got)
				}
				return
			}
			if !strings.Contains(got, tc.want) {
				t.Fatalf("oracleDifferential(%q) problems = %q, want them to name %q", path, got, tc.want)
			}
		})
	}
}

// flipVerdict turns a verdict row's accept into refuse and refuse into
// accept, leaving every other field as it was.
func flipVerdict(r string) string {
	f := strings.Split(r, "\t")
	if len(f) > 1 {
		if f[1] == "accept" {
			f[1] = "refuse"
		} else {
			f[1] = "accept"
		}
	}
	return strings.Join(f, "\t")
}

// A verdicts file that covers every file but holds a verdict tomllib did
// not give must fail by that file's name, through the same path
// TestDifferential takes (review round 2, base#1851). The live rows are
// the control and give no problem. With one vendored toml-test row
// flipped, the one problem names that file; with every row flipped,
// every file is named, so a comparison that skips any file, or compares
// nothing once the rows match the files, fails here.
func TestOracleDifferentialNamesEveryFlippedVerdict(t *testing.T) {
	rows, err := loadOracleVerdicts(os.Getenv("CONFIG_GEN_TOML_ORACLE"))
	if err != nil {
		t.Fatal(err)
	}
	files := oracleFiles(t)
	if _, base := oracleDifferential(writeOracle(t, rows), files, liveExpect); len(base) != 0 {
		t.Fatalf("the live rows give %d problems (TestDifferential names them); a flipped verdict cannot be told from them", len(base))
	}

	one := -1
	for i, r := range rows {
		if strings.Contains(r, "/testdata/toml-test/") {
			one = i
			break
		}
	}
	if one < 0 {
		t.Fatal("no vendored toml-test row in the live verdicts")
	}
	flipped := append([]string(nil), rows...)
	flipped[one] = flipVerdict(rows[one])
	rel, _, _ := strings.Cut(rows[one], "\t")
	_, problems := oracleDifferential(writeOracle(t, flipped), files, liveExpect)
	if len(problems) != 1 || !strings.HasPrefix(problems[0], rel+": gate+BurntSushi ") {
		t.Errorf("one flipped verdict, %s: problems = %q, want one naming it", rel, problems)
	}

	for i, r := range rows {
		flipped[i] = flipVerdict(r)
	}
	_, problems = oracleDifferential(writeOracle(t, flipped), files, liveExpect)
	named := map[string]bool{}
	for _, p := range problems {
		if f, _, ok := strings.Cut(p, ": gate+BurntSushi "); ok {
			named[f] = true
		}
	}
	for rel := range files {
		if !named[rel] {
			t.Errorf("every verdict flipped: no problem names %s", rel)
		}
	}
}

// The live rows, from the verdicts file `just test go` hands the build
// through CONFIG_GEN_TOML_ORACLE, must equal oracleFiles' set.
func TestOracleRows(t *testing.T) {
	rows, err := loadOracleVerdicts(os.Getenv("CONFIG_GEN_TOML_ORACLE"))
	if err != nil {
		t.Fatal(err)
	}
	var files []string
	for rel := range oracleFiles(t) {
		files = append(files, rel)
	}
	if err := checkOracleRows(rows, files); err != nil {
		t.Fatal(err)
	}
}

// designVerdicts are tomllib's verdicts on the year and offset-hour forms,
// as measured in the base#1441 design run2 r1 §1 (CPython 3.13.13
// Lib/tomllib): year 0000 is refused in every form, year 0001 and 9999
// are accepted, offset hour 24 is refused and 23 accepted, and the same
// text inside strings, keys, headers and comments is accepted. A live
// verdict that differs fails the row by name.
var designVerdicts = map[string]string{
	"internal/gate/testdata/forms/date-year0-local-date.toml":     "refuse",
	"internal/gate/testdata/forms/date-year0-local-datetime.toml": "refuse",
	"internal/gate/testdata/forms/date-year0-offset.toml":         "refuse",
	"internal/gate/testdata/forms/date-year1.toml":                "accept",
	"internal/gate/testdata/forms/date-year0-text.toml":           "accept",
	"internal/gate/testdata/forms/offset-hour24.toml":             "refuse",
	"internal/gate/testdata/forms/offset-hour23.toml":             "accept",

	// A year-0000 date as an array's second value (review round 1,
	// base#1851).
	"internal/gate/testdata/forms/date-year0-array.toml": "refuse",

	// tomllib loads a float literal past float64 max
	// as inf, keeps float64 max and maps underflow to 0.
	"internal/gate/testdata/forms/float-over.toml":       "accept",
	"internal/gate/testdata/forms/float-over-neg.toml":   "accept",
	"internal/gate/testdata/forms/float-over-mixed.toml": "accept",
	"internal/gate/testdata/forms/float-over-array.toml": "accept",
	"internal/gate/testdata/forms/float-over-int64.toml": "accept",
	"internal/gate/testdata/forms/float-max.toml":        "accept",
	"internal/gate/testdata/forms/float-under.toml":      "accept",

	// ADR-39's one exception: tomllib loads 2^63 as a Python int, which
	// BurntSushi refuses as outside int64 (base#1441; an exception file
	// with no float in it).
	"internal/gate/testdata/forms/int64-over.toml": "accept",

	// base#1441, measured 2026-11-02 (CPython 3.13.13
	// Lib/tomllib; BurntSushi v1.6.0 accepts the first three): a basic
	// string's \e or \x after a multi-line literal that ends in four or
	// five quotes is refused; a [b] header after [[a]] / b.c = 1 names a
	// table of its own and is accepted.
	"internal/gate/testdata/forms/literal-close4-escape.toml":  "refuse",
	"internal/gate/testdata/forms/literal-close5-escape.toml":  "refuse",
	"internal/gate/testdata/forms/aot-dotted-root-header.toml": "accept",

	// Input where the table pass stops, which Check refuses with
	// ReasonSyntax; tomllib and BurntSushi v1.6.0 both refuse each of these
	// (measured 2026-11-02): an inline-table key with no `=`, inline-table pairs or
	// array values with no comma, a header `[` at the end of the document.
	"internal/gate/testdata/forms/stop-inline-no-equals.toml": "refuse",
	"internal/gate/testdata/forms/stop-inline-no-comma.toml":  "refuse",
	"internal/gate/testdata/forms/stop-array-no-comma.toml":   "refuse",
	"internal/gate/testdata/forms/stop-header-eof.toml":       "refuse",

	// base#1441 (a Lib/tomllib copy under
	// python3 -I, 2026-11-02): a quoted key part holding \u0000 is a key
	// of its own, not the dotted path around the NUL, as a key, a header
	// and an inline-table member.
	"internal/gate/testdata/forms/key-nul-not-dotted.toml": "accept",

	// base#1441 (a Lib/tomllib copy under
	// python3 -I, 2026-11-02): a float past float64 max that breaks the
	// float ABNF is refused, not loaded as an infinity.
	"internal/gate/testdata/forms/float-bad-leading-zero.toml":      "refuse",
	"internal/gate/testdata/forms/float-bad-double-underscore.toml": "refuse",
	"internal/gate/testdata/forms/float-bad-exp-underscore.toml":    "refuse",

	// The refused forms' bytes inside a literal string, a comment and a
	// multi-line literal string (acceptedOutsideTheirContext, base#1441).
	"internal/gate/testdata/forms/accept-newline-literal.toml":    "accept",
	"internal/gate/testdata/forms/accept-newline-comment.toml":    "accept",
	"internal/gate/testdata/forms/accept-newline-ml-literal.toml": "accept",
	"internal/gate/testdata/forms/accept-comma-literal.toml":      "accept",
	"internal/gate/testdata/forms/accept-comma-comment.toml":      "accept",
	"internal/gate/testdata/forms/accept-comma-ml-literal.toml":   "accept",
	"internal/gate/testdata/forms/accept-time-literal.toml":       "accept",
	"internal/gate/testdata/forms/accept-time-comment.toml":       "accept",
	"internal/gate/testdata/forms/accept-time-ml-literal.toml":    "accept",
	"internal/gate/testdata/forms/accept-bom-literal.toml":        "accept",
	"internal/gate/testdata/forms/accept-bom-comment.toml":        "accept",
	"internal/gate/testdata/forms/accept-bom-ml-literal.toml":     "accept",
}

// designValues are tomllib's decoded values for the float forms (base#1441,
// CPython 3.13.13 Lib/tomllib), written as literals: an
// overflowing literal loads as +inf or -inf with its sign kept, in any
// container and with underscores; the key `1e999` and the string "1e999"
// stay text; float64 max stays exact and underflow loads as 0. The int64
// file's b is checked only through the int64 exception path.
var designValues = map[string]map[string]any{
	"internal/gate/testdata/forms/float-over.toml":     {"a": math.Inf(1)},
	"internal/gate/testdata/forms/float-over-neg.toml": {"a": math.Inf(-1)},
	"internal/gate/testdata/forms/float-over-mixed.toml": {
		"1e999": math.Inf(1),
		"b":     []any{math.Inf(1), int64(2)},
		"c":     map[string]any{"d": math.Inf(1)},
		"s":     "1e999",
	},
	// An overflowing literal after an array's comma, and after a comment
	// and a line ending (review round 1, base#1851).
	"internal/gate/testdata/forms/float-over-array.toml": {
		"a": []any{int64(1), math.Inf(1)},
		"b": []any{math.Inf(-1)},
	},
	"internal/gate/testdata/forms/float-max.toml":   {"a": 1.7976931348623157e308},
	"internal/gate/testdata/forms/float-under.toml": {"a": float64(0)},
}

// int64Rows are the files whose acceptance must come through the int64
// exception (int64Only) and no other way; no other file, on any path, may
// take it.
var int64Rows = map[string]bool{
	"internal/gate/testdata/forms/float-over-int64.toml": true,
	"internal/gate/testdata/forms/int64-over.toml":       true,
}

// oracleExpect is what differential holds the rows to beyond the verdict
// itself: the files that must take the int64 exception and no others
// (int64Rows), tomllib's a for those whose first line holds one (int64A),
// and tomllib's decoded values (values). Each caller passes its own, so a
// planted case never inherits a real file's pins (base#1851).
type oracleExpect struct {
	int64Rows map[string]bool
	int64A    map[string]float64
	values    map[string]map[string]any
}

// liveExpect holds the expectations for the committed files.
var liveExpect = oracleExpect{int64Rows: int64Rows, int64A: int64A, values: designValues}

// The gate plus BurntSushi must give tomllib's verdict on every TOML file
// the live oracle answered (seam S2, base#1851); oracleDifferential reads
// the verdicts file and does the comparison. The live rows must also hold
// tomllib's design-measured verdict for every designVerdicts file.
func TestDifferential(t *testing.T) {
	rows, problems := oracleDifferential(os.Getenv("CONFIG_GEN_TOML_ORACLE"), oracleFiles(t), liveExpect)
	for _, p := range problems {
		t.Error(p)
	}
	seen := 0
	for _, r := range rows {
		f := strings.Split(r, "\t")
		rel, live := f[0], ""
		if len(f) > 1 {
			live = f[1]
		}
		if want, pinned := designVerdicts[rel]; pinned {
			seen++
			if live != want {
				t.Errorf("%s: live tomllib verdict %s, design §1 measured %s", rel, live, want)
			}
		}
	}
	if seen != len(designVerdicts) {
		t.Errorf("oracle rows named %d of the %d design-measured forms", seen, len(designVerdicts))
	}
}

// oracleDifferential is TestDifferential's whole comparison: it reads the
// verdicts file at path (loadOracleVerdicts, so an empty path or an
// unreadable file is the one problem noOracleMsg) and compares its rows
// with files (differential) under the expectations exp. It returns the
// rows read and one line per problem (review round 2, base#1851).
func oracleDifferential(path string, files map[string]string, exp oracleExpect) ([]string, []string) {
	rows, err := loadOracleVerdicts(path)
	if err != nil {
		return nil, []string{err.Error()}
	}
	return rows, differential(rows, files, exp)
}

// differential compares the gate plus BurntSushi with the tomllib verdict
// rows on files (rel -> path to read) and returns one line per problem.
// The rows must first name exactly the files (checkOracleRows), each
// once; otherwise that is the only problem, before any verdict is
// compared (review round 1, base#1851). Each row must then be
// `<rel>\t<verdict>\t<sha256>`, and the digest, of the bytes tomllib
// parsed, must be that of the file as read here: a row about other bytes
// is named and its verdict not compared (review round 2, base#1851).
// Then each row's verdict is accept
// when Check returns nil and toml.Decode then succeeds, refuse otherwise,
// with one exception: when Check returns nil and toml.Decode refuses only
// integers outside int64 (int64Only), which tomllib accepts, the verdict
// is accept. Only exp.int64Rows may take that path, and each of them must, on
// every path: forms, toml-test and the shared corpus (review round 2,
// base#1851).
// Each disagreeing file is named with both verdicts.
func differential(rows []string, files map[string]string, exp oracleExpect) []string {
	rels := make([]string, 0, len(files))
	for rel := range files {
		rels = append(rels, rel)
	}
	if err := checkOracleRows(rows, rels); err != nil {
		return []string{err.Error()}
	}
	var problems []string
	count := map[string]int{}
	for _, r := range rows {
		rel, _, _ := strings.Cut(r, "\t")
		if count[rel]++; count[rel] == 2 {
			problems = append(problems, "oracle verdict row for "+rel+" appears more than once")
		}
	}
	if len(problems) > 0 {
		return problems
	}
	for _, r := range rows {
		f := strings.Split(r, "\t")
		if len(f) != 3 {
			problems = append(problems, fmt.Sprintf("oracle verdict row %q is not <rel>, <verdict> and <sha256>", r))
			continue
		}
		rel, live, digest := f[0], f[1], f[2]
		src, err := os.ReadFile(files[rel])
		if err != nil {
			problems = append(problems, err.Error())
			continue
		}
		if sum := sha256.Sum256(src); hex.EncodeToString(sum[:]) != digest {
			problems = append(problems, fmt.Sprintf("%s: tomllib answered on bytes with sha256 %s, the file has %s", rel, digest, hex.EncodeToString(sum[:])))
			continue
		}
		got, viaInt64 := "refuse", false
		var v map[string]any
		if Check(rel, src) == nil {
			norm := Normalize(src)
			if len(norm) != len(src) {
				problems = append(problems, fmt.Sprintf("%s: Normalize changed the length %d -> %d", rel, len(src), len(norm)))
			}
			if _, err := toml.Decode(string(norm), &v); err == nil {
				got = "accept"
			} else if int64Only(norm, err) {
				got, viaInt64 = "accept", true
				if want, ok := exp.int64A[rel]; ok {
					if a, ok := designInt64A(norm); !ok || a != want {
						problems = append(problems, fmt.Sprintf("%s: a = %v (ok %v) after the int64 path, tomllib loads %v", rel, a, ok, want))
					}
				}
			}
		}
		if got != live {
			problems = append(problems, fmt.Sprintf("%s: gate+BurntSushi %s, tomllib %s", rel, got, live))
		}
		if viaInt64 != exp.int64Rows[rel] {
			problems = append(problems, fmt.Sprintf("%s: int64 exception path taken = %v, want %v", rel, viaInt64, exp.int64Rows[rel]))
		}
		if want, ok := exp.values[rel]; ok && got == "accept" && !reflect.DeepEqual(v, want) {
			problems = append(problems, fmt.Sprintf("%s: decoded %#v, tomllib loads %#v", rel, v, want))
		}
	}
	return problems
}

// The int64 exception is a closed set on every path, and only BurntSushi
// refusals that are all out-of-int64 integers reach it (base#1851). Each
// case is a planted file at a rel no live table names, with its own
// oracleExpect, so it inherits no real file's pins; the row is tomllib's
// verdict on those bytes, read from the live bridge (2^63 alone, 2^63 in
// hex, and two out-of-int64 tokens accept; 2^63 beside `b = tru`, and a
// key carrying the int64 message text beside `tru`, refuse). A file
// outside the set that takes the exception is named on forms, the vendored
// toml-test and the shared corpus; a file in the set that is refused for
// a second, non-integer reason is named for not taking it.
func TestDifferentialHoldsTheInt64ExceptionToItsSetOnEveryPath(t *testing.T) {
	const (
		forms  = "internal/gate/testdata/forms/"
		valid  = "internal/gate/testdata/toml-test/valid/"
		corpus = "testdata/corpus/s1/"
		over   = "a = 9223372036854775808\n"
		hexed  = "a = 0x8000000000000000\n"
		two    = "a = -9223372036854775809\nb = [9223372036854775808]\n"
		second = "a = 9223372036854775808\nb = tru\n"
		decoy  = "\"x is out of range for int64\" = tru\n"
	)
	for _, tc := range []struct {
		rel, src, verdict string
		inSet             bool
		want              string // "" = no problem
	}{
		{forms + "planted-1.toml", over, "accept", true, ""},
		{forms + "planted-2.toml", over, "accept", false, forms + "planted-2.toml: int64 exception path taken = true, want false"},
		{valid + "planted-3.toml", over, "accept", false, valid + "planted-3.toml: int64 exception path taken = true, want false"},
		{corpus + "planted-4.toml", over, "accept", false, corpus + "planted-4.toml: int64 exception path taken = true, want false"},
		{forms + "planted-5.toml", hexed, "accept", true, ""},
		{valid + "planted-6.toml", two, "accept", true, ""},
		{corpus + "planted-7.toml", second, "refuse", false, ""},
		{forms + "planted-8.toml", second, "refuse", true, forms + "planted-8.toml: int64 exception path taken = false, want true"},
		{valid + "planted-9.toml", decoy, "refuse", false, ""},
	} {
		p := filepath.Join(t.TempDir(), "f.toml")
		if err := os.WriteFile(p, []byte(tc.src), 0o600); err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256([]byte(tc.src))
		row := tc.rel + "\t" + tc.verdict + "\t" + hex.EncodeToString(sum[:])
		exp := oracleExpect{int64Rows: map[string]bool{}}
		if tc.inSet {
			exp.int64Rows[tc.rel] = true
		}
		_, problems := oracleDifferential(writeOracle(t, []string{row}), map[string]string{tc.rel: p}, exp)
		got := strings.Join(problems, "\n")
		if got != tc.want {
			t.Errorf("%s (%q, in set %v): problems = %q, want %q", tc.rel, tc.src, tc.inSet, got, tc.want)
		}
	}
}

// int64A is tomllib's a for the int64 exception files whose first line
// holds a float beside the out-of-int64 integer (base#1441):
// float-over-int64.toml's a = 1e999 loads as +Inf. Only these files get
// the check; another exception file has no such a.
var int64A = map[string]float64{
	"internal/gate/testdata/forms/float-over-int64.toml": math.Inf(1),
}

// designInt64A decodes the int64 form's first line on its own (the file's
// b is the out-of-int64 integer) and returns its a.
func designInt64A(src []byte) (float64, bool) {
	line, _, _ := strings.Cut(string(src), "\n")
	var v map[string]any
	if _, err := toml.Decode(line, &v); err != nil {
		return 0, false
	}
	a, ok := v["a"].(float64)
	return a, ok
}
