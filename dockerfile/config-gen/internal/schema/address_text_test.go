package schema

import (
	"errors"
	"testing"
)

// Every address refusal, from ParseAddress and from (*Config).Entry,
// gives no address or entry and an *AddressError whose kind, address and
// message are its own: the message names the address as given and says
// what is wrong with its entry number (base#1443 review round 1 finding
// 1, the refusal-test contract's display point for a typed error).
//
// Expected values: the addresses are those of the kind tests
// (address_*_test.go, entry_*_test.go); each message is the address
// quoted, then the kind's wording [lit]. A built Address is spelled
// `<section>.<prefix>_<N>` in its message, as the shell writes it.
func TestAddressRefusalText(t *testing.T) {
	cfg, refusals := Decode([]byte("[[volumes]]\nsource = \"/a\"\n"))
	if len(refusals) != 0 || cfg == nil {
		t.Fatalf("Decode = %v, %+v, want a Config and no refusals", cfg, refusals)
	}
	for _, tc := range []struct {
		in   string
		kind AddressKind
		msg  string
	}{
		{"volumes.mount_-1", AddrNegative, `address "volumes.mount_-1": entry number is negative`},
		{"volumes.mount_x", AddrNotNumeric, `address "volumes.mount_x": entry number is not a number`},
		{"volumes.mount_0", AddrOutOfRange, `address "volumes.mount_0": entry number is out of range`},
		{"volumes.mount_99999999999999999999", AddrOutOfRange, `address "volumes.mount_99999999999999999999": entry number is out of range`},
		{"security.privileged_1", AddrThroughScalar, `address "security.privileged_1": entry number indexes through a scalar key`},
		{"gui.foo_1", AddrUnknown, `address "gui.foo_1": entry number is under no array family`},
	} {
		t.Run(tc.in, func(t *testing.T) {
			got, err := ParseAddress(tc.in)

			if got != (Address{}) {
				t.Errorf("ParseAddress = %+v, want the zero Address", got)
			}
			var ae *AddressError
			if !errors.As(err, &ae) || ae.Kind != tc.kind || ae.Addr != tc.in || err.Error() != tc.msg {
				t.Errorf("ParseAddress error = %v (%#v), want Kind %v, Addr %q, message %q", err, ae, tc.kind, tc.in, tc.msg)
			}
		})
	}
	// An Address built without ParseAddress is judged by Entry on the
	// same rules, with the same messages; entry 2 of a family holding
	// one is past its end.
	for _, tc := range []struct {
		a    Address
		addr string
		kind AddressKind
		msg  string
	}{
		{Address{"volumes", "mount", 2}, "volumes.mount_2", AddrOutOfRange, `address "volumes.mount_2": entry number is out of range`},
		{Address{"volumes", "mount", 0}, "volumes.mount_0", AddrOutOfRange, `address "volumes.mount_0": entry number is out of range`},
		{Address{"volumes", "mount", -1}, "volumes.mount_-1", AddrNegative, `address "volumes.mount_-1": entry number is negative`},
		{Address{"security", "privileged", 1}, "security.privileged_1", AddrThroughScalar, `address "security.privileged_1": entry number indexes through a scalar key`},
		{Address{"gui", "foo", 1}, "gui.foo_1", AddrUnknown, `address "gui.foo_1": entry number is under no array family`},
	} {
		t.Run("Entry "+tc.addr, func(t *testing.T) {
			defer func() {
				if p := recover(); p != nil {
					t.Fatalf("Entry(%+v) panicked: %v", tc.a, p)
				}
			}()
			e, err := cfg.Entry(tc.a)

			if e != nil {
				t.Errorf("Entry = %+v, want no entry", *e)
			}
			var ae *AddressError
			if !errors.As(err, &ae) || ae.Kind != tc.kind || ae.Addr != tc.addr || err.Error() != tc.msg {
				t.Errorf("Entry error = %v (%#v), want Kind %v, Addr %q, message %q", err, ae, tc.kind, tc.addr, tc.msg)
			}
		})
	}
}
