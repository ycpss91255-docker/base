package diag

import (
	"bytes"
	"testing"
)

// A frame is eight NUL-terminated fields -- the tag `D`, severity, event,
// file, line, column, key and text -- each carried byte for byte: a tab,
// LF, CR, `"`, `\` or a multi-byte UTF-8 character in the label or the
// message is neither escaped nor quoted, and an empty field is an empty
// field (ADR-00000039 §3, base#1469). The want bytes are written out by
// hand from that frame layout, with the UTF-8 bytes of é (C3 A9) and the
// em dash (E2 80 94) spelled in hex.
func TestEncodeCarriesFieldsVerbatim(t *testing.T) {
	f := Frame{
		Sev:   "error",
		Event: "conf_toml_parse_failed",
		File:  "l\ta\"b\\é\nc\rd",
		Line:  "3",
		Col:   "14",
		Key:   "",
		Text:  "bad \"v\" — x\\y",
	}
	want := []byte("D\x00" +
		"error\x00" +
		"conf_toml_parse_failed\x00" +
		"l\x09a\x22b\x5c\xc3\xa9\x0ac\x0dd\x00" +
		"3\x00" +
		"14\x00" +
		"\x00" +
		"bad \x22v\x22 \xe2\x80\x94 x\x5cy\x00")

	got := Encode(f)
	if !bytes.Equal(got, want) {
		t.Fatalf("Encode = %q, want %q", got, want)
	}
}
