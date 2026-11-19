package gate

import (
	"errors"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
)

// A `\e` escape in a basic string is TOML 1.1 only; tomllib (the oracle)
// refuses it while BurntSushi accepts it, so the gate must refuse it at
// the backslash (base#1850). Column 7 is counted by hand:
// a(1) ' '(2) =(3) ' '(4) "(5) x(6) \(7).
func TestCheckRefusesEscapeEInBasicString(t *testing.T) {
	src := []byte("a = \"x\\e\"\n")
	// Control: the decoder accepts the form, so the gate is the only
	// thing between these bytes and a TOML 1.1 parse.
	var v map[string]any
	if _, err := toml.Decode(string(src), &v); err != nil {
		t.Fatalf("toml.Decode(%q) = %v, want nil (the decoder accepts \\e)", src, err)
	}
	err := Check("t.toml", src)
	var r *Refusal
	if !errors.As(err, &r) {
		t.Fatalf("Check() = %v, want *Refusal", err)
	}
	if r.File != "t.toml" || r.Line != 1 || r.Col != 7 || r.Reason != ReasonEscape {
		t.Fatalf("Refusal = {%q %d %d %v}, want {\"t.toml\" 1 7 ReasonEscape}", r.File, r.Line, r.Col, r.Reason)
	}
	if !strings.HasPrefix(r.Error(), "t.toml:1:7: ") {
		t.Fatalf("Error() = %q, want prefix %q", r.Error(), "t.toml:1:7: ")
	}
}

// A `\xHH` escape in a basic string is TOML 1.1 only as well; tomllib
// refuses `a = "x\x41"` (rc=1) while BurntSushi accepts it, so the gate
// must refuse it at the backslash, not match `\e` only (base#1850).
// Column 7 is counted by hand: a(1) ' '(2) =(3) ' '(4) "(5) x(6) \(7).
func TestCheckRefusesEscapeXInBasicString(t *testing.T) {
	src := []byte("a = \"x\\x41\"\n")
	var v map[string]any
	if _, err := toml.Decode(string(src), &v); err != nil {
		t.Fatalf("toml.Decode(%q) = %v, want nil (the decoder accepts \\x)", src, err)
	}
	err := Check("t.toml", src)
	var r *Refusal
	if !errors.As(err, &r) {
		t.Fatalf("Check() = %v, want *Refusal", err)
	}
	if r.File != "t.toml" || r.Line != 1 || r.Col != 7 || r.Reason != ReasonEscape {
		t.Fatalf("Refusal = {%q %d %d %v}, want {\"t.toml\" 1 7 ReasonEscape}", r.File, r.Line, r.Col, r.Reason)
	}
	if !strings.HasPrefix(r.Error(), "t.toml:1:7: ") {
		t.Fatalf("Error() = %q, want prefix %q", r.Error(), "t.toml:1:7: ")
	}
}
