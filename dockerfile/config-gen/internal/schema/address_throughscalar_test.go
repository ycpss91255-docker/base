package schema

import (
	"errors"
	"testing"
)

// An address whose prefix names a scalar key of its section, indexing
// through a scalar, is refused with a typed *AddressError of kind
// AddrThroughScalar, naming the address as given, and no Address is read
// from it (base#1443, design r1 cycle 16, design-r3 P5).
//
// Expected values: the shell's key check, `_setup_known_key` in
// dist/script/docker/lib/setup_cmd.sh, run under LC_ALL=C, knows the
// scalar and refuses the numbered spelling [shell]:
//
//	security privileged_1 -> 1   security privileged -> 0
//	deploy gpu_count_2    -> 1   deploy gpu_count    -> 0
//
// The kind is the one design-r3 names for both (`AddrThroughScalar`).
func TestParseAddressThroughScalarRefused(t *testing.T) {
	for _, in := range []string{
		"security.privileged_1",
		"deploy.gpu_count_2",
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
		if ae.Kind != AddrThroughScalar || ae.Addr != in {
			t.Errorf("ParseAddress(%q) error = %+v, want Kind AddrThroughScalar, Addr %q", in, *ae, in)
		}
	}
}
