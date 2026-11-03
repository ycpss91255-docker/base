package main

import (
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

			status, fr := runCheck(t, path)

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

// `config-gen check` judges a value by the key registry first and its
// written kind second, for every kind at every class of key (base#1442
// redesign R7; review round 1 finding 1 was a `[[k]]` judged by its kind
// before the registry). Rows: {scalar, inline table, inline array,
// `[[k]]`, `[k]`} x {registered scalar key security.privileged, family
// key security.cap_drop, free-form key build.tz, unknown key
// security.typo}. Expected values, run in LC_ALL=C on the same bytes
// (scratch probe p1442r3_kinds.sh): where the bridge's `--kv` is rc 0, the
// shell's verdicts on its `--tables` and `--kv` rows (_setup_known_section,
// _setup_known_key, _schema_validate): a table at any key is an unknown
// table, a scalar at the family key or an unknown key is an unknown key;
// where the bridge refuses an array with no numbered family (rc 1, "is an
// array, and no numbered family of the shell view carries an array by
// that name"), conf_value_type_refused at a key _setup_known_key knows and
// conf_unknown_key at any other. A family array with a payload the bridge
// reads (`cap = "ALL"`, `--kv` rc 0, row security.cap_drop_1 known and
// valid) is accepted.
func TestCheckKindByRegistryFirst(t *testing.T) {
	cases := []struct {
		name   string
		src    string
		status int
		want   [][]string
	}{
		{"scalar at a registered key", "[security]\nprivileged = true\n", 0, nil},
		{"inline table at a registered key", "[security]\nprivileged = { x = 1 }\n", 1, [][]string{{"conf_unknown_table", "2", "1", "security.privileged"}}},
		{"inline array at a registered key", "[security]\nprivileged = [\"a\"]\n", 1, [][]string{{"conf_value_type_refused", "2", "1", "security.privileged"}}},
		{"array of tables at a registered key", "[[security.privileged]]\nx = \"a\"\n", 1, [][]string{{"conf_value_type_refused", "1", "1", "security.privileged"}}},
		{"table at a registered key", "[security.privileged]\nx = \"a\"\n", 1, [][]string{{"conf_unknown_table", "1", "1", "security.privileged"}}},
		{"scalar at a family key", "[security]\ncap_drop = \"ALL\"\n", 1, [][]string{{"conf_unknown_key", "2", "1", "security.cap_drop"}}},
		{"inline table at a family key", "[security]\ncap_drop = { x = 1 }\n", 1, [][]string{{"conf_unknown_table", "2", "1", "security.cap_drop"}}},
		{"inline array at a family key", "[security]\ncap_drop = [{ cap = \"ALL\" }]\n", 0, nil},
		{"array of tables at a family key", "[[security.cap_drop]]\ncap = \"ALL\"\n", 0, nil},
		{"table at a family key", "[security.cap_drop]\nx = \"a\"\n", 1, [][]string{{"conf_unknown_table", "1", "1", "security.cap_drop"}}},
		{"scalar at a free-form key", "[build]\ntz = \"UTC\"\n", 0, nil},
		{"inline table at a free-form key", "[build]\ntz = { x = 1 }\n", 1, [][]string{{"conf_unknown_table", "2", "1", "build.tz"}}},
		{"inline array at a free-form key", "[build]\ntz = [\"a\"]\n", 1, [][]string{{"conf_value_type_refused", "2", "1", "build.tz"}}},
		{"array of tables at a free-form key", "[[build.tz]]\nx = \"a\"\n", 1, [][]string{{"conf_value_type_refused", "1", "1", "build.tz"}}},
		{"table at a free-form key", "[build.tz]\nx = \"a\"\n", 1, [][]string{{"conf_unknown_table", "1", "1", "build.tz"}}},
		{"scalar at an unknown key", "[security]\ntypo = 1\n", 1, [][]string{{"conf_unknown_key", "2", "1", "security.typo"}}},
		{"inline table at an unknown key", "[security]\ntypo = { x = 1 }\n", 1, [][]string{{"conf_unknown_table", "2", "1", "security.typo"}}},
		{"inline array at an unknown key", "[security]\ntypo = [\"a\"]\n", 1, [][]string{{"conf_unknown_key", "2", "1", "security.typo"}}},
		{"array of tables at an unknown key", "[[security.typo]]\nx = \"a\"\n", 1, [][]string{{"conf_unknown_key", "1", "1", "security.typo"}}},
		{"table at an unknown key", "[security.typo]\nx = \"a\"\n", 1, [][]string{{"conf_unknown_table", "1", "1", "security.typo"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			checkFrames(t, tc.src, tc.status, tc.want)
		})
	}
}
