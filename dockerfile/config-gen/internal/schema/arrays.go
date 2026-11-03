package schema

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
// the unknown field. A field-less element, the cleared
// slot, carries nothing and is not refused (base#1443). An element
// holding a name that keyCharEvent refuses keeps that refusal as its only
// one, as base#1442 decided.
func (d *decoder) checkEntries(p []string, b *bound) {
	gating, ok := gatingFields[p[len(p)-1]]
	if !ok {
		return
	}
	for _, e := range b.children {
		if !e.isTable() {
			line, col := e.firstPos()
			d.refuse("conf_entry_not_table", p, line, col)
			continue
		}
		if len(e.children) == 0 || holdsBadName(e) {
			continue
		}
		if !carriesAny(e, gating) {
			line, col := e.firstPos()
			d.refuse("conf_entry_no_gating_field", p, line, col)
			continue
		}
		read := [][]string{gating, alsoRead[p[len(p)-1]]}
		if f := firstBy(e, func(c *bound) bool { return !carriedBy(c.node.Key, read...) }); f != nil {
			line, col := f.declPos()
			d.refuse("conf_entry_unknown_field", append(append([]string{}, p...), f.node.Key), line, col)
			continue
		}
		if f := firstBy(e, func(c *bound) bool { return c.isTable() || c.isArray() }); f != nil {
			line, col := f.declPos()
			d.refuse("conf_value_type_refused", append(append([]string{}, p...), f.node.Key), line, col)
		}
	}
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
