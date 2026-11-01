package schema

import (
	"reflect"
	"testing"
)

// An unregistered scalar name beside a known one in a known table is one
// conf_unknown_key refusal at the line the key is written on (base#1442).
// The verdicts are schema.sh's: `deploy gpu_count` is a known key and
// `deploy gpu_cuont` is not. Line 3 is counted from the input bytes.
// BurntSushi's Undecoded() carries no position, so the line rules it out
// as the source of the refusal.
func TestDecodeUnknownKeyInKnownTable(t *testing.T) {
	src := []byte("[deploy]\ngpu_count = \"all\"\ngpu_cuont = \"1\"\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_unknown_key" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_unknown_key")
	}
	if want := []string{"deploy", "gpu_cuont"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 3 {
		t.Errorf("Line = %d, want 3", got.Line)
	}
}

// A table schema.sh does not know is one conf_unknown_table refusal at its
// header line, and the keys under it get no refusal of their own
// (base#1442). The verdict is the shell's: `_setup_known_section deploy2`
// fails and setup_cmd.sh reports apply_unknown_table once for the table,
// with no apply_unknown_key for `deploy2.x`. Line 3 is counted from the
// input bytes.
func TestDecodeUnknownTable(t *testing.T) {
	src := []byte("[deploy]\ngpu_count = \"all\"\n[deploy2]\nx = 1\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_unknown_table" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_unknown_table")
	}
	if want := []string{"deploy2"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 3 {
		t.Errorf("Line = %d, want 3", got.Line)
	}
}

// A scalar written at the root, above any table header, is one
// conf_top_level_key refusal naming that key at its line (base#1308,
// base#1442). schema.sh has no root section, so no root scalar is a
// known key; the event id is the base#1442 design's. Line 1 is counted from the
// input bytes. The table that follows it gets no refusal of its own.
func TestDecodeTopLevelScalar(t *testing.T) {
	src := []byte("top = \"v\"\n[deploy]\ngpu_count = \"all\"\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_top_level_key" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_top_level_key")
	}
	if want := []string{"top"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 1 {
		t.Errorf("Line = %d, want 1", got.Line)
	}
}
