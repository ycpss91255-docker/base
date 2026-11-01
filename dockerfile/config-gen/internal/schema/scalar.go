package schema

import "fmt"

// Scalar is one scalar value of a layer. Text is the bridge's text for it
// (toml_bridge.py _format_value: a bool is `true` or `false`, a string is
// itself), the text _schema_validate judges.
type Scalar struct {
	Text string
}

// UnmarshalTOML implements toml.Unmarshaler. Strings and bools so far; the
// other kinds follow in later cycles of base#1442.
func (s *Scalar) UnmarshalTOML(v any) error {
	switch x := v.(type) {
	case string:
		s.Text = x
	case bool:
		s.Text = "false"
		if x {
			s.Text = "true"
		}
	default:
		return fmt.Errorf("unsupported scalar type %T", v)
	}
	return nil
}
