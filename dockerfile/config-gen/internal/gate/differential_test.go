package gate

import (
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

// The verdicts file is named by CONFIG_GEN_TOML_ORACLE, which only the
// build `just test go` drives sets. An unset variable (empty path) and a
// path with no file behind it must both fail with noOracleMsg.
func TestLoadOracleVerdictsFailsClosed(t *testing.T) {
	cases := []struct {
		name string
		path string
	}{
		{"empty path", ""},
		{"missing file", filepath.Join(t.TempDir(), "absent", "toml-verdicts.tsv")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rows, err := loadOracleVerdicts(tc.path)
			if err == nil {
				t.Fatalf("loadOracleVerdicts(%q) = %v, nil; want error %q", tc.path, rows, noOracleMsg)
			}
			if !strings.Contains(err.Error(), noOracleMsg) {
				t.Fatalf("loadOracleVerdicts(%q) error = %q, want it to contain %q", tc.path, err.Error(), noOracleMsg)
			}
		})
	}
}

// The verdict rows must name exactly the TOML files under this package's
// testdata (base#1851): a file with no row was never asked of tomllib,
// and a row with no file is a verdict for something the differential
// cannot read. Each direction fails naming the path; the same set in
// another order passes. Rows are the step's `<rel>\t<verdict>` lines,
// rel taken from dockerfile/config-gen.
func TestCheckOracleRowsSetEquality(t *testing.T) {
	const a = "internal/gate/testdata/toml-test/valid/a.toml"
	const b = "internal/gate/testdata/toml-test/invalid/b.toml"
	cases := []struct {
		name  string
		rows  []string
		files []string
		want  string // "" = nil error; otherwise a substring of the error
	}{
		{"equal sets", []string{b + "\trefuse", a + "\taccept"}, []string{a, b}, ""},
		{"missing row", []string{a + "\taccept"}, []string{a, b}, b},
		{"extra row", []string{a + "\taccept", b + "\trefuse"}, []string{a}, b},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := checkOracleRows(tc.rows, tc.files)
			if tc.want == "" {
				if err != nil {
					t.Fatalf("checkOracleRows(%q, %q) = %v, want nil", tc.rows, tc.files, err)
				}
				return
			}
			if err == nil {
				t.Fatalf("checkOracleRows(%q, %q) = nil, want an error naming %q", tc.rows, tc.files, tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("checkOracleRows(%q, %q) error = %q, want it to name %q", tc.rows, tc.files, err.Error(), tc.want)
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

// int64Rows are the forms files whose acceptance must come through the
// int64 exception (int64Only) and no other way; every other forms file
// must not take it.
var int64Rows = map[string]bool{
	"internal/gate/testdata/forms/float-over-int64.toml": true,
	"internal/gate/testdata/forms/int64-over.toml":       true,
}

// The gate plus BurntSushi must give tomllib's verdict on every TOML file
// the live oracle answered (seam S2, base#1851):
// accept when Check returns nil and toml.Decode then succeeds, refuse
// otherwise, with one exception: when Check returns nil and toml.Decode
// refuses only integers outside int64 (int64Only), which tomllib accepts,
// the verdict is accept. Among the forms files, only int64Rows may take
// that path. Each disagreeing file fails by name with both verdicts.
func TestDifferential(t *testing.T) {
	rows, err := loadOracleVerdicts(os.Getenv("CONFIG_GEN_TOML_ORACLE"))
	if err != nil {
		t.Fatal(err)
	}
	files := oracleFiles(t)
	seen := 0
	for _, r := range rows {
		rel, live, ok := strings.Cut(r, "\t")
		if !ok {
			t.Fatalf("oracle verdict row %q has no tab", r)
		}
		if want, pinned := designVerdicts[rel]; pinned {
			seen++
			if live != want {
				t.Errorf("%s: live tomllib verdict %s, design §1 measured %s", rel, live, want)
			}
		}
		path, ok := files[rel]
		if !ok {
			t.Fatalf("oracle verdict row %s names no file the differential reads", rel)
		}
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		got, viaInt64 := "refuse", false
		var v map[string]any
		if Check(rel, src) == nil {
			norm := Normalize(src)
			if len(norm) != len(src) {
				t.Errorf("%s: Normalize changed the length %d -> %d", rel, len(src), len(norm))
			}
			if _, err := toml.Decode(string(norm), &v); err == nil {
				got = "accept"
			} else if int64Only(norm, err) {
				got, viaInt64 = "accept", true
				if want, ok := int64A[rel]; ok {
					if a, ok := designInt64A(norm); !ok || a != want {
						t.Errorf("%s: a = %v (ok %v) after the int64 path, tomllib loads %v", rel, a, ok, want)
					}
				}
			}
		}
		if got != live {
			t.Errorf("%s: gate+BurntSushi %s, tomllib %s", rel, got, live)
		}
		if viaInt64 != int64Rows[rel] && strings.Contains(rel, "/forms/") {
			t.Errorf("%s: int64 exception path taken = %v, want %v", rel, viaInt64, int64Rows[rel])
		}
		if want, ok := designValues[rel]; ok && got == "accept" && !reflect.DeepEqual(v, want) {
			t.Errorf("%s: decoded %#v, tomllib loads %#v", rel, v, want)
		}
	}
	if seen != len(designVerdicts) {
		t.Errorf("oracle rows named %d of the %d design-measured forms", seen, len(designVerdicts))
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

// 2^63 (int64 max + 1) in decimal and hex, and two out-of-range tokens in
// one file. The false rows: a second, non-integer refusal behind the
// integer; a float range refusal (1e999); a key that carries the int64
// message text; a hand-built error whose Message names an int64 overflow
// but whose span is not an integer; and a hand-built span over int64 max,
// which is in range. Errors come from BurntSushi v1.6.0's toml.Decode,
// except the two hand-built ParseError values.
func TestInt64Only(t *testing.T) {
	decodeErr := func(t *testing.T, src string) error {
		t.Helper()
		var v map[string]any
		_, err := toml.Decode(src, &v)
		if err == nil {
			t.Fatalf("toml.Decode(%q) = nil, want a refusal to test int64Only on", src)
		}
		return err
	}
	cases := []struct {
		name string
		src  string
		err  func(t *testing.T, src string) error
		want bool
	}{
		{"decimal 2^63", "a = 9223372036854775808\n", decodeErr, true},
		{"hex 2^63", "a = 0x8000000000000000\n", decodeErr, true},
		{"two out-of-range tokens", "a = -9223372036854775809\nb = [9223372036854775808]\n", decodeErr, true},
		{"second refusal not an integer", "a = 9223372036854775808\nb = tru\n", decodeErr, false},
		{"float range", "a = 1e999\n", decodeErr, false},
		{"key carries the int64 message", "\"x is out of range for int64\" = tru\n", func(t *testing.T, src string) error {
			t.Helper()
			err := decodeErr(t, src)
			if !strings.Contains(err.Error(), "out of range for int64") {
				t.Fatalf("toml.Decode(%q) error = %q; the decoy needs it to contain %q", src, err.Error(), "out of range for int64")
			}
			return err
		}, false},
		{"message names int64, span is not an integer", "\"9223372036854775808\" = 1\n", func(*testing.T, string) error {
			return toml.ParseError{
				Message:  "9223372036854775808 is out of range for int64",
				Position: toml.Position{Line: 1, Start: 0, Len: 3},
			}
		}, false},
		{"span over int64 max", "a = 9223372036854775807\n", func(*testing.T, string) error {
			return toml.ParseError{
				Message:  "9223372036854775807 is out of range for int64",
				Position: toml.Position{Line: 1, Start: 4, Len: 19},
			}
		}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.err(t, tc.src)
			if got := int64Only([]byte(tc.src), err); got != tc.want {
				t.Fatalf("int64Only(%q, %v) = %v, want %v", tc.src, err, got, tc.want)
			}
		})
	}
}
