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
	// AddrOutOfRange: the entry number is 0 (`mount_0`, `port_00`), which
	// no entry carries since entries number from 1, or above the int
	// range.
	AddrOutOfRange
	// AddrThroughScalar: the prefix names a scalar key of its section
	// (`security.privileged_1`), which _setup_known_key refuses, as an entry
	// number indexes through a scalar.
	AddrThroughScalar
	// AddrUnknown: no array family is numbered under that section and
	// prefix (`gui.foo_1`, `network.mount_1`, `bogus.mount_1`), which
	// _setup_known_key refuses.
	AddrUnknown
)

// addrKindText says what each AddressKind found wrong with the entry
// number (base#1443).
var addrKindText = map[AddressKind]string{
	AddrNegative:      "is negative",
	AddrNotNumeric:    "is not a number",
	AddrOutOfRange:    "is out of range",
	AddrThroughScalar: "indexes through a scalar key",
	AddrUnknown:       "is under no array family",
}

// AddressError is ParseAddress's typed refusal: its kind and the address
// as given (base#1443).
type AddressError struct {
	Kind AddressKind
	Addr string
}

func (e *AddressError) Error() string {
	return fmt.Sprintf("address %q: entry number %s", e.Addr, addrKindText[e.Kind])
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
	prefix, number := key[:i], key[i+1:]
	if !asciiDigits(strings.TrimPrefix(number, "-")) {
		return Address{}, &AddressError{Kind: AddrNotNumeric, Addr: s}
	}
	if strings.HasPrefix(number, "-") {
		return Address{}, &AddressError{Kind: AddrNegative, Addr: s}
	}
	if knownKey(section, prefix) {
		return Address{}, &AddressError{Kind: AddrThroughScalar, Addr: s}
	}
	if !familyAddress(section, prefix) {
		return Address{}, &AddressError{Kind: AddrUnknown, Addr: s}
	}
	n, err := strconv.Atoi(number)
	if err != nil || n == 0 {
		return Address{}, &AddressError{Kind: AddrOutOfRange, Addr: s}
	}
	return Address{Section: section, Prefix: prefix, Index: n}, nil
}

// familyAddress reports whether an array home of that section is
// numbered under that prefix, as Homes lists them (base#1443).
func familyAddress(section, prefix string) bool {
	for _, h := range homes {
		if h.path[0] == section && h.prefix == prefix {
			return true
		}
	}
	return false
}

// String is the address as the shell spells it, `<section>.<prefix>_<N>`.
func (a Address) String() string {
	return fmt.Sprintf("%s.%s_%d", a.Section, a.Prefix, a.Index)
}

// check judges an Address however it was built, by the rules
// ParseAddress applies to the text it reads: a prefix naming a scalar
// key, a section and prefix no family is numbered under, a negative
// entry number and entry number 0 are each refused by their kind
// (base#1443 review round 2 finding 1).
func (a Address) check() error {
	switch {
	case knownKey(a.Section, a.Prefix):
		return &AddressError{Kind: AddrThroughScalar, Addr: a.String()}
	case !familyAddress(a.Section, a.Prefix):
		return &AddressError{Kind: AddrUnknown, Addr: a.String()}
	case a.Index < 0:
		return &AddressError{Kind: AddrNegative, Addr: a.String()}
	case a.Index == 0:
		return &AddressError{Kind: AddrOutOfRange, Addr: a.String()}
	}
	return nil
}

// Entry is the entry of the layer the shell writes under that address:
// entry N, counted in written order with the cleared slot kept in its
// position, of the first family whose home the address's section and
// prefix name and that the layer carries (base#1443). The address is
// judged first, so an Address built without ParseAddress is held to the
// same rules (base#1443 review round 2 finding 1).
func (c *Config) Entry(a Address) (*Entry, error) {
	if err := a.check(); err != nil {
		return nil, err
	}
	for _, h := range homes {
		if h.path[0] != a.Section || h.prefix != a.Prefix {
			continue
		}
		fam, ok := c.Array(h.path...)
		if !ok {
			continue
		}
		if a.Index > len(fam.Entries) {
			return nil, &AddressError{Kind: AddrOutOfRange, Addr: a.String()}
		}
		e := fam.Entries[a.Index-1]
		return &e, nil
	}
	return nil, fmt.Errorf("address %s names no entry of the layer", a)
}
