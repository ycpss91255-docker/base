package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// cg-gates ratchet (base#1465): 0 and no output when every package holds
// its floor; 1 with one cg_event line per refusal on stdout and the
// coverage gate id on stderr; 1 on a measurement it cannot read; 2 on
// usage.

const mod = "example.com/m"

func tree(t *testing.T, floor, measured string) (dir string) {
	t.Helper()
	dir = t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "floors.d"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"floors.d/s1e.txt": "a " + floor + "\n",
		"base":             "absent\n",
		"measured":         measured,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func args(dir string) []string {
	return []string{"ratchet", "--measured", filepath.Join(dir, "measured"), "--floors", filepath.Join(dir, "floors.d"),
		"--base", filepath.Join(dir, "base"), "--module", mod}
}

func TestRun(t *testing.T) {
	cases := []struct {
		name        string
		floor       string
		measured    string
		args        func(dir string) []string
		status      int
		out, errOut string
	}{
		{"green", "95.0", mod + "/a\t1000\t955\n", args, 0, "", ""},
		{"a refusal", "95.0", mod + "/a\t100\t90\n", args, 1,
			"cg_event config_gen_coverage_floor_below pkg=a measured=90.0 floor=95.0\n", "config_gen_gate_coverage_failed\n"},
		{"an unreadable measurement", "95.0", "x\n", args, 1, "", ""},
		{"no subcommand", "95.0", "", func(string) []string { return nil }, 2, "", ""},
		{"another subcommand", "95.0", "", func(string) []string { return []string{"admit"} }, 2, "", ""},
		{"a flag left out", "95.0", "", func(dir string) []string { return args(dir)[:7] }, 2, "", ""},
		{"an unknown flag", "95.0", "", func(dir string) []string { return append(args(dir), "--x") }, 2, "", ""},
		{"an extra argument", "95.0", "", func(dir string) []string { return append(args(dir), "x") }, 2, "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := tree(t, c.floor, c.measured)
			var out, errOut bytes.Buffer
			if got := run(c.args(dir), &out, &errOut); got != c.status {
				t.Fatalf("status %d, want %d; stderr %q", got, c.status, errOut.String())
			}
			if out.String() != c.out {
				t.Errorf("stdout %q, want %q", out.String(), c.out)
			}
			if c.errOut != "" && errOut.String() != c.errOut {
				t.Errorf("stderr %q, want %q", errOut.String(), c.errOut)
			}
			if c.status == 1 && c.errOut == "" && !bytes.Contains(errOut.Bytes(), []byte("config_gen_gate_coverage_failed reason=unreadable")) {
				t.Errorf("stderr %q names no coverage gate refusal", errOut.String())
			}
		})
	}
}

func TestMain_ExitsWithRunStatus(t *testing.T) {
	var got int
	osExit = func(code int) { got = code }
	defer func() { osExit = os.Exit }()
	saved := os.Args
	os.Args = []string{"cg-gates"}
	defer func() { os.Args = saved }()
	main()
	if got != exitUsage {
		t.Errorf("main exited %d, want %d", got, exitUsage)
	}
}

// cg-gates mutation (base#1467), with a fake gremlins first on PATH that
// logs its argv and copies <reports>/../fake/<n>.json to its -o path,
// where <n> is the package argument with . and / as _. A fake/<n>.fail
// file makes it exit 3 instead.

const fakeGremlins = `#!/bin/sh
printf '%s\n' "$*" >>"${0%/*}/argv"
n="$(printf '%s' "$8" | tr ./ __)"
[ -e "${0%/*}/${n}.fail" ] && exit 3
[ -e "${0%/*}/${n}.json" ] && cp "${0%/*}/${n}.json" "$7"
exit 0
`

// fakeGo stands in for `go list -json -test -deps ./...` of a module
// holding the packages the manifests name: its root and internal/a.
const fakeGo = `#!/bin/sh
printf '%s\n' '{"ImportPath":"` + mod + `"}' '{"ImportPath":"` + mod + `/internal/a"}'
`

// killed is a gremlins report with k KILLED and l LIVED mutants.
func killed(k, l int) string {
	s := `{"files":[{"file_name":"a.go","mutations":[`
	for i := 0; i < k+l; i++ {
		if i > 0 {
			s += ","
		}
		st := "KILLED"
		if i >= k {
			st = "LIVED"
		}
		s += `{"status":"` + st + `"}`
	}
	return s + `]}],"test_efficacy":100}`
}

// fake writes the fake gremlins and its per-package files under
// dir/fake, puts it first on PATH, and returns dir/fake.
func fake(t *testing.T, dir string, files map[string]string) string {
	t.Helper()
	bin := filepath.Join(dir, "fake")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	files["gremlins"] = fakeGremlins
	if _, ok := files["go"]; !ok {
		files["go"] = fakeGo
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return bin
}

const mhead = "base=a head=b dirty=yes context=pr\n"

func TestMutation(t *testing.T) {
	cases := []struct {
		name     string
		manifest string
		files    map[string]string
		status   int
		out      string
		argv     string
	}{
		{"a package that kills every mutant", mhead + "M\tdockerfile/config-gen/internal/a/a_test.go\n",
			map[string]string{"__internal_a.json": killed(2, 0)}, 0,
			mod + "/internal/a ok efficacy=100.0\n",
			"unleash --workers 1 --timeout-coefficient 10 -o REPORTS/0.json ./internal/a\n"},
		{"exactly the floor", mhead + "M\tdockerfile/config-gen/internal/a/a.go\n",
			map[string]string{"__internal_a.json": killed(9, 1)}, 0,
			mod + "/internal/a ok efficacy=90.0\n", ""},
		{"a surviving mutant, whatever gremlins exits", mhead + "M\tdockerfile/config-gen/internal/a/a_test.go\n",
			map[string]string{"__internal_a.json": killed(0, 2)}, 1,
			mod + "/internal/a failed reason=below measured=0.0\n", ""},
		{"just under the floor", mhead + "M\tdockerfile/config-gen/internal/a/a.go\n",
			map[string]string{"__internal_a.json": killed(8, 1)}, 1,
			mod + "/internal/a failed reason=below measured=88.8\n", ""},
		{"one red package does not stop the next", mhead +
			"M\tdockerfile/config-gen/internal/a/a.go\nM\tdockerfile/config-gen/x.go\n",
			map[string]string{"___.json": killed(1, 2), "__internal_a.json": killed(3, 0)}, 1,
			mod + " failed reason=below measured=33.3\n" + mod + "/internal/a ok efficacy=100.0\n",
			"unleash --workers 1 --timeout-coefficient 10 -o REPORTS/0.json ./.\n" +
				"unleash --workers 1 --timeout-coefficient 10 -o REPORTS/1.json ./internal/a\n"},
		{"gremlins exits non-zero", mhead + "M\tdockerfile/config-gen/internal/a/a.go\n",
			map[string]string{"__internal_a.fail": "", "__internal_a.json": killed(1, 0)}, 1,
			mod + "/internal/a failed reason=gremlins_failed\n", ""},
		{"no report written", mhead + "M\tdockerfile/config-gen/internal/a/a.go\n",
			map[string]string{}, 1, mod + "/internal/a failed reason=report\n", ""},
		{"a report it cannot read", mhead + "M\tdockerfile/config-gen/internal/a/a.go\n",
			map[string]string{"__internal_a.json": "x"}, 1, mod + "/internal/a failed reason=report\n", ""},
		{"no Go file", mhead + "none: no-go-change\n", map[string]string{}, 0, "mutation targets none\n", ""},
		{"a module file the mapping refuses", mhead + "A\tdockerfile/config-gen/notes.txt\n",
			map[string]string{}, 1, "cg_event config_gen_mutation_unmapped file=dockerfile/config-gen/notes.txt\n", ""},
		{"go list fails", mhead + "M\tdockerfile/config-gen/internal/a/a.go\n",
			map[string]string{"go": "#!/bin/sh\nexit 1\n"}, 1, "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			bin := fake(t, dir, c.files)
			reports := filepath.Join(dir, "reports")
			if err := os.Mkdir(reports, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "manifest"), []byte(c.manifest), 0o644); err != nil {
				t.Fatal(err)
			}
			var out, errOut bytes.Buffer
			got := run([]string{"mutation", "--manifest", filepath.Join(dir, "manifest"), "--module", mod,
				"--reports", reports}, &out, &errOut)
			if got != c.status {
				t.Fatalf("status %d, want %d; stderr %q", got, c.status, errOut.String())
			}
			if out.String() != c.out {
				t.Errorf("stdout %q, want %q", out.String(), c.out)
			}
			if gate := bytes.Contains(errOut.Bytes(), []byte("config_gen_gate_mutation_failed")); gate != (c.status == 1) {
				t.Errorf("stderr %q: gate id present %v, want %v", errOut.String(), gate, c.status == 1)
			}
			if c.argv != "" {
				argv, _ := os.ReadFile(filepath.Join(bin, "argv"))
				if want := strings.ReplaceAll(c.argv, "REPORTS", reports); string(argv) != want {
					t.Errorf("gremlins argv %q, want %q", argv, want)
				}
			}
		})
	}
}

func TestMutationRefusesBeforeGremlins(t *testing.T) {
	dir := t.TempDir()
	cases := []struct {
		name   string
		args   []string
		status int
	}{
		{"no manifest", []string{"mutation", "--manifest", filepath.Join(dir, "absent"), "--module", mod, "--reports", dir}, 1},
		{"a flag left out", []string{"mutation", "--manifest", "m", "--module", mod}, 2},
		{"no module", []string{"mutation", "--manifest", "m", "--module", "", "--reports", dir}, 2},
		{"no manifest flag value", []string{"mutation", "--manifest", "", "--module", mod, "--reports", dir}, 2},
		{"an unknown flag", []string{"mutation", "--x"}, 2},
		{"an extra argument", []string{"mutation", "--manifest", "m", "--module", mod, "--reports", dir, "x"}, 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var out, errOut bytes.Buffer
			if got := run(c.args, &out, &errOut); got != c.status {
				t.Fatalf("status %d, want %d; stderr %q", got, c.status, errOut.String())
			}
			if out.Len() != 0 {
				t.Errorf("stdout %q, want none", out.String())
			}
			if c.status == 1 && !bytes.Contains(errOut.Bytes(), []byte("config_gen_gate_mutation_failed reason=unreadable")) {
				t.Errorf("stderr %q names no mutation gate refusal", errOut.String())
			}
		})
	}
}

// cg-gates sensitivity (base#1467), with a fake go first on PATH. `go list`
// prints fake/list.json. `go test` logs its argv to fake/argv; with
// CG_TESTCORPUS_TRACE set (the traced baseline) it fails when
// fake/<n>.basefail exists and else appends fake/<n>.trace to the trace
// file, <n> being the package argument with . and / as _; without it (a
// flipped run) it fails only when the root-relative file fake/<n>.reads
// names differs in the root it was linked with from the same file under
// fake/orig's root, so a package with no .reads file passes whatever byte
// is flipped.
const fakeSensitivityGo = `#!/bin/sh
d="${0%/*}"
if [ "$1" = list ]; then exec cat "$d/list.json"; fi
printf '%s\n' "$*" >>"$d/argv"
for a; do
  case "$a" in -ldflags=*) r="${a#*.root=}" ;; esac
  p="$a"
done
n="$(printf '%s' "$p" | tr ./ __)"
if [ -n "${CG_TESTCORPUS_TRACE:-}" ]; then
  [ -e "$d/$n.basefail" ] && exit 1
  [ -e "$d/$n.trace" ] && cat "$d/$n.trace" >>"$CG_TESTCORPUS_TRACE"
  exit 0
fi
[ -e "$d/$n.reads" ] || exit 0
f="$(cat "$d/$n.reads")"
cmp -s "$r/$f" "$(cat "$d/orig")/$f" && exit 0
exit 1
`

// importers is a go list of three test binaries that depend on
// testcorpus (internal/a, internal/w, internal/testcorpus) and one that
// does not (internal/x).
const importers = `{"ImportPath":"` + mod + `/internal/testcorpus"}
{"ImportPath":"` + mod + `/internal/testcorpus.test","Deps":["` + mod + `/internal/testcorpus [` + mod + `/internal/testcorpus.test]"]}
{"ImportPath":"` + mod + `/internal/a.test","Deps":["` + mod + `/internal/testcorpus"]}
{"ImportPath":"` + mod + `/internal/w.test","Deps":["` + mod + `/internal/testcorpus"]}
{"ImportPath":"` + mod + `/internal/x.test","Deps":["fmt"]}
`

const globSrc = "package testcorpus\n\nfunc Glob() {}\n"

// sensTree writes files (paths relative to a new directory, every ROOT in
// a body replaced by that directory's root/) and the fake go, puts the
// fake first on PATH, makes mod/ the working directory, and returns the
// directory.
func sensTree(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	files["fake/go"] = fakeSensitivityGo
	files["fake/orig"] = filepath.Join(dir, "root")
	if err := os.MkdirAll(filepath.Join(dir, "work"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "mod"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range files {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(strings.ReplaceAll(body, "ROOT", filepath.Join(dir, "root"))), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", filepath.Join(dir, "fake")+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Chdir(filepath.Join(dir, "mod"))
	return dir
}

func sensArgs(dir string) []string {
	return []string{"sensitivity", "--module", mod, "--root", filepath.Join(dir, "root"),
		"--work", filepath.Join(dir, "work")}
}

// corpus is a root with two goldens and a corpus file, the testcorpus
// source and the go list above; extra adds the per-package fake files and
// replaces any of these, a "-" body leaving that file out.
func corpus(extra map[string]string) map[string]string {
	files := map[string]string{}
	files["root/golden/s1/a.golden"] = "a golden\n"
	files["root/golden/s1/b.golden"] = "b golden\n"
	files["root/corpus/s1/seed.toml"] = "x = 1\n"
	files["mod/internal/testcorpus/testcorpus.go"] = globSrc
	files["fake/list.json"] = importers
	for k, v := range extra {
		files[k] = v
		if v == "-" {
			delete(files, k)
		}
	}
	return files
}

func TestSensitivity(t *testing.T) {
	const weak = "cg_event config_gen_corpus_sensitivity_weak pkg=" + mod
	strongA := map[string]string{"fake/__internal_a.trace": "ROOT/golden/s1/a.golden\n", "fake/__internal_a.reads": "golden/s1/a.golden"}
	with := func(base map[string]string, kv ...string) map[string]string {
		out := map[string]string{}
		for k, v := range base {
			out[k] = v
		}
		for i := 0; i+1 < len(kv); i += 2 {
			out[kv[i]] = kv[i+1]
		}
		return out
	}
	cases := []struct {
		name   string
		extra  map[string]string
		status int
		out    string
	}{
		{"a consumer that reads its golden, and a golden nobody is handed", strongA, 0,
			"golden=golden/s1/b.golden consumers none\n"},
		{"a consumer handed a golden it never reads", with(strongA, "fake/__internal_w.trace", "ROOT/golden/s1/a.golden\n"), 1,
			weak + "/internal/w file=golden/s1/a.golden\n" + "golden=golden/s1/b.golden consumers none\n"},
		{"each golden is flipped alone and put back before the next",
			with(strongA, "fake/__internal_w.trace", "ROOT/golden/s1/b.golden\nROOT/golden/s1/a.golden\n",
				"fake/__internal_w.reads", "golden/s1/a.golden"), 1,
			weak + "/internal/w file=golden/s1/b.golden\n"},
		{"an empty golden a consumer is handed", with(strongA, "root/golden/s1/a.golden", ""), 1,
			"golden=golden/s1/a.golden failed reason=empty\ngolden=golden/s1/b.golden consumers none\n"},
		{"a baseline that fails", with(strongA, "fake/__internal_a.basefail", ""), 1,
			mod + "/internal/a failed reason=baseline_failed\n"},
		{"a testcorpus with no top-level Glob", map[string]string{"mod/internal/testcorpus/testcorpus.go": "package testcorpus\n"}, 1,
			"cg_event config_gen_corpus_sensitivity_invalid reason=glob_not_found\n"},
		{"go list fails", map[string]string{"fake/list.json": "-"}, 1, ""},
		{"go list prints what it cannot decode", map[string]string{"fake/list.json": "x"}, 1, ""},
		{"no testcorpus source", map[string]string{"mod/internal/testcorpus/testcorpus.go": "-"}, 1, ""},
		{"no corpus root", map[string]string{"root/golden/s1/a.golden": "-", "root/golden/s1/b.golden": "-", "root/corpus/s1/seed.toml": "-"}, 1, ""},
		{"a corpus root with no golden directory",
			map[string]string{"root/golden/s1/a.golden": "-", "root/golden/s1/b.golden": "-"}, 1, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := sensTree(t, corpus(c.extra))
			var out, errOut bytes.Buffer
			if got := run(sensArgs(dir), &out, &errOut); got != c.status {
				t.Fatalf("status %d, want %d; stderr %q", got, c.status, errOut.String())
			}
			if out.String() != c.out {
				t.Errorf("stdout %q, want %q", out.String(), c.out)
			}
			if gate := bytes.Contains(errOut.Bytes(), []byte("config_gen_gate_corpus_sensitivity_failed")); gate != (c.status == 1) {
				t.Errorf("stderr %q: gate id present %v, want %v", errOut.String(), gate, c.status == 1)
			}
			if c.status == 1 && c.out == "" && !bytes.Contains(errOut.Bytes(), []byte("_failed reason=unreadable")) {
				t.Errorf("stderr %q names no unreadable refusal", errOut.String())
			}
		})
	}
}

// The traced baseline builds the packages with the overlay against the
// corpus root; each flipped run builds the consumers of one golden with no
// overlay against the copy, which ends as the root it was copied from.
func TestSensitivityRunsTheOverlayThenTheCopy(t *testing.T) {
	dir := sensTree(t, corpus(map[string]string{"fake/__internal_a.trace": "ROOT/golden/s1/a.golden\n", "fake/__internal_a.reads": "golden/s1/a.golden"}))
	var out, errOut bytes.Buffer
	if got := run(sensArgs(dir), &out, &errOut); got != 0 {
		t.Fatalf("status %d, want 0; stderr %q", got, errOut.String())
	}
	root, work := filepath.Join(dir, "root"), filepath.Join(dir, "work")
	x := "-ldflags=-X=" + mod + "/internal/testcorpus.root="
	base := "test -count=1 -overlay " + work + "/overlay.json " + x + root
	want := base + " ./internal/a\n" + base + " ./internal/testcorpus\n" + base + " ./internal/w\n" +
		"test -count=1 " + x + work + "/corpus ./internal/a\n"
	if argv, _ := os.ReadFile(filepath.Join(dir, "fake", "argv")); string(argv) != want {
		t.Errorf("go argv %q, want %q", argv, want)
	}
	ov, _ := os.ReadFile(filepath.Join(work, "overlay.json"))
	tc := filepath.Join(dir, "mod", "internal", "testcorpus")
	wantOv := `{"Replace":{"` + tc + `/testcorpus.go":"` + work + `/testcorpus.go","` +
		tc + `/zz_cgtrace.go":"` + work + `/zz_cgtrace.go"}}`
	if string(ov) != wantOv {
		t.Errorf("overlay %s, want %s", ov, wantOv)
	}
	if src, _ := os.ReadFile(filepath.Join(work, "testcorpus.go")); string(src) != "package testcorpus\n\nfunc cgUntracedGlob() {}\n" {
		t.Errorf("overlay testcorpus.go %q", src)
	}
	if src, _ := os.ReadFile(filepath.Join(work, "zz_cgtrace.go")); !strings.Contains(string(src), "cgUntracedGlob(t, pattern)") {
		t.Errorf("overlay zz_cgtrace.go %q", src)
	}
	for _, r := range []string{root, work + "/corpus"} {
		if b, _ := os.ReadFile(filepath.Join(r, "golden", "s1", "a.golden")); string(b) != "a golden\n" {
			t.Errorf("%s/golden/s1/a.golden = %q after the gate, want it as it was", r, b)
		}
	}
}

func TestSensitivityUsage(t *testing.T) {
	for _, args := range [][]string{
		{"sensitivity"},
		{"sensitivity", "--module", mod, "--root", "r"},
		{"sensitivity", "--module", "", "--root", "r", "--work", "w"},
		{"sensitivity", "--x"},
		{"sensitivity", "--module", mod, "--root", "r", "--work", "w", "x"},
	} {
		var out, errOut bytes.Buffer
		if got := run(args, &out, &errOut); got != exitUsage {
			t.Errorf("%q: status %d, want %d", args, got, exitUsage)
		}
		if out.Len() != 0 {
			t.Errorf("%q: stdout %q, want none", args, out.String())
		}
	}
}

// cg-gates ignored (base#1467): 0 and no output when the context holds no
// file ignored.sha256 lists; 1 with one cg_event line per listed file it
// holds on stdout and the gate id on stderr; 1 on a list it cannot read;
// 2 on usage.
func TestIgnored(t *testing.T) {
	const sha = "\t0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
	dir := t.TempDir()
	ctx := filepath.Join(dir, "ctx")
	if err := os.MkdirAll(filepath.Join(ctx, "cmd", "x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ctx, "cmd", "x", "zz.go"), []byte("package x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	held := filepath.Join(dir, "held")
	gone := filepath.Join(dir, "gone")
	for name, body := range map[string]string{
		held: "dockerfile/config-gen/gone.go" + sha + "dockerfile/config-gen/cmd/x/zz.go" + sha,
		gone: "dockerfile/config-gen/gone.go" + sha,
	} {
		if err := os.WriteFile(name, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cases := []struct {
		name        string
		args        []string
		status      int
		out, errOut string
	}{
		{"a listed file in the context", []string{"ignored", "--list", held, "--context", ctx}, 1,
			"cg_event config_gen_mutation_ignored_input file=dockerfile/config-gen/cmd/x/zz.go\n",
			"config_gen_gate_ignored_failed\n"},
		{"no listed file in the context", []string{"ignored", "--list", gone, "--context", ctx}, 0, "", ""},
		{"an unreadable list", []string{"ignored", "--list", filepath.Join(dir, "absent"), "--context", ctx}, 1, "", ""},
		{"a flag left out", []string{"ignored", "--list", held}, 2, "", ""},
		{"an empty list flag", []string{"ignored", "--list", "", "--context", ctx}, 2, "", ""},
		{"an unknown flag", []string{"ignored", "--x"}, 2, "", ""},
		{"an extra argument", []string{"ignored", "--list", held, "--context", ctx, "x"}, 2, "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var out, errOut bytes.Buffer
			if got := run(c.args, &out, &errOut); got != c.status {
				t.Fatalf("status %d, want %d; stderr %q", got, c.status, errOut.String())
			}
			if out.String() != c.out {
				t.Errorf("stdout %q, want %q", out.String(), c.out)
			}
			switch {
			case c.status == 0 && errOut.Len() != 0:
				t.Errorf("stderr %q, want none", errOut.String())
			case c.status == 1 && c.errOut != "" && errOut.String() != c.errOut:
				t.Errorf("stderr %q, want %q", errOut.String(), c.errOut)
			case c.status == 1 && c.errOut == "" &&
				!strings.Contains(errOut.String(), "config_gen_gate_ignored_failed reason=unreadable"):
				t.Errorf("stderr %q names no ignored gate refusal", errOut.String())
			}
		})
	}
}
