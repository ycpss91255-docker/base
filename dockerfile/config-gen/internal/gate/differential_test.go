package gate

import (
	"io/fs"
	"os"
	"path/filepath"
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
