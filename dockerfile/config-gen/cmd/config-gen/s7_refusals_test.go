package main

import (
	"path/filepath"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// s7Refusals is, per refused corpus/s7 fixture, the one frame `config-gen
// check` reports for it: {event, line, col, key} (base#1443 review round
// 1 finding 1). Every refusal rule the array families add has a row here:
// the entry that is not a table, the entry with no gating field, the
// unknown field, the field holding a list or a table, the field written
// without the field it needs, the family written two ways and the
// stage-table array and key no family or reader knows.
//
// Expected values: the events, entry numbers, fields and lines are the
// ones the decode-level tests of each rule take from the bridge's own
// refusals (arrays_*_test.go in internal/schema). Columns are counted
// from the fixture bytes [lit]: a `[[...]]` entry's header and a field's
// key are at column 1; an inline element is at its first byte
// (`volumes = ["x"]`: column 12; `tmpfs = [1]`: 10; `args = ["A=1"]`:
// 9); the inline `value` of s7_type_args_inline.toml is at column 22.
var s7Refusals = map[string][]string{
	"s7_nottable_string.toml":        {"conf_entry_not_table", "1", "12", "volumes[1]"},
	"s7_nottable_int.toml":           {"conf_entry_not_table", "1", "10", "tmpfs[1]"},
	"s7_nottable_args.toml":          {"conf_entry_not_table", "2", "9", "build.args[1]"},
	"s7_nottable_second.toml":        {"conf_entry_not_table", "3", "3", "volumes[2]"},
	"s7_order_nottable_newline.toml": {"conf_entry_not_table", "1", "12", "volumes[1]"},
	"s7_nogating_volumes.toml":       {"conf_entry_no_gating_field", "1", "1", "volumes[1]"},
	"s7_nogating_tmpfs.toml":         {"conf_entry_no_gating_field", "1", "1", "tmpfs[1]"},
	"s7_nogating_args.toml":          {"conf_entry_no_gating_field", "1", "1", "build.args[1]"},
	"s7_nogating_ports.toml":         {"conf_entry_no_gating_field", "1", "1", "network.ports[1]"},
	"s7_nogating_contexts.toml":      {"conf_entry_no_gating_field", "1", "1", "additional_contexts[1]"},
	"s7_nogating_second.toml":        {"conf_entry_no_gating_field", "3", "1", "volumes[2]"},
	"s7_order_nogating_list.toml":    {"conf_entry_no_gating_field", "1", "1", "tmpfs[1]"},
	"s7_order_nogating_newline.toml": {"conf_entry_no_gating_field", "1", "1", "volumes[1]"},
	"s7_unknown_devices.toml":        {"conf_entry_unknown_field", "3", "1", "devices[1].foo"},
	"s7_unknown_tmpfs.toml":          {"conf_entry_unknown_field", "3", "1", "tmpfs[1].sise"},
	"s7_unknown_table_value.toml":    {"conf_entry_unknown_field", "3", "1", "volumes[1].zz"},
	"s7_unknown_second.toml":         {"conf_entry_unknown_field", "6", "1", "volumes[2].zz"},
	"s7_order_unknown_newline.toml":  {"conf_entry_unknown_field", "3", "1", "volumes[1].zz"},
	"s7_type_tmpfs_list.toml":        {"conf_value_type_refused", "3", "1", "tmpfs[1].size"},
	"s7_type_volumes_table.toml":     {"conf_value_type_refused", "3", "1", "volumes[1].mode"},
	"s7_type_args_inline.toml":       {"conf_value_type_refused", "2", "22", "build.args[1].value"},
	"s7_type_second.toml":            {"conf_value_type_refused", "6", "1", "network.ports[2].container"},
	"s7_needs_target.toml":           {"conf_entry_field_needs", "2", "1", "volumes[1].target"},
	"s7_needs_mode.toml":             {"conf_entry_field_needs", "3", "1", "volumes[1].mode"},
	"s7_needs_empty_source.toml":     {"conf_entry_field_needs", "3", "1", "volumes[1].mode"},
	"s7_needs_second.toml":           {"conf_entry_field_needs", "9", "1", "volumes[3].target"},
	"s7_two_spellings.toml":          {"conf_family_two_spellings", "2", "1", "security.cap_drop_1"},
	"s7_stage_quoted_array.toml":     {"conf_unknown_key", "2", "1", "stage:dev.build.args"},
	"s7_stage_unknown_flat.toml":     {"conf_unknown_key", "2", "1", "stage:dev.deploy.bogus"},
	"s7_stage_unknown_build.toml":    {"conf_unknown_key", "2", "1", "stage:dev.build.target"},
	"s7_stage_unknown_nested.toml":   {"conf_unknown_key", "2", "1", "stage:dev.deploy.bogus"},
}

// `config-gen check` on every corpus/s7 fixture holds each refusal to
// the five points of the refusal-test contract (base#1395 plan, "Every
// refusal test asserts five things"; base#1443 review round 1 finding
// 1): status 1, empty stdout and stderr wholly frames naming the
// fixture as the file (runCheck), the event, and the line, column and
// key of the one frame, whose display text is the event's own and names
// the key (runCheck). A fixture with no row in s7Refusals is an accepted
// layer: status 0 and no frame. So a refusal fixture added without a row
// fails here, as does a rule that reports its refusal at another
// position or key, or adds a second refusal beside it.
func TestCheckS7Corpus(t *testing.T) {
	seen := map[string]bool{}
	for _, path := range testcorpus.Glob(t, "corpus/s7/*.toml") {
		base := filepath.Base(path)
		seen[base] = true
		t.Run(base, func(t *testing.T) {
			want, refused := s7Refusals[base]

			status, fr := runCheck(t, path)

			if !refused {
				if status != 0 || len(fr) != 0 {
					t.Fatalf("check = %d, frames %q; want 0 and no frame", status, fr)
				}
				return
			}
			if status != 1 || len(fr) != 1 {
				t.Fatalf("check = %d, frames %q; want 1 and one frame", status, fr)
			}
			if got := []string{fr[0][2], fr[0][4], fr[0][5], fr[0][6]}; !reflect.DeepEqual(got, want) {
				t.Errorf("frame (event line col key) = %q, want %q", got, want)
			}
		})
	}
	for base := range s7Refusals {
		if !seen[base] {
			t.Errorf("s7Refusals names %s, which is no corpus/s7 file", base)
		}
	}
}
