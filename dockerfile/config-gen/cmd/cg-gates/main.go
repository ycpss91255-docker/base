// Command cg-gates runs the config generator's build-time gates that need
// Go (base#1465). It is built and run only in the Dockerfile's test stage,
// after admission bound the build context to the host mutation baseline;
// it never ships in final.
//
//	cg-gates ratchet --measured <file> --floors <dir> --base <file> --module <path>
//
// ratchet judges coverage.sh --measure's counts against the
// coverage-floors.d fragments and the base's union (internal/buildgate).
// Each refusal is one stdout line `cg_event config_gen_coverage_<rule>
// k=v...`; after the last, `config_gen_gate_coverage_failed` goes to
// stderr.
//
// Exit statuses:
//
//	0  every package holds its floor
//	1  a refusal, or a measurement or floors directory it could not read
//	2  usage
package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/buildgate"
)

const (
	exitOK    = 0
	exitFail  = 1
	exitUsage = 2
)

// failed is the coverage gate's id, spelled once.
const failed = "config_gen_gate_coverage_failed"

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "ratchet" {
		_, _ = fmt.Fprintln(stderr, "usage: cg-gates ratchet --measured <file> --floors <dir> --base <file> --module <path>")
		return exitUsage
	}
	fs := flag.NewFlagSet("ratchet", flag.ContinueOnError)
	fs.SetOutput(stderr)
	measured := fs.String("measured", "", "coverage.sh --measure output")
	floors := fs.String("floors", "", "the coverage-floors.d directory")
	base := fs.String("base", "", "floors.base from the 05-floors-base step")
	module := fs.String("module", "", "the module path (go list -m)")
	if err := fs.Parse(args[1:]); err != nil || fs.NArg() != 0 ||
		*measured == "" || *floors == "" || *base == "" || *module == "" {
		_, _ = fmt.Fprintln(stderr, "usage: cg-gates ratchet --measured <file> --floors <dir> --base <file> --module <path>")
		return exitUsage
	}
	events, err := buildgate.Ratchet(*measured, *floors, *base, *module)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "cg-gates: ratchet: %v\n%s reason=unreadable\n", err, failed)
		return exitFail
	}
	for _, e := range events {
		_, _ = fmt.Fprintln(stdout, e.String())
	}
	if len(events) > 0 {
		_, _ = fmt.Fprintln(stderr, failed)
		return exitFail
	}
	return exitOK
}

// osExit is swapped by the tests so main itself is exercised.
var osExit = os.Exit

func main() {
	osExit(run(os.Args[1:], os.Stdout, os.Stderr))
}
