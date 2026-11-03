package locate

import (
	"fmt"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
)

// treeSeeds are the documents of base#1442 redesign r1-r3 that the corpus
// does not hold: H1-H5 (header and dotted-key resolution), F1-F5 (the
// review round 3 findings), and inputs FuzzTreeParity found, which the
// parser refuses -- a header whose last key is empty under a table that a
// `[[a` line also wrote, a header through a key, a header through an
// array of tables a `[a` line wrote a key under, a key redefining a dotted
// table and a dotted key through an array, which BurntSushi v1.6.0 accepts
// (both decode to map[0:map[0:0]]) and the bridge refuses ("Can not
// overwrite a value (at line 2, column 4)" for the first); a document
// opening with a byte-order mark, which the parser skips; a key of 2000
// empty dotted parts, on which the locator once took over a minute; and
// keys spelled
// with the TOML 1.1 escapes \e and \xHH, which the parser decodes; and a
// multi-line basic string ending in an escaped backslash and six quotes
// inside an array and an inline table (base#1526), which BurntSushi v1.6.0
// accepts (the first decodes to one item, a backslash and three quotes)
// and the bridge refuses ("Unclosed array (at line 1, column 14)",
// "Unclosed inline table (at line 1, column 16)").
var treeSeeds = []string{
	"[logging.web]\ndriver = \"json-file\"\n[logging]\ndriver = \"local\"\n",
	"[[a]]\nx = 1\n[[a]]\nx = 2\n[a.b]\ny = 3\n",
	"[a]\nb.c = 1\n[d]\ne = 2\n",
	"[[a]]\nc.d = 1\n[[a]]\nc.d = 2\n",
	"[[a]]\n[[a.b]]\nk = 1\n[[a]]\n[[a.b]]\nk = 2\n[[a.b]]\nk = 3\n",
	"[[security.privileged]]\nvalue = true\n",
	"volumes = [\n  { source = \"/a\", target = \"/b\", \"bad\\tkey\" = \"x\" }\n]\n",
	"volumes = [\n  { \"bad\\tkey\".x = 1 }\n]\n",
	"volumes = [{ extra.z = 1, extra.a = 2 }]\n",
	"volumes = [\n  {\n    opts = [\n      { \"bad\\tk\" = 1 },\n    ],\n  },\n]\n",
	"[a\n[[a\n[a. ",
	"=\n[.",
	"[\"\\e\"]",
	"[\"\\x41\"]",
	"[[a \n[a \n=\n[a.",
	"0.0=0\n0=0",
	"0=[]\n0.0=0",
	"\xfe\xff0=\"\"",
	"\xef\xbb\xbfa = 1\n",
	strings.Repeat(".", 2000) + "0=0.++++++++",
	`0=["""\\""""""]#",1]`,
	`0={a="""\\""""""}#",b=1}`,
}

// treeParity holds the tree of src to the log it is built beside and to
// the value BurntSushi decodes, when it decodes one:
//   - every record of the log (Entries, the members, the inline tables) and
//     every record kept off it is owned by exactly one node, an element
//     sharing its `[[path]]` record with its array node;
//   - every node but the root owns at least one record, and the path from
//     the root to it, element and item steps dropped, is the Path of each;
//   - the tree has the decoded value's shape, compared by a walker of its
//     own: a table's children are its keys, an array of tables' elements
//     and an inline array's items are its entries, and a scalar has none.
func treeParity(t *testing.T, name string, src []byte) {
	t.Helper()
	m := Index(src)
	owners := map[*Occurrence]int{}
	var walk func(n *Node, path []string)
	walk = func(n *Node, path []string) {
		for _, c := range n.Children {
			p := path
			if c.Kind != NElement && c.Kind != NItem {
				p = append(append([]string{}, path...), c.Key)
			}
			if len(c.Occ) == 0 {
				t.Errorf("%s: node %q (kind %d) owns no record", name, p, c.Kind)
			}
			for _, o := range c.Occ {
				if c.Kind != NElement {
					owners[o]++
				}
				if !reflect.DeepEqual(o.Path, p) && !(len(o.Path) == 0 && len(p) == 0) {
					t.Errorf("%s: node at %q owns a record of %q", name, p, o.Path)
				}
			}
			walk(c, p)
		}
	}
	walk(m.root, nil)
	for _, list := range [][]*Occurrence{m.entries, m.members, m.inlineTables, m.extra} {
		for _, o := range list {
			if owners[o] != 1 {
				t.Errorf("%s: record %q at %d:%d is owned by %d nodes, want 1", name, o.Path, o.KeyLine, o.KeyCol, owners[o])
			}
		}
	}
	var v map[string]any
	if _, err := toml.Decode(string(src), &v); err != nil || redefines(m.root) {
		return
	}
	if diff := sameShape(m.root, v, nil); diff != "" {
		t.Errorf("%s: tree and decoded value differ: %s", name, diff)
	}
}

// redefines reports whether the subtree n writes a key twice: two
// siblings share a key, or a header or dotted key crosses a key, so a node
// holding a scalar or an inline array has a child that is not its item.
// TOML 1.0 refuses each. BurntSushi v1.6.0 accepts some (`a.b=0` then
// `a=0`, and `a=[]` then `a.b=0`, each decode to {"a":{"b":0}}), so no
// tree can have their shape; the TOML 1.0 gate of base#1441 refuses them
// before Decode.
func redefines(n *Node) bool {
	seen := map[string]bool{}
	for _, c := range n.Children {
		switch {
		case c.Kind == NElement || c.Kind == NItem:
		case seen[c.Key]:
			return true
		default:
			seen[c.Key] = true
		}
		crossed := (n.Kind == NKey || n.Kind == NItem) && (n.Open == 0 || n.Open == '[' && c.Kind != NItem)
		if crossed || redefines(c) {
			return true
		}
	}
	return false
}

// sameShape compares the subtree n with the decoded value v at path and
// returns the first difference, or "".
func sameShape(n *Node, v any, path []string) string {
	at := fmt.Sprintf("%q", path)
	switch x := v.(type) {
	case map[string]any:
		if !tableLike(n) {
			return at + ": decoded a table, node kind " + fmt.Sprint(n.Kind) + " open " + string(n.Open)
		}
		var keys, nodeKeys []string
		for k := range x {
			keys = append(keys, k)
		}
		for _, c := range n.Children {
			nodeKeys = append(nodeKeys, c.Key)
		}
		sort.Strings(keys)
		sort.Strings(nodeKeys)
		if !reflect.DeepEqual(keys, nodeKeys) {
			return fmt.Sprintf("%s: decoded keys %q, node children %q", at, keys, nodeKeys)
		}
		for _, c := range n.Children {
			if d := sameShape(c, x[c.Key], append(append([]string{}, path...), c.Key)); d != "" {
				return d
			}
		}
		return ""
	case []map[string]any:
		items := make([]any, len(x))
		for i, e := range x {
			items[i] = e
		}
		return sameItems(n, items, path)
	case []any:
		return sameItems(n, x, path)
	}
	if n.Kind != NKey && n.Kind != NItem || n.Open != 0 || len(n.Children) != 0 {
		return fmt.Sprintf("%s: decoded a scalar, node kind %d open %q with %d children", at, n.Kind, n.Open, len(n.Children))
	}
	return ""
}

// tableLike reports whether n holds a table: the root, a table, an
// element, a dotted parent inside an inline value, or a key or item
// holding an inline table.
func tableLike(n *Node) bool {
	switch n.Kind {
	case NTable, NElement, NInlineTable:
		return true
	case NKey, NItem:
		return n.Open == '{'
	case NArrayTables:
	}
	return false
}

// sameItems compares the entries of an array with the elements of an
// array-of-tables node or the items of a node holding an inline array.
func sameItems(n *Node, items []any, path []string) string {
	at := fmt.Sprintf("%q", path)
	if n.Kind != NArrayTables && n.Open != '[' {
		return fmt.Sprintf("%s: decoded an array, node kind %d open %q", at, n.Kind, n.Open)
	}
	if len(n.Children) != len(items) {
		return fmt.Sprintf("%s: decoded %d entries, node has %d", at, len(items), len(n.Children))
	}
	for i, c := range n.Children {
		if d := sameShape(c, items[i], append(append([]string{}, path...), fmt.Sprint(i))); d != "" {
			return d
		}
	}
	return ""
}

// The locate tree is checked against its own log and against BurntSushi
// on every corpus TOML file and the redesign seeds (base#1442 redesign
// R4). A file the parser refuses is still indexed and its records owned.
func TestTreeParity(t *testing.T) {
	files := CorpusTOML(t)
	if len(files) == 0 {
		t.Fatal("no corpus TOML file")
	}
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		treeParity(t, f, src)
	}
	for i, s := range treeSeeds {
		treeParity(t, fmt.Sprintf("seed %d", i), []byte(s))
	}
}

// FuzzTreeParity runs treeParity on any input; `go test` runs its seeds,
// the redesign seeds and every corpus TOML file.
func FuzzTreeParity(f *testing.F) {
	for _, s := range treeSeeds {
		f.Add([]byte(s))
	}
	for _, file := range CorpusTOML(f) {
		src, err := os.ReadFile(file)
		if err != nil {
			f.Fatal(err)
		}
		f.Add(src)
	}
	f.Fuzz(func(t *testing.T, src []byte) {
		treeParity(t, "input", src)
	})
}
