package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const minimal = "[gui]\nmode = \"x11\"\n[network]\nmode = \"host\"\nipc = \"host\"\n"

type tc struct {
	name      string
	files     map[string]string // name -> content; written into a temp dir
	args      []string          // "{name}" expands to that file's path, "{tmpl}" to the shipped template
	setup     func(t *testing.T, dir string)
	wantCode  int
	wantOut   *string  // exact stdout when non-nil
	outHas    []string // stdout substrings
	errHas    []string // stderr substrings (all must appear)
	wantNoErr bool     // stderr must be empty
}

func s(v string) *string { return &v }

func runCase(t *testing.T, c tc) {
	t.Helper()
	dir := t.TempDir()
	for n, body := range c.files {
		if err := os.WriteFile(filepath.Join(dir, n), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if c.setup != nil {
		c.setup(t, dir)
	}
	tmpl, _ := filepath.Abs("testdata/setup.toml")
	args := make([]string, len(c.args))
	for i, a := range c.args {
		if a == "{tmpl}" {
			args[i] = tmpl
		} else if strings.HasPrefix(a, "{") && strings.HasSuffix(a, "}") {
			args[i] = filepath.Join(dir, a[1:len(a)-1])
		} else {
			args[i] = a
		}
	}
	var out, errb bytes.Buffer
	code := run(args, &out, &errb)
	if code != c.wantCode {
		t.Errorf("exit code = %d, want %d\nstdout: %q\nstderr: %q", code, c.wantCode, out.String(), errb.String())
	}
	if c.wantOut != nil && out.String() != *c.wantOut {
		if len(out.String()) > 200 || len(*c.wantOut) > 200 {
			t.Errorf("stdout mismatch (len %d, want len %d)", out.Len(), len(*c.wantOut))
		} else {
			t.Errorf("stdout = %q, want %q", out.String(), *c.wantOut)
		}
	}
	for _, h := range c.outHas {
		if !strings.Contains(out.String(), h) {
			t.Errorf("stdout %q lacks %q", out.String(), h)
		}
	}
	for _, h := range c.errHas {
		if !strings.Contains(errb.String(), h) {
			t.Errorf("stderr %q lacks %q", errb.String(), h)
		}
	}
	if c.wantNoErr && errb.Len() != 0 {
		t.Errorf("stderr not empty: %q", errb.String())
	}
	if c.wantCode != exitOK && errb.Len() == 0 {
		t.Errorf("failure exit %d with empty stderr", code)
	}
}

func TestValidate(t *testing.T) {
	for _, c := range []tc{
		{name: "shipped template is valid", args: []string{"validate", "{tmpl}"}, wantCode: 0, wantOut: s(""), wantNoErr: true},
		{name: "template plus empty overlay is valid",
			files: map[string]string{"local.toml": ""},
			args:  []string{"validate", "{tmpl}", "{local.toml}"}, wantCode: 0, wantNoErr: true},
		{name: "malformed toml names file, line and column",
			files: map[string]string{"bad.toml": "[gui]\nmode = \"x11\"\n[network]\nmode = \n"},
			args:  []string{"validate", "{bad.toml}"}, wantCode: 1,
			errHas: []string{"bad.toml:4:8: unexpected character"}},
		{name: "unterminated string",
			files: map[string]string{"bad.toml": minimal + "[project]\nname = \"oops\n"},
			args:  []string{"validate", "{bad.toml}"}, wantCode: 1, errHas: []string{"bad.toml:7:"}},
		{name: "unknown key in known table",
			files: map[string]string{"u.toml": "[gui]\nmode = \"x11\"\nbogus = 1\n[network]\nmode = \"host\"\n"},
			args:  []string{"validate", "{u.toml}"}, wantCode: 1,
			errHas: []string{"u.toml:3:1:", `unknown key "gui.bogus"`}},
		{name: "unknown table",
			files: map[string]string{"u.toml": minimal + "[nosuch]\nx = 1\n"},
			args:  []string{"validate", "{u.toml}"}, wantCode: 1,
			errHas: []string{"u.toml:6:2:", `unknown key "nosuch"`}},
		{name: "unknown key inside array-of-tables entry",
			files: map[string]string{"u.toml": minimal + "[[build.args]]\nkey = \"A\"\nvalu = \"typo\"\n"},
			args:  []string{"validate", "{u.toml}"}, wantCode: 1,
			errHas: []string{"u.toml:8:1:", `unknown key "build.args.valu"`}},
		{name: "every unknown key is reported, not only the first",
			files: map[string]string{"u.toml": minimal + "[lifecycle]\nfoo = 1\nbar = 2\n"},
			args:  []string{"validate", "{u.toml}"}, wantCode: 1,
			errHas: []string{`unknown key "lifecycle.foo"`, `unknown key "lifecycle.bar"`}},
		{name: "wrong type string for int",
			files: map[string]string{"w.toml": minimal + "[logging]\nmax_file = \"3\"\n"},
			args:  []string{"validate", "{w.toml}"}, wantCode: 1,
			errHas: []string{"w.toml:7:12:", "logging.max_file:", "cannot decode TOML string"}},
		{name: "wrong type string for bool",
			files: map[string]string{"w.toml": minimal + "[security]\nprivileged = \"yes\"\n"},
			args:  []string{"validate", "{w.toml}"}, wantCode: 1,
			errHas: []string{"w.toml:7:", "security.privileged:"}},
		{name: "wrong type scalar where array of tables expected",
			files: map[string]string{"w.toml": minimal + "[image]\nrules = \"prefix:x\"\n"},
			args:  []string{"validate", "{w.toml}"}, wantCode: 1, errHas: []string{"w.toml:7:", "image.rules"}},
		{name: "wrong type int for string",
			files: map[string]string{"w.toml": "[gui]\nmode = 5\n[network]\nmode = \"host\"\n"},
			args:  []string{"validate", "{w.toml}"}, wantCode: 1, errHas: []string{"w.toml:2:8:", "gui.mode:"}},
		{name: "empty file alone misses required fields",
			files: map[string]string{"e.toml": ""},
			args:  []string{"validate", "{e.toml}"}, wantCode: 1,
			errHas: []string{"missing required field network.mode", "missing required field gui.mode"}},
		{name: "whitespace and comments only is the same as empty",
			files: map[string]string{"e.toml": "  \n# just a comment\n\n"},
			args:  []string{"validate", "{e.toml}"}, wantCode: 1, errHas: []string{"missing required field gui.mode"}},
		{name: "missing gui.mode only",
			files: map[string]string{"m.toml": "[network]\nmode = \"host\"\n"},
			args:  []string{"validate", "{m.toml}"}, wantCode: 1, errHas: []string{"missing required field gui.mode"}},
		{name: "array entry missing required key",
			files: map[string]string{"m.toml": minimal + "[[build.args]]\nvalue = \"v\"\n"},
			args:  []string{"validate", "{m.toml}"}, wantCode: 1, errHas: []string{"missing required field build.args[0].key"}},
		{name: "image rule missing rule",
			files: map[string]string{"m.toml": minimal + "[[image.rules]]\n"},
			args:  []string{"validate", "{m.toml}"}, wantCode: 1, errHas: []string{"missing required field image.rules[0].rule"}},
		{name: "volume missing target",
			files: map[string]string{"m.toml": minimal + "[[volumes]]\nsource = \"./src\"\n"},
			args:  []string{"validate", "{m.toml}"}, wantCode: 1, errHas: []string{"missing required field volumes[0].target"}},
		{name: "volume missing source",
			files: map[string]string{"m.toml": minimal + "[[volumes]]\ntarget = \"/w\"\n"},
			args:  []string{"validate", "{m.toml}"}, wantCode: 1, errHas: []string{"missing required field volumes[0].source"}},
		{name: "cap_add entry missing cap",
			files: map[string]string{"m.toml": minimal + "[[security.cap_add]]\n"},
			args:  []string{"validate", "{m.toml}"}, wantCode: 1, errHas: []string{"missing required field security.cap_add[0].cap"}},
		{name: "port missing container",
			files: map[string]string{"m.toml": minimal + "[[network.ports]]\nhost = 80\n"},
			args:  []string{"validate", "{m.toml}"}, wantCode: 1, errHas: []string{"missing required field network.ports[0].container"}},
		{name: "port missing host",
			files: map[string]string{"m.toml": minimal + "[[network.ports]]\ncontainer = 80\n"},
			args:  []string{"validate", "{m.toml}"}, wantCode: 1, errHas: []string{"missing required field network.ports[0].host"}},
		{name: "port out of range high",
			files: map[string]string{"p.toml": minimal + "[[network.ports]]\nhost = 70000\ncontainer = 80\n"},
			args:  []string{"validate", "{p.toml}"}, wantCode: 1, errHas: []string{"network.ports[0]: port 70000 out of range"}},
		{name: "port zero out of range",
			files: map[string]string{"p.toml": minimal + "[[network.ports]]\nhost = 80\ncontainer = 0\n"},
			args:  []string{"validate", "{p.toml}"}, wantCode: 1, errHas: []string{"port 0 out of range"}},
		{name: "port boundaries 1 and 65535 are valid",
			files: map[string]string{"p.toml": minimal + "[[network.ports]]\nhost = 1\ncontainer = 65535\n"},
			args:  []string{"validate", "{p.toml}"}, wantCode: 0, wantNoErr: true},
		{name: "duplicate key names the second line",
			files: map[string]string{"d.toml": "[gui]\nmode = \"a\"\n[network]\nmode = \"host\"\nmode = \"bridge\"\n"},
			args:  []string{"validate", "{d.toml}"}, wantCode: 1, errHas: []string{"d.toml:5:1:", "key mode is already defined"}},
		{name: "duplicate table header",
			files: map[string]string{"d.toml": minimal + "[gui]\nmode = \"y\"\n"},
			args:  []string{"validate", "{d.toml}"}, wantCode: 1, errHas: []string{"d.toml:6:"}},
		{name: "invalid utf-8 is refused",
			files: map[string]string{"x.toml": minimal + "[project]\nname = \"\xff\xfe\"\n"},
			args:  []string{"validate", "{x.toml}"}, wantCode: 1, errHas: []string{"x.toml:7:"}},
		{name: "invalid environment variable name",
			files: map[string]string{"x.toml": minimal + "[environment]\n\"BAD-NAME\" = \"1\"\n"},
			args:  []string{"validate", "{x.toml}"}, wantCode: 1, errHas: []string{`environment: "BAD-NAME" is not a valid variable name`}},
		{name: "environment name starting with a digit",
			files: map[string]string{"x.toml": minimal + "[environment]\n1X = \"1\"\n"},
			args:  []string{"validate", "{x.toml}"}, wantCode: 1, errHas: []string{`"1X" is not a valid`}},
		{name: "nonexistent file",
			args: []string{"validate", "{nope.toml}"}, wantCode: 1, errHas: []string{"nope.toml: cannot read:", "no such file"}},
		{name: "directory instead of file",
			setup: func(t *testing.T, dir string) { os.Mkdir(filepath.Join(dir, "d.toml"), 0o755) },
			args:  []string{"validate", "{d.toml}"}, wantCode: 1, errHas: []string{"d.toml: cannot read:", "is a directory"}},
		{name: "unreadable file",
			files: map[string]string{"r.toml": minimal},
			setup: func(t *testing.T, dir string) {
				if os.Geteuid() == 0 {
					t.Skip("root reads mode-000 files")
				}
				os.Chmod(filepath.Join(dir, "r.toml"), 0)
			},
			args: []string{"validate", "{r.toml}"}, wantCode: 1, errHas: []string{"r.toml: cannot read:", "permission denied"}},
		{name: "a bad layer fails even when the base is good",
			files: map[string]string{"bad.toml": "[gui\n"},
			args:  []string{"validate", "{tmpl}", "{bad.toml}"}, wantCode: 1, errHas: []string{"bad.toml:1:"}},
	} {
		t.Run(c.name, func(t *testing.T) { runCase(t, c) })
	}
}

func TestGet(t *testing.T) {
	long := strings.Repeat("x", 1<<20)
	base := minimal + "[project]\nname = \"repo\"\n[[network.ports]]\nhost = 8080\ncontainer = 80\n[environment]\nA = \"1\"\nB = \"2\"\n"
	for _, c := range []tc{
		{name: "scalar from template", args: []string{"get", "gui.mode", "{tmpl}"}, wantCode: 0, wantOut: s("auto\n"), wantNoErr: true},
		{name: "int scalar", args: []string{"get", "logging.max_file", "{tmpl}"}, wantCode: 0, wantOut: s("3\n")},
		{name: "bool scalar", args: []string{"get", "lifecycle.init", "{tmpl}"}, wantCode: 0, wantOut: s("true\n")},
		{name: "false bool is set, not missing", args: []string{"get", "security.privileged", "{tmpl}"}, wantCode: 0, wantOut: s("false\n")},
		{name: "int64 beyond 2^53 is exact",
			files: map[string]string{"b.toml": minimal + "[logging]\ncontainer_log_keep = 9007199254740993\n"},
			args:  []string{"get", "logging.container_log_keep", "{b.toml}"}, wantCode: 0, wantOut: s("9007199254740993\n")},
		{name: "array index zero", args: []string{"get", "image.rules.0.rule", "{tmpl}"}, wantCode: 0, wantOut: s("prefix:docker_\n")},
		{name: "array index into array of tables", args: []string{"get", "image.rules.1.rule", "{tmpl}"}, wantCode: 0, wantOut: s("suffix:_ws\n")},
		{name: "json array", args: []string{"get", "--json", "image.rules", "{tmpl}"}, wantCode: 0,
			wantOut: s(`[{"rule":"prefix:docker_"},{"rule":"suffix:_ws"},{"rule":"@basename"}]` + "\n")},
		{name: "json scalar is quoted", args: []string{"get", "--json", "gui.mode", "{tmpl}"}, wantCode: 0, wantOut: s("\"auto\"\n")},
		{name: "explicit empty string is set", args: []string{"get", "project.name", "{tmpl}"}, wantCode: 0, wantOut: s("\n"), wantNoErr: true},
		{name: "non-scalar without --json is an error, not missing",
			args: []string{"get", "build.args", "{tmpl}"}, wantCode: 1, errHas: []string{"build.args: not a scalar (use --json)"}},
		{name: "nonexistent top-level path", args: []string{"get", "nosuch", "{tmpl}"}, wantCode: 3, errHas: []string{"get: nosuch: not set"}},
		{name: "nonexistent nested path", args: []string{"get", "gui.nosuch", "{tmpl}"}, wantCode: 3, errHas: []string{"gui.nosuch: not set"}},
		{name: "path through a scalar", args: []string{"get", "gui.mode.deeper", "{tmpl}"}, wantCode: 3, errHas: []string{"not set"}},
		{name: "array index out of range", args: []string{"get", "image.rules.3.rule", "{tmpl}"}, wantCode: 3, errHas: []string{"image.rules.3.rule: not set"}},
		{name: "negative array index", args: []string{"get", "image.rules.-1", "{tmpl}"}, wantCode: 3, errHas: []string{"not set"}},
		{name: "non-numeric array index", args: []string{"get", "image.rules.first", "{tmpl}"}, wantCode: 3, errHas: []string{"not set"}},
		{name: "absent key in schema", args: []string{"get", "--json", "network.ports", "{tmpl}"}, wantCode: 3, errHas: []string{"network.ports: not set"}},
		{name: "missing path wins over nothing on stdout", args: []string{"get", "volumes", "{tmpl}"}, wantCode: 3, wantOut: s("")},
		{name: "malformed path double dot", args: []string{"get", "gui..mode", "{tmpl}"}, wantCode: 2, errHas: []string{`malformed path "gui..mode"`}},
		{name: "malformed path leading dot", args: []string{"get", ".gui", "{tmpl}"}, wantCode: 2, errHas: []string{"malformed path"}},
		{name: "malformed path trailing dot", args: []string{"get", "gui.", "{tmpl}"}, wantCode: 2, errHas: []string{"malformed path"}},
		{name: "empty path", args: []string{"get", "", "{tmpl}"}, wantCode: 2, errHas: []string{"malformed path"}},
		{name: "get on invalid file reports the parse error, not missing",
			files: map[string]string{"bad.toml": "[gui]\nmode = \n"},
			args:  []string{"get", "gui.mode", "{bad.toml}"}, wantCode: 1, errHas: []string{"bad.toml:2:"}},
		{name: "get on nonexistent file", args: []string{"get", "gui.mode", "{nope.toml}"}, wantCode: 1, errHas: []string{"cannot read"}},
		{name: "unicode value round-trips",
			files: map[string]string{"u.toml": minimal + "[environment]\nGREETING = \"こんにちは 🌏 \\u00e9\"\n"},
			args:  []string{"get", "environment.GREETING", "{u.toml}"}, wantCode: 0, wantOut: s("こんにちは 🌏 é\n")},
		{name: "unicode quoted key",
			files: map[string]string{"u.toml": minimal + "[environment]\n\"名前\" = \"v\"\n"},
			args:  []string{"validate", "{u.toml}"}, wantCode: 1, errHas: []string{`"名前" is not a valid variable name`}},
		{name: "CRLF line endings parse and leave no CR in values",
			files: map[string]string{"c.toml": "[network]\r\nmode = \"bridge\"\r\n[gui]\r\nmode = \"x11\"\r\n"},
			args:  []string{"get", "network.mode", "{c.toml}"}, wantCode: 0, wantOut: s("bridge\n"), wantNoErr: true},
		{name: "CRLF error still reports the line",
			files: map[string]string{"c.toml": "[network]\r\nmode = \"bridge\"\r\n[gui]\r\nmode = \r\n"},
			args:  []string{"validate", "{c.toml}"}, wantCode: 1, errHas: []string{"c.toml:4:"}},
		{name: "very long value (1 MiB) is returned whole",
			files: map[string]string{"l.toml": minimal + "[project]\nname = \"" + long + "\"\n"},
			args:  []string{"get", "project.name", "{l.toml}"}, wantCode: 0, wantOut: s(long + "\n")},
		{name: "get with no operands at all", args: []string{"get"}, wantCode: 2, errHas: []string{"need DOTTED.PATH"}},
		{name: "get --json with nothing else", args: []string{"get", "--json"}, wantCode: 2, errHas: []string{"need DOTTED.PATH"}},
		{name: "missing operands", args: []string{"get", "gui.mode"}, wantCode: 2, errHas: []string{"need DOTTED.PATH and at least one FILE"}},
		{name: "missing operands with --json", args: []string{"get", "--json", "gui.mode"}, wantCode: 2, errHas: []string{"need DOTTED.PATH"}},

		// Layered merge.
		{name: "scalar override", files: map[string]string{"b.toml": base, "o.toml": "[gui]\nmode = \"wayland\"\n"},
			args: []string{"get", "gui.mode", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s("wayland\n")},
		{name: "unmentioned key in overridden table inherits", files: map[string]string{"b.toml": base, "o.toml": "[network]\nmode = \"bridge\"\n"},
			args: []string{"get", "network.ipc", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s("host\n")},
		{name: "overridden key in same table", files: map[string]string{"b.toml": base, "o.toml": "[network]\nmode = \"bridge\"\n"},
			args: []string{"get", "network.mode", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s("bridge\n")},
		{name: "absent array inherits", files: map[string]string{"b.toml": base, "o.toml": "[network]\nmode = \"bridge\"\n"},
			args: []string{"get", "--json", "network.ports", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s(`[{"container":80,"host":8080}]` + "\n")},
		{name: "explicit empty array replaces", files: map[string]string{"b.toml": base, "o.toml": "[network]\nports = []\n"},
			args: []string{"get", "--json", "network.ports", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s("[]\n")},
		{name: "array replaces whole, not by index", files: map[string]string{"o.toml": "[[image.rules]]\nrule = \"@basename\"\n"},
			args: []string{"get", "--json", "image.rules", "{tmpl}", "{o.toml}"}, wantCode: 0, wantOut: s(`[{"rule":"@basename"}]` + "\n")},
		{name: "explicit empty string overrides non-empty", files: map[string]string{"b.toml": base, "o.toml": "[project]\nname = \"\"\n"},
			args: []string{"get", "project.name", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s("\n")},
		{name: "explicit false overrides true", files: map[string]string{"o.toml": "[lifecycle]\ninit = false\n"},
			args: []string{"get", "lifecycle.init", "{tmpl}", "{o.toml}"}, wantCode: 0, wantOut: s("false\n")},
		{name: "explicit zero overrides", files: map[string]string{"o.toml": "[logging]\nmax_file = 0\n"},
			args: []string{"get", "logging.max_file", "{tmpl}", "{o.toml}"}, wantCode: 0, wantOut: s("0\n")},
		{name: "environment merges key by key", files: map[string]string{"b.toml": base, "o.toml": "[environment]\nB = \"two\"\nC = \"3\"\n"},
			args: []string{"get", "--json", "environment", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s(`{"A":"1","B":"two","C":"3"}` + "\n")},
		{name: "explicit empty [environment] is set, not missing", args: []string{"get", "--json", "environment", "{tmpl}"}, wantCode: 0, wantOut: s("{}\n")},
		{name: "absent [environment] is missing", files: map[string]string{"m.toml": minimal},
			args: []string{"get", "--json", "environment", "{m.toml}"}, wantCode: 3, errHas: []string{"environment: not set"}},
		{name: "explicit empty [environment] overlay keeps lower keys", files: map[string]string{"b.toml": base, "o.toml": "[environment]\n"},
			args: []string{"get", "--json", "environment", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s(`{"A":"1","B":"2"}` + "\n")},
		{name: "explicit empty [environment] over absent stays explicit", files: map[string]string{"b.toml": minimal, "o.toml": "[environment]\n"},
			args: []string{"get", "--json", "environment", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s("{}\n")},
		{name: "lower environment survives an overlay without one", files: map[string]string{"b.toml": base, "o.toml": "[gui]\nmode = \"off\"\n"},
			args: []string{"get", "environment.A", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s("1\n")},
		{name: "upper environment applies over a base without one", files: map[string]string{"o.toml": "[environment]\nX = \"y\"\n"},
			args: []string{"get", "environment.X", "{tmpl}", "{o.toml}"}, wantCode: 0, wantOut: s("y\n")},
		{name: "higher layer wins over three layers", files: map[string]string{"o1.toml": "[gui]\nmode = \"x11\"\n", "o2.toml": "[gui]\nmode = \"off\"\n"},
			args: []string{"get", "gui.mode", "{tmpl}", "{o1.toml}", "{o2.toml}"}, wantCode: 0, wantOut: s("off\n")},
		{name: "lower layer fills a table the upper lacks", files: map[string]string{"o.toml": "[gui]\nmode = \"x11\"\n"},
			args: []string{"get", "deploy.gpu_count", "{tmpl}", "{o.toml}"}, wantCode: 0, wantOut: s("all\n")},
		{name: "upper layer adds a table the lower lacks", files: map[string]string{"b.toml": minimal, "o.toml": "[resources]\nshm_size = \"1g\"\n"},
			args: []string{"get", "resources.shm_size", "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s("1g\n")},
		{name: "required field satisfied only by the merge", files: map[string]string{"a.toml": "[gui]\nmode = \"x11\"\n", "b.toml": "[network]\nmode = \"host\"\n"},
			args: []string{"validate", "{a.toml}", "{b.toml}"}, wantCode: 0, wantNoErr: true},
	} {
		t.Run(c.name, func(t *testing.T) { runCase(t, c) })
	}
}

func TestEnvAndUsage(t *testing.T) {
	for _, c := range []tc{
		{name: "env from template", args: []string{"env", "{tmpl}"}, wantCode: 0, wantNoErr: true,
			wantOut: s("PROJECT_NAME=''\nTARGET_ARCH=''\nBUILD_NETWORK='auto'\nGPU_MODE='auto'\nGUI_MODE='auto'\nNETWORK_MODE='host'\nIPC_MODE='host'\nPRIVILEGED='false'\n")},
		{name: "env minimal omits absent tables", files: map[string]string{"m.toml": "[gui]\nmode = \"x11\"\n[network]\nmode = \"host\"\n"},
			args: []string{"env", "{m.toml}"}, wantCode: 0, wantOut: s("GUI_MODE='x11'\nNETWORK_MODE='host'\nIPC_MODE=''\n")},
		{name: "env includes sorted environment and unicode",
			files: map[string]string{"m.toml": minimal + "[environment]\nZ = \"last\"\nA = \"日本\"\n"},
			args:  []string{"env", "{m.toml}"}, wantCode: 0,
			wantOut: s("GUI_MODE='x11'\nNETWORK_MODE='host'\nIPC_MODE='host'\nA='日本'\nZ='last'\n")},
		{name: "env refuses a value with a single quote",
			files: map[string]string{"m.toml": minimal + "[environment]\nQ = \"it's\"\n"},
			args:  []string{"env", "{m.toml}"}, wantCode: 1, wantOut: s(""), errHas: []string{"env: Q: value contains a quote or newline"}},
		{name: "env refuses a newline", files: map[string]string{"m.toml": minimal + "[environment]\nN = \"a\\nb\"\n"},
			args: []string{"env", "{m.toml}"}, wantCode: 1, wantOut: s(""), errHas: []string{"env: N:"}},
		{name: "env refuses a carriage return", files: map[string]string{"m.toml": minimal + "[environment]\nN = \"a\\rb\"\n"},
			args: []string{"env", "{m.toml}"}, wantCode: 1, errHas: []string{"env: N:"}},
		{name: "env on invalid config", files: map[string]string{"e.toml": ""}, args: []string{"env", "{e.toml}"}, wantCode: 1,
			wantOut: s(""), errHas: []string{"missing required field"}},
		{name: "no arguments", args: nil, wantCode: 2, errHas: []string{"usage:"}},
		{name: "unknown command", args: []string{"frob"}, wantCode: 2, errHas: []string{`unknown command "frob"`, "usage:"}},
		{name: "validate without files", args: []string{"validate"}, wantCode: 2, errHas: []string{"validate: at least one FILE is required"}},
		{name: "env without files", args: []string{"env"}, wantCode: 2, errHas: []string{"env: at least one FILE is required"}},
	} {
		t.Run(c.name, func(t *testing.T) { runCase(t, c) })
	}
}

// TestMergeEveryField overrides each scalar of the template, one key per
// overlay, and checks the override lands and a sibling key is inherited.
// It guards every pick() call in merge(), which a table of scenarios
// would leave half-covered.
func TestMergeEveryField(t *testing.T) {
	type field struct{ table, key, value, want, sibling, siblingWant string }
	for _, f := range []field{
		{"project", "name", `"p"`, "p", "", ""},
		{"build", "target_arch", `"arm64"`, "arm64", "network", "auto"},
		{"build", "network", `"host"`, "host", "target_arch", ""},
		{"deploy", "gpu_mode", `"off"`, "off", "gpu_count", "all"},
		{"deploy", "gpu_count", `"1"`, "1", "gpu_mode", "auto"},
		{"deploy", "gpu_capabilities", `"gpu"`, "gpu", "gpu_runtime", "auto"},
		{"deploy", "gpu_runtime", `"runc"`, "runc", "dri_groups", "auto"},
		{"deploy", "dri_groups", `"44"`, "44", "gpu_capabilities", "gpu compute utility graphics"},
		{"lifecycle", "restart", `"no"`, "no", "init", "true"},
		{"lifecycle", "init", `false`, "false", "restart", "unless-stopped"},
		{"gui", "mode", `"x11"`, "x11", "", ""},
		{"network", "mode", `"bridge"`, "bridge", "ipc", "host"},
		{"network", "ipc", `"private"`, "private", "pid", "private"},
		{"network", "pid", `"host"`, "host", "mode", "host"},
		{"network", "network_name", `"n"`, "n", "mode", "host"},
		{"security", "privileged", `true`, "true", "", ""},
		{"resources", "shm_size", `"1g"`, "1g", "", ""},
		{"logging", "driver", `"local"`, "local", "max_size", "10m"},
		{"logging", "max_size", `"1m"`, "1m", "driver", "json-file"},
		{"logging", "max_file", `9`, "9", "compress", "true"},
		{"logging", "compress", `false`, "false", "max_file", "3"},
		{"logging", "local_path", `"./log/"`, "./log/", "driver", "json-file"},
		{"logging", "container_log_keep", `5`, "5", "container_log_days", "14"},
		{"logging", "container_log_days", `6`, "6", "container_log_keep", "20"},
		{"logging", "wrapper_transcript", `false`, "false", "wrapper_transcript_keep", "20"},
		{"logging", "wrapper_transcript_keep", `7`, "7", "wrapper_transcript_days", "14"},
		{"logging", "wrapper_transcript_days", `8`, "8", "wrapper_transcript", "true"},
	} {
		overlay := "[" + f.table + "]\n" + f.key + " = " + f.value + "\n"
		t.Run(f.table+"."+f.key, func(t *testing.T) {
			runCase(t, tc{files: map[string]string{"o.toml": overlay},
				args: []string{"get", f.table + "." + f.key, "{tmpl}", "{o.toml}"}, wantCode: 0, wantOut: s(f.want + "\n")})
			if f.sibling != "" {
				runCase(t, tc{files: map[string]string{"o.toml": overlay},
					args: []string{"get", f.table + "." + f.sibling, "{tmpl}", "{o.toml}"}, wantCode: 0, wantOut: s(f.siblingWant + "\n")})
			}
		})
	}
	for _, arr := range []struct{ name, base, overlay, path, want string }{
		{"build.args", "[[build.args]]\nkey = \"A\"\n", "[build]\nnetwork = \"host\"\n[[build.args]]\nkey = \"B\"\n", "build.args", `[{"key":"B"}]`},
		{"security.cap_add", "[[security.cap_add]]\ncap = \"A\"\n", "[security]\nprivileged = true\n[[security.cap_add]]\ncap = \"B\"\n", "security.cap_add", `[{"cap":"B"}]`},
		{"volumes", "[[volumes]]\nsource = \"a\"\ntarget = \"/a\"\n", "volumes = []\n", "volumes", `[]`},
		{"volumes inherit", "[[volumes]]\nsource = \"a\"\ntarget = \"/a\"\n", "[gui]\nmode = \"off\"\n", "volumes", `[{"source":"a","target":"/a"}]`},
		{"cap_add inherit across security overlay", "[[security.cap_add]]\ncap = \"A\"\n", "[security]\nprivileged = true\n", "security.cap_add", `[{"cap":"A"}]`},
		{"build.args inherit across build overlay", "[[build.args]]\nkey = \"A\"\n", "[build]\nnetwork = \"host\"\n", "build.args", `[{"key":"A"}]`},
	} {
		t.Run(arr.name, func(t *testing.T) {
			runCase(t, tc{files: map[string]string{"b.toml": minimal + arr.base, "o.toml": arr.overlay},
				args: []string{"get", "--json", arr.path, "{b.toml}", "{o.toml}"}, wantCode: 0, wantOut: s(arr.want + "\n")})
		})
	}
}
