package schema

// State says whether a field is written in the layer.
type State int

// The states of a field decoded so far.
const (
	Absent State = iota
	Set
	// Empty is a table that is written but holds no key (base#1309).
	Empty
)

// Field is one scalar of the layer: its state, its value and the 1-based
// line its key is written on.
type Field struct {
	State State
	Value Scalar
	Line  int
}

// Deploy is the part of the decoded [deploy] section that resolves the
// legacy alias.
type Deploy struct {
	// GPURuntime is gpu_runtime when it is set to a non-empty value, and
	// otherwise the legacy runtime's field: the rule deploy.sh's
	// _resolve_deploy_config applies (base#1442).
	GPURuntime Field
	// Runtime is the legacy key as written.
	Runtime Field
}

// Deprecation is one key written in a deprecated spelling: its path, the
// canonical path it stands for, and the 1-based line it is written on.
type Deprecation struct {
	Path      []string
	Canonical []string
	Line      int
}

// Environment is the decoded [environment] section.
type Environment struct {
	// Table is Absent with no [environment], Empty when it is written
	// with no key, Set when it holds a key.
	Table Field
	// Env is each scalar key directly under the table.
	Env map[string]Field
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
// (toml_bridge.py line 914) merges them (base#1442).
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
	// its key and its place, and Child.Defer indexes Config.Deferred.
	ChildDeferred
)

// Child is one child of a node.
type Child struct {
	Kind ChildKind
	// Key is the child's TOML key as spelled.
	Key   string
	Node  int
	Row   Field
	Defer int
}

// Deferred is one array the array stage owns, with its whole payload, so
// two layers that differ only inside an array decode to different models
// (base#1442).
type Deferred struct {
	// Path is the raw TOML path of the array.
	Path []string
	// Type is the library's md.Type for the path.
	Type string
	// Line is the 1-based line of the array's first occurrence.
	Line  int
	Value Value
}

// ValueKind is what a Value is.
type ValueKind int

// The kinds of a value.
const (
	VScalar ValueKind = iota
	VArray
	VTable
)

// Value is one value inside a deferred array.
type Value struct {
	Kind   ValueKind
	Scalar Scalar
	// Items are the elements of a VArray.
	Items []Value
	// Members are the keys of a VTable, in source order.
	Members []Member
	// Header marks a VTable written as a `[[path]]` element.
	Header bool
	// Line is the 1-based line the value starts on: an element's header
	// line, a key's line.
	Line int
}

// Member is one key of a VTable and its value.
type Member struct {
	Key   string
	Value Value
}

// Family is one `[[array]]` family of the layer: its TOML path as
// written, one element per key segment, its state, the 1-based line of
// its first occurrence and its entries in written order (base#1443).
type Family struct {
	Path    []string
	State   State
	Line    int
	Entries []Entry
}

// Entry is one element of a family: its 1-based index in the family, the
// 1-based line it starts on and its fields in written order.
type Entry struct {
	Index  int
	Line   int
	Fields []EntryField
}

// EntryField is one key of an entry and its value.
type EntryField struct {
	Key   string
	Value Value
}

// Cleared reports an entry that carries no field, the cleared slot: it is
// kept in its position as one empty entry (base#1443).
func (e Entry) Cleared() bool {
	return len(e.Fields) == 0
}
