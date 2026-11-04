package locate_test

import (
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/locate"
	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// childKeys lists the keys of n's children in order.
func childKeys(n *locate.Node) []string {
	var out []string
	for _, c := range n.Children {
		out = append(out, c.Key)
	}
	return out
}

// child is n's child with key k, failing the test when there is none.
func child(t *testing.T, n *locate.Node, k string) *locate.Node {
	t.Helper()
	for _, c := range n.Children {
		if c.Key == k {
			return c
		}
	}
	t.Fatalf("node %q has no child %q; children %q", n.Key, k, childKeys(n))
	return nil
}

// occs lists n's records as "implicit|explicit line:col".
func occs(n *locate.Node) []string {
	var out []string
	for _, o := range n.Occ {
		form := "explicit"
		if o.Implicit {
			form = "implicit"
		}
		out = append(out, fmt.Sprintf("%s %d:%d", form, o.KeyLine, o.KeyCol))
	}
	return out
}

// A header names its table from the root, never from the table the
// header before it opened (base#1442 redesign r3, H1). For
// `[logging.web]` then `[logging]`, BurntSushi decodes
// map[logging:map[driver:local web:map[driver:json-file]]] and the bridge's
// `--kv` prints `logging.web<TAB>driver<TAB>json-file` then
// `logging<TAB>driver<TAB>local` (rc 0): one logging table holding web and
// driver. Its node owns both of its records, the implicit one `[logging.web]`
// creates at 1:1 and the explicit `[logging]` at 3:1, so neither position
// is lost to the other.
func TestRootHeaderResolvesFromRoot(t *testing.T) {
	m := locate.Index([]byte("[logging.web]\ndriver = \"json-file\"\n[logging]\ndriver = \"local\"\n"))

	root := m.Root()
	if got := childKeys(root); !reflect.DeepEqual(got, []string{"logging"}) {
		t.Fatalf("root children = %q, want [logging]", got)
	}
	logging := child(t, root, "logging")
	if logging.Kind != locate.NTable {
		t.Errorf("logging kind = %v, want NTable", logging.Kind)
	}
	if got, want := occs(logging), []string{"implicit 1:1", "explicit 3:1"}; !reflect.DeepEqual(got, want) {
		t.Errorf("logging records = %q, want %q", got, want)
	}
	if got := childKeys(logging); !reflect.DeepEqual(got, []string{"web", "driver"}) {
		t.Errorf("logging children = %q, want [web driver]", got)
	}
	web := child(t, logging, "web")
	if got := childKeys(web); !reflect.DeepEqual(got, []string{"driver"}) {
		t.Errorf("logging.web children = %q, want [driver]", got)
	}
	if got, want := occs(child(t, web, "driver")), []string{"explicit 2:1"}; !reflect.DeepEqual(got, want) {
		t.Errorf("logging.web.driver records = %q, want %q", got, want)
	}
	if got, want := occs(child(t, logging, "driver")), []string{"explicit 4:1"}; !reflect.DeepEqual(got, want) {
		t.Errorf("logging.driver records = %q, want %q", got, want)
	}
}

// shape writes the subtree under n: a table or a dotted parent inside an
// inline value as key{...}, an array of tables as key[[...]], an element
// as {...}, a key as its name, followed by ={...} or =[...] when its value
// is an inline table or array, and an item of an inline array as {...},
// [...] or _ for any other value.
func shape(n *locate.Node) string {
	var b strings.Builder
	for i, c := range n.Children {
		if i > 0 {
			b.WriteByte(' ')
		}
		switch c.Kind {
		case locate.NTable, locate.NInlineTable:
			b.WriteString(c.Key + "{" + shape(c) + "}")
		case locate.NArrayTables:
			b.WriteString(c.Key + "[[" + shape(c) + "]]")
		case locate.NElement:
			b.WriteString("{" + shape(c) + "}")
		case locate.NKey:
			b.WriteString(c.Key + inlineShape(c, "="))
		case locate.NItem:
			b.WriteString(inlineShape(c, ""))
		}
	}
	return b.String()
}

// inlineShape writes the inline value n holds after prefix, or "" for a
// key and "_" for an item holding any other value.
func inlineShape(n *locate.Node, prefix string) string {
	switch n.Open {
	case '{':
		return prefix + "{" + shape(n) + "}"
	case '[':
		return prefix + "[" + shape(n) + "]"
	}
	if n.Kind == locate.NItem {
		return "_"
	}
	return ""
}

// A header that crosses an array of tables lands in its last element
// (base#1442 redesign r3, H2 and H5). BurntSushi decodes H2
// `[[a]] x=1 [[a]] x=2 [a.b] y=3` as {"a":[{"x":1},{"b":{"y":3},"x":2}]}
// and H5 `[[a]] [[a.b]] k=1 [[a]] [[a.b]] k=2 [[a.b]] k=3` as
// {"a":[{"b":[{"k":1}]},{"b":[{"k":2},{"k":3}]}]}; the bridge refuses
// `[[volumes]]` twice then `[volumes.opts]` with "entry 2 of volumes
// carries opts", so the table is the second element's.
func TestHeaderThroughArrayOfTablesLandsInLastElement(t *testing.T) {
	cases := []struct{ name, src, want string }{
		{"H2", "[[a]]\nx = 1\n[[a]]\nx = 2\n[a.b]\ny = 3\n", "a[[{x} {x b{y}}]]"},
		{"H5", "[[a]]\n[[a.b]]\nk = 1\n[[a]]\n[[a.b]]\nk = 2\n[[a.b]]\nk = 3\n", "a[[{b[[{k}]]} {b[[{k} {k}]]}]]"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := shape(locate.Index([]byte(tc.src)).Root()); got != tc.want {
				t.Errorf("tree = %s, want %s", got, tc.want)
			}
		})
	}
}

// A dotted key resolves from the table or element the last header opened,
// and each element owns its own dotted parents (base#1442 redesign r3, H3
// and H4). BurntSushi decodes H3 `[a] b.c=1 [d] e=2` as
// {"a":{"b":{"c":1}},"d":{"e":2}} and H4 `[[a]] c.d=1 [[a]] c.d=2` as
// {"a":[{"c":{"d":1}},{"c":{"d":2}}]}. The log records the implicit
// table a.c once, for the first element; the second element's c still owns
// one record of its own, at its own line.
func TestDottedKeyResolvesFromCurrentTable(t *testing.T) {
	if got, want := shape(locate.Index([]byte("[a]\nb.c = 1\n[d]\ne = 2\n")).Root()), "a{b{c}} d{e}"; got != want {
		t.Errorf("H3 tree = %s, want %s", got, want)
	}
	root := locate.Index([]byte("[[a]]\nc.d = 1\n[[a]]\nc.d = 2\n")).Root()
	if got, want := shape(root), "a[[{c{d}} {c{d}}]]"; got != want {
		t.Fatalf("H4 tree = %s, want %s", got, want)
	}
	a := child(t, root, "a")
	for i, want := range []string{"implicit 2:1", "implicit 4:1"} {
		if got := occs(child(t, a.Children[i], "c")); !reflect.DeepEqual(got, []string{want}) {
			t.Errorf("H4 element %d c records = %q, want [%s]", i, got, want)
		}
	}
}

// A key node keeps where its value ends as well as where its key starts
// (base#1442 redesign R2). In s6_ml_header.toml the key watchdog_check is
// on line 2 and its multi-line string closes on line 4; the bridge's
// `--kv` prints `lifecycle<TAB>watchdog_check<TAB>[fake]` (rc 0), so the
// header-like line is content and the key is the only one under lifecycle.
func TestKeyNodeKeepsValueEnd(t *testing.T) {
	src, err := os.ReadFile(testcorpus.Glob(t, "corpus/s6/s6_ml_header.toml")[0])
	if err != nil {
		t.Fatal(err)
	}
	root := locate.Index(src).Root()
	if got, want := shape(root), "lifecycle{watchdog_check}"; got != want {
		t.Fatalf("tree = %s, want %s", got, want)
	}
	d := child(t, child(t, root, "lifecycle"), "watchdog_check").Decl()
	if d == nil || d.KeyLine != 2 || d.KeyCol != 1 || d.ValueEndLine != 4 {
		t.Errorf("watchdog_check Decl = %+v, want KeyLine 2 KeyCol 1 ValueEndLine 4", d)
	}
}

// A dotted key inside an inline value creates its parent as a node under
// the item that holds it, owning one record per dotted key that writes it,
// and the members keep the order they are written in (base#1442 redesign
// R3, finding F4 of review round 3). For
// `volumes = [{ extra.z = 1, extra.a = 2 }]` BurntSushi decodes
// {"volumes":[{"extra":{"a":2,"z":1}}]}, whose map has no order; the
// positions are counted from the bytes: `extra.z` starts at column 14 and
// `extra.a` at column 27.
func TestInlineDottedKeyNodes(t *testing.T) {
	root := locate.Index([]byte("volumes = [{ extra.z = 1, extra.a = 2 }]\n")).Root()
	if got, want := shape(root), "volumes=[{extra{z a}}]"; got != want {
		t.Fatalf("tree = %s, want %s", got, want)
	}
	extra := child(t, child(t, root, "volumes").Children[0], "extra")
	if extra.Kind != locate.NInlineTable {
		t.Errorf("extra kind = %v, want NInlineTable", extra.Kind)
	}
	if got, want := occs(extra), []string{"implicit 1:14", "implicit 1:27"}; !reflect.DeepEqual(got, want) {
		t.Errorf("extra records = %q, want %q", got, want)
	}
	for k, want := range map[string]string{"z": "explicit 1:14", "a": "explicit 1:27"} {
		if got := occs(child(t, extra, k)); !reflect.DeepEqual(got, []string{want}) {
			t.Errorf("extra.%s records = %q, want [%s]", k, got, want)
		}
	}
}

// An item of an inline array keeps whether its own value is an inline
// table or array (base#1467, the item half of Occurrence.Inline). In
// `ports = [80, [1, 2], { host = 8080 }]` TOML gives an integer, an
// inline array and an inline table, in that order, so only the second and
// third items' records are Inline.
func TestInlineArrayItemRecordsMarkInlineValues(t *testing.T) {
	root := locate.Index([]byte("ports = [80, [1, 2], { host = 8080 }]\n")).Root()
	if got, want := shape(root), "ports=[_ [_ _] {host}]"; got != want {
		t.Fatalf("tree = %s, want %s", got, want)
	}
	items := child(t, root, "ports").Children
	for i, want := range []bool{false, true, true} {
		if len(items[i].Occ) != 1 {
			t.Fatalf("item %d records = %q, want one", i, occs(items[i]))
		}
		if got := items[i].Occ[0].Inline; got != want {
			t.Errorf("item %d Inline = %v, want %v", i, got, want)
		}
	}
}
