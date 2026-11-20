package main

import (
	"bytes"
	"runtime"
	"strings"
	"testing"
)

// config-gen version prints the toolchain it was built with as one line,
// "toolchain <x.y.z>" (base#2022).
func TestVersionPrintsToolchainLine(t *testing.T) {
	var stdout, stderr bytes.Buffer
	got := run([]string{"version"}, &stdout, &stderr)
	if got != 0 {
		t.Fatalf("run(version) = %d, want 0 (stderr %q)", got, stderr.String())
	}
	want := "toolchain " + strings.TrimPrefix(runtime.Version(), "go") + "\n"
	if stdout.String() != want {
		t.Fatalf("stdout = %q, want %q", stdout.String(), want)
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}
