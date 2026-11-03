package schema

import (
	"reflect"
	"testing"
)

// A layer the parser refuses is one conf_toml_parse_failed refusal with
// attribution (base#1442 AC "Invalid UTF-8 is refused with attribution",
// review round 2 finding 2): the parser's line and column, and the path of
// the last table or key the locator found at or before that line, so the
// refusal names what the operator has to edit. Line and column are the
// library's for these bytes: line 2 column 9 for the byte 0xff inside the
// value, line 2 for a 0xff inside the key, whose key the locator cannot
// read, so the table above it is named.
func TestDecodeParseErrorIsAttributed(t *testing.T) {
	cases := []struct {
		name string
		src  string
		path []string
		line int
		col  int
	}{
		{"invalid UTF-8 in a value", "[environment]\nenv_1 = \"\xff\"\n", []string{"environment", "env_1"}, 2, 9},
		{"invalid UTF-8 in a key", "[environment]\nenv_\xff = \"A=b\"\n", []string{"environment"}, 2, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, refusals := Decode([]byte(tc.src))

			if cfg != nil || len(refusals) != 1 {
				t.Fatalf("Decode = %+v, %+v; want no config and one refusal", cfg, refusals)
			}
			got := refusals[0]
			if got.Event != "conf_toml_parse_failed" || got.Line != tc.line || !reflect.DeepEqual(got.Path, tc.path) {
				t.Errorf("refusal = %+v, want conf_toml_parse_failed at line %d naming %q", got, tc.line, tc.path)
			}
			if tc.col != 0 && got.Col != tc.col {
				t.Errorf("Col = %d, want %d", got.Col, tc.col)
			}
			if got.Col <= 0 {
				t.Errorf("Col = %d, want the parser's column", got.Col)
			}
		})
	}
}
