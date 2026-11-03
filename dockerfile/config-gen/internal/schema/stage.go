package schema

import "strings"

// MemberKind is what a member of a stage table is.
type MemberKind int

// The kinds of a stage member.
const (
	// MemberScalar is a scalar key: StageMember.Value is its value.
	MemberScalar MemberKind = iota
	// MemberTable is a sub-table: StageMember.Table holds its members.
	MemberTable
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
// with its dot, its kind, its 1-based line and its value, or for a
// sub-table its members in Table.
type StageMember struct {
	Key   string
	Kind  MemberKind
	Line  int
	Value Scalar
	Table *StageTable
}

// StageTable is a sub-table of a stage, `["stage:<name>".deploy]` or the
// dotted `deploy.gpu_mode` inside the stage: its members in written
// order (base#1443).
type StageTable struct {
	Members []StageMember
}

// projectStages is every `["stage:<name>"]` table directly under the
// root of t, in traversal order, with its scalar keys and sub-tables as
// Members.
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
		out = append(out, Stage{Name: name, Line: n.Line, Members: stageMembers(t, n)})
	}
	return out
}

// stageMembers is the scalar keys and sub-tables of n in written order.
func stageMembers(t *Tree, n Node) []StageMember {
	var out []StageMember
	for _, r := range n.Children {
		switch r.Kind {
		case ChildRow:
			out = append(out, StageMember{Key: r.Key, Kind: MemberScalar, Line: r.Row.Line, Value: r.Row.Value})
		case ChildNode:
			sub := t.Nodes[r.Node]
			out = append(out, StageMember{Key: r.Key, Kind: MemberTable, Line: sub.Line, Table: &StageTable{Members: stageMembers(t, sub)}})
		case ChildDeferred:
			// An array is not modelled as a stage member.
		}
	}
	return out
}
