package main

import (
	"bytes"
	"os"
	"path/filepath"
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
