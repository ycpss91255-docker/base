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

// versionCmd prints the toolchain config-gen was built with as one line,
// "toolchain <x.y.z>" (base#2022).
func versionCmd(_ []string, stdout, _ io.Writer) error {
	_, err := fmt.Fprintf(stdout, "toolchain %s\n", strings.TrimPrefix(runtime.Version(), "go"))
	return err
}
