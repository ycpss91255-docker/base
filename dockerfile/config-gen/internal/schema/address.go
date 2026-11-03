package schema

import (
	"fmt"
	"strconv"
	"strings"
)

// Address is a shell address `<section>.<prefix>_<N>`: the section, the
// numbered prefix its family's entries are written under and the entry
// number, as `_conf_toml_aot_nskey` (dist/script/docker/lib/conf.sh)
// writes the N-th block of an array home (base#1443).
type Address struct {
	Section string
	Prefix  string
	Index   int
}

// AddressKind names why ParseAddress refused an address (base#1443).
type AddressKind int

const (
	// AddrNegative: the entry number is negative (`mount_-1`); entries
	// number from 1, so no entry has one.
	AddrNegative AddressKind = iota + 1
	// AddrNotNumeric: the entry number is not a run of ASCII digits
	// (`mount_x`, `mount_+1`, a bare `mount_`, a fullwidth digit).
	AddrNotNumeric
)

// AddressError is ParseAddress's typed refusal: its kind and the address
// as given (base#1443).
type AddressError struct {
	Kind AddressKind
	Addr string
}

func (e *AddressError) Error() string {
	if e.Kind == AddrNotNumeric {
		return fmt.Sprintf("address %q: entry number is not a number", e.Addr)
	}
	return fmt.Sprintf("address %q: entry number is negative", e.Addr)
}

// asciiDigits reports whether s is a non-empty run of ASCII digits.
func asciiDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// ParseAddress reads a shell address into its section, its prefix (the
// part before the last underscore, which may itself carry one) and its
// entry number, read as a decimal as the bridge's int(rest) reads it
// (base#1443).
func ParseAddress(s string) (Address, error) {
	section, key, ok := strings.Cut(s, ".")
	if !ok {
		return Address{}, fmt.Errorf("address %q has no section", s)
	}
	i := strings.LastIndex(key, "_")
	if i < 0 {
		return Address{}, fmt.Errorf("address %q has no entry number", s)
	}
	if !asciiDigits(strings.TrimPrefix(key[i+1:], "-")) {
		return Address{}, &AddressError{Kind: AddrNotNumeric, Addr: s}
	}
	n, err := strconv.Atoi(key[i+1:])
	if err != nil {
		return Address{}, fmt.Errorf("address %q: %w", s, err)
	}
	if n < 0 {
		return Address{}, &AddressError{Kind: AddrNegative, Addr: s}
	}
	return Address{Section: section, Prefix: key[:i], Index: n}, nil
}
