package schema

import (
	"errors"
	"testing"
)

// A negative entry number in a shell address is refused with a typed
// *AddressError of kind AddrNegative, naming the address as given, and no
// Address is read from it (base#1443, design r1 cycle 16).
//
// Expected values: the shell's key check refuses `volumes mount_-1` with
// rc 1 (`_setup_known_key`, r3 p1443/known.out, design-r3 1l), and entries
// number from 1 (`_emit_array`: `enumerate(items, 1)`), so no entry has a
// negative number [shell][spec]. The kind is the one design-r3 names for
// `mount_-1` (`AddrNegative`).
func TestParseAddressNegativeIndexRefused(t *testing.T) {
	for _, in := range []string{"volumes.mount_-1", "network.port_-3", "devices.cgroup_rule_-12"} {
		got, err := ParseAddress(in)
		if got != (Address{}) {
			t.Errorf("ParseAddress(%q) = %+v, want the zero Address", in, got)
		}
		var ae *AddressError
		if !errors.As(err, &ae) {
			t.Errorf("ParseAddress(%q) error = %v, want an *AddressError", in, err)
			continue
		}
		if ae.Kind != AddrNegative || ae.Addr != in {
			t.Errorf("ParseAddress(%q) error = %+v, want Kind AddrNegative, Addr %q", in, *ae, in)
		}
	}
}
