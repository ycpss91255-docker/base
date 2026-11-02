package main

import (
	"bytes"
	"errors"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/BurntSushi/toml"

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

// countingWriter is a bytes.Buffer that counts the Write calls made on it.
type countingWriter struct {
	bytes.Buffer
	calls int
}

func (w *countingWriter) Write(p []byte) (int, error) {
	w.calls++
	return w.Buffer.Write(p)
}

// `config-gen tables --name <label> <path>` exits 0 and prints exactly the
// bytes the bridge's `toml_bridge.py --tables` prints for the same file,
// in one stdout Write call, with nothing on stderr (base#1469 Partial
// write: the answer is built in memory and written once). The want bytes
// are the goldens captured into golden/s1, one per corpus/s1 fixture.
func TestTablesPrintsTheBridgeGolden(t *testing.T) {
	for _, src := range testcorpus.Glob(t, "corpus/s1/*.toml") {
		name := strings.TrimSuffix(filepath.Base(src), ".toml")
		t.Run(name, func(t *testing.T) {
			goldens := testcorpus.Glob(t, "golden/s1/"+name+".golden")
			want, err := os.ReadFile(goldens[0])
			if err != nil {
				t.Fatalf("read %s: %v", goldens[0], err)
			}

			var out countingWriter
			var errb bytes.Buffer
			trapped = -1
			rc := run([]string{"tables", "--name", name + ".toml", src}, &out, &errb)
			if trapped != -1 {
				rc = trapped
			}
			stdout, stderr := out.Bytes(), errb.Bytes()
			if rc != 0 {
				t.Fatalf("config-gen tables exited %d, want 0 (stderr %q)", rc, stderr)
			}
			if !bytes.Equal(stdout, want) {
				t.Fatalf("config-gen tables stdout = %q, want the bridge golden %q", stdout, want)
			}
			if len(stderr) != 0 {
				t.Fatalf("config-gen tables stderr = %q, want empty", stderr)
			}
			if out.calls != 1 {
				t.Fatalf("config-gen tables made %d stdout Write calls, want exactly 1: the answer is built in memory and written once", out.calls)
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

// refusal parses stderr fully as frames and fails the test unless it is
// exactly one error-severity frame with the given event id, whose `file`
// field is file byte for byte and whose `key` field is empty: every
// refusal of `config-gen tables` is about the whole input, so it names the
// `--name` label and no key (base#1469 five-point refusal test: file and
// key attribution). It returns that frame's eight fields.
func refusal(t *testing.T, stderr []byte, event, file string) []string {
	t.Helper()
	got := frames(t, stderr)
	if len(got) != 1 {
		t.Fatalf("stderr holds %d frames, want exactly 1 (stderr %q)", len(got), stderr)
	}
	f := got[0]
	if f[1] != "error" {
		t.Fatalf("frame severity = %q, want error (stderr %q)", f[1], stderr)
	}
	if f[2] != event {
		t.Fatalf("frame event = %q, want %s (stderr %q)", f[2], event, stderr)
	}
	if f[3] != file {
		t.Fatalf("frame file = %q, want %q byte for byte (stderr %q)", f[3], file, stderr)
	}
	if f[6] != "" {
		t.Fatalf("frame key = %q, want empty: the refusal is about the whole input (stderr %q)", f[6], stderr)
	}
	return f
}

// `config-gen tables` called with the wrong argv -- no arguments, a path
// with no `--name`, an extra argument after the path, or three arguments
// whose first is not `--name` -- exits 2, prints nothing on stdout, and
// its stderr is exactly one frame whose event is `config_gen_usage_invalid`
// (base#1469 I/O contract; exit 2 is wrong argv per the issue, the event
// id is the one log-events.txt registers). The three-argument rows have
// the right count, so only the flag check can refuse them.
func TestTablesWrongArgvIsOneUsageFrame(t *testing.T) {
	src := testcorpus.Glob(t, "corpus/s1/*.toml")[0]
	for _, tc := range []struct {
		name string
		args []string
	}{
		{"none", []string{"tables"}},
		{"positional_only", []string{"tables", src}},
		{"extra", []string{"tables", "--name", "l.toml", src, "extra"}},
		{"misspelled_flag", []string{"tables", "--nam", "l.toml", src}},
		{"flag_after_label", []string{"tables", "l.toml", "--name", src}},
		{"path_first", []string{"tables", src, "--name", "l.toml"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rc, stdout, stderr := cli(t, tc.args...)
			if rc != 2 {
				t.Fatalf("config-gen %q exited %d, want 2 (stderr %q)", tc.args, rc, stderr)
			}
			if len(stdout) != 0 {
				t.Fatalf("config-gen %q stdout = %q, want empty", tc.args, stdout)
			}
			// No label was given validly, so the frame names no file.
			refusal(t, stderr, "config_gen_usage_invalid", "")
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
//
// The label and the library's message are both carried verbatim
// (base#1469 Diagnostics): the label holds a tab, CR, LF, `"`, `\` and
// é, and the frame's text, line and col must equal what BurntSushi/toml
// itself reports for the same bytes -- the message its Decode returns and
// the position of its ParseError -- so a command that escapes, trims or
// rewrites either one before it reaches the encoder fails here, not only
// in the encoder's own test.
func TestTablesParseErrorIsOneFrameNamingTheLabel(t *testing.T) {
	const label = "lab\tel\r\n\"q\"\\é.toml"
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
			f := refusal(t, stderr, "conf_toml_parse_failed", label)

			// The oracle: the library's own verdict on the same bytes.
			var doc map[string]any
			_, perr := toml.Decode(tc.src, &doc)
			var pe toml.ParseError
			if !errors.As(perr, &pe) {
				t.Fatalf("toml.Decode(%q) err = %v, want a toml.ParseError", tc.src, perr)
			}
			if f[7] != perr.Error() {
				t.Fatalf("frame text = %q, want the library message %q verbatim", f[7], perr.Error())
			}
			if want := strconv.Itoa(pe.Position.Line); f[4] != want {
				t.Fatalf("frame line = %q, want the library's line %s", f[4], want)
			}
			if want := strconv.Itoa(pe.Position.Col); f[5] != want {
				t.Fatalf("frame col = %q, want the library's col %s", f[5], want)
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

// An input that is not a regular file -- a directory, a FIFO with no
// writer, the character device /dev/null, or a listening unix socket --
// makes `config-gen tables` exit 1 with nothing on stdout and exactly one
// `config_gen_input_not_regular` frame, and it does so promptly: a FIFO
// must not hold the command in open(2) waiting for a writer (base#1469
// Input: open O_NONBLOCK, then fstat; not a regular file ->
// config_gen_input_not_regular). Each row runs under a deadline so a
// blocking open fails the test instead of hanging it.
func TestTablesNonRegularInputIsOneNotRegularFrame(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "fifo.toml")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatalf("mkfifo %s: %v", fifo, err)
	}
	// A short directory keeps the socket path under sun_path's 108 bytes.
	sockDir, err := os.MkdirTemp("", "s")
	if err != nil {
		t.Fatalf("mkdtemp: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(sockDir) })
	sock := filepath.Join(sockDir, "s.toml")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen unix %s: %v", sock, err)
	}
	t.Cleanup(func() { _ = ln.Close() })

	for _, tc := range []struct {
		name string
		path string
	}{
		{"directory", dir},
		{"fifo", fifo},
		{"dev_null", "/dev/null"},
		{"unix_socket", sock},
	} {
		t.Run(tc.name, func(t *testing.T) {
			type result struct {
				rc             int
				stdout, stderr []byte
			}
			done := make(chan result, 1)
			go func() {
				rc, stdout, stderr := cli(t, "tables", "--name", "l.toml", tc.path)
				done <- result{rc, stdout, stderr}
			}()
			var r result
			select {
			case r = <-done:
			case <-time.After(10 * time.Second):
				t.Fatalf("config-gen tables on %s did not return within 10s", tc.path)
			}
			if r.rc != 1 {
				t.Fatalf("config-gen tables on %s exited %d, want 1 (stderr %q)", tc.path, r.rc, r.stderr)
			}
			if len(r.stdout) != 0 {
				t.Fatalf("config-gen tables on %s stdout = %q, want empty", tc.path, r.stdout)
			}
			refusal(t, r.stderr, "config_gen_input_not_regular", "l.toml")
		})
	}
}

// A path that names no file -- nothing at that name (ENOENT), or a name
// under a regular file used as a directory (ENOTDIR) -- makes `config-gen
// tables` exit 1 with nothing on stdout and exactly one `no_such_file`
// frame whose `file` field is the `--name` label, never the opened path
// (base#1469 Input: a missing file gives no_such_file; the event id is the
// one log-events.txt registers).
func TestTablesMissingInputIsOneNoSuchFileFrame(t *testing.T) {
	const label = "l.toml"
	dir := t.TempDir()
	reg := filepath.Join(dir, "reg")
	if err := os.WriteFile(reg, []byte("[a]\n"), 0o600); err != nil {
		t.Fatalf("write %s: %v", reg, err)
	}
	for _, tc := range []struct {
		name string
		path string
	}{
		{"enoent", filepath.Join(dir, "absent.toml")},
		{"enotdir", filepath.Join(reg, "x")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rc, stdout, stderr := cli(t, "tables", "--name", label, tc.path)
			if rc != 1 {
				t.Fatalf("config-gen tables on %s exited %d, want 1 (stderr %q)", tc.path, rc, stderr)
			}
			if len(stdout) != 0 {
				t.Fatalf("config-gen tables on %s stdout = %q, want empty", tc.path, stdout)
			}
			refusal(t, stderr, "no_such_file", label)
		})
	}
}

// faultWriter takes at most limit bytes in total and then refuses. The
// write that reaches the limit, and every write after it, returns the
// bytes it took and a non-nil error -- or, with shortNil, a short count
// with a nil error, which the io.Writer contract forbids but a caller
// must still not take as success.
type faultWriter struct {
	limit    int
	shortNil bool
	got      []byte
	calls    int
}

var errFault = errors.New("injected write fault")

func (w *faultWriter) Write(p []byte) (int, error) {
	w.calls++
	room := w.limit - len(w.got)
	if room >= len(p) {
		w.got = append(w.got, p...)
		return len(p), nil
	}
	if room < 0 {
		room = 0
	}
	w.got = append(w.got, p[:room]...)
	if w.shortNil {
		return room, nil
	}
	return room, errFault
}

// When the answer cannot be written in full -- the sink takes no bytes,
// or takes some and then refuses, or reports a short count -- `config-gen
// tables` exits 4 and its stderr is exactly one `config_gen_output_failed`
// frame; the bytes the sink did take are a strict prefix of the bridge
// golden, and the command made exactly one Write call, so it neither
// streamed the answer in chunks nor retried the rest after a short write
// (base#1469 I/O contract: exit 4 on any write error or short write, one
// frame, never one per chunk). The fixture's bridge golden is over 64
// KiB, so half of it is more than one pipe buffer.
func TestTablesWriteFailureIsExit4AndOneFrame(t *testing.T) {
	src := testcorpus.Glob(t, "corpus/s1/large_tables.toml")[0]
	golden := testcorpus.Glob(t, "golden/s1/large_tables.golden")[0]
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read %s: %v", golden, err)
	}
	if len(want) < 64*1024 {
		t.Fatalf("golden %s is %d bytes, want at least 64 KiB", golden, len(want))
	}
	for _, tc := range []struct {
		name string
		w    *faultWriter
	}{
		{"zero_bytes", &faultWriter{limit: 0}},
		{"half", &faultWriter{limit: len(want) / 2}},
		{"half_short_count_nil_error", &faultWriter{limit: len(want) / 2, shortNil: true}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var stderr bytes.Buffer
			trapped = -1
			rc := run([]string{"tables", "--name", "large_tables.toml", src}, tc.w, &stderr)
			if trapped != -1 {
				rc = trapped
			}
			if rc != 4 {
				t.Fatalf("config-gen tables exited %d, want 4 (stderr %q)", rc, stderr.Bytes())
			}
			refusal(t, stderr.Bytes(), "config_gen_output_failed", "large_tables.toml")
			if len(tc.w.got) >= len(want) || !bytes.HasPrefix(want, tc.w.got) {
				t.Fatalf("sink took %d bytes, want a strict prefix of the %d-byte golden", len(tc.w.got), len(want))
			}
			if tc.w.calls != 1 {
				t.Fatalf("config-gen tables made %d Write calls on stdout, want exactly 1", tc.w.calls)
			}
		})
	}
}

// An input the caller may not read -- a regular file with mode 000, opened
// by uid 65534 -- makes `config-gen tables` exit 1 with nothing on stdout
// and exactly one `config_gen_input_unreadable` frame whose `file` field
// is the `--name` label (base#1469 Input: EACCES/EPERM on open ->
// config_gen_input_unreadable). Root reads a mode-000 file through
// CAP_DAC_OVERRIDE, so when the test runs as root it sets this thread's
// filesystem uid to 65534 for the call, which drops that capability from
// the thread's effective set until the fsuid is set back to 0.
func TestTablesUnreadableInputIsOneUnreadableFrame(t *testing.T) {
	const label = "l.toml"
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatalf("chmod %s: %v", dir, err)
	}
	path := filepath.Join(dir, "locked.toml")
	if err := os.WriteFile(path, []byte("[a]\n"), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatalf("chmod %s: %v", path, err)
	}

	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if os.Geteuid() == 0 {
		_, _, _ = syscall.RawSyscall(syscall.SYS_SETFSUID, 65534, 0, 0)
		defer func() { _, _, _ = syscall.RawSyscall(syscall.SYS_SETFSUID, 0, 0, 0) }()
	}
	// The precondition: this thread can not open the file. Without it a
	// pass would not show the refusal path ran.
	if f, err := os.Open(path); !errors.Is(err, syscall.EACCES) {
		if f != nil {
			_ = f.Close()
		}
		t.Fatalf("open %s as uid %d: err = %v, want EACCES", path, os.Geteuid(), err)
	}

	rc, stdout, stderr := cli(t, "tables", "--name", label, path)
	if rc != 1 {
		t.Fatalf("config-gen tables on %s exited %d, want 1 (stderr %q)", path, rc, stderr)
	}
	if len(stdout) != 0 {
		t.Fatalf("config-gen tables on %s stdout = %q, want empty", path, stdout)
	}
	refusal(t, stderr, "config_gen_input_unreadable", label)
}

// A descriptor that opens but that fstat(2) then fails on -- here an
// injected EIO, since no regular file on a healthy filesystem makes it
// fail -- makes `config-gen tables` exit 1 with nothing on stdout and
// exactly one `config_gen_input_unreadable` frame naming the label
// (base#1469 Input: any open, stat or read error other than a missing
// name is config_gen_input_unreadable). It also keeps cmd/config-gen at
// the 100.0 floor base#1465's coverage-floors.d/s1e.txt gives it: without
// this test the fstat error return is the one statement no test reaches.
func TestTablesFstatFailureIsOneUnreadableFrame(t *testing.T) {
	src := testcorpus.Glob(t, "corpus/s1/*.toml")[0]
	saved := fstat
	fstat = func(int, *syscall.Stat_t) error { return syscall.EIO }
	t.Cleanup(func() { fstat = saved })

	rc, stdout, stderr := cli(t, "tables", "--name", "l.toml", src)
	if rc != 1 {
		t.Fatalf("config-gen tables exited %d, want 1 (stderr %q)", rc, stderr)
	}
	if len(stdout) != 0 {
		t.Fatalf("config-gen tables stdout = %q, want empty", stdout)
	}
	refusal(t, stderr, "config_gen_input_unreadable", "l.toml")
}
