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

// checkEntries refuses, as conf_entry_no_gating_field at its first
// position, each table element of the array b at path p that carries
// fields but none of the fields its family is read from, as the bridge's
// _check_entry does. A field-less element, the cleared slot, carries
// nothing and is not refused (base#1443). An element holding a name that
// keyCharEvent refuses keeps that refusal as its only one, as base#1442
// decided.
func (d *decoder) checkEntries(p []string, b *bound) {
	gating, ok := gatingFields[p[len(p)-1]]
	if !ok {
		return
	}
	for _, e := range b.children {
		if !e.isTable() || len(e.children) == 0 || carriesAny(e, gating) || holdsBadName(e) {
			continue
		}
		line, col := e.firstPos()
		d.refuse("conf_entry_no_gating_field", p, line, col)
	}
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
