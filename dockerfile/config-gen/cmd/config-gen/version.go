package main

import (
	"fmt"
	"io"
	"runtime"
	"strings"
)

func init() {
	Register("version", versionCmd)
}

// contentDigest is stamped at build time with -ldflags -X
// main.contentDigest=<digest>; "unstamped" means a plain go build, and an empty stamp prints the same (base#2034).
var contentDigest = "unstamped"

// versionCmd prints "toolchain <x.y.z>" (base#2022), then
// "digest <contentDigest>" (base#2033).
func versionCmd(_ []string, stdout, _ io.Writer) error {
	digest := contentDigest
	if digest == "" {
		digest = "unstamped"
	}
	_, err := fmt.Fprintf(stdout, "toolchain %s\ndigest %s\n", strings.TrimPrefix(runtime.Version(), "go"), digest)
	return err
}
