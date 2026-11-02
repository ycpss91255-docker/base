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
