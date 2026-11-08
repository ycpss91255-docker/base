package schema

import (
	"errors"
	"os"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// (*Config).Entry refuses a well-formed address whose entry number is
// above the number of entries the layer writes for that family: it
// returns no entry and a typed *AddressError of kind AddrOutOfRange naming
// the address (base#1443, design r1 cycle 17, design-r3 row 21).
//
// Expected values: the real bridge, `--kv` on s7_cleared_mid.toml
// (s7d1 bridge.out, f15_cleared_mid.toml), rc 0 with exactly three rows
// [bridge]:
//
//	volumes mount_1 /a
//	volumes mount_2 ""
//	volumes mount_3 /c
//
// so no entry is written as `volumes.mount_4` or `volumes.mount_9`; the
// kind is the one design-r3 row 21 names for `volumes.mount_4` [spec].
func TestConfigEntryOutOfRangeRefused(t *testing.T) {
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

	for _, addr := range []string{"volumes.mount_4", "volumes.mount_9"} {
		a, err := ParseAddress(addr)
		if err != nil {
			t.Fatalf("ParseAddress(%q) error = %v", addr, err)
		}
		e, err := cfg.Entry(a)
		if e != nil {
			t.Errorf("Entry(%q) = %+v, want no entry", addr, *e)
		}
		var ae *AddressError
		if !errors.As(err, &ae) {
			t.Errorf("Entry(%q) error = %v, want an *AddressError", addr, err)
			continue
		}
		if ae.Kind != AddrOutOfRange || ae.Addr != addr {
			t.Errorf("Entry(%q) error = %+v, want Kind AddrOutOfRange, Addr %q", addr, *ae, addr)
		}
	}
}
