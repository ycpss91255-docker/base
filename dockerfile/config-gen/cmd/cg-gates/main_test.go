package main

import (
	"bytes"
	"os"
	"path/filepath"
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
