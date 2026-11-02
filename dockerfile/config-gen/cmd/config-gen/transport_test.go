package main

import (
	"bytes"
	"fmt"
	"testing"
)

// `config-gen check` refuses a name or value the bridge's tab-separated
// view cannot carry, and U+0000, at every depth a layer can hold one
// (base#1442, ADR-00000039 "Behaviour that changes on purpose"): a tab,
// LF or CR in a key or table name is conf_key_char_refused, an LF or CR
// in a value conf_value_newline_refused (toml_bridge.py
// _check_transportable refuses both, rc 1), and U+0000 in either
// conf_value_nul_refused (the bridge passes it, rc 0; the generator
// refuses it on purpose). Each is one frame at the line of the key that
// holds it, whether the key sits at the root, in a known section, in a
// `[logging.<service>]` table, in a `["stage:<name>"]` table, in an
// inline table or in a `[[volumes]]` entry.
func TestCheckTransportAtEveryDepth(t *testing.T) {
	depths := []struct {
		name, key, value string // %s is the planted name or value
	}{
		{"root", "%s = 1\n", ""},
		{"section", "[environment]\n%s = \"x\"\n", "[environment]\nenv_1 = %s\n"},
		{"logging service", "[logging.web]\n%s = \"x\"\n", "[logging.web]\ndriver = %s\n"},
		{"stage", "[\"stage:dev\"]\n%s = 1\n", "[\"stage:dev\"]\nx = %s\n"},
		{"inline member", "[\"stage:dev\"]\nt = { %s = 1 }\n", "[\"stage:dev\"]\nt = { y = %s }\n"},
		{"volumes entry", "[[volumes]]\n%s = \"x\"\n", "[[volumes]]\nsource = %s\n"},
	}
	plants := []struct {
		name, text, keyEvent, valueEvent string
	}{
		{"tab", `"a\tb"`, "conf_key_char_refused", "-"},
		{"LF", `"a\nb"`, "conf_key_char_refused", "conf_value_newline_refused"},
		{"CR", `"a\rb"`, "conf_key_char_refused", "conf_value_newline_refused"},
		{"NUL", `"a\u0000b"`, "conf_value_nul_refused", "conf_value_nul_refused"},
	}
	for _, d := range depths {
		for _, p := range plants {
			for _, c := range []struct{ where, layout, event string }{
				{"key", d.key, p.keyEvent},
				{"value", d.value, p.valueEvent},
			} {
				// A tab in a value is carried by the bridge, so it is no
				// transport case.
				if c.layout == "" || c.event == "-" {
					continue
				}
				t.Run(d.name+"/"+c.where+"/"+p.name, func(t *testing.T) {
					src := fmt.Sprintf(c.layout, p.text)
					path := writeLayer(t, src)
					var stdout, stderr bytes.Buffer

					status := run([]string{"check", path}, &stdout, &stderr)

					fr := frames(t, stderr.String())
					line := "1"
					if d.name != "root" {
						line = "2"
					}
					if status != 1 || len(fr) != 1 || fr[0][2] != c.event || fr[0][4] != line {
						t.Errorf("check %q = %d, frames %q; want 1 and one %s at line %s", src, status, fr, c.event, line)
					}
				})
			}
		}
	}
}
