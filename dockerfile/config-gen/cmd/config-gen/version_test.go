package main

import (
	"bytes"
	"runtime"
	"strings"
	"testing"
)

// config-gen version prints the toolchain it was built with as its first
// line, "toolchain <x.y.z>" (base#2022), then "digest unstamped" when no
// content digest was stamped at build time (base#2033).
func TestVersionPrintsToolchainLine(t *testing.T) {
	var stdout, stderr bytes.Buffer
	got := run([]string{"version"}, &stdout, &stderr)
	if got != 0 {
		t.Fatalf("run(version) = %d, want 0 (stderr %q)", got, stderr.String())
	}
	want := "toolchain " + strings.TrimPrefix(runtime.Version(), "go") + "\ndigest unstamped\n"
	if stdout.String() != want {
		t.Fatalf("stdout = %q, want %q", stdout.String(), want)
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}

// A build stamped with -X main.contentDigest=<digest> prints it on the second
// line (base#2033).
func TestVersionPrintsStampedDigest(t *testing.T) {
	old := contentDigest
	contentDigest = "0123456789ab"
	t.Cleanup(func() { contentDigest = old })
	var stdout, stderr bytes.Buffer
	got := run([]string{"version"}, &stdout, &stderr)
	if got != 0 {
		t.Fatalf("run(version) = %d, want 0 (stderr %q)", got, stderr.String())
	}
	want := "toolchain " + strings.TrimPrefix(runtime.Version(), "go") + "\ndigest 0123456789ab\n"
	if stdout.String() != want {
		t.Fatalf("stdout = %q, want %q", stdout.String(), want)
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}

// A build whose -X main.contentDigest= value is empty (CONFIG_GEN_DIGEST
// unset, base#2034) overwrites the default with ""; version prints
// "digest unstamped" for it as for a plain go build.
func TestVersionEmptyDigestPrintsUnstamped(t *testing.T) {
	old := contentDigest
	contentDigest = ""
	t.Cleanup(func() { contentDigest = old })
	var stdout, stderr bytes.Buffer
	got := run([]string{"version"}, &stdout, &stderr)
	if got != 0 {
		t.Fatalf("run(version) = %d, want 0 (stderr %q)", got, stderr.String())
	}
	want := "toolchain " + strings.TrimPrefix(runtime.Version(), "go") + "\ndigest unstamped\n"
	if stdout.String() != want {
		t.Fatalf("stdout = %q, want %q", stdout.String(), want)
	}
}
