// Package schema decodes a setup.toml layer and refuses what schema.sh
// does not know (base#1442).
package schema

import (
	"bytes"
	"strings"

	"github.com/BurntSushi/toml"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/locate"
)

// Refusal is one key the decode refused: the event id, the TOML path of
// the key and the 1-based line it is written on.
type Refusal struct {
	Event string
	Path  []string
	Line  int
}

// Config is the decoded layer.
type Config struct{}

// known is SCHEMA_VALIDATOR's scalar rows (dist/script/docker/lib/schema.sh)
// by section. Only [deploy] so far; the other sections and the numbered
// families follow in later cycles of base#1442.
var known = map[string][]string{
	"deploy": {"gpu_mode", "gpu_count", "gpu_capabilities", "gpu_runtime", "runtime", "dri_groups"},
}

// Decode decodes src and returns one conf_unknown_table refusal for each
// top-level table schema.sh does not know, at its header line, and one
// conf_unknown_key refusal for each key of a known table that the table
// does not register. Keys under an unknown table get no refusal.
func Decode(src []byte) (*Config, []Refusal) {
	var root map[string]toml.Primitive
	md, err := toml.Decode(string(src), &root)
	if err != nil {
		return nil, []Refusal{{Event: "conf_toml_parse_failed"}}
	}
	var refusals []Refusal
	var lines *locate.Map
	for _, k := range md.Keys() {
		keys, ok := known[k[0]]
		if len(k) == 1 && !ok {
			if lines == nil {
				lines = locate.Index(src)
			}
			occ, _ := lines.Table(k)
			refusals = append(refusals, Refusal{Event: "conf_unknown_table", Path: k, Line: occ.KeyLine})
		}
		if len(k) == 2 && ok && !contains(keys, k[1]) {
			refusals = append(refusals, Refusal{Event: "conf_unknown_key", Path: k, Line: keyLine(src, k)})
		}
	}
	return &Config{}, refusals
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// keyLine is the line of `<key> =` under the header `[<table>]`.
func keyLine(src []byte, k toml.Key) int {
	table := ""
	for i, line := range bytes.Split(src, []byte("\n")) {
		s := strings.TrimSpace(string(line))
		if strings.HasPrefix(s, "[") {
			table = strings.Trim(s, "[]")
		} else if name, _, ok := strings.Cut(s, "="); ok && table == k[0] && strings.TrimSpace(name) == k[1] {
			return i + 1
		}
	}
	return 0
}
