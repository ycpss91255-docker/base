package schema

import (
	"errors"
	"os"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// (*Config).Entry judges the Address it is handed, not only one that
// ParseAddress built: an exported Address whose section and prefix name
// a family the layer carries but whose entry number is 0 or negative
// returns no entry and a typed *AddressError, the kind ParseAddress gives
// the same spelling (`mount_0` AddrOutOfRange, `mount_-1` AddrNegative),
// and never indexes the family with it (base#1443 review round 2
// finding 1).
//
// Expected values: the real bridge, `--kv` on s7_cleared_mid.toml, rc 0
// with entries numbered 1 to 3 only (s7d1 bridge.out) [bridge]; the kinds
// are ParseAddress's for the spellings (TestParseAddressNegativeIndexRefused,
// TestParseAddressOutOfRangeIndexRefused) [spec].
func TestConfigEntryRefusesAnEntryNumberBelowOne(t *testing.T) {
	files := testcorpus.Glob(t, "corpus/s7/s7_cleared_mid.toml")
	if len(files) != 1 {
		t.Fatalf("Glob = %v, want s7_cleared_mid.toml", files)
	}
	src, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	cfg, refusals := Decode(src)
	if len(refusals) != 0 || cfg == nil {
		t.Fatalf("Decode = %v, %+v, want a Config and no refusals", cfg, refusals)
	}

	for _, tc := range []struct {
		index int
		addr  string
		kind  AddressKind
	}{
		{0, "volumes.mount_0", AddrOutOfRange},
		{-1, "volumes.mount_-1", AddrNegative},
		{-4, "volumes.mount_-4", AddrNegative},
	} {
		t.Run(tc.addr, func(t *testing.T) {
			defer func() {
				if p := recover(); p != nil {
					t.Fatalf("Entry(%+v) panicked: %v", tc, p)
				}
			}()
			e, err := cfg.Entry(Address{Section: "volumes", Prefix: "mount", Index: tc.index})
			if e != nil {
				t.Errorf("Entry = %+v, want no entry", *e)
			}
			var ae *AddressError
			if !errors.As(err, &ae) {
				t.Fatalf("Entry error = %v, want an *AddressError", err)
			}
			if ae.Kind != tc.kind || ae.Addr != tc.addr {
				t.Errorf("Entry error = %+v, want Kind %v, Addr %q", *ae, tc.kind, tc.addr)
			}
		})
	}
}
