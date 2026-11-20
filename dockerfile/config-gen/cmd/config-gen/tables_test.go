package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
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

// argvEnv names the variable that turns a re-exec of this test binary into
// a run of config-gen itself: its value is a JSON array of the arguments
// after the program name (base#1469).
const argvEnv = "CONFIG_GEN_TEST_ARGV"

// TestMain swaps osExit for a recorder before any test runs, so a command
// that exits can never end the test process: its status is read back by
// cli instead (base#1469). When argvEnv is set the binary is a child a
// test started: it runs main with that argv and the real os.Exit, so the
// child is the production process -- same main, same signal handling.
func TestMain(m *testing.M) {
	if argv, ok := os.LookupEnv(argvEnv); ok {
		var args []string
		if err := json.Unmarshal([]byte(argv), &args); err != nil {
			os.Exit(99)
		}
		os.Args = append([]string{os.Args[0]}, args...)
		main()
		os.Exit(98)
	}
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
// are the goldens captured into golden/s1, one per corpus/s1 fixture
// whose golden/s1/EXPECT class is `parity`; a fixture of any other class
// has no golden to print, and one with no row fails (base#1936).
func TestTablesPrintsTheBridgeGolden(t *testing.T) {
	expect, rows := expectRows(t)
	class := map[string]string{}
	for _, row := range rows {
		class[row.name] = row.class
	}
	for _, src := range testcorpus.Glob(t, "corpus/s1/*.toml") {
		name := strings.TrimSuffix(filepath.Base(src), ".toml")
		c, ok := class[name]
		if !ok {
			t.Fatalf("corpus/s1/%s.toml has no row in %s", name, expect)
		}
		if c != "parity" {
			continue
		}
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

// Every corpus/s1 fixture whose golden/s1/EXPECT class is `parity-refused`
// -- the rows where toml_bridge.py --tables exits 1, which the golden spec
// re-checks -- is refused by `config-gen tables` too: exit 1, nothing on
// stdout, one `config_gen_toml_gate_refused` frame naming the `--name`
// label, at the 1-based line and byte column of the fixture's first TOML
// 1.1-only byte (base#1936). Positions are counted by hand on the
// fixture: `color = "\e` -> `\` is byte 10 of line 3; `A = "\x41"` -> 6
// of line 3; `opts = {` -> the LF is byte 9 of line 4; `deps = { db = {
// host = "x", ...` -> the first comma before `}` is byte 27 of line 4;
// `at = 07:32` -> `0` is byte 6 of line 4. A parity-refused row with no
// position here fails, so a new row can not pass unchecked.
func TestTablesParityRefusedFixtureIsOneGateFrame(t *testing.T) {
	want := map[string][2]string{
		"toml11_escape_e":              {"3", "10"},
		"toml11_escape_x":              {"3", "6"},
		"toml11_inline_newline":        {"4", "9"},
		"toml11_inline_trailing_comma": {"4", "27"},
		"toml11_time_no_seconds":       {"4", "6"},
	}
	expect, rows := expectRows(t)
	seen := 0
	for _, row := range rows {
		name := row.name
		if row.class != "parity-refused" {
			continue
		}
		seen++
		t.Run(name, func(t *testing.T) {
			pos, ok := want[name]
			if !ok {
				t.Fatalf("parity-refused row %s has no hand-counted position in this test", name)
			}
			src := testcorpus.Glob(t, "corpus/s1/"+name+".toml")[0]
			label := name + ".toml"
			rc, stdout, stderr := cli(t, "tables", "--name", label, src)
			if rc != 1 {
				t.Fatalf("config-gen tables exited %d, want 1 (stdout %q, stderr %q)", rc, stdout, stderr)
			}
			if len(stdout) != 0 {
				t.Fatalf("config-gen tables stdout = %q, want empty", stdout)
			}
			f := refusal(t, stderr, "config_gen_toml_gate_refused", label)
			if f[4] != pos[0] || f[5] != pos[1] {
				t.Fatalf("frame line, col = %q, %q, want %s, %s", f[4], f[5], pos[0], pos[1])
			}
		})
	}
	if seen != len(want) {
		t.Fatalf("%s holds %d parity-refused rows, want %d", expect, seen, len(want))
	}
}

// expectRow is one golden/s1/EXPECT line: a corpus/s1 stem and its class.
type expectRow struct{ name, class string }

// expectRows returns the path of golden/s1/EXPECT and its rows in file
// order, each split at its first tab (base#1936).
func expectRows(t *testing.T) (string, []expectRow) {
	t.Helper()
	expect := testcorpus.Glob(t, "golden/s1/EXPECT")[0]
	body, err := os.ReadFile(expect)
	if err != nil {
		t.Fatalf("read %s: %v", expect, err)
	}
	var rows []expectRow
	for _, line := range strings.Split(strings.TrimSuffix(string(body), "\n"), "\n") {
		name, class, _ := strings.Cut(line, "\t")
		rows = append(rows, expectRow{name, class})
	}
	return expect, rows
}

// refusal parses stderr fully as frames (the package helper in
// check_test.go) and fails the test unless it is
// exactly one error-severity frame with the given event id, whose `file`
// field is file byte for byte and whose `key` field is empty: every
// refusal of `config-gen tables` is about the whole input, so it names the
// `--name` label and no key (base#1469 five-point refusal test: file and
// key attribution). It returns that frame's eight fields.
func refusal(t *testing.T, stderr []byte, event, file string) []string {
	t.Helper()
	got := frames(t, string(stderr))
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

// A key-value named "" below the root, which tables.Emit refuses with an
// *EmptyNameError, makes `config-gen tables` exit 1 with nothing on stdout
// and exactly one `conf_toml_parse_failed` frame: `file` is the label,
// `text` is the error's message verbatim, and `line` and `col` are 0,
// since the refusal is not a parser ParseError and carries no position
// (base#1469). `[a]` `"" = []` `[a.b]` is valid TOML the bridge prints as
// a, a.b; whether to accept it is base#1565.
func TestTablesEmptyNameValueIsOneParseFailedFrameAtLineZero(t *testing.T) {
	const label = "lab.toml"
	path := filepath.Join(t.TempDir(), "f.toml")
	if err := os.WriteFile(path, []byte("[a]\n\"\" = []\n[a.b]\n"), 0o600); err != nil {
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
	const text = `key a."": a key-value named "" below the root is not supported (base#1565)`
	if f[7] != text {
		t.Fatalf("frame text = %q, want %q", f[7], text)
	}
	if f[4] != "0" || f[5] != "0" {
		t.Fatalf("frame line, col = %q, %q, want 0, 0", f[4], f[5])
	}
}

// A TOML 1.1-only form the bridge refuses -- here the `\e` escape in a
// basic string -- makes `config-gen tables` exit 1 with nothing on stdout
// and exactly one `config_gen_toml_gate_refused` frame, raised by
// internal/gate before decode (base#1936): `file` is the `--name` label
// verbatim, `key` is empty, and `line` and `col` are the 1-based line and
// byte column of the backslash. The position is counted by hand: line 2
// is `msg = "a\e[0m"`, and `m s g ' ' = ' ' " a` are 8 bytes, so `\` is
// byte 9. The text is the gate's own sentence for the form, not
// Refusal.Error(), which would repeat the label.
func TestTablesTOML11FormIsOneGateFrame(t *testing.T) {
	const label = "lab\tel\r\n\"q\"\\é.toml"
	path := filepath.Join(t.TempDir(), "f.toml")
	if err := os.WriteFile(path, []byte("[log]\nmsg = \"a\\e[0m\"\n"), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	rc, stdout, stderr := cli(t, "tables", "--name", label, path)
	if rc != 1 {
		t.Fatalf("config-gen tables exited %d, want 1 (stdout %q, stderr %q)", rc, stdout, stderr)
	}
	if len(stdout) != 0 {
		t.Fatalf("config-gen tables stdout = %q, want empty", stdout)
	}
	f := refusal(t, stderr, "config_gen_toml_gate_refused", label)
	if f[4] != "2" || f[5] != "9" {
		t.Fatalf("frame line, col = %q, %q, want 2, 9", f[4], f[5])
	}
	const text = `escape sequence \e is not TOML 1.0`
	if f[7] != text {
		t.Fatalf("frame text = %q, want %q", f[7], text)
	}
}

// The gate runs before decode, so a file that holds both a TOML 1.1-only
// form and a TOML syntax error is reported as the gate refusal, even when
// the syntax error comes first: line 2, `k = = 1`, is one the decoder
// refuses (conf_toml_parse_failed, as in
// TestTablesParseErrorIsOneFrameNamingTheLabel), and line 3,
// `msg = "\e"`, holds the `\e` escape at byte 8 (`m s g ' ' = ' ' "` is
// 7 bytes). The answer is exit 1, nothing on stdout, and one
// `config_gen_toml_gate_refused` frame at 3:8 (base#1936). A command that
// decoded first and gated only a file the decoder accepted would report
// the parse error and fail it.
func TestTablesGateRefusalPrecedesAParseError(t *testing.T) {
	const label = "both.toml"
	path := filepath.Join(t.TempDir(), "f.toml")
	if err := os.WriteFile(path, []byte("[a]\nk = = 1\nmsg = \"\\e\"\n"), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	rc, stdout, stderr := cli(t, "tables", "--name", label, path)
	if rc != 1 {
		t.Fatalf("config-gen tables exited %d, want 1 (stdout %q, stderr %q)", rc, stdout, stderr)
	}
	if len(stdout) != 0 {
		t.Fatalf("config-gen tables stdout = %q, want empty", stdout)
	}
	f := refusal(t, stderr, "config_gen_toml_gate_refused", label)
	if f[4] != "3" || f[5] != "8" {
		t.Fatalf("frame line, col = %q, %q, want 3, 8", f[4], f[5])
	}
}

// Each of the other five TOML 1.1-only forms internal/gate owns (base#1850)
// is refused the same way as the `\e` escape: exit 1, nothing on stdout,
// one `config_gen_toml_gate_refused` frame naming the `--name` label, the
// 1-based line and byte column of the offending byte, and the gate's own
// sentence for the form (base#1936). Positions are counted by hand:
// `v = "\x41"` -> `v ' ' = ' ' "` is 5 bytes, `\` is byte 6;
// `opts = {` -> 8 bytes, the LF is byte 9; `deps = {db = 1,}` -> the
// comma is byte 15; `at = 07:30` -> `a t ' ' = ' '` is 5 bytes, `0` is
// byte 6; the BOM is the file's first byte. The column is a byte count,
// not a character count: in the two `_after_multibyte` rows a two-byte é
// sits before the offending byte on the same line, so `msg = "é\e"`
// puts `\` at byte 10 (character 9) and `deps = {"é" = 1,}` puts the
// comma at byte 17 (character 16).
func TestTablesEveryTOML11FormIsOneGateFrame(t *testing.T) {
	for _, tc := range []struct {
		name, src, line, col, text string
	}{
		{"escape_x", "[env]\nv = \"\\x41\"\n", "2", "6", `escape sequence \x is not TOML 1.0`},
		{"inline_newline", "[srv]\nopts = {\n  a = 1 }\n", "2", "9", "line ending inside an inline table is not TOML 1.0"},
		{"inline_trailing_comma", "[app]\ndeps = {db = 1,}\n", "2", "15", "trailing comma in an inline table is not TOML 1.0"},
		{"time_no_seconds", "[sched]\nat = 07:30\n", "2", "6", "time without seconds is not TOML 1.0"},
		{"bom", "\xEF\xBB\xBF[a]\n", "1", "1", "leading byte order mark is not TOML 1.0"},
		{"escape_e_after_multibyte", "[log]\nmsg = \"\u00e9\\e\"\n", "2", "10", `escape sequence \e is not TOML 1.0`},
		{"inline_trailing_comma_after_multibyte", "[app]\ndeps = {\"\u00e9\" = 1,}\n", "2", "17", "trailing comma in an inline table is not TOML 1.0"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			label := tc.name + ".toml"
			path := filepath.Join(t.TempDir(), "f.toml")
			if err := os.WriteFile(path, []byte(tc.src), 0o600); err != nil {
				t.Fatalf("write %s: %v", path, err)
			}
			rc, stdout, stderr := cli(t, "tables", "--name", label, path)
			if rc != 1 {
				t.Fatalf("config-gen tables exited %d, want 1 (stdout %q, stderr %q)", rc, stdout, stderr)
			}
			if len(stdout) != 0 {
				t.Fatalf("config-gen tables stdout = %q, want empty", stdout)
			}
			f := refusal(t, stderr, "config_gen_toml_gate_refused", label)
			if f[4] != tc.line || f[5] != tc.col {
				t.Fatalf("frame line, col = %q, %q, want %s, %s", f[4], f[5], tc.line, tc.col)
			}
			if f[7] != tc.text {
				t.Fatalf("frame text = %q, want %q", f[7], tc.text)
			}
		})
	}
}

// The bytes of every TOML 1.1-only form are accepted where TOML 1.0
// holds them as plain text, in a comment and in a literal string alike:
// `\e`, `\x41`, a trailing-comma inline table, the time without seconds
// `07:32` and the UTF-8 byte order mark EF BB BF (not at the file's
// start) in the comment and in `msg`, `{x = 1,}` in `t`, and an inline
// table broken by a line ending in the multi-line literal `m`. So
// `config-gen tables` exits 0 with nothing on stderr and prints the
// bridge's own `--tables` answer, `log` and an LF (toml_bridge.py
// --tables on these bytes, rc 0; base#1936). A check that refused any of
// these bytes anywhere in the file instead of the gate's TOML-aware scan
// would fail it.
func TestTablesTOML11BytesInACommentOrLiteralStringAreAccepted(t *testing.T) {
	path := filepath.Join(t.TempDir(), "f.toml")
	src := "[log] # \"\\e\" \"\\x41\" {a = 1,} 07:32 \xEF\xBB\xBF\n" +
		"msg = 'a\\e[0m \\x41 {a = 1,} 07:32 \xEF\xBB\xBF'\n" +
		"t = '{x = 1,}'\n" +
		"m = '''{\n  a = 1 }'''\n"
	if err := os.WriteFile(path, []byte(src), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	rc, stdout, stderr := cli(t, "tables", "--name", "f.toml", path)
	if rc != 0 {
		t.Fatalf("config-gen tables exited %d, want 0 (stdout %q, stderr %q)", rc, stdout, stderr)
	}
	if string(stdout) != "log\n" {
		t.Fatalf("config-gen tables stdout = %q, want the bridge's %q", stdout, "log\n")
	}
	if len(stderr) != 0 {
		t.Fatalf("config-gen tables stderr = %q, want empty", stderr)
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

// open(2) answering ENODEV -- a device node with no driver behind it --
// names a character or block device, not a regular file, so the command
// exits 1 with nothing on stdout and exactly one
// `config_gen_input_not_regular` frame naming the label, like the
// /dev/null row above (base#1469 Input: a char device gives
// config_gen_input_not_regular). No path an unprivileged test can make
// opens with ENODEV, so the command is run with an open(2) that answers
// the errno, and the answer goes through readRegular and the refusal as
// syscall.Open's would (base#1469 review round 2). ENXIO is the socket
// answer; EACCES, the control, stays the unreadable frame, so the test
// fails for a mapping that calls every open error not regular.
func TestTablesOpenENODEVIsOneNotRegularFrame(t *testing.T) {
	const label = "l.toml"
	path := filepath.Join(t.TempDir(), "p.toml")
	if err := os.WriteFile(path, []byte("[a]\n"), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	for _, tc := range []struct {
		errno syscall.Errno
		event string
	}{
		{syscall.ENODEV, "config_gen_input_not_regular"},
		{syscall.ENXIO, "config_gen_input_not_regular"},
		{syscall.EACCES, "config_gen_input_unreadable"},
	} {
		t.Run(tc.errno.Error(), func(t *testing.T) {
			var opened []string
			open := func(p string, _ int, _ uint32) (int, error) {
				opened = append(opened, p)
				return -1, tc.errno
			}
			var stdout, stderr bytes.Buffer
			rc := runTables([]string{"--name", label, path}, &stdout, &stderr, open)
			if rc != 1 {
				t.Fatalf("config-gen tables with open(2) = %v exited %d, want 1 (stderr %q)", tc.errno, rc, stderr.Bytes())
			}
			if len(opened) != 1 || opened[0] != path {
				t.Fatalf("config-gen tables opened %q, want [%q]", opened, path)
			}
			if stdout.Len() != 0 {
				t.Fatalf("config-gen tables with open(2) = %v stdout = %q, want empty", tc.errno, stdout.Bytes())
			}
			refusal(t, stderr.Bytes(), tc.event, label)
		})
	}
}

// The command opens its input once, read-only and non-blocking, and
// decides "regular file" from an fstat of the descriptor that open gave
// it, never from a second look at the path (base#1469 Input: open with
// O_RDONLY|O_NONBLOCK, then fstat the fd; the descriptor race, base#1469
// review round 2). The path always names a regular file here, so a
// check of the path passes every row; the open hands back a descriptor
// the test opened itself. When that descriptor is a FIFO or a directory
// the command must exit 1 with nothing on stdout and one
// `config_gen_input_not_regular` frame; when it is a regular file the
// command prints its tables, so a command that refuses every substituted
// descriptor fails the control row. Every open must be read-only and
// carry O_NONBLOCK.
func TestTablesRegularityIsTheOpenedDescriptors(t *testing.T) {
	const label = "l.toml"
	dir := t.TempDir()
	path := filepath.Join(dir, "p.toml")
	if err := os.WriteFile(path, []byte("[x]\n"), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	other := filepath.Join(dir, "other.toml")
	if err := os.WriteFile(other, []byte("[a.b]\n[c]\n[a.d]\n"), 0o600); err != nil {
		t.Fatalf("write %s: %v", other, err)
	}
	fifo := filepath.Join(dir, "fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatalf("mkfifo %s: %v", fifo, err)
	}
	sub := filepath.Join(dir, "sub")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatalf("mkdir %s: %v", sub, err)
	}
	for _, tc := range []struct {
		name   string
		target string
		rc     int
		stdout string
		event  string
	}{
		{"fifo", fifo, 1, "", "config_gen_input_not_regular"},
		{"directory", sub, 1, "", "config_gen_input_not_regular"},
		{"regular", other, 0, "a\na.b\na.d\nc\n", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var opened []string
			open := func(p string, mode int, _ uint32) (int, error) {
				opened = append(opened, p)
				if mode&syscall.O_ACCMODE != syscall.O_RDONLY {
					t.Errorf("open(%q) access mode = %#o, want O_RDONLY", p, mode&syscall.O_ACCMODE)
				}
				if mode&syscall.O_NONBLOCK == 0 {
					t.Errorf("open(%q) mode = %#o, want O_NONBLOCK set", p, mode)
				}
				// The FIFO has no writer: only a non-blocking open returns.
				return syscall.Open(tc.target, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
			}
			var stdout, stderr bytes.Buffer
			rc := runTables([]string{"--name", label, path}, &stdout, &stderr, open)
			if len(opened) != 1 || opened[0] != path {
				t.Fatalf("config-gen tables opened %q, want exactly [%q]", opened, path)
			}
			if rc != tc.rc {
				t.Fatalf("config-gen tables on a %s descriptor exited %d, want %d (stderr %q)", tc.name, rc, tc.rc, stderr.Bytes())
			}
			if stdout.String() != tc.stdout {
				t.Fatalf("config-gen tables on a %s descriptor stdout = %q, want %q", tc.name, stdout.Bytes(), tc.stdout)
			}
			if tc.event == "" {
				if stderr.Len() != 0 {
					t.Fatalf("config-gen tables on a %s descriptor stderr = %q, want empty", tc.name, stderr.Bytes())
				}
				return
			}
			refusal(t, stderr.Bytes(), tc.event, label)
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
// frame, never one per chunk). The frame's text is the library's message
// for the failed write, verbatim: the writer's own error when the write
// returns one, and io.ErrShortWrite's message when it returns a short count
// with no error (base#1469 Diagnostics: library messages are carried
// verbatim). The test requires the fixture's bridge
// golden to be at least 64 KiB, so in the half cases the sink takes at
// least 32 KiB before it fails. The fault writer is not a pipe; the
// closed-pipe case is TestTablesClosedStdoutPipeIsExit4AndOneFrame.
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
		text string
	}{
		{"zero_bytes", &faultWriter{limit: 0}, errFault.Error()},
		{"half", &faultWriter{limit: len(want) / 2}, errFault.Error()},
		{"half_short_count_nil_error", &faultWriter{limit: len(want) / 2, shortNil: true}, io.ErrShortWrite.Error()},
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
			got := refusal(t, stderr.Bytes(), "config_gen_output_failed", "large_tables.toml")
			if len(tc.w.got) >= len(want) || !bytes.HasPrefix(want, tc.w.got) {
				t.Fatalf("sink took %d bytes, want a strict prefix of the %d-byte golden", len(tc.w.got), len(want))
			}
			if tc.w.calls != 1 {
				t.Fatalf("config-gen tables made %d Write calls on stdout, want exactly 1", tc.w.calls)
			}
			if got[7] != tc.text {
				t.Fatalf("frame text = %q, want the library message %q verbatim", got[7], tc.text)
			}
		})
	}
}

// modeFile writes body to a file named name in a fresh t.TempDir and sets
// the file's mode to mode. Both levels of the temp dir (<per-test dir> and
// <NNN>, each created mode 0700) are opened to 0755 so that uid 65534 can
// search them: the file's own mode then decides what an open as that uid
// gets, not a directory on the way to it (base#1469).
func modeFile(t *testing.T, name string, body []byte, mode os.FileMode) string {
	t.Helper()
	dir := t.TempDir()
	for _, d := range []string{filepath.Dir(dir), dir} {
		if err := os.Chmod(d, 0o755); err != nil {
			t.Fatalf("chmod %s: %v", d, err)
		}
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatalf("chmod %s: %v", path, err)
	}
	return path
}

// asNonRoot pins the calling goroutine to its OS thread and, when the test
// runs as root, sets that thread's filesystem uid to 65534, which drops
// CAP_DAC_OVERRIDE from the thread's effective set, so file modes bind the
// thread as they bind a non-root caller (base#1469). The returned func
// sets the fsuid back to 0 and unpins the goroutine; defer it.
func asNonRoot() func() {
	runtime.LockOSThread()
	root := os.Geteuid() == 0
	if root {
		_, _, _ = syscall.RawSyscall(syscall.SYS_SETFSUID, 65534, 0, 0)
	}
	return func() {
		if root {
			_, _, _ = syscall.RawSyscall(syscall.SYS_SETFSUID, 0, 0, 0)
		}
		runtime.UnlockOSThread()
	}
}

// An input the caller may not read -- a regular file with mode 000, opened
// by a non-root caller -- makes `config-gen tables` exit 1 with nothing on
// stdout and exactly one `config_gen_input_unreadable` frame whose `file`
// field is the `--name` label (base#1469 Input: EACCES/EPERM on open ->
// config_gen_input_unreadable). Root reads a mode-000 file through
// CAP_DAC_OVERRIDE, so a root run drops it with asNonRoot for the call.
func TestTablesUnreadableInputIsOneUnreadableFrame(t *testing.T) {
	const label = "l.toml"
	path := modeFile(t, "locked.toml", []byte("[a]\n"), 0)

	defer asNonRoot()()
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

// The `config_gen_input_unreadable` frame's text is the library's message
// for the refused open, verbatim (base#1469 Diagnostics: library messages
// are carried verbatim). The want is what os.Open reports for the same
// mode-000 file on the same non-root thread, not a string the command
// builds.
func TestTablesUnreadableFrameTextIsTheOpenMessage(t *testing.T) {
	path := modeFile(t, "locked.toml", []byte("[a]\n"), 0)

	defer asNonRoot()()
	f, err := os.Open(path)
	if !errors.Is(err, syscall.EACCES) {
		if f != nil {
			_ = f.Close()
		}
		t.Fatalf("open %s as uid %d: err = %v, want EACCES", path, os.Geteuid(), err)
	}

	_, _, stderr := cli(t, "tables", "--name", "l.toml", path)
	got := refusal(t, stderr, "config_gen_input_unreadable", "l.toml")
	if got[7] != err.Error() {
		t.Fatalf("frame text = %q, want the library message %q verbatim", got[7], err.Error())
	}
}

// `config-gen tables` only reads its input, so a regular file the caller
// may read but not write -- mode 0444, opened by a non-root caller --
// gives exit 0, the bridge golden on stdout and nothing on stderr
// (base#1469 Input: the input is opened O_RDONLY). A root run drops
// CAP_DAC_OVERRIDE with asNonRoot for the call, so the capability can not
// grant the write access a read-write open would ask for.
func TestTablesReadOnlyInputPrintsTheBridgeGolden(t *testing.T) {
	src := testcorpus.Glob(t, "corpus/s1/interleaved.toml")[0]
	golden := testcorpus.Glob(t, "golden/s1/interleaved.golden")[0]
	body, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read %s: %v", src, err)
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read %s: %v", golden, err)
	}
	path := modeFile(t, "ro.toml", body, 0o444)

	defer asNonRoot()()
	// The preconditions: this thread can open the file for reading and can
	// not open it for writing. Without both a pass would not show the open
	// asks for read access only.
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open %s read-only as fsuid 65534 or uid %d: %v, want success", path, os.Geteuid(), err)
	}
	_ = f.Close()
	if f, err := os.OpenFile(path, os.O_RDWR, 0); !errors.Is(err, syscall.EACCES) {
		if f != nil {
			_ = f.Close()
		}
		t.Fatalf("open %s read-write as uid %d: err = %v, want EACCES", path, os.Geteuid(), err)
	}

	rc, stdout, stderr := cli(t, "tables", "--name", "ro.toml", path)
	if rc != 0 {
		t.Fatalf("config-gen tables on mode-0444 %s exited %d, want 0 (stderr %q)", path, rc, stderr)
	}
	if !bytes.Equal(stdout, want) {
		t.Fatalf("config-gen tables stdout = %q, want the bridge golden %q", stdout, want)
	}
	if len(stderr) != 0 {
		t.Fatalf("config-gen tables stderr = %q, want empty", stderr)
	}
}

// When the reader of stdout is gone before the answer is written -- a pipe
// whose read end is closed before the command starts, as in `config-gen
// tables ... | true` -- the process is not killed by SIGPIPE: it exits
// normally with status 4 and its stderr is exactly one
// `config_gen_output_failed` frame naming the --name label with an empty
// key, and no "unregistered log body" (base#1469 I/O contract: exit 4 on
// any write error, one frame). It runs the real binary as a child, since
// the signal only exists for a process writing to a real pipe on fd 1;
// the golden is over 64 KiB, more than one pipe buffer, so the write can
// not succeed by fitting into the buffer whatever the reader does.
func TestTablesClosedStdoutPipeIsExit4AndOneFrame(t *testing.T) {
	src := testcorpus.Glob(t, "corpus/s1/large_tables.toml")[0]
	golden := testcorpus.Glob(t, "golden/s1/large_tables.golden")[0]
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read %s: %v", golden, err)
	}
	if len(want) <= 64*1024 {
		t.Fatalf("golden %s is %d bytes, want more than 64 KiB", golden, len(want))
	}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	if err := r.Close(); err != nil {
		t.Fatalf("close read end: %v", err)
	}
	stderr := childExit4(t, w, nil, "tables", "--name", "large_tables.toml", src)
	_ = w.Close()
	refusal(t, stderr, "config_gen_output_failed", "large_tables.toml")
}

// childExit4 runs config-gen as a child process -- this test binary
// re-executed with argvEnv, so the child is main itself with the real
// os.Exit and signal handling -- with args, its stdout on the file
// stdout, and, when wrap is non-nil, started through wrap (the child's
// path is appended as wrap's last argument). It fails the test unless the
// child exited normally with status 4 and its stderr carries no
// "unregistered log body"; it returns the child's stderr (base#1469 I/O
// contract: exit 4 on any write error, never a signal).
func childExit4(t *testing.T, stdout *os.File, wrap []string, args ...string) []byte {
	t.Helper()
	argv, err := json.Marshal(args)
	if err != nil {
		t.Fatalf("marshal argv: %v", err)
	}
	name, cargs := os.Args[0], []string(nil)
	if wrap != nil {
		name, cargs = wrap[0], append(append([]string(nil), wrap[1:]...), os.Args[0])
	}
	var stderr bytes.Buffer
	cmd := exec.Command(name, cargs...)
	cmd.Env = append(os.Environ(), argvEnv+"="+string(argv))
	cmd.Stdout = stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()
	if cmd.ProcessState == nil {
		t.Fatalf("config-gen %q did not run: %v", args, runErr)
	}
	ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus)
	if !ok {
		t.Fatalf("process state %T is not a syscall.WaitStatus", cmd.ProcessState.Sys())
	}
	if ws.Signaled() {
		t.Fatalf("config-gen %q was killed by signal %v (stderr %q), want a normal exit 4", args, ws.Signal(), stderr.Bytes())
	}
	if rc := ws.ExitStatus(); rc != 4 {
		t.Fatalf("config-gen %q exited %d, want 4 (stderr %q)", args, rc, stderr.Bytes())
	}
	if bytes.Contains(stderr.Bytes(), []byte("unregistered log body")) {
		t.Fatalf("stderr %q carries \"unregistered log body\"", stderr.Bytes())
	}
	return stderr.Bytes()
}

// A process whose stdout is /dev/full -- a real sink that takes no bytes
// and refuses with ENOSPC -- exits 4 with exactly one
// `config_gen_output_failed` frame naming the --name label with an empty
// key, and that frame's text is the write's own message verbatim
// (base#1469 Partial write: process tests run in the test stage, `>
// /dev/full` gives rc 4 and a config_gen_output_failed frame). This runs
// under `go test` in Dockerfile.config-gen's test stage, so the process
// case is not left to the bats spec alone. The want text is the
// *os.PathError os.File.Write returns for the child's os.Stdout on ENOSPC.
func TestTablesDevFullStdoutIsExit4AndOneFrame(t *testing.T) {
	src := testcorpus.Glob(t, "corpus/s1/large_tables.toml")[0]
	full, err := os.OpenFile("/dev/full", os.O_WRONLY, 0)
	if err != nil {
		t.Fatalf("open /dev/full: %v", err)
	}
	defer func() { _ = full.Close() }()

	stderr := childExit4(t, full, nil, "tables", "--name", "large_tables.toml", src)
	f := refusal(t, stderr, "config_gen_output_failed", "large_tables.toml")
	want := (&os.PathError{Op: "write", Path: os.Stdout.Name(), Err: syscall.ENOSPC}).Error()
	if f[7] != want {
		t.Fatalf("frame text = %q, want the write message %q verbatim", f[7], want)
	}
}

// A process whose stdout is a regular file it may grow only to half the
// large golden -- SIGXFSZ ignored, then `prlimit --fsize=<half>`, so the
// kernel takes that many bytes and then refuses the rest with EFBIG
// instead of killing the process with SIGXFSZ -- exits 4 with exactly one
// `config_gen_output_failed` frame naming the --name label with an empty
// key, whose text is the write's own message verbatim, and the file holds
// a non-empty strict prefix of the golden (base#1469 Partial write:
// process tests run in the test stage with util-linux prlimit). /dev/full
// can not show a sink that takes some bytes first. prlimit must be on
// PATH in Dockerfile.config-gen's test stage; a missing prlimit fails
// here, it is never skipped.
func TestTablesSizeLimitedStdoutIsExit4AndAGoldenPrefix(t *testing.T) {
	src := testcorpus.Glob(t, "corpus/s1/large_tables.toml")[0]
	golden := testcorpus.Glob(t, "golden/s1/large_tables.golden")[0]
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read %s: %v", golden, err)
	}
	if len(want) < 64*1024 {
		t.Fatalf("golden %s is %d bytes, want at least 64 KiB", golden, len(want))
	}
	if _, err := exec.LookPath("prlimit"); err != nil {
		t.Fatalf("prlimit is not on PATH (%v); Dockerfile.config-gen's test stage must provide util-linux prlimit for this case (base#1469)", err)
	}
	limit := len(want) / 2
	capPath := filepath.Join(t.TempDir(), "cap")
	capFile, err := os.Create(capPath)
	if err != nil {
		t.Fatalf("create %s: %v", capPath, err)
	}
	defer func() { _ = capFile.Close() }()

	wrap := []string{"sh", "-c", `trap '' XFSZ; exec prlimit --fsize="$1" "$2"`, "sh", strconv.Itoa(limit)}
	stderr := childExit4(t, capFile, wrap, "tables", "--name", "large_tables.toml", src)
	f := refusal(t, stderr, "config_gen_output_failed", "large_tables.toml")
	wantText := (&os.PathError{Op: "write", Path: os.Stdout.Name(), Err: syscall.EFBIG}).Error()
	if f[7] != wantText {
		t.Fatalf("frame text = %q, want the write message %q verbatim", f[7], wantText)
	}
	got, err := os.ReadFile(capPath)
	if err != nil {
		t.Fatalf("read %s: %v", capPath, err)
	}
	if len(got) == 0 || len(got) >= len(want) || !bytes.HasPrefix(want, got) {
		t.Fatalf("stdout file took %d bytes, want a non-empty strict prefix of the %d-byte golden", len(got), len(want))
	}
}
