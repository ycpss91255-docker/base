// Command cg-gates runs the config generator's build-time gates that need
// Go (base#1465). It is built and run only in the Dockerfile's test stage,
// after admission bound the build context to the host mutation baseline;
// it never ships in final.
//
//	cg-gates ratchet --measured <file> --floors <dir> --base <file> --module <path>
//	cg-gates mutation --manifest <file> --module <path> --reports <dir>
//	cg-gates sensitivity --module <path> --root <dir> --work <dir>
//	cg-gates ignored --list <file> --context <dir>
//
// ratchet judges coverage.sh --measure's counts against the
// coverage-floors.d fragments and the base's union (internal/buildgate).
// Each refusal is one stdout line `cg_event config_gen_coverage_<rule>
// k=v...`; after the last, `config_gen_gate_coverage_failed` goes to
// stderr.
//
// mutation (base#1467) runs gremlins once on each package
// buildgate.Map draws from the change manifest and `go list -json -test
// -deps ./...` of the working directory (a refusal of Map is printed as its
// cg_event line on stdout), with one worker and a timeout coefficient
// of 10, its report written under <dir>. Two checks judge each package,
// in order. The first is gremlins' exit status: a non-zero exit fails the
// package, reason gremlins_failed, and its report is not read, whatever
// efficacy it holds. The second, after an exit of 0, is the report: the
// efficacy is its KILLED over KILLED, LIVED and TIMED OUT, never the
// efficacy figure gremlins writes itself, and a package fails with reason
// report when there is no report it can read, or below when that efficacy
// is under 90.0. A package gremlins wrote no report for after printing
// `No results to report.` and exiting 0 prints `<pkg> no-mutants` and
// passes. Each other package prints `<pkg> ok efficacy=<e>`, or, failed,
// `cg_event config_gen_mutation_package_failed pkg=<pkg> reason=<r>
// [measured=<e>]` (buildgate.PackageFailed) on stdout, which the runner
// re-emits as a record naming the package.
// After the last package any failure puts
// `config_gen_gate_mutation_failed` on stderr. Before any package, each
// package the manifest deletes that the head tree no longer holds prints
// `removed <pkg>`, and a manifest that maps to no package prints
// `mutation targets none`.
//
// sensitivity (base#1467) checks that each golden file under the corpus
// root <root> fails every package its tests were handed it by. Each
// package whose test binary depends on internal/testcorpus runs its tests
// once with a traced Glob (traceOverlay, by `go test -overlay`,
// the source left as it is) against <root>; a red baseline prints
// `<pkg> failed reason=baseline_failed`. The packages whose trace holds a
// golden are its consumers. In a copy of <root> under the existing
// directory <work>, each golden in turn has its first byte flipped (an
// empty golden is given the one byte 0xff) and each consumer runs its
// tests with the real Glob against the copy: one that still passes prints
// `cg_event config_gen_corpus_sensitivity_weak pkg= file=` on stdout. The
// golden is then put back as it was. A golden with no consumer prints
// `golden=<file> consumers none`. After the last golden any weak pair puts
// `config_gen_gate_corpus_sensitivity_failed` on stderr. A golden the
// flip or the put-back cannot write stops the run at once with that id
// and reason=unwritable on stderr.
//
// ignored (base#1467) refuses a build context holding a Git-ignored module
// file: each path the producer's ignored.sha256 <file> lists that the
// context <dir> holds prints `cg_event config_gen_mutation_ignored_input
// file=` on stdout, and any puts `config_gen_gate_ignored_failed` on
// stderr.
//
// Exit statuses:
//
//	0  the gate passed
//	1  a refusal, or an input it could not read
//	2  usage
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/buildgate"
)

const (
	exitOK    = 0
	exitFail  = 1
	exitUsage = 2
)

// The gate ids, spelled once.
const (
	failed            = "config_gen_gate_coverage_failed"
	mutationFailed    = "config_gen_gate_mutation_failed"
	sensitivityFailed = "config_gen_gate_corpus_sensitivity_failed"
	ignoredFailed     = "config_gen_gate_ignored_failed"
)

// noMutants is what gremlins prints, writing no report and exiting 0, on a
// package with no mutants (measured on ./internal/testcorpus, base#1467).
const noMutants = "No results to report."

const usage = "usage: cg-gates ratchet --measured <file> --floors <dir> --base <file> --module <path>\n" +
	"       cg-gates mutation --manifest <file> --module <path> --reports <dir>\n" +
	"       cg-gates sensitivity --module <path> --root <dir> --work <dir>\n" +
	"       cg-gates ignored --list <file> --context <dir>"

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
	case "sensitivity":
		return sensitivity(args[1:], stdout, stderr)
	case "ignored":
		return ignored(args[1:], stdout, stderr)
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
	pkgs, err := goList()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "cg-gates: mutation: go list: %v\n%s reason=unreadable\n", err, mutationFailed)
		return exitFail
	}
	m, err := buildgate.Map(string(body), *module, pkgs)
	if err != nil {
		_, _ = fmt.Fprintln(stdout, err.Error())
		_, _ = fmt.Fprintln(stderr, mutationFailed)
		return exitFail
	}
	for _, rel := range m.Removed {
		_, _ = fmt.Fprintf(stdout, "removed %s\n", buildgate.ImportPath(*module, rel))
	}
	if len(m.Targets) == 0 {
		_, _ = fmt.Fprintln(stdout, "mutation targets none")
	}
	bad := false
	for i, rel := range m.Targets {
		pkg := buildgate.ImportPath(*module, rel)
		out := filepath.Join(*reports, strconv.Itoa(i)+".json")
		cmd := exec.Command("gremlins", "unleash", "--workers", "1", "--timeout-coefficient", "10",
			"-o", out, "./"+rel)
		var said strings.Builder
		w := io.MultiWriter(stderr, &said)
		cmd.Stdout, cmd.Stderr = w, w
		if err := cmd.Run(); err != nil {
			_, _ = fmt.Fprintln(stdout, buildgate.PackageFailed(pkg, "gremlins_failed").String())
			bad = true
			continue
		}
		rep, err := os.ReadFile(out)
		if errors.Is(err, os.ErrNotExist) && strings.Contains(said.String(), noMutants) {
			_, _ = fmt.Fprintf(stdout, "%s no-mutants\n", pkg)
			continue
		}
		eff := 0
		if err == nil {
			eff, err = buildgate.Efficacy(rep)
		}
		if err != nil {
			_, _ = fmt.Fprintln(stdout, buildgate.PackageFailed(pkg, "report").String())
			bad = true
			continue
		}
		e := fmt.Sprintf("%d.%d", eff/10, eff%10)
		if eff < buildgate.MutationFloor {
			_, _ = fmt.Fprintln(stdout, buildgate.PackageFailed(pkg, "below", "measured", e).String())
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

func sensitivity(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("sensitivity", flag.ContinueOnError)
	flags.SetOutput(stderr)
	module := flags.String("module", "", "the module path (go list -m)")
	root := flags.String("root", "", "the corpus root the race gate moved testdata/ to")
	work := flags.String("work", "", "an existing directory for the overlay, traces and the flipped copy")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 ||
		*module == "" || *root == "" || *work == "" {
		_, _ = fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	unreadable := func(err error) int {
		_, _ = fmt.Fprintf(stderr, "cg-gates: sensitivity: %v\n%s reason=unreadable\n", err, sensitivityFailed)
		return exitFail
	}
	unwritable := func(err error) int {
		_, _ = fmt.Fprintf(stderr, "cg-gates: sensitivity: %v\n%s reason=unwritable\n", err, sensitivityFailed)
		return exitFail
	}
	wd, _ := os.Getwd()
	tc := filepath.Join(wd, "internal", "testcorpus")
	pkgs, err := goList()
	var src []byte
	if err == nil {
		src, err = os.ReadFile(filepath.Join(tc, "testcorpus.go"))
	}
	if err != nil {
		return unreadable(err)
	}
	traced, err := traceOverlay(src)
	if err != nil {
		_, _ = fmt.Fprintln(stdout, err.Error())
		_, _ = fmt.Fprintln(stderr, sensitivityFailed)
		return exitFail
	}
	replace := map[string]string{}
	replace[filepath.Join(tc, "testcorpus.go")] = filepath.Join(*work, "testcorpus.go")
	replace[filepath.Join(tc, "zz_cgtrace.go")] = filepath.Join(*work, "zz_cgtrace.go")
	ov, _ := json.Marshal(map[string]map[string]string{"Replace": replace})
	overlay := filepath.Join(*work, "overlay.json")
	flip := filepath.Join(*work, "corpus")
	err = errors.Join(
		os.WriteFile(filepath.Join(*work, "testcorpus.go"), traced, 0o644),
		os.WriteFile(filepath.Join(*work, "zz_cgtrace.go"), []byte(traceSource), 0o644),
		os.WriteFile(overlay, ov, 0o644),
		os.CopyFS(flip, os.DirFS(*root)),
	)
	var goldens []string
	bodies := map[string][]byte{}
	if err == nil {
		err = filepath.WalkDir(filepath.Join(flip, "golden"), func(p string, d fs.DirEntry, err error) error {
			if err == nil && d.Type().IsRegular() {
				goldens = append(goldens, p)
				bodies[p], err = os.ReadFile(p)
			}
			return err
		})
	}
	if err != nil {
		return unreadable(err)
	}
	x := "-ldflags=-X=" + *module + "/internal/testcorpus.root="
	consumers := map[string][]string{}
	for i, rel := range buildgate.CorpusImporters(*module, pkgs) {
		trace := filepath.Join(*work, "trace"+strconv.Itoa(i))
		cmd := exec.Command("go", "test", "-count=1", "-overlay", overlay, x+*root, "./"+rel)
		cmd.Env = append(os.Environ(), traceEnv+"="+trace)
		cmd.Stdout, cmd.Stderr = stderr, stderr
		if err := cmd.Run(); err != nil {
			_, _ = fmt.Fprintf(stdout, "%s failed reason=baseline_failed\n", buildgate.ImportPath(*module, rel))
			_, _ = fmt.Fprintln(stderr, sensitivityFailed)
			return exitFail
		}
		body, _ := os.ReadFile(trace)
		for _, g := range buildgate.TracedGoldens(string(body), *root) {
			consumers[g] = append(consumers[g], rel)
		}
	}
	bad := false
	for _, p := range goldens {
		g := strings.TrimPrefix(p, flip+"/")
		users := consumers[g]
		if len(users) == 0 {
			_, _ = fmt.Fprintf(stdout, "golden=%s consumers none\n", g)
			continue
		}
		// A write that fails can leave the golden truncated or partly
		// written, and a consumer run on it, or on the next golden's flip
		// with this one never put back, says nothing about its
		// sensitivity: the gate fails at once (base#1469 review round 2).
		if err := os.WriteFile(p, perturbed(bodies[p]), 0o644); err != nil {
			return unwritable(err)
		}
		for _, rel := range users {
			cmd := exec.Command("go", "test", "-count=1", x+flip, "./"+rel)
			cmd.Stdout, cmd.Stderr = stderr, stderr
			if cmd.Run() == nil {
				_, _ = fmt.Fprintln(stdout, buildgate.SensitivityWeak(buildgate.ImportPath(*module, rel), g).String())
				bad = true
			}
		}
		if err := os.WriteFile(p, bodies[p], 0o644); err != nil {
			return unwritable(err)
		}
	}
	if bad {
		_, _ = fmt.Fprintln(stderr, sensitivityFailed)
		return exitFail
	}
	return exitOK
}

func ignored(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("ignored", flag.ContinueOnError)
	flags.SetOutput(stderr)
	list := flags.String("list", "", "the producer's ignored.sha256")
	ctxDir := flags.String("context", "", "the build context, bound unchanged")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *list == "" || *ctxDir == "" {
		_, _ = fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	body, err := os.ReadFile(*list)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "cg-gates: ignored: %v\n%s reason=unreadable\n", err, ignoredFailed)
		return exitFail
	}
	events := buildgate.IgnoredInputs(string(body), func(rel string) bool {
		_, err := os.Lstat(filepath.Join(*ctxDir, rel))
		return err == nil
	})
	for _, e := range events {
		_, _ = fmt.Fprintln(stdout, e.String())
	}
	if len(events) > 0 {
		_, _ = fmt.Fprintln(stderr, ignoredFailed)
		return exitFail
	}
	return exitOK
}

// goList decodes `go list -json -test -deps ./...` of the working
// directory, the package graph the mutation and sensitivity gates read.
func goList() ([]buildgate.Package, error) {
	list, err := exec.Command("go", "list", "-json", "-test", "-deps", "./...").Output()
	if err != nil {
		return nil, err
	}
	return buildgate.DecodeList(list)
}

// perturbed is a copy of b with its first byte inverted, or the one byte
// 0xff when b is empty, so a test comparing against a golden sees other
// bytes either way: an input with no tables has an empty golden
// (base#1469: the s1 fixtures empty.toml, comment_only.toml, seed.toml).
func perturbed(b []byte) []byte {
	if len(b) == 0 {
		return []byte{0xff}
	}
	out := append([]byte(nil), b...)
	out[0] ^= 0xff
	return out
}

// osExit is swapped by the tests so main itself is exercised.
var osExit = os.Exit

func main() {
	osExit(run(os.Args[1:], os.Stdout, os.Stderr))
}
