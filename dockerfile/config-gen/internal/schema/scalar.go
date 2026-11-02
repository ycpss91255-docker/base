package schema

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// Kind is the TOML kind of a scalar value.
type Kind string

// The scalar kinds decoded so far, named as toml-test names them.
const (
	KindString    Kind = "string"
	KindInt       Kind = "int"
	KindFloat     Kind = "float"
	KindBool      Kind = "bool"
	KindDatetime  Kind = "datetime"
	KindLocalDate Kind = "date-local"
)

// Scalar is one scalar value of a layer. Kind is its TOML kind; Text is
// the bridge's text for it (toml_bridge.py _format_value: a bool is
// `true` or `false`, a string is itself, anything else is Python's
// str()), the text _schema_validate judges.
type Scalar struct {
	Kind Kind
	Text string
}

// UnmarshalTOML implements toml.Unmarshaler.
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
		s.Kind, s.Text = KindFloat, pythonFloat(x)
	case time.Time:
		k, text, err := pythonTime(x)
		if err != nil {
			return err
		}
		s.Kind, s.Text = k, text
	default:
		return fmt.Errorf("unsupported scalar type %T", v)
	}
	return nil
}

// pythonFloat is Python's str() of a float: the shortest round-tripping
// digits, positional with a trailing `.0` when integral (`3.0`), and
// scientific with a two-digit exponent (`1e+16`, `1e-05`) when the
// decimal exponent is below -4 or 16 and above; `inf`, `-inf`, `nan`.
func pythonFloat(x float64) string {
	if math.IsInf(x, 0) || math.IsNaN(x) {
		return strings.ToLower(strings.TrimPrefix(strconv.FormatFloat(x, 'g', -1, 64), "+"))
	}
	sci := strconv.FormatFloat(x, 'e', -1, 64)
	_, exp, _ := strings.Cut(sci, "e")
	if e, _ := strconv.Atoi(exp); e < -4 || e >= 16 {
		return sci
	}
	fixed := strconv.FormatFloat(x, 'f', -1, 64)
	if !strings.Contains(fixed, ".") {
		fixed += ".0"
	}
	return fixed
}

// pythonTime is the TOML kind of a decoded date or offset datetime and
// Python's str() of what tomllib makes of it. BurntSushi/toml marks a
// local date by the name of the zone it parses it in. A local datetime,
// a local time and a fractional second are not decoded yet; they follow
// in later cycles of base#1442.
func pythonTime(t time.Time) (Kind, string, error) {
	switch {
	case t.Location().String() == "date-local":
		return KindLocalDate, t.Format("2006-01-02"), nil
	case strings.HasSuffix(t.Location().String(), "-local") || t.Nanosecond() != 0:
		return "", "", fmt.Errorf("unsupported scalar value %s", t.Format(time.RFC3339Nano))
	}
	return KindDatetime, t.Format("2006-01-02 15:04:05-07:00"), nil
}
