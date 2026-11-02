package schema

import (
	"fmt"
	"strconv"
)

// Kind is the TOML kind of a scalar value.
type Kind string

// The scalar kinds decoded so far.
const (
	KindString Kind = "string"
	KindInt    Kind = "int"
	KindFloat  Kind = "float"
	KindBool   Kind = "bool"
)

// Scalar is one scalar value of a layer. Kind is its TOML kind; Text is
// the bridge's text for it (toml_bridge.py _format_value: a bool is
// `true` or `false`, a string is itself, a number is Python's str()), the
// text _schema_validate judges.
type Scalar struct {
	Kind Kind
	Text string
}

// UnmarshalTOML implements toml.Unmarshaler. Strings, bools, ints and
// floats so far; the other kinds, and Python's text for every float
// (`1000.0`, `1e+16`), follow in later cycles of base#1442.
func (s *Scalar) UnmarshalTOML(v any) error {
	switch x := v.(type) {
	case string:
		s.Kind, s.Text = KindString, x
	case bool:
		s.Kind, s.Text = KindBool, "false"
		if x {
			s.Text = "true"
		}
	case int64:
		s.Kind, s.Text = KindInt, strconv.FormatInt(x, 10)
	case float64:
		s.Kind, s.Text = KindFloat, strconv.FormatFloat(x, 'g', -1, 64)
	default:
		return fmt.Errorf("unsupported scalar type %T", v)
	}
	return nil
}
