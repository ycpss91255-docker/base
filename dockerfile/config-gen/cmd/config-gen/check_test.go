package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// frames splits a diagnostic stream into its frames (ADR-00000039 section
// 3, Diagnostics): each frame is exactly eight NUL-terminated fields, the
// first the tag D. A stream that is not wholly such frames fails the test.
func frames(t *testing.T, stream string) [][]string {
	t.Helper()
	if stream == "" {
		return nil
	}
	if !strings.HasSuffix(stream, "\x00") {
		t.Fatalf("stream %q does not end in a NUL", stream)
	}
	fields := strings.Split(strings.TrimSuffix(stream, "\x00"), "\x00")
	if len(fields)%8 != 0 {
		t.Fatalf("stream %q has %d fields, not whole 8-field frames", stream, len(fields))
	}
	var out [][]string
	for i := 0; i < len(fields); i += 8 {
		f := fields[i : i+8]
		if f[0] != "D" || f[1] != "error" || f[2] == "" || f[7] == "" {
			t.Fatalf("frame %q: want tag D, severity error, an event and a display text", f)
		}
		out = append(out, f)
	}
	return out
}

// writeLayer writes src to a fresh layer file and returns its path.
func writeLayer(t *testing.T, src string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "setup.toml")
	if err := os.WriteFile(path, []byte(src), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// runCheck runs `config-gen check <path>` and returns its status and its
// frames. Every call is held to the fixed points of the refusal-test
// contract (base#1395 plan, "Every refusal test asserts five things"), so
// no refusal test can leave one out: stdout stays empty, stderr is wholly
// frames, and every frame names path as its file. The caller asserts the
// status, the event and the key.
func runCheck(t *testing.T, path string) (int, [][]string) {
	t.Helper()
	var stdout, stderr bytes.Buffer

	status := run([]string{"check", path}, &stdout, &stderr)

	if stdout.Len() != 0 {
		t.Errorf("check %s: stdout = %q, want empty", path, stdout.String())
	}
	fr := frames(t, stderr.String())
	for i, f := range fr {
		if f[3] != path {
			t.Errorf("check %s: frame %d file = %q, want the layer's path", path, i, f[3])
		}
	}
	return status, fr
}

// `config-gen check <layer>` decodes each layer and reports every refusal
// as one diagnostic frame naming the file, the line, the column and the
// key (base#1442 AC "Unknown keys", review round 2 finding 1). A refused
// layer exits 1 (ADR-00000039: configuration refused), with nothing on
// stdout and stderr wholly frames. A layer with no refusal exits 0 with no
// output at all. Lines are counted from the input bytes; the column is the
// key's first byte.
func TestCheckRefusals(t *testing.T) {
	cases := []struct {
		name   string
		src    string
		status int
		want   [][]string // event, line, col, key per frame
	}{
		{"accepted layer", "[deploy]\ngpu_count = 1\n", 0, nil},
		{"unknown key", "[deploy]\ngpu_cuont = 1\n", 1, [][]string{{"conf_unknown_key", "2", "1", "deploy.gpu_cuont"}}},
		{"two refusals, both reported", "[deploy]\ngpu_cuont = 1\n  foo = 2\n", 1,
			[][]string{{"conf_unknown_key", "2", "1", "deploy.gpu_cuont"}, {"conf_unknown_key", "3", "3", "deploy.foo"}}},
		{"unknown table", "[deploy2]\nx = 1\n", 1, [][]string{{"conf_unknown_table", "1", "1", "deploy2"}}},
		{"top-level scalar", "top = \"v\"\n", 1, [][]string{{"conf_top_level_key", "1", "1", "top"}}},
		{"wrong type", "[security]\nprivileged = \"yes\"\n", 1, [][]string{{"conf_value_type_refused", "2", "1", "security.privileged"}}},
		{"invalid UTF-8", "[environment]\nenv_1 = \"\xff\"\n", 1, [][]string{{"conf_toml_parse_failed", "2", "9", "environment.env_1"}}},
		// A leading byte-order mark is refused at line 1 column 1, as the
		// bridge refuses it (review round 4): FF FE and FE FF are not
		// UTF-8, and EF BB BF decodes to U+FEFF, which tomllib refuses
		// as an invalid statement at line 1 column 1. The TOML library
		// strips all three before parsing, so the bytes are judged as read.
		{"UTF-16 LE mark", "\xff\xfe[environment]\nenv_1 = \"A=b\"\n", 1, [][]string{{"conf_toml_parse_failed", "1", "1", "environment"}}},
		{"UTF-16 BE mark", "\xfe\xff[environment]\nenv_1 = \"A=b\"\n", 1, [][]string{{"conf_toml_parse_failed", "1", "1", "environment"}}},
		{"UTF-8 mark", "\xef\xbb\xbf[environment]\nenv_1 = \"A=b\"\n", 1, [][]string{{"conf_toml_parse_failed", "1", "1", "environment"}}},
		// A key holding U+0000 is shown with the six characters \u0000 in
		// its place (ADR-00000039 section 3), so the frame stays 8 fields.
		{"NUL in a key", "[logging.\"a\\u0000b\"]\ndriver = \"local\"\n", 1,
			[][]string{{"conf_value_nul_refused", "1", "1", `logging.a\u0000b`}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			checkFrames(t, tc.src, tc.status, tc.want)
		})
	}
}

// A malformed invocation is a usage error, exit 2 (ADR-00000039: 2 is
// usage), with one config_gen_check_usage frame and nothing on stdout. An
// input that is missing or not a regular file is an I/O error, exit 4,
// with one config_gen_check_input_failed frame naming it. Neither is
// mapped to exit 1, the refused-configuration status.
func TestCheckUsageAndInput(t *testing.T) {
	dir := t.TempDir()
	cases := []struct {
		name   string
		args   []string
		status int
		event  string
	}{
		{"no layer", []string{"check"}, 2, "config_gen_check_usage"},
		{"unknown flag", []string{"check", "--bogus"}, 2, "config_gen_check_usage"},
		{"missing layer", []string{"check", filepath.Join(dir, "absent.toml")}, 4, "config_gen_check_input_failed"},
		{"directory", []string{"check", dir}, 4, "config_gen_check_input_failed"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer

			got := run(tc.args, &stdout, &stderr)

			if got != tc.status {
				t.Fatalf("run(%q) = %d, want %d (stderr %q)", tc.args, got, tc.status, stderr.String())
			}
			if stdout.Len() != 0 {
				t.Errorf("stdout = %q, want empty", stdout.String())
			}
			fr := frames(t, stderr.String())
			// A usage frame names no layer; an input frame names the
			// layer it could not read.
			file := ""
			if tc.status == 4 {
				file = tc.args[len(tc.args)-1]
			}
			if len(fr) != 1 || fr[0][2] != tc.event || fr[0][3] != file {
				t.Errorf("frames = %q, want one %s naming file %q", fr, tc.event, file)
			}
		})
	}
}

// failingWriter fails its nth Write and every one after it.
type failingWriter struct {
	n, calls int
	buf      bytes.Buffer
}

func (w *failingWriter) Write(p []byte) (int, error) {
	w.calls++
	if w.calls >= w.n {
		return 0, errors.New("write failed")
	}
	return w.buf.Write(p)
}

// A diagnostic that cannot be written is an I/O error, exit 4
// (ADR-00000039: a failed write is never 0), whether the first frame's
// write fails or a later one's, and no write is tried after the first
// that failed.
func TestCheckFailedFrameWriteIsIO(t *testing.T) {
	path := writeLayer(t, "[deploy]\ngpu_cuont = 1\nfoo = 2\n")
	for _, n := range []int{1, 2} {
		w := &failingWriter{n: n}
		var stdout bytes.Buffer

		got := run([]string{"check", path}, &stdout, w)

		if got != 4 {
			t.Errorf("write %d failing: check = %d, want 4", n, got)
		}
		if w.calls != n {
			t.Errorf("write %d failing: %d writes tried, want %d", n, w.calls, n)
		}
	}
}

// A FIFO in a layer's place is refused as not a regular file, exit 4,
// without blocking on it (base#1400).
func TestCheckFIFOIsInputFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fifo.toml")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer

	got := run([]string{"check", "--", path}, &stdout, &stderr)

	fr := frames(t, stderr.String())
	if got != 4 || len(fr) != 1 || fr[0][2] != "config_gen_check_input_failed" || fr[0][3] != path {
		t.Errorf("check FIFO = %d, frames %q; want 4 and one config_gen_check_input_failed naming it", got, fr)
	}
}

// A reported error reads and unwraps as the error it wraps.
func TestReportedErrorWraps(t *testing.T) {
	cause := errors.New("cause")
	err := reported(exitUsage, cause)
	if err.Error() != "cause" || !errors.Is(err, cause) {
		t.Errorf("reported(2, cause) = %q, errors.Is = %v; want the cause's text and chain", err, errors.Is(err, cause))
	}
}
