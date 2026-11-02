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
