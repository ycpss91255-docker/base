package main

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// `config-gen check` judges a value's TOML kind as s6_kinds.tsv lists
// (base#1442 AC "Wrong types", ADR-00000039 l.121 and l.125). Each row is
// a one-key layer. An int key (the watchdog counts, max_file, the *_keep
// and *_days keys) takes only a TOML int and a bool key (privileged, init,
// compress, wrapper_transcript) only a TOML bool: every other kind is one
// conf_value_type_refused frame at the key's line, so `max_file = "3"` and
// `privileged = 1` are refused although the shell passes their text.
// gpu_count takes a string or an int. Any other key takes any scalar kind
// and is judged on the bridge's text: `tz = 1979-05-27` and
// `network_name = 1` pass, and `shm_size = 1.5` is conf_value_invalid, not
// a type refusal. The bats half holds the int and bool keys of the table
// equal to the keys schema.sh itself types.
func TestCheckKinds(t *testing.T) {
	paths := testcorpus.Glob(t, "corpus/s6/s6_kinds.tsv")
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	rows := 0
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 6 {
			t.Fatalf("%s:%d: %d fields, want 6: %q", paths[0], i+1, len(f), line)
		}
		rows++
		section, key, literal, event := f[0], f[1], f[2], f[4]
		t.Run(section+"."+key+"="+literal, func(t *testing.T) {
			path := writeLayer(t, "["+section+"]\n"+key+" = "+literal+"\n")
			var stdout, stderr bytes.Buffer

			status := run([]string{"check", path}, &stdout, &stderr)

			fr := frames(t, stderr.String())
			if event == "-" {
				if status != 0 || len(fr) != 0 {
					t.Errorf("tsv line %d: check = %d, frames %q; want 0 and none", i+1, status, fr)
				}
				return
			}
			if status != 1 || len(fr) != 1 {
				t.Fatalf("tsv line %d: check = %d, frames %q; want 1 and one %s", i+1, status, fr, event)
			}
			if fr[0][2] != event || fr[0][4] != "2" || fr[0][6] != section+"."+key {
				t.Errorf("tsv line %d: frame %q, want %s at line 2 naming %s.%s", i+1, fr[0], event, section, key)
			}
		})
	}
	if rows == 0 {
		t.Fatalf("%s: no rows", paths[0])
	}
}
