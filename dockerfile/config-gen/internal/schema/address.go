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
	n, err := strconv.Atoi(key[i+1:])
	if err != nil {
		return Address{}, fmt.Errorf("address %q: %w", s, err)
	}
	return Address{Section: section, Prefix: key[:i], Index: n}, nil
}
