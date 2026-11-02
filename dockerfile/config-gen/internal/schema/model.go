package schema

// State says whether a field is written in the layer.
type State int

// The states of a field decoded so far.
const (
	Absent State = iota
	Set
)

// Field is one scalar of the layer: its state, its value and the 1-based
// line its key is written on.
type Field struct {
	State State
	Value Scalar
	Line  int
}

// Logging is the decoded [logging] section.
type Logging struct {
	// Services is keyed by the section text below `logging.`, whatever
	// TOML path produced it (`[logging.a.b]` and `"a.b".driver` under
	// [logging] both feed "a.b").
	Services map[string]*Service
}

// Service is one per-service logging section.
type Service struct {
	// Rows is every scalar row for the section text, in the bridge's
	// traversal order, duplicates kept.
	Rows []Row
	// Driver and MaxFile are each the last row of Rows with their key
	// (the `_conf_get` rule), or Absent.
	Driver  Field
	MaxFile Field
}

// Row is one scalar row of a service: the key as spelled and its field.
type Row struct {
	Key   string
	Field Field
}

// Tree is every accepted table node of a layer, empty ones included, so
// two layers can be merged on TOML keys the way _merge_tables
// (toml_bridge.py:914) merges them (base#1442).
type Tree struct {
	// Nodes[0] is the root; a node's index is its visit order in the
	// bridge's traversal.
	Nodes []Node
}

// Node is one table node.
type Node struct {
	// Path is the raw TOML path (`["logging.a"]` and `["logging","a"]`
	// are two nodes); nil for the root.
	Path []string
	// Text is Path joined with ".", the section text.
	Text string
	// Line is the 1-based line of the node's first occurrence: its
	// header, its first creator's when Implicit, its key's when Inline.
	Line int
	// Implicit marks a table with no header of its own.
	Implicit bool
	// Inline marks an inline table.
	Inline bool
	// Children are in creation order, the bridge's dict insertion order.
	Children []Child
}

// ChildKind is what a child of a node is.
type ChildKind int

// The kinds of a child.
const (
	// ChildNode is a table: Child.Node indexes Tree.Nodes.
	ChildNode ChildKind = iota
	// ChildRow is a scalar: Child.Row is its field.
	ChildRow
	// ChildDeferred is an array, which the array stage owns; S6 keeps
	// only its key and its place.
	ChildDeferred
)

// Child is one child of a node.
type Child struct {
	Kind ChildKind
	// Key is the child's TOML key as spelled.
	Key  string
	Node int
	Row  Field
}
