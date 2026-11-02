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
