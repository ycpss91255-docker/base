package gate

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
)

// noOracleMsg is the refusal design-ahead r3 cycle 12 fixes for a run
// without the live tomllib verdicts (base#1441): the differential must
// fail closed, never pass by comparing against nothing.
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
// testdata (design-ahead r3 cycle 12, base#1441): a file with no row was
// never asked of tomllib, and a row with no file is a verdict for
// something the differential cannot read. Each direction fails naming
// the path; the same set in another order passes. Rows are the step's
// `<rel>\t<verdict>` lines, rel taken from dockerfile/config-gen.
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

// The live rows, from the verdicts file `just test go` hands the build
// through CONFIG_GEN_TOML_ORACLE, must equal the WalkDir set of
// testdata/**/*.toml, keyed the way the step keys them
// (internal/gate/<path>).
func TestOracleRows(t *testing.T) {
	rows, err := loadOracleVerdicts(os.Getenv("CONFIG_GEN_TOML_ORACLE"))
	if err != nil {
		t.Fatal(err)
	}
	var files []string
	walkErr := filepath.WalkDir("testdata", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && strings.HasSuffix(p, ".toml") {
			files = append(files, "internal/gate/"+filepath.ToSlash(p))
		}
		return nil
	})
	if walkErr != nil {
		t.Fatal(walkErr)
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
}

// The gate plus BurntSushi must give tomllib's verdict on every TOML file
// the live oracle answered (design-ahead r3 cycle 13, seam 2, base#1441):
// accept when Check returns nil and toml.Decode then succeeds, refuse
// otherwise. Each disagreeing file fails by name with both verdicts.
func TestDifferential(t *testing.T) {
	rows, err := loadOracleVerdicts(os.Getenv("CONFIG_GEN_TOML_ORACLE"))
	if err != nil {
		t.Fatal(err)
	}
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
		src, err := os.ReadFile(strings.TrimPrefix(rel, "internal/gate/"))
		if err != nil {
			t.Fatal(err)
		}
		got := "refuse"
		if Check(rel, src) == nil {
			var v map[string]any
			if _, err := toml.Decode(string(src), &v); err == nil {
				got = "accept"
			}
		}
		if got != live {
			t.Errorf("%s: gate+BurntSushi %s, tomllib %s", rel, got, live)
		}
	}
	if seen != len(designVerdicts) {
		t.Errorf("oracle rows named %d of the %d design-measured forms", seen, len(designVerdicts))
	}
}

// int64Only is the differential's one tolerated disagreement (base#1441
// design run1 r2 F1, ADR-39): BurntSushi refuses an integer outside int64
// that tomllib accepts. It must decide from structure and arithmetic only:
// the refusal's byte span is an integer literal outside int64, and once
// every such literal is replaced the decode succeeds. The true rows are
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
