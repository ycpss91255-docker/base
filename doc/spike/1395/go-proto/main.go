// Command setupgen is a throwaway prototype for base#1395: read layered
// setup.toml files into typed structs and answer validate / get / env.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/pelletier/go-toml/v2"
)

// Exit codes. A missing get path is distinct from every failure.
const (
	exitOK      = 0
	exitError   = 1 // unreadable, malformed, invalid, not a scalar
	exitUsage   = 2
	exitMissing = 3 // get: path not present in the merged config
)

const usage = `usage:
  setupgen validate FILE...
  setupgen get [--json] DOTTED.PATH FILE...
  setupgen env FILE...
FILEs are layers, lowest precedence first.`

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "validate", "env":
		if len(rest) == 0 {
			fmt.Fprintf(stderr, "setupgen: %s: at least one FILE is required\n", cmd)
			return exitUsage
		}
		cfg, code := loadAll(rest, stderr)
		if code != exitOK {
			return code
		}
		if cmd == "validate" {
			return exitOK
		}
		return renderEnv(cfg, stdout, stderr)
	case "get":
		asJSON := false
		if len(rest) > 0 && rest[0] == "--json" {
			asJSON, rest = true, rest[1:]
		}
		if len(rest) < 2 {
			fmt.Fprintln(stderr, "setupgen: get: need DOTTED.PATH and at least one FILE")
			return exitUsage
		}
		cfg, code := loadAll(rest[1:], stderr)
		if code != exitOK {
			return code
		}
		return get(cfg, rest[0], asJSON, stdout, stderr)
	default:
		fmt.Fprintf(stderr, "setupgen: unknown command %q\n%s\n", cmd, usage)
		return exitUsage
	}
}

func loadAll(paths []string, stderr io.Writer) (*Config, int) {
	merged := &Config{}
	for _, p := range paths {
		layer, err := loadFile(p)
		if err != nil {
			fmt.Fprintf(stderr, "setupgen: %v\n", err)
			return nil, exitError
		}
		merged = merge(merged, layer)
	}
	if errs := validate(merged); len(errs) > 0 {
		for _, e := range errs {
			fmt.Fprintf(stderr, "setupgen: %s\n", e)
		}
		return nil, exitError
	}
	return merged, exitOK
}

func loadFile(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("%s: cannot read: %w", path, err)
	}
	cfg := &Config{}
	dec := toml.NewDecoder(bytes.NewReader(raw)).DisallowUnknownFields()
	if err := dec.Decode(cfg); err != nil {
		return nil, describe(path, err)
	}
	return cfg, nil
}

// describe turns a go-toml error into "path:line:col: message".
func describe(path string, err error) error {
	var strict *toml.StrictMissingError
	if errors.As(err, &strict) {
		lines := make([]string, 0, len(strict.Errors))
		for i := range strict.Errors {
			e := &strict.Errors[i]
			row, col := e.Position()
			lines = append(lines, fmt.Sprintf("%s:%d:%d: unknown key %q", path, row, col, strings.Join(e.Key(), ".")))
		}
		return errors.New(strings.Join(lines, "\nsetupgen: "))
	}
	var de *toml.DecodeError
	if errors.As(err, &de) {
		row, col := de.Position()
		msg := strings.TrimPrefix(de.Error(), "toml: ")
		if k := de.Key(); len(k) > 0 {
			msg = strings.Join(k, ".") + ": " + msg
		}
		return fmt.Errorf("%s:%d:%d: %s", path, row, col, msg)
	}
	return fmt.Errorf("%s: %w", path, err)
}

// validate checks the merged result: required keys and per-entry fields.
func validate(c *Config) []string {
	var errs []string
	need := func(ok bool, path string) {
		if !ok {
			errs = append(errs, "missing required field "+path)
		}
	}
	need(c.Network != nil && c.Network.Mode != nil, "network.mode")
	need(c.GUI != nil && c.GUI.Mode != nil, "gui.mode")
	if c.Image != nil && c.Image.Rules != nil {
		for i, r := range *c.Image.Rules {
			need(r.Rule != nil, fmt.Sprintf("image.rules[%d].rule", i))
		}
	}
	if c.Build != nil && c.Build.Args != nil {
		for i, a := range *c.Build.Args {
			need(a.Key != nil, fmt.Sprintf("build.args[%d].key", i))
		}
	}
	if c.Network != nil && c.Network.Ports != nil {
		for i, p := range *c.Network.Ports {
			need(p.Host != nil, fmt.Sprintf("network.ports[%d].host", i))
			need(p.Container != nil, fmt.Sprintf("network.ports[%d].container", i))
			for _, v := range []*int64{p.Host, p.Container} {
				if v != nil && (*v < 1 || *v > 65535) {
					errs = append(errs, fmt.Sprintf("network.ports[%d]: port %d out of range 1-65535", i, *v))
				}
			}
		}
	}
	if c.Security != nil && c.Security.CapAdd != nil {
		for i, x := range *c.Security.CapAdd {
			need(x.Cap != nil, fmt.Sprintf("security.cap_add[%d].cap", i))
		}
	}
	if c.Volumes != nil {
		for i, v := range *c.Volumes {
			need(v.Source != nil, fmt.Sprintf("volumes[%d].source", i))
			need(v.Target != nil, fmt.Sprintf("volumes[%d].target", i))
		}
	}
	env := envOf(c)
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if !envName.MatchString(k) {
			errs = append(errs, fmt.Sprintf("environment: %q is not a valid variable name", k))
		}
	}
	return errs
}

func envOf(c *Config) map[string]string {
	if c.Environment == nil {
		return nil
	}
	return *c.Environment
}

var envName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// tree is the merged config as generic JSON values; absent keys are
// omitted (omitempty on nil pointers), explicit "" / [] are kept.
func tree(c *Config) any {
	b, err := json.Marshal(c)
	if err != nil {
		panic(err) // Config holds only strings, ints, bools, slices, maps
	}
	var t any
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber() // int64 values above 2^53 must not round through float64
	if err := dec.Decode(&t); err != nil {
		panic(err)
	}
	return t
}

func get(c *Config, path string, asJSON bool, stdout, stderr io.Writer) int {
	if path == "" || strings.HasPrefix(path, ".") || strings.HasSuffix(path, ".") || strings.Contains(path, "..") {
		fmt.Fprintf(stderr, "setupgen: get: malformed path %q\n", path)
		return exitUsage
	}
	node := tree(c)
	for _, part := range strings.Split(path, ".") {
		switch n := node.(type) {
		case map[string]any:
			v, ok := n[part]
			if !ok {
				fmt.Fprintf(stderr, "setupgen: get: %s: not set\n", path)
				return exitMissing
			}
			node = v
		case []any:
			i, err := strconv.Atoi(part)
			if err != nil || i < 0 || i >= len(n) {
				fmt.Fprintf(stderr, "setupgen: get: %s: not set\n", path)
				return exitMissing
			}
			node = n[i]
		default:
			fmt.Fprintf(stderr, "setupgen: get: %s: not set\n", path)
			return exitMissing
		}
	}
	if asJSON {
		b, _ := json.Marshal(node)
		fmt.Fprintln(stdout, string(b))
		return exitOK
	}
	switch v := node.(type) {
	case string:
		fmt.Fprintln(stdout, v)
	case json.Number:
		fmt.Fprintln(stdout, v.String())
	case bool:
		fmt.Fprintln(stdout, strconv.FormatBool(v))
	default:
		fmt.Fprintf(stderr, "setupgen: get: %s: not a scalar (use --json)\n", path)
		return exitError
	}
	return exitOK
}

// renderEnv writes the .env subset. Values are single-quoted; a value
// that cannot be single-quoted safely is refused rather than mangled.
func renderEnv(c *Config, stdout, stderr io.Writer) int {
	str := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	var lines [][2]string
	add := func(k, v string) { lines = append(lines, [2]string{k, v}) }
	if c.Project != nil {
		add("PROJECT_NAME", str(c.Project.Name))
	}
	if c.Build != nil {
		add("TARGET_ARCH", str(c.Build.TargetArch))
		add("BUILD_NETWORK", str(c.Build.Network))
	}
	if c.Deploy != nil {
		add("GPU_MODE", str(c.Deploy.GPUMode))
	}
	add("GUI_MODE", str(c.GUI.Mode))
	add("NETWORK_MODE", str(c.Network.Mode))
	add("IPC_MODE", str(c.Network.IPC))
	if c.Security != nil && c.Security.Privileged != nil {
		add("PRIVILEGED", strconv.FormatBool(*c.Security.Privileged))
	}
	env := envOf(c)
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		add(k, env[k])
	}
	var out strings.Builder
	for _, kv := range lines {
		if strings.ContainsAny(kv[1], "'\n\r") {
			fmt.Fprintf(stderr, "setupgen: env: %s: value contains a quote or newline\n", kv[0])
			return exitError
		}
		fmt.Fprintf(&out, "%s='%s'\n", kv[0], kv[1])
	}
	io.WriteString(stdout, out.String())
	return exitOK
}
