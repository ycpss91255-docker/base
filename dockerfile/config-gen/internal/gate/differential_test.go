package gate

import (
	"path/filepath"
	"strings"
	"testing"
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
