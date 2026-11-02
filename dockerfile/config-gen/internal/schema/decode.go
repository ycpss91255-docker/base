// Package schema decodes a setup.toml layer and refuses what schema.sh
// does not know (base#1442).
package schema

import (
	"bytes"
	"errors"
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

// known is the set of sections _setup_known_section accepts
// (dist/script/docker/lib/setup_cmd.sh). Only [deploy], [devices],
// [security] and [volumes] so far; the other sections follow in later cycles of
// base#1442. A key of a known section is known when it resolves to a
// SCHEMA_VALIDATOR row, as _setup_known_key does.
var known = map[string]bool{
	"deploy":   true,
	"devices":  true,
	"security": true,
	"volumes":  true,
}

// Decode decodes src and returns one conf_unknown_table refusal for each
// top-level table schema.sh does not know, at its header line, and one
// conf_unknown_key refusal for each key of a known table that the table
// does not register. Keys under an unknown table get no refusal. A key
// written at the root is one conf_top_level_key refusal at its line. A
// known key whose value Validate refuses is one refusal with Validate's
// event at the key's line.
func Decode(src []byte) (*Config, []Refusal) {
	var root map[string]toml.Primitive
	md, err := toml.Decode(string(src), &root)
	if err != nil {
		return nil, []Refusal{{Event: "conf_toml_parse_failed"}}
	}
	var refusals []Refusal
	var lines *locate.Map
	for _, k := range md.Keys() {
		ok := known[k[0]]
		if len(k) == 1 && !ok {
			if lines == nil {
				lines = locate.Index(src)
			}
			if occ, found := lines.Key(k); found == locate.Found {
				refusals = append(refusals, Refusal{Event: "conf_top_level_key", Path: k, Line: occ.KeyLine})
				continue
			}
			occ, _ := lines.Table(k)
			refusals = append(refusals, Refusal{Event: "conf_unknown_table", Path: k, Line: occ.KeyLine})
		}
		if len(k) != 2 || !ok {
			continue
		}
		if _, isKey := canonical(k[0], k[1]); !isKey {
			refusals = append(refusals, Refusal{Event: "conf_unknown_key", Path: k, Line: keyLine(src, k)})
		} else {
			var table map[string]toml.Primitive
			var s Scalar
			// A value of a kind Scalar does not decode yet is left
			// unvalidated; the other kinds follow in later cycles of
			// base#1442.
			if md.PrimitiveDecode(root[k[0]], &table) != nil || md.PrimitiveDecode(table[k[1]], &s) != nil {
				continue
			}
			var ve *ValueError
			if err := Validate(k[0], k[1], s); errors.As(err, &ve) {
				refusals = append(refusals, Refusal{Event: ve.Event, Path: k, Line: keyLine(src, k)})
			}
		}
	}
	return &Config{}, refusals
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
