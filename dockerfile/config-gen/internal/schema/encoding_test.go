package schema

import (
	"testing"
)

// Bytes that are not UTF-8 are refused wherever they stand (base#1442 AC
// "Invalid UTF-8 is refused with attribution", review round 4): the bridge
// decodes the whole layer as UTF-8 before tomllib reads it, so no position
// is exempt, a leading FF FE or FE FF that the TOML library strips as a
// byte-order mark included. Each invalid sequence is inserted at every
// offset of an accepted layer, and every result must be one
// conf_toml_parse_failed refusal with a line and a column, and no Config.
func TestDecodeRefusesInvalidUTF8AtEveryOffset(t *testing.T) {
	base := "# layer\n[environment]\nenv_1 = \"A=b\" # note\n[deploy]\ngpu_count = 1\n"
	if cfg, refusals := Decode([]byte(base)); cfg == nil || len(refusals) != 0 {
		t.Fatalf("base layer: Decode = %+v, %+v; want accepted", cfg, refusals)
	}
	for _, bad := range []string{"\xff", "\xfe", "\xff\xfe", "\xfe\xff", "\xc3", "\xed\xa0\x80"} {
		for i := 0; i <= len(base); i++ {
			src := base[:i] + bad + base[i:]
			cfg, refusals := Decode([]byte(src))
			if cfg != nil || len(refusals) != 1 || refusals[0].Event != "conf_toml_parse_failed" {
				t.Errorf("%q at offset %d: Decode = %+v, %+v; want one conf_toml_parse_failed", bad, i, cfg, refusals)
				continue
			}
			if refusals[0].Line <= 0 || refusals[0].Col <= 0 {
				t.Errorf("%q at offset %d: refusal %+v has no line and column", bad, i, refusals[0])
			}
		}
	}
}

// A leading UTF-8 byte-order mark is refused at line 1 column 1: the
// bridge decodes it to U+FEFF, which tomllib refuses as "Invalid statement
// (at line 1, column 1)", while the TOML library strips it (review
// round 4).
func TestDecodeRefusesUTF8ByteOrderMark(t *testing.T) {
	cfg, refusals := Decode([]byte("\xef\xbb\xbf[deploy]\ngpu_count = 1\n"))
	if cfg != nil || len(refusals) != 1 {
		t.Fatalf("Decode = %+v, %+v; want no config and one refusal", cfg, refusals)
	}
	if r := refusals[0]; r.Event != "conf_toml_parse_failed" || r.Line != 1 || r.Col != 1 {
		t.Errorf("refusal = %+v, want conf_toml_parse_failed at 1:1", r)
	}
}
