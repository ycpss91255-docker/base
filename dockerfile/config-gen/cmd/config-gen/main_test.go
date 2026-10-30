package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"testing"
)

// The exit statuses every caller of config-gen reads (base#1462):
// 0 success, 1 a command's error, 2 a usage error (no command, or one
// that is not registered), 4 a command that panicked.

func init() {
	Register("test-ok", func(args []string, stdout, stderr io.Writer) error {
		_, err := io.WriteString(stdout, "ok\n")
		return err
	})
	Register("test-fail", func(args []string, stdout, stderr io.Writer) error {
		return errors.New("test-fail failed")
	})
	Register("test-panic", func(args []string, stdout, stderr io.Writer) error {
		panic("test-panic")
	})
}

func TestRunStatus(t *testing.T) {
	cases := []struct {
		name       string
		args       []string
		want       int
		wantStdout string
	}{
		{"no arguments is usage", nil, 2, ""},
		{"empty arguments is usage", []string{}, 2, ""},
		{"unknown command is usage", []string{"no-such-command"}, 2, ""},
		{"success", []string{"test-ok"}, 0, "ok\n"},
		{"command error", []string{"test-fail"}, 1, ""},
		{"command panic", []string{"test-panic"}, 4, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			got := run(c.args, &stdout, &stderr)
			if got != c.want {
				t.Fatalf("run(%q) = %d, want %d (stderr %q)", c.args, got, c.want, stderr.String())
			}
			if stdout.String() != c.wantStdout {
				t.Fatalf("run(%q) stdout = %q, want %q", c.args, stdout.String(), c.wantStdout)
			}
			if got != 0 && stderr.Len() == 0 {
				t.Fatalf("run(%q) = %d with nothing on stderr", c.args, got)
			}
		})
	}
}

func TestRegisterTwicePanics(t *testing.T) {
	Register("test-dup", func(args []string, stdout, stderr io.Writer) error { return nil })
	defer func() {
		if recover() == nil {
			t.Fatal("registering test-dup twice did not panic")
		}
	}()
	Register("test-dup", func(args []string, stdout, stderr io.Writer) error { return nil })
}

func TestMainExitsWithRunStatus(t *testing.T) {
	saved, savedArgs := osExit, os.Args
	defer func() { osExit, os.Args = saved, savedArgs }()
	got := -1
	osExit = func(code int) { got = code }
	os.Args = []string{"config-gen"}
	main()
	if got != 2 {
		t.Fatalf("main() with no arguments exited %d, want 2", got)
	}
}

func FuzzRun(f *testing.F) {
	f.Add("")
	f.Add("test-ok")
	f.Add("test-fail")
	f.Add("test-panic")
	f.Add("no-such-command")
	f.Fuzz(func(t *testing.T, name string) {
		var stdout, stderr bytes.Buffer
		got := run([]string{name}, &stdout, &stderr)
		switch got {
		case 0, 1, 2, 4:
		default:
			t.Fatalf("run(%q) = %d, outside {0,1,2,4}", name, got)
		}
		if got == 2 && stdout.Len() != 0 {
			t.Fatalf("run(%q) = 2 with stdout %q", name, stdout.String())
		}
	})
}
