package schema

import "testing"

// An address without the `<section>.` part or without the `_<N>` part is
// refused by what it lacks, and never panics: `mount_1` has no section,
// `volumes.mount` no entry number (base#1443 review round 1 mutation
// survey).
//
// Expected values: the shell address `<section>.<prefix>_<N>` that
// _conf_toml_aot_nskey (dist/script/docker/lib/conf.sh) writes; each
// input lacks one of its two separators, and the error names the part
// that is missing, as ParseAddress's two shape errors state.
func TestParseAddressRefusesAMissingPart(t *testing.T) {
	for _, tc := range []struct {
		addr string
		want string
	}{
		{"mount_1", `address "mount_1" has no section`},
		{"volumes.mount", `address "volumes.mount" has no entry number`},
	} {
		t.Run(tc.addr, func(t *testing.T) {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("ParseAddress(%q) panicked: %v", tc.addr, r)
				}
			}()

			a, err := ParseAddress(tc.addr)

			if err == nil || err.Error() != tc.want {
				t.Errorf("ParseAddress(%q) = %+v, %v; want error %q", tc.addr, a, err, tc.want)
			}
		})
	}
}
