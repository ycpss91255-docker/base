// Command cg-gates runs the config generator's build-time gates that need
// Go (base#1465). It is built and run only in the Dockerfile's test stage,
// after admission bound the build context to the host mutation baseline;
// it never ships in final.
//
//	cg-gates ratchet --measured <file> --floors <dir> --base <file> --module <path>
//	cg-gates mutation --manifest <file> --module <path> --reports <dir>
//
// ratchet judges coverage.sh --measure's counts against the
// coverage-floors.d fragments and the base's union (internal/buildgate).
// Each refusal is one stdout line `cg_event config_gen_coverage_<rule>
// k=v...`; after the last, `config_gen_gate_coverage_failed` goes to
// stderr.
//
// mutation (base#1467) runs gremlins once on each package the change
// manifest lists a Go file of, with one worker and a timeout coefficient
// of 10, its report written under <dir>. The verdict is the report's
// KILLED over KILLED and LIVED, never gremlins' exit status or its own
// efficacy figure: each package prints `<pkg> ok efficacy=<e>` or
// `<pkg> failed reason=<r> [measured=<e>]` on stdout, reason
// gremlins_failed (it exited non-zero), report (no report it could read)
// or below (under 90.0), and after the last package any failure puts
// `config_gen_gate_mutation_failed` on stderr. A manifest listing no Go
// file prints `mutation targets none`.
//
// Exit statuses:
//
//	0  every package holds its floor
//	1  a refusal, or an input it could not read
//	2  usage
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/buildgate"
)

const (
	exitOK    = 0
	exitFail  = 1
	exitUsage = 2
)

// The gate ids, spelled once.
const (
	failed         = "config_gen_gate_coverage_failed"
	mutationFailed = "config_gen_gate_mutation_failed"
)

const usage = "usage: cg-gates ratchet --measured <file> --floors <dir> --base <file> --module <path>\n" +
	"       cg-gates mutation --manifest <file> --module <path> --reports <dir>"

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		_, _ = fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	switch args[0] {
	case "ratchet":
		return ratchet(args[1:], stdout, stderr)
	case "mutation":
		return mutation(args[1:], stdout, stderr)
	}
	_, _ = fmt.Fprintln(stderr, usage)
	return exitUsage
}

func ratchet(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("ratchet", flag.ContinueOnError)
	fs.SetOutput(stderr)
	measured := fs.String("measured", "", "coverage.sh --measure output")
	floors := fs.String("floors", "", "the coverage-floors.d directory")
	base := fs.String("base", "", "floors.base from the 05-floors-base step")
	module := fs.String("module", "", "the module path (go list -m)")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 ||
		*measured == "" || *floors == "" || *base == "" || *module == "" {
		_, _ = fmt.Fprintln(stderr, usage)
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

func mutation(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("mutation", flag.ContinueOnError)
	fs.SetOutput(stderr)
	manifest := fs.String("manifest", "", "the change manifest the 00-manifest step wrote")
	module := fs.String("module", "", "the module path (go list -m)")
	reports := fs.String("reports", "", "an existing directory for gremlins' reports")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 ||
		*manifest == "" || *module == "" || *reports == "" {
		_, _ = fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	body, err := os.ReadFile(*manifest)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "cg-gates: mutation: %v\n%s reason=unreadable\n", err, mutationFailed)
		return exitFail
	}
	targets := buildgate.Targets(string(body))
	if len(targets) == 0 {
		_, _ = fmt.Fprintln(stdout, "mutation targets none")
	}
	bad := false
	for i, rel := range targets {
		pkg := *module
		if rel != "." {
			pkg += "/" + rel
		}
		out := filepath.Join(*reports, strconv.Itoa(i)+".json")
		cmd := exec.Command("gremlins", "unleash", "--workers", "1", "--timeout-coefficient", "10",
			"-o", out, "./"+rel)
		cmd.Stdout, cmd.Stderr = stderr, stderr
		if err := cmd.Run(); err != nil {
			_, _ = fmt.Fprintf(stdout, "%s failed reason=gremlins_failed\n", pkg)
			bad = true
			continue
		}
		rep, err := os.ReadFile(out)
		eff := 0
		if err == nil {
			eff, err = buildgate.Efficacy(rep)
		}
		if err != nil {
			_, _ = fmt.Fprintf(stdout, "%s failed reason=report\n", pkg)
			bad = true
			continue
		}
		e := fmt.Sprintf("%d.%d", eff/10, eff%10)
		if eff < buildgate.MutationFloor {
			_, _ = fmt.Fprintf(stdout, "%s failed reason=below measured=%s\n", pkg, e)
			bad = true
			continue
		}
		_, _ = fmt.Fprintf(stdout, "%s ok efficacy=%s\n", pkg, e)
	}
	if bad {
		_, _ = fmt.Fprintln(stderr, mutationFailed)
		return exitFail
	}
	return exitOK
}

// osExit is swapped by the tests so main itself is exercised.
var osExit = os.Exit

func main() {
	osExit(run(os.Args[1:], os.Stdout, os.Stderr))
}
