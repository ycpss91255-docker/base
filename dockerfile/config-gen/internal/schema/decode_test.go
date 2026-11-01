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
