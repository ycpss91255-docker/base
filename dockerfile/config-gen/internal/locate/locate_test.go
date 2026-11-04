package locate

import (
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// corpusFile reads the one corpus/s6 file named base through testcorpus.
func corpusFile(t *testing.T, base string) []byte {
	t.Helper()
	files := testcorpus.Glob(t, "corpus/s6/"+base)
	src, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	return src
}

// occLines returns each occurrence's KeyLine and Ordinal, in order.
func occLines(all []Occurrence) (lines, ordinals []int) {
	for _, o := range all {
		lines = append(lines, o.KeyLine)
		ordinals = append(ordinals, o.Ordinal)
	}
	return lines, ordinals
}

// TestIndexRepeatedOccurrences checks the earlier occurrences of a path
// written more than once, which the library cannot report (it keeps only
// the last position), so every expected line is counted by hand from the
// fixture text (base#1442). An explicit table stays one occurrence when a
// later array-table header lies under it, and an inline array is one
// occurrence with nothing inside it indexed.
func TestIndexRepeatedOccurrences(t *testing.T) {
	t.Run("s6_loc_aot.toml", func(t *testing.T) {
		m := Index(corpusFile(t, "s6_loc_aot.toml"))
		vol := []string{"volumes"}
		src := []string{"volumes", "source"}

		lines, ords := occLines(m.Tables(vol))
		if !reflect.DeepEqual(lines, []int{1, 4, 7}) || !reflect.DeepEqual(ords, []int{0, 1, 2}) {
			t.Errorf("Tables(volumes) lines=%v ordinals=%v, want [1 4 7] [0 1 2]", lines, ords)
		}
		lines, _ = occLines(m.Keys(src))
		if !reflect.DeepEqual(lines, []int{2, 5, 8}) {
			t.Errorf("Keys(volumes.source) lines=%v, want [2 5 8]", lines)
		}
		if _, lk := m.Table(vol); lk != Repeated {
			t.Errorf("Table(volumes) = %v, want Repeated", lk)
		}
		if _, lk := m.Key(src); lk != Repeated {
			t.Errorf("Key(volumes.source) = %v, want Repeated", lk)
		}
		var seq []string
		for _, o := range m.Entries() {
			seq = append(seq, fmt.Sprintf("%s#%d", toml.Key(o.Path), o.Ordinal))
		}
		want := []string{"volumes#0", "volumes.source#0", "volumes#1", "volumes.source#1", "volumes#2", "volumes.source#2"}
		if !reflect.DeepEqual(seq, want) {
			t.Errorf("Entries() = %q, want %q", seq, want)
		}
	})

	t.Run("s6_loc_aot_nested.toml", func(t *testing.T) {
		m := Index(corpusFile(t, "s6_loc_aot_nested.toml"))
		if o, lk := m.Table([]string{"devices"}); lk != Found || o.KeyLine != 1 {
			t.Errorf("Table(devices) = %v line %d, want Found line 1 (all: %+v)", lk, o.KeyLine, m.Tables([]string{"devices"}))
		}
		if o, lk := m.Key([]string{"devices", "device_1"}); lk != Found || o.KeyLine != 2 {
			t.Errorf("Key(devices.device_1) = %v line %d, want Found line 2", lk, o.KeyLine)
		}
		if lines, _ := occLines(m.Tables([]string{"devices", "bindings"})); !reflect.DeepEqual(lines, []int{4, 7}) {
			t.Errorf("Tables(devices.bindings) lines=%v, want [4 7]", lines)
		}
		if lines, _ := occLines(m.Keys([]string{"devices", "bindings", "path"})); !reflect.DeepEqual(lines, []int{5, 8}) {
			t.Errorf("Keys(devices.bindings.path) lines=%v, want [5 8]", lines)
		}
	})

	t.Run("s6_loc_inline_aot.toml", func(t *testing.T) {
		m := Index(corpusFile(t, "s6_loc_inline_aot.toml"))
		all := m.Keys([]string{"volumes"})
		if len(all) != 1 || !all[0].Inline || all[0].KeyLine != 1 {
			t.Errorf("Keys(volumes) = %+v, want one Inline occurrence on line 1", all)
		}
		if n := len(m.Keys([]string{"volumes", "source"})); n != 0 {
			t.Errorf("Keys(volumes.source): %d occurrences, want none", n)
		}
	})
}

// TestIndexHeaderInMultilineString checks that a header-like line inside a
// multi-line basic string is string content, not a header (base#1442). The
// bridge (`toml_bridge.py --tables`) prints only `lifecycle` for this file
// and `--kv` prints `lifecycle\twatchdog_check\t[fake]`; the key sits on
// line 2 of the fixture text and its value ends on line 4.
func TestIndexHeaderInMultilineString(t *testing.T) {
	m := Index(corpusFile(t, "s6_ml_header.toml"))
	if all := m.Tables([]string{"fake"}); len(all) != 0 {
		t.Errorf("Tables(fake) = %+v, want no occurrence (the line is inside a string)", all)
	}
	var tables []string
	for _, o := range m.Entries() {
		if o.Kind == Header || o.Kind == ArrayHeader {
			tables = append(tables, toml.Key(o.Path).String())
		}
	}
	if !reflect.DeepEqual(tables, []string{"lifecycle"}) {
		t.Errorf("header occurrences = %q, want [lifecycle]", tables)
	}
	o, lk := m.Key([]string{"lifecycle", "watchdog_check"})
	if lk != Found || o.KeyLine != 2 || o.ValueEndLine != 4 {
		t.Errorf("Key(lifecycle.watchdog_check) = %v KeyLine=%d ValueEndLine=%d, want Found 2 4", lk, o.KeyLine, o.ValueEndLine)
	}
}

// TestIndexMultilineArray checks that a multi-line array is one value: a
// line inside it that starts with `[` is array content, not a header, and
// the key after it belongs to the enclosing table (base#1442). The library
// lists only devices, devices.matrix and devices.after for this file, and
// reports a multi-line array at its START line (BurntSushi v1.6.0, design
// probe3: key line 2, ends line 4 -> line 2), so ValueEndLine stays on
// the key's line; the other lines are counted by hand from the fixture.
func TestIndexMultilineArray(t *testing.T) {
	m := Index(corpusFile(t, "s6_loc_ml_array.toml"))
	var seq []string
	for _, o := range m.Entries() {
		seq = append(seq, fmt.Sprintf("%s#%d", toml.Key(o.Path), o.Ordinal))
	}
	want := []string{"devices#0", "devices.matrix#0", "devices.after#0"}
	if !reflect.DeepEqual(seq, want) {
		t.Errorf("Entries() = %q, want %q", seq, want)
	}
	if o, lk := m.Key([]string{"devices", "matrix"}); lk != Found || !o.Inline || o.KeyLine != 2 || o.ValueEndLine != 2 {
		t.Errorf("Key(devices.matrix) = %v Inline=%v KeyLine=%d ValueEndLine=%d, want Found true 2 2", lk, o.Inline, o.KeyLine, o.ValueEndLine)
	}
	if o, lk := m.Key([]string{"devices", "after"}); lk != Found || o.KeyLine != 6 {
		t.Errorf("Key(devices.after) = %v KeyLine=%d, want Found 6", lk, o.KeyLine)
	}
}

// TestIndexKeyEscapes checks that a quoted key is indexed under the key
// the library decodes, every TOML 1.0 escape included, and that an escaped
// quote does not end the key (base#1442). The expected paths are the
// library's md.Keys().
func TestIndexKeyEscapes(t *testing.T) {
	src := []byte("[\"t\\\"able\"]\n\"a\\bb\\tc\\nd\\fe\\rf\\\"g\\\\h\\u0041\\U0001F600\" = 1\n'lit\\eral' = 2\n")
	md, err := toml.Decode(string(src), new(map[string]any))
	if err != nil {
		t.Fatalf("library refused %q: %v", src, err)
	}
	var want, got []string
	for _, k := range md.Keys() {
		want = append(want, fmt.Sprintf("%q", []string(k)))
	}
	for _, o := range Index(src).Entries() {
		got = append(got, fmt.Sprintf("%q", o.Path))
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Entries() paths = %v, want md.Keys() %v", got, want)
	}
}

// TestIndexBareKeyEveryAllowedByte checks that a bare key runs through
// every byte TOML allows in one: the header holds A-Z, one key line a-z
// and the other 0-9, `_` and `-`, so each range is written whole, its
// first and last byte included (base#1467: the S1f mutation gate found no
// test that writes A, Z or 9 in a bare key). The expected paths are the
// library's md.Keys().
func TestIndexBareKeyEveryAllowedByte(t *testing.T) {
	src := []byte("[ABCDEFGHIJKLMNOPQRSTUVWXYZ]\nabcdefghijklmnopqrstuvwxyz = 1\n0123456789_- = 2\n")
	md, err := toml.Decode(string(src), new(map[string]any))
	if err != nil {
		t.Fatalf("library refused %q: %v", src, err)
	}
	var want, got []string
	for _, k := range md.Keys() {
		want = append(want, fmt.Sprintf("%q", []string(k)))
	}
	for _, o := range Index(src).Entries() {
		got = append(got, fmt.Sprintf("%q", o.Path))
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Entries() paths = %v, want md.Keys() %v", got, want)
	}
}

// prefixSweepBound is the largest input whose every byte prefix is
// indexed. Indexing every prefix costs the square of the input's length:
// the 108,951-byte large_tables.toml fixture (base#1469) alone made
// 108,952 calls that scanned about 5.9e9 bytes, and the race gate's go
// test ran into its 10-minute timeout on it. Every other corpus file is
// at most 684 bytes, so each is still swept in full.
const prefixSweepBound = 4096

// cutContextLines is how many whole lines before a cut a larger input's
// cut keeps (see indexCutPoints), so a string, array or inline table that
// spans lines is still open when the input ends inside it.
const cutContextLines = 8

// TestIndexEveryPrefixIsSafe indexes the cut points of every corpus TOML
// file at any depth (CorpusTOML; indexCutPoints), so an unterminated
// string, escape, array or header at any point cannot make the scan run
// past the input (base#1442, review round 1: an escaped quote used to
// start a scan beyond the end and panic).
func TestIndexEveryPrefixIsSafe(t *testing.T) {
	for _, file := range CorpusTOML(t) {
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		indexCutPoints(t, file, src)
	}
}

// TestIndexCutPointsPastTheSweepBoundAreSafe holds indexCutPoints to its
// claim on an input longer than prefixSweepBound: the header and key with
// a \u and a \U escape come only after the swept head, so only the cuts
// past it can end the input inside their hex digits (base#1469: a scan that
// reads past the end there must still fail this package's tests).
func TestIndexCutPointsPastTheSweepBoundAreSafe(t *testing.T) {
	head := strings.Repeat("value = 0\n", prefixSweepBound/10+1)
	if len(head) <= prefixSweepBound {
		t.Fatalf("head is %d bytes, want more than prefixSweepBound (%d)", len(head), prefixSweepBound)
	}
	indexCutPoints(t, "hex escapes past the sweep bound", []byte(head+"[\"\\u0041\"]\n\"\\U0001F600\" = 1\n"))
}

// indexCutPoints indexes the cut points of src and fails the test if one
// panics. An input of at most prefixSweepBound bytes has every byte prefix
// indexed. A longer one has every prefix of its first prefixSweepBound
// bytes indexed, the whole input indexed, and, for every byte offset n
// past the start of each line, the bytes from the start of the line
// cutContextLines lines earlier (or of the input) up to n: so the input
// ends at every byte boundary, every token boundary among them, with the
// lines before it in place, at a cost linear in the input's length. The
// fuzz target FuzzTreeParity indexes any other input.
func indexCutPoints(t *testing.T, label string, src []byte) {
	t.Helper()
	if len(src) <= prefixSweepBound {
		indexEveryPrefix(t, label, src)
		return
	}
	indexEveryPrefix(t, label, src[:prefixSweepBound])
	indexSafe(t, label, 0, src)
	starts := []int{0}
	for i, c := range src {
		if c == '\n' && i+1 < len(src) {
			starts = append(starts, i+1)
		}
	}
	for i, ls := range starts {
		end := len(src)
		if i+1 < len(starts) {
			end = starts[i+1]
		}
		from := starts[max(0, i-cutContextLines)]
		for n := ls + 1; n <= end; n++ {
			indexSafe(t, label, from, src[from:n:n])
		}
	}
}

// indexEveryPrefix indexes each byte prefix of src and fails the test if
// one panics. Each prefix is passed with its capacity cut to its length,
// so a read past the end panics instead of reading the bytes that follow
// it (base#1467: with src[:n] a mutant that read past the end lived).
func indexEveryPrefix(t *testing.T, label string, src []byte) {
	t.Helper()
	for n := 0; n <= len(src); n++ {
		indexSafe(t, label, 0, src[:n:n])
	}
}

// indexSafe indexes doc, the bytes of label's input from offset from, and
// fails the test if Index panics. doc's capacity must be its length.
func indexSafe(t *testing.T, label string, from int, doc []byte) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("%s: Index of bytes %d-%d %q panicked: %v", label, from, from+len(doc), doc, r)
		}
	}()
	Index(doc)
}

// TestIndexCutHexEscapeIsSafe indexes every byte prefix of a header and a
// key whose quoted names hold a \u and a \U escape, so input that ends
// inside the hex digits of an escape cannot make the scan read past the
// input (base#1467: the S1f mutation gate found no corpus file with a hex
// escape, so no prefix of one was indexed).
func TestIndexCutHexEscapeIsSafe(t *testing.T) {
	indexEveryPrefix(t, "hex escapes", []byte("[\"\\u0041\"]\n\"\\U0001F600\" = 1\n"))
}

// TestIndexInlineMembers checks that each key written inside an inline
// value is a member at its own line and column, under the path the
// library lists it by (base#1442 review round 1 finding 2): a bracket in
// a string or a comment inside the value is content, an array item
// spanning lines moves the line on, and the holding key stays the only
// entry. The expected paths are the library's md.Keys() after `a`; the
// lines and columns are counted by hand from the text.
func TestIndexInlineMembers(t *testing.T) {
	src := []byte("a = { b = \"}{\", c = [ # } ]\n  { d = 1 } ] }\n")
	md, err := toml.Decode(string(src), new(map[string]any))
	if err != nil {
		t.Fatalf("library refused %q: %v", src, err)
	}
	var want []string
	for _, k := range md.Keys()[1:] {
		want = append(want, fmt.Sprintf("%q", []string(k)))
	}
	m := Index(src)
	var got []string
	var pos [][2]int
	for _, p := range [][]string{{"a", "b"}, {"a", "c"}, {"a", "c", "d"}} {
		for _, o := range m.Members(p) {
			got = append(got, fmt.Sprintf("%q", o.Path))
			pos = append(pos, [2]int{o.KeyLine, o.KeyCol})
		}
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Members paths = %v, want md.Keys() %v", got, want)
	}
	if wantPos := [][2]int{{1, 7}, {1, 17}, {2, 5}}; !reflect.DeepEqual(pos, wantPos) {
		t.Errorf("Members positions = %v, want %v", pos, wantPos)
	}
	if len(m.Entries()) != 1 {
		t.Errorf("Entries() = %+v, want only a", m.Entries())
	}
}

// TestIndexInlineDottedTables checks that each parent component of a
// dotted key written inside an inline value is an implicit inline table
// at the dotted key's own line and column, once per dotted key, and is
// not an entry (base#1442 review round 2 finding 1). The positions are
// counted by hand from the text.
func TestIndexInlineDottedTables(t *testing.T) {
	src := []byte("v = [\n  { a.b.c = 1 },\n  { a.d = 2 }\n]\n")
	m := Index(src)
	var got [][3]any
	for _, p := range [][]string{{"v", "a"}, {"v", "a", "b"}} {
		for _, o := range m.InlineTables(p) {
			got = append(got, [3]any{fmt.Sprintf("%q", o.Path), o.KeyLine, o.KeyCol})
		}
	}
	want := [][3]any{
		{`["v" "a"]`, 2, 5},
		{`["v" "a"]`, 3, 5},
		{`["v" "a" "b"]`, 2, 5},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("InlineTables = %v, want %v", got, want)
	}
	if len(m.Entries()) != 1 {
		t.Errorf("Entries() = %+v, want only v", m.Entries())
	}
}

// TestIndexInlineMemberRecordsMarkInlineValues checks that a member of an
// inline table keeps whether its own value is an inline table or array
// (base#1467, the member half of Occurrence.Inline). In
// `a = { s = 1, t = { u = 2 }, v = [3] }` TOML gives a.s an integer, a.t
// an inline table holding the integer a.t.u, and a.v an inline array, so
// only a.t and a.v are Inline.
func TestIndexInlineMemberRecordsMarkInlineValues(t *testing.T) {
	m := Index([]byte("a = { s = 1, t = { u = 2 }, v = [3] }\n"))
	for _, c := range []struct {
		path []string
		want bool
	}{
		{[]string{"a", "s"}, false},
		{[]string{"a", "t"}, true},
		{[]string{"a", "t", "u"}, false},
		{[]string{"a", "v"}, true},
	} {
		ms := m.Members(c.path)
		if len(ms) != 1 {
			t.Fatalf("Members(%q) = %+v, want one", c.path, ms)
		}
		if got := ms[0].Inline; got != c.want {
			t.Errorf("Members(%q) Inline = %v, want %v", c.path, got, c.want)
		}
	}
}

// TestIndexRepeatedInlineMemberOrdinals checks that a member path written
// once in each table item of an inline array keeps the Ordinal the
// Occurrence contract gives it, the count of its earlier occurrences
// (base#1467). In `v = [{ a = 1 }, { a = 2 }, { a = 3 }]` v.a is written
// three times on line 1, its keys at the columns counted by hand, 8, 19
// and 30, so its ordinals are 0, 1 and 2.
func TestIndexRepeatedInlineMemberOrdinals(t *testing.T) {
	m := Index([]byte("v = [{ a = 1 }, { a = 2 }, { a = 3 }]\n"))
	var cols, ords []int
	for _, o := range m.Members([]string{"v", "a"}) {
		cols = append(cols, o.KeyCol)
		ords = append(ords, o.Ordinal)
	}
	if !reflect.DeepEqual(cols, []int{8, 19, 30}) || !reflect.DeepEqual(ords, []int{0, 1, 2}) {
		t.Errorf("Members(v.a) columns=%v ordinals=%v, want [8 19 30] [0 1 2]", cols, ords)
	}
}

// TestIndexHexEscapeAtInputEnd checks that a hex escape whose digits are
// the last bytes of the input is decoded, as hexRune decodes the n hex
// digits at the current position: the unterminated header `["\u0041` is
// the path ["A"] (base#1467: the S1f mutation gate found no input that
// ends right after an escape's digits).
func TestIndexHexEscapeAtInputEnd(t *testing.T) {
	var got []string
	for _, o := range Index([]byte(`["\u0041`)).Entries() {
		got = append(got, fmt.Sprintf("%q", o.Path))
	}
	if want := []string{`["A"]`}; !reflect.DeepEqual(got, want) {
		t.Errorf("Entries() paths = %v, want %v", got, want)
	}
}

// TestIndexMultilineCloseTakesAtMostFiveQuotes checks that the run of
// quotes closing a multi-line basic string is consumed up to five bytes,
// the content's two and the delimiter's three, so a sixth quote opens a
// new string (base#1467: the S1f mutation gate found no input with a
// longer run). In `k = """a"""""" { x = 1 }` the sixth quote's string
// runs to the end of the line, so the braces after it are its content and
// k has no member x.
func TestIndexMultilineCloseTakesAtMostFiveQuotes(t *testing.T) {
	m := Index([]byte("k = \"\"\"a\"\"\"\"\"\" { x = 1 }\n"))
	if got := m.Members([]string{"k", "x"}); len(got) != 0 {
		t.Errorf("Members(k.x) = %+v, want none", got)
	}
}
