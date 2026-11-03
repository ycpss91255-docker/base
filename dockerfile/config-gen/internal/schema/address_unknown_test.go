package schema

import (
	"errors"
	"testing"
)

// An address whose section and prefix no array family is numbered under
// is refused with a typed *AddressError of kind AddrUnknown, naming the
// address as given, and no Address is read from it: the prefix is not a
// family's (`gui.foo_1`, `security.bogus_2`), it belongs to a family of
// another section (`network.mount_1`, `volumes.foo_1`), or the section is
// not one the schema knows (`bogus.mount_1`) (base#1443, design r1
// cycle 16, design-r3 row 20).
//
// Expected values: the shell's key check, `_setup_known_key` in
// dist/script/docker/lib/setup_cmd.sh with dist/script/docker/lib/schema.sh,
// run under LC_ALL=C, knows none of them and knows the family spellings
// beside them [shell]:
//
//	gui foo_1        -> 1   volumes mount_1  -> 0
//	security bogus_2 -> 1   network port_1   -> 0
//	network mount_1  -> 1   devices device_1 -> 0
//	volumes foo_1    -> 1
//	bogus mount_1    -> 1
//
// The kind is the one design-r3 names for "no family carries that section
// and prefix" (`AddrUnknown`).
func TestParseAddressUnknownFamilyRefused(t *testing.T) {
	for _, in := range []string{
		"gui.foo_1",
		"security.bogus_2",
		"network.mount_1",
		"volumes.foo_1",
		"bogus.mount_1",
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
		if ae.Kind != AddrUnknown || ae.Addr != in {
			t.Errorf("ParseAddress(%q) error = %+v, want Kind AddrUnknown, Addr %q", in, *ae, in)
		}
	}
}
