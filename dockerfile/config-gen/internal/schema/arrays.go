package schema

import "strings"

// gatingFields is, per array family, the fields its entries are read
// from: the third element of the bridge's _ARRAY_SPEC
// (dockerfile/toml_bridge.py), keyed as the bridge keys it, by the
// array's last name (base#1443).
var gatingFields = map[string][]string{
	"rules":               {"rule"},
	"args":                {"key"},
	"ports":               {"host"},
	"cap_add":             {"cap"},
	"cap_drop":            {"cap"},
	"security_opt":        {"opt"},
	"volumes":             {"source", "target", "mode"},
	"tmpfs":               {"path"},
	"devices":             {"path"},
	"bindings":            {"path"},
	"cgroup_rules":        {"rule"},
	"additional_contexts": {"name"},
}

// alsoRead is, per array family, the fields its entries are read from
// beyond gatingFields: the fourth element of the bridge's _ARRAY_SPEC.
// The two together are every field the family reads (base#1443).
var alsoRead = map[string][]string{
	"args":                {"value"},
	"ports":               {"container"},
	"tmpfs":               {"size"},
	"additional_contexts": {"source"},
}

// fieldNeeds is, per array family, the fields its entries read only
// beside another one, mapped to that other field: the bridge's
// _FIELD_NEEDS (dockerfile/toml_bridge.py). Presence, not truthiness,
// supplies the needed field (base#1443).
var fieldNeeds = map[string]map[string]string{
	"volumes": {"target": "source", "mode": "target"},
}

// checkEntries refuses, as conf_entry_not_table at its position, each
// element of the array b at path p that is not a table, and, as
// conf_entry_no_gating_field at its first position, each table element
// that carries fields but none of the fields its family is read from, as
// the bridge's _check_entry does. A table element that carries a gating
// field and, beside it, a field its family does not read is refused as
// conf_entry_unknown_field at that field, the first in sorted order, as
// the bridge names them sorted. An element whose fields are all read
// and one of which holds a list or a table, where a single value
// belongs, is refused as conf_value_type_refused at that field, the
// first in sorted order, as the bridge's _check_entry checks it after
// the unknown field. An element carrying a field without the field its
// family needs beside it (fieldNeeds) is refused, checked last, as
// conf_entry_field_needs at that field, the first in sorted order, as
// the bridge walks _FIELD_NEEDS sorted. A field-less element, the cleared
// slot, carries nothing and is not refused (base#1443). An element
// holding a name that keyCharEvent refuses keeps that refusal as its only
// one, as base#1442 decided. It returns the elements it refused, so
// that no value refusal is added beside the one it picked (base#1443).
func (d *decoder) checkEntries(p []string, b *bound) map[*bound]bool {
	refused := map[*bound]bool{}
	gating, ok := gatingFields[p[len(p)-1]]
	if !ok {
		return refused
	}
	for _, e := range b.children {
		if !e.isTable() {
			line, col := e.firstPos()
			d.refuse("conf_entry_not_table", p, line, col)
			refused[e] = true
			continue
		}
		if len(e.children) == 0 || holdsBadName(e) {
			continue
		}
		if !carriesAny(e, gating) {
			line, col := e.firstPos()
			d.refuse("conf_entry_no_gating_field", p, line, col)
			refused[e] = true
			continue
		}
		read := [][]string{gating, alsoRead[p[len(p)-1]]}
		if f := firstBy(e, func(c *bound) bool { return !carriedBy(c.node.Key, read...) }); f != nil {
			line, col := f.declPos()
			d.refuse("conf_entry_unknown_field", append(append([]string{}, p...), f.node.Key), line, col)
			refused[e] = true
			continue
		}
		if f := firstBy(e, func(c *bound) bool { return c.isTable() || c.isArray() }); f != nil {
			line, col := f.declPos()
			d.refuse("conf_value_type_refused", append(append([]string{}, p...), f.node.Key), line, col)
			refused[e] = true
			continue
		}
		if f := firstBy(e, func(c *bound) bool {
			need, ok := fieldNeeds[p[len(p)-1]][c.node.Key]
			return ok && !carriesAny(e, []string{need})
		}); f != nil {
			line, col := f.declPos()
			d.refuse("conf_entry_field_needs", append(append([]string{}, p...), f.node.Key), line, col)
			refused[e] = true
		}
	}
	return refused
}

// firstBy is the member of the table e, first by name, that match
// reports, or nil when it reports none.
func firstBy(e *bound, match func(*bound) bool) *bound {
	var first *bound
	for _, c := range e.children {
		if !match(c) {
			continue
		}
		if first == nil || c.node.Key < first.node.Key {
			first = c
		}
	}
	return first
}

// carriedBy reports whether name is in one of the lists.
func carriedBy(name string, lists ...[]string) bool {
	for _, l := range lists {
		for _, n := range l {
			if n == name {
				return true
			}
		}
	}
	return false
}

// holdsBadName reports whether a name at or under b draws keyCharEvent.
func holdsBadName(b *bound) bool {
	for _, c := range b.children {
		if (!c.keyless() && keyCharEvent(c.node.Key) != "") || holdsBadName(c) {
			return true
		}
	}
	return false
}

// carriesAny reports whether the table e holds a key named in names.
func carriesAny(e *bound, names []string) bool {
	for _, c := range e.children {
		for _, n := range names {
			if c.node.Key == n {
				return true
			}
		}
	}
	return false
}

// FamilySpec is what one array family reads: its last name, the
// numbered prefix the shell side writes its entries under, the fields
// its entries are read from and those read beside them, and the fields
// read only beside another one -- the bridge's _ARRAY_SPEC and
// _FIELD_NEEDS (dockerfile/toml_bridge.py) for that name (base#1443).
type FamilySpec struct {
	Leaf     string
	Prefix   string
	Gating   []string
	AlsoRead []string
	Needs    map[string]string
}

// Home is one place an array family is written: its path, its family
// and whether it is the legacy one-array `[[devices]]` spelling
// (base#1443).
type Home struct {
	Path   []string
	Spec   FamilySpec
	Legacy bool
}

// homes is every array home in the order the shell writers number them
// (_conf_toml_aot_section over SCHEMA_SECTIONS, dist/script/docker/lib/conf.sh),
// with the prefix each is written under, the legacy `[[devices]]` last.
var homes = []struct {
	path   []string
	prefix string
	legacy bool
}{
	{[]string{"image", "rules"}, "rule", false},
	{[]string{"build", "args"}, "arg", false},
	{[]string{"network", "ports"}, "port", false},
	{[]string{"security", "cap_add"}, "cap_add", false},
	{[]string{"security", "cap_drop"}, "cap_drop", false},
	{[]string{"security", "security_opt"}, "security_opt", false},
	{[]string{"tmpfs"}, "tmpfs", false},
	{[]string{"devices", "bindings"}, "device", false},
	{[]string{"devices", "cgroup_rules"}, "cgroup_rule", false},
	{[]string{"volumes"}, "mount", false},
	{[]string{"additional_contexts"}, "context", false},
	{[]string{"devices"}, "device", true},
}

// Homes is every array home, derived from the family tables the entry
// check reads, in the shell writers' order (base#1443).
func Homes() []Home {
	out := make([]Home, 0, len(homes))
	for _, h := range homes {
		leaf := h.path[len(h.path)-1]
		out = append(out, Home{
			Path: append([]string{}, h.path...),
			Spec: FamilySpec{
				Leaf:     leaf,
				Prefix:   h.prefix,
				Gating:   gatingFields[leaf],
				AlsoRead: alsoRead[leaf],
				Needs:    fieldNeeds[leaf],
			},
			Legacy: h.legacy,
		})
	}
	return out
}

// checkSpellings refuses, as conf_family_two_spellings at the scalar's
// position, each table scalar `<prefix>_<digits>` of a table under the
// root that also holds the array of the family numbered under that
// prefix, as the bridge's _check_one_spelling does: the shell view would
// carry that entry twice. Only a table below the root is walked, as the
// bridge walks it; a root-level family cannot collide in one file
// (base#1443).
func (d *decoder) checkSpellings(b *bound, path []string) {
	for _, c := range b.children {
		if !c.isTable() || c.keyless() {
			continue
		}
		p := append(append([]string{}, path...), c.node.Key)
		d.checkSpellings(c, p)
		for _, a := range c.children {
			if !a.isArray() {
				continue
			}
			prefix, ok := prefixOf(a.node.Key)
			if !ok {
				continue
			}
			for _, s := range c.children {
				k := append(append([]string{}, p...), s.node.Key)
				if s.isTable() || s.isArray() || !numberedUnder(s.node.Key, prefix) || d.refusedUnder(k) {
					continue
				}
				line, col := s.declPos()
				d.refuse("conf_family_two_spellings", k, line, col)
			}
		}
	}
}

// prefixOf is the numbered prefix the shell side writes the family whose
// array is named leaf under, from homes.
func prefixOf(leaf string) (string, bool) {
	for _, h := range homes {
		if h.path[len(h.path)-1] == leaf {
			return h.prefix, true
		}
	}
	return "", false
}

// numberedUnder reports whether key is prefix, "_" and one or more
// decimal digits, the suffix _scalar_spellings_of accepts.
func numberedUnder(key, prefix string) bool {
	rest, ok := strings.CutPrefix(key, prefix+"_")
	if !ok || rest == "" {
		return false
	}
	for _, r := range rest {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
