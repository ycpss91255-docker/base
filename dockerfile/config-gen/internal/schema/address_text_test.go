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
// quoted, then the kind's wording [lit].
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
	t.Run("entry 2 of a family with one", func(t *testing.T) {
		e, err := cfg.Entry(Address{"volumes", "mount", 2})

		if e != nil {
			t.Errorf("Entry = %+v, want no entry", *e)
		}
		const msg = `address "volumes.mount_2": entry number is out of range`
		var ae *AddressError
		if !errors.As(err, &ae) || ae.Kind != AddrOutOfRange || ae.Addr != "volumes.mount_2" || err.Error() != msg {
			t.Errorf("Entry error = %v (%#v), want Kind AddrOutOfRange, Addr volumes.mount_2, message %q", err, ae, msg)
		}
	})
}
