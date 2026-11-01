package main

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// trapped is the status the last osExit call asked for, or -1 when none
// was made since cli reset it.
var trapped = -1

// TestMain swaps osExit for a recorder before any test runs, so a command
// that exits can never end the test process: its status is read back by
// cli instead (base#1469).
func TestMain(m *testing.M) {
	osExit = func(code int) { trapped = code }
	os.Exit(m.Run())
}

// cli runs config-gen in-process with args and returns its exit status,
// stdout and stderr. A status a command handed to osExit takes the place
// of run's own, as the real process would end with it.
func cli(t *testing.T, args ...string) (int, []byte, []byte) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	trapped = -1
	rc := run(args, &stdout, &stderr)
	if trapped != -1 {
		rc = trapped
	}
	return rc, stdout.Bytes(), stderr.Bytes()
}

// `config-gen tables --name <label> <path>` exits 0 and prints exactly the
// bytes the bridge's `toml_bridge.py --tables` prints for the same file,
// with nothing on stderr (base#1469). The want bytes are those bridge
// outputs, captured into golden/s1, one per corpus/s1 fixture.
func TestTablesPrintsTheBridgeGolden(t *testing.T) {
	for _, src := range testcorpus.Glob(t, "corpus/s1/*.toml") {
		name := strings.TrimSuffix(filepath.Base(src), ".toml")
		t.Run(name, func(t *testing.T) {
			goldens := testcorpus.Glob(t, "golden/s1/"+name+".golden")
			want, err := os.ReadFile(goldens[0])
			if err != nil {
				t.Fatalf("read %s: %v", goldens[0], err)
			}

			rc, stdout, stderr := cli(t, "tables", "--name", name+".toml", src)
			if rc != 0 {
				t.Fatalf("config-gen tables exited %d, want 0 (stderr %q)", rc, stderr)
			}
			if !bytes.Equal(stdout, want) {
				t.Fatalf("config-gen tables stdout = %q, want the bridge golden %q", stdout, want)
			}
			if len(stderr) != 0 {
				t.Fatalf("config-gen tables stderr = %q, want empty", stderr)
			}
		})
	}
}

// frames parses stderr as NUL-framed diagnostics and fails the test unless
// all of it is frames: eight NUL-terminated fields each, the first being
// the tag `D` and the second a non-empty severity (ADR-00000039 §3,
// base#1469). It returns each frame's fields.
func frames(t *testing.T, stderr []byte) [][]string {
	t.Helper()
	if len(stderr) == 0 {
		return nil
	}
	if stderr[len(stderr)-1] != 0 {
		t.Fatalf("stderr %q does not end in NUL, so it is not all frames", stderr)
	}
	fields := strings.Split(string(stderr[:len(stderr)-1]), "\x00")
	if len(fields)%8 != 0 {
		t.Fatalf("stderr %q has %d NUL-terminated fields, not a multiple of 8", stderr, len(fields))
	}
	var out [][]string
	for i := 0; i < len(fields); i += 8 {
		f := fields[i : i+8]
		if f[0] != "D" {
			t.Fatalf("frame %d of stderr %q starts with %q, want the tag D", i/8, stderr, f[0])
		}
		if f[1] == "" {
			t.Fatalf("frame %d of stderr %q has an empty severity", i/8, stderr)
		}
		out = append(out, f)
	}
	return out
}

// `config-gen tables` called with the wrong argv -- no arguments, a path
// with no `--name`, or an extra argument after the path -- exits 2, prints
// nothing on stdout, and its stderr is exactly one frame whose event is
// `config_gen_usage_invalid` (base#1469 I/O contract; exit 2 is wrong argv
// per the issue, the event id is the one log-events.txt registers).
func TestTablesWrongArgvIsOneUsageFrame(t *testing.T) {
	src := testcorpus.Glob(t, "corpus/s1/*.toml")[0]
	for _, tc := range []struct {
		name string
		args []string
	}{
		{"none", []string{"tables"}},
		{"positional_only", []string{"tables", src}},
		{"extra", []string{"tables", "--name", "l.toml", src, "extra"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rc, stdout, stderr := cli(t, tc.args...)
			if rc != 2 {
				t.Fatalf("config-gen %q exited %d, want 2 (stderr %q)", tc.args, rc, stderr)
			}
			if len(stdout) != 0 {
				t.Fatalf("config-gen %q stdout = %q, want empty", tc.args, stdout)
			}
			got := frames(t, stderr)
			if len(got) != 1 {
				t.Fatalf("config-gen %q wrote %d frames, want 1 (stderr %q)", tc.args, len(got), stderr)
			}
			if got[0][2] != "config_gen_usage_invalid" {
				t.Fatalf("config-gen %q frame event = %q, want config_gen_usage_invalid", tc.args, got[0][2])
			}
		})
	}
}

// A file the TOML spec refuses -- a syntax error, a table header declared
// twice, or bytes that are not UTF-8 -- makes `config-gen tables` exit 1
// with nothing on stdout and exactly one `conf_toml_parse_failed` frame.
// That frame's `file` field is the `--name` label verbatim, never the
// opened path, and its `line` and `col` fields are decimal numbers
// (base#1469 Input; the event id is the one log-events.txt registers).
// The inputs are invalid by the TOML 1.0 spec: `k = = 1` has no value,
// `[a]` twice defines one table twice, and 0xFF 0xFE is not UTF-8.
func TestTablesParseErrorIsOneFrameNamingTheLabel(t *testing.T) {
	const label = "lab\tel\n\"q\"\\é.toml"
	for _, tc := range []struct {
		name string
		src  string
	}{
		{"syntax", "[a]\nk = = 1\n"},
		{"duplicate_table", "[a]\nk = 1\n[a]\nj = 2\n"},
		{"invalid_utf8", "[a]\nk = \"\xff\xfe\"\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "f.toml")
			if err := os.WriteFile(path, []byte(tc.src), 0o600); err != nil {
				t.Fatalf("write %s: %v", path, err)
			}
			rc, stdout, stderr := cli(t, "tables", "--name", label, path)
			if rc != 1 {
				t.Fatalf("config-gen tables exited %d, want 1 (stderr %q)", rc, stderr)
			}
			if len(stdout) != 0 {
				t.Fatalf("config-gen tables stdout = %q, want empty", stdout)
			}
			got := frames(t, stderr)
			if len(got) != 1 {
				t.Fatalf("config-gen tables wrote %d frames, want 1 (stderr %q)", len(got), stderr)
			}
			f := got[0]
			if f[2] != "conf_toml_parse_failed" {
				t.Fatalf("frame event = %q, want conf_toml_parse_failed", f[2])
			}
			if f[3] != label {
				t.Fatalf("frame file = %q, want the --name label %q verbatim", f[3], label)
			}
			decimal := regexp.MustCompile(`^[0-9]+$`)
			if !decimal.MatchString(f[4]) {
				t.Fatalf("frame line = %q, want a decimal number", f[4])
			}
			if !decimal.MatchString(f[5]) {
				t.Fatalf("frame col = %q, want a decimal number", f[5])
			}
		})
	}
}
