package schema

import (
	"errors"
	"testing"
)

// An entry number that is not a plain run of ASCII digits is refused with a
// typed *AddressError of kind AddrNotNumeric, naming the address as given,
// and no Address is read from it (base#1443, design r1 cycle 16).
//
// Expected values: the shell's key check refuses `volumes mount_x` and
// `volumes mount_+1` with rc 1 (`_setup_known_key`, r3 p1443/known.out,
// design-r3 1l) [shell]. design-r3 (address seam, cycle 20) names the
// kind for `mount_x`, `mount_+1`, the bare `mount_` and a fullwidth digit
// (`mount_１`), the digit class being ASCII as `_scalar_spellings_of`
// uses [spec]. A sign is not a digit, so `+1` names no entry even though a
// signed-integer reader would take it as 1.
func TestParseAddressNotNumericIndexRefused(t *testing.T) {
	for _, in := range []string{
		"volumes.mount_x",
		"volumes.mount_+1",
		"volumes.mount_",
		"volumes.mount_１",
		"network.port_1a",
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
		if ae.Kind != AddrNotNumeric || ae.Addr != in {
			t.Errorf("ParseAddress(%q) error = %+v, want Kind AddrNotNumeric, Addr %q", in, *ae, in)
		}
	}
}
