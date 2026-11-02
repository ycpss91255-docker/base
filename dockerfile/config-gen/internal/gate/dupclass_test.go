package gate

import (
	"errors"
	"fmt"
	"hash/fnv"
	"sort"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/BurntSushi/toml"
)

// dupShapes are the duplicate class's members, each written once with
// three placeholders: F, a top-level table name the document has not used;
// K1, a key spelling; K2, a second spelling (base#1441).
// The `@` marks the byte where the second definition starts, the byte a
// refusal must name, and is removed before use. With K2 a spelling of the
// same key as K1 the shape defines one key path twice and Check must
// refuse it; with K2 a different key every shape is a valid document,
// which BurntSushi decodes and Check accepts. The shapes cover key
// assignments, inline-table members, headers, array-of-tables collisions,
// frozen ancestors at one and two levels, dotted keys and the scope of an
// array-of-tables element.
var dupShapes = []string{
	"[F]\nK1 = 1\n@K2 = 2\n",
	"[F]\nK1.x = 1\n@K2.x = 2\n",
	"[F]\nK1 = 1\n@K2.x = 1\n",
	"[F]\nK1 = 1\n@[F.K2]\n",
	"[F]\nv = {K1 = 1, @K2 = 2}\n",
	"[F]\nv = {K1.x = 1, @K2.x = 2}\n",
	"[F]\nv = {K1 = {}, @K2.x = 1}\n",
	"[F.K1]\n@[F.K2]\n",
	"[F.K1]\ny = 1\n@[F.K2]\n",
	"[[F.K1]]\n@[F.K2]\n",
	"[F.K1]\n@[[F.K2]]\n",
	"[F]\nK1 = []\n@[[F.K2]]\n",
	"[F]\nK1 = 1\n@[[F.K2]]\n",
	"[F]\nK1 = 1\n@[[F.K2.x]]\n",
	"[F]\nK1 = {}\n@[[F.K2]]\n",
	"[F]\nK1 = {}\n@[[F.K2.x]]\n",
	"[F]\nK1 = []\n@[[F.K2.x]]\n",
	"[F]\nK1 = {a = {}}\n@[[F.K2.a.x]]\n",
	"[F]\nK1 = {}\n@[F.K2.x]\n",
	"[F]\nK1 = {a = {}}\n@[F.K2.a.x]\n",
	"[F]\nK1 = {}\n@K2.x = 1\n",
	"[F]\nK1 = []\n@K2.x = 1\n",
	"[F]\nK1 = {a = {}}\n@K2.a.x = 1\n",
	"[F]\nK1 = {}\n@[F.K2]\n",
	"[F]\nK1.x = 1\n@[F.K2]\n",
	"[F]\nK1.x = 1\n@[F.K2.x]\n",
	"[[F]]\nK1 = 1\n@K2 = 2\n",
	"[[F]]\n[F.K1]\n@[F.K2]\n",
	"[[F]]\nK1.x = 1\n@[F.K2]\n",
}

// sameKey are pairs of spellings of one key: bare and quoted, literal,
// \u and \U escapes, the empty key, a decoded NUL, a dot inside quotes, a
// non-ASCII letter, dotted keys split differently, and a digit key.
var sameKey = [][2]string{
	{"k", `"k"`},
	{"k", `'k'`},
	{`"k"`, `"k"`},
	{"k", `"\U0000006b"`},
	{`""`, `''`},
	{`"a\u0000b"`, `"a\U00000000b"`},
	{`"a.b"`, `'a.b'`},
	{`"é"`, `"é"`},
	{"p.q", `p."q"`},
	{"p.q", `"p" . 'q'`},
	{`"\u0000"`, `"\U00000000"`},
	{"1", `"1"`},
}

// otherKey are pairs of spellings of two different keys, among them the
// ones a lossy path encoding would merge: a NUL or a dot inside a quoted
// part against the dotted path around it.
var otherKey = [][2]string{
	{"k", "j"},
	{`"a\u0000b"`, "a.b"},
	{"a.b", `"a\u0000b"`},
	{`"a.b"`, "a.b"},
	{"a.b", `'a.b'`},
	{`""`, `" "`},
	{"p.q", "p.r"},
}

// dupDoc returns prefix, a line ending, and shape with F, K1 and K2
// filled in, and the offset the shape's `@` marks in the result.
func dupDoc(prefix, shape, f, k1, k2 string) (string, int) {
	s := strings.NewReplacer("F", f, "K1", k1, "K2", k2).Replace(shape)
	doc := prefix + "\n" + s
	at := strings.IndexByte(doc[len(prefix):], '@') + len(prefix)
	return doc[:at] + doc[at+1:], at
}

// checkDuplicate fails t unless Check refuses doc as a member of the
// duplicate class at offset at, with the class's one text.
func checkDuplicate(t *testing.T, doc string, at int) {
	t.Helper()
	err := Check("f.toml", []byte(doc))
	var r *Refusal
	if !errors.As(err, &r) {
		t.Fatalf("Check(%q) = %v, want the duplicate refusal", doc, err)
	}
	line := 1 + strings.Count(doc[:at], "\n")
	col := at - strings.LastIndexByte(doc[:at], '\n')
	want := fmt.Sprintf("f.toml:%d:%d: Cannot overwrite a value (at line %d, column %d)", line, col, line, col)
	if (r.Reason != ReasonDuplicate && r.Reason != ReasonRedefine) || r.Error() != want {
		t.Fatalf("Check(%q) = %v %q, want ReasonDuplicate or ReasonRedefine %q", doc, r.Reason, r.Error(), want)
	}
}

// checkDistinct fails t unless doc, a shape filled with two different
// keys, is a valid document that BurntSushi decodes and Check accepts.
func checkDistinct(t *testing.T, doc string) {
	t.Helper()
	var v map[string]any
	if _, err := toml.Decode(string(Normalize([]byte(doc))), &v); err != nil {
		t.Fatalf("toml.Decode(%q) = %v: the control document is not valid", doc, err)
	}
	if err := Check("f.toml", []byte(doc)); err != nil {
		t.Fatalf("Check(%q) = %v, want nil", doc, err)
	}
}

// Every shape with every same-key pair is refused at its `@`, and with
// every different-key pair is accepted (base#1441).
func TestCheckDuplicateClassMatrix(t *testing.T) {
	for _, shape := range dupShapes {
		for _, p := range sameKey {
			doc, at := dupDoc("", shape, "dup", p[0], p[1])
			checkDuplicate(t, doc, at)
		}
		for _, p := range otherKey {
			doc, _ := dupDoc("", shape, "dup", p[0], p[1])
			checkDistinct(t, doc)
		}
	}
}

// dupProperty is FuzzCheck's duplicate-class property for src, a
// document Check accepted. When BurntSushi also decodes it, src is a
// valid document: every shape, filled with a fresh top-level name and a
// key pair chosen from src's hash, is appended to it and must be refused
// at its `@` with a same-key pair and accepted with a different-key pair;
// and src's first top-level key in byte order, defined again first under
// a fully escaped spelling, must be refused past that first line with the
// class's text.
func dupProperty(t *testing.T, src []byte) {
	var v map[string]any
	if _, err := toml.Decode(string(Normalize(src)), &v); err != nil {
		return
	}
	f := "dup"
	for n := 0; v[f] != nil; n++ {
		f = fmt.Sprintf("dup%d", n)
	}
	h := fnv.New32a()
	_, _ = h.Write(src)
	seed := int(h.Sum32() >> 1)
	for i, shape := range dupShapes {
		p := sameKey[(seed+i)%len(sameKey)]
		doc, at := dupDoc(string(src), shape, f, p[0], p[1])
		checkDuplicate(t, doc, at)
		q := otherKey[(seed+i)%len(otherKey)]
		doc, _ = dupDoc(string(src), shape, f, q[0], q[1])
		checkDistinct(t, doc)
	}
	keys := make([]string, 0, len(v))
	for k := range v {
		if utf8.ValidString(k) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys[:min(1, len(keys))] {
		doc := escapedKey(k) + " = 1\n" + string(src)
		err := Check("f.toml", []byte(doc))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Fatalf("Check(%q) = %v, want the duplicate refusal", doc, err)
		}
		want := fmt.Sprintf("f.toml:%d:%d: Cannot overwrite a value (at line %d, column %d)", r.Line, r.Col, r.Line, r.Col)
		if (r.Reason != ReasonDuplicate && r.Reason != ReasonRedefine) || r.Line < 2 || r.Error() != want {
			t.Fatalf("Check(%q) = %v %q, want a duplicate refusal past line 1 reading %q", doc, r.Reason, r.Error(), want)
		}
	}
}

// escapedKey returns k as a basic-string key whose every character is a
// \U escape.
func escapedKey(k string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, c := range k {
		fmt.Fprintf(&b, `\U%08X`, c)
	}
	b.WriteByte('"')
	return b.String()
}
