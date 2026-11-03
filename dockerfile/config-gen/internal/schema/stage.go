package schema

import "strings"

// MemberKind is what a member of a stage table is.
type MemberKind int

// The kinds of a stage member.
const (
	// MemberScalar is a scalar key: StageMember.Value is its value.
	MemberScalar MemberKind = iota
)

// Stage is one `["stage:<name>"]` table of the layer: the name after
// `stage:`, the 1-based line of its first occurrence and its members in
// written order (base#1443).
type Stage struct {
	Name    string
	Line    int
	Members []StageMember
}

// StageMember is one key of a stage table: the key exactly as written,
// one TOML key segment, so a quoted `"deploy.gpu_mode"` stays one key
// with its dot, its kind, its 1-based line and its value.
type StageMember struct {
	Key   string
	Kind  MemberKind
	Line  int
	Value Scalar
}

// projectStages is every `["stage:<name>"]` table directly under the
// root of t, in traversal order, with its scalar keys as Members.
func projectStages(t *Tree) []Stage {
	var out []Stage
	if len(t.Nodes) == 0 {
		return out
	}
	for _, c := range t.Nodes[0].Children {
		name, ok := strings.CutPrefix(c.Key, "stage:")
		if c.Kind != ChildNode || !ok {
			continue
		}
		n := t.Nodes[c.Node]
		s := Stage{Name: name, Line: n.Line}
		for _, r := range n.Children {
			if r.Kind != ChildRow {
				continue
			}
			s.Members = append(s.Members, StageMember{Key: r.Key, Kind: MemberScalar, Line: r.Row.Line, Value: r.Row.Value})
		}
		out = append(out, s)
	}
	return out
}
