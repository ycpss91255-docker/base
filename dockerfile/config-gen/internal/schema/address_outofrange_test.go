package schema

import (
	"errors"
	"testing"
)

// An entry number that no entry can carry, 0 or one above the int range,
// is refused with a typed *AddressError of kind AddrOutOfRange, naming the
// address as given, and no Address is read from it (base#1443, design r1
// cycle 16).
//
// Expected values: entries number from 1 (`_emit_array`:
// `enumerate(items, 1)`; `_conf_toml_aot_nskey <path> <N>`), so no entry
// is numbered 0; the shell's key check passes `volumes mount_0` and the
// 20-digit `volumes mount_99999999999999999999` (rc 0, r3 p1443/known.out,
// design-r3 1l) although neither names an entry [shell][spec]. The kind is
// the one design-r3 names for both (`AddrOutOfRange`).
func TestParseAddressOutOfRangeIndexRefused(t *testing.T) {
	for _, in := range []string{
		"volumes.mount_0",
		"network.port_00",
		"volumes.mount_99999999999999999999",
		"devices.cgroup_rule_9223372036854775808",
	} {
		got, err := ParseAddress(in)
		if got != (Address{}) {
			t.Errorf("ParseAddress(%q) = %+v, want the zero Address", in, got)
		}
		var ae *AddressError
		if !errors.As(err, &ae) {
			t.Errorf("ParseAddress(%q) error = %v, want an *AddressError", in, err)
			continue
		}
		if ae.Kind != AddrOutOfRange || ae.Addr != in {
			t.Errorf("ParseAddress(%q) error = %+v, want Kind AddrOutOfRange, Addr %q", in, *ae, in)
		}
	}
}
