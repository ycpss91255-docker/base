package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
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
	// test-args echoes the arguments it was handed, so a dispatch that
	// drops or mangles everything after the command name goes red
	// (base#1462).
	Register("test-args", func(args []string, stdout, stderr io.Writer) error {
		_, err := fmt.Fprintf(stdout, "%d %q\n", len(args), args)
		return err
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
		{"arguments after the name reach the command", []string{"test-args", "a", "-b", ""}, 0, "3 [\"a\" \"-b\" \"\"]\n"},
		{"no arguments after the name", []string{"test-args"}, 0, "0 []\n"},
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

// TestUsageOnStderr pins what a usage refusal says, not only that it said
// something: why it was refused, the usage line, and the registered names,
// all on stderr (base#1462).
func TestUsageOnStderr(t *testing.T) {
	cases := []struct {
		name string
		args []string
		why  string
	}{
		{"no arguments", nil, "no command given"},
		{"unknown command", []string{"no-such-command"}, `unknown command "no-such-command"`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			if got := run(c.args, &stdout, &stderr); got != 2 {
				t.Fatalf("run(%q) = %d, want 2", c.args, got)
			}
			if stdout.Len() != 0 {
				t.Fatalf("run(%q) stdout = %q, want empty", c.args, stdout.String())
			}
			want := "config-gen: " + c.why + "\nusage: config-gen <command> [args...]\ncommands: ["
			if !strings.HasPrefix(stderr.String(), want) {
				t.Fatalf("run(%q) stderr = %q, want it to start with %q", c.args, stderr.String(), want)
			}
			for _, name := range []string{"test-args", "test-fail", "test-ok", "test-panic"} {
				if !strings.Contains(stderr.String(), name) {
					t.Fatalf("run(%q) stderr = %q does not list the registered command %s", c.args, stderr.String(), name)
				}
			}
			if !strings.HasSuffix(stderr.String(), "]\n") {
				t.Fatalf("run(%q) stderr = %q does not end the command list", c.args, stderr.String())
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
