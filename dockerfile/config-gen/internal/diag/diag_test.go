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

// Every field, not only the label, carries the whole set of bytes an
// encoder might be tempted to escape -- tab, LF, CR, `"`, `\`, é and the em
// dash -- byte for byte (base#1469 Diagnostics: the `--name` label and
// library messages are carried verbatim). Each row puts that set into one
// field and plain words into the other six, so an encoder that escapes or
// quotes any single field, the message text included, fails the row for
// that field. The hostile value is spelled in hex in want.
func TestEncodeCarriesEachFieldVerbatim(t *testing.T) {
	const hostile = "a\tb\nc\rd\"e\\f é — g"
	const hostileHex = "a\x09b\x0ac\x0dd\x22e\x5cf \xc3\xa9 \xe2\x80\x94 g"
	plain := []string{"sev", "event", "file", "line", "col", "key", "text"}
	set := []func(*Frame, string){
		func(f *Frame, v string) { f.Sev = v },
		func(f *Frame, v string) { f.Event = v },
		func(f *Frame, v string) { f.File = v },
		func(f *Frame, v string) { f.Line = v },
		func(f *Frame, v string) { f.Col = v },
		func(f *Frame, v string) { f.Key = v },
		func(f *Frame, v string) { f.Text = v },
	}
	for i, name := range plain {
		t.Run(name, func(t *testing.T) {
			var f Frame
			want := []byte("D\x00")
			for j := range plain {
				v, w := plain[j], plain[j]
				if j == i {
					v, w = hostile, hostileHex
				}
				set[j](&f, v)
				want = append(want, w...)
				want = append(want, 0)
			}
			got := Encode(f)
			if !bytes.Equal(got, want) {
				t.Fatalf("Encode with %s = %q: got %q, want %q", name, hostile, got, want)
			}
		})
	}
}
