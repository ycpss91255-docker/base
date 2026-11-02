package schema

import (
	"reflect"
	"strings"
	"testing"
)

// Layer bytes of base#1442 design r4 section 1q (p1442c/in). Base A has an
// empty quoted `["logging.a"]` node on line 1; base B has a blank line 1,
// so its header is line 2. Single-layer, both give the same rows.
const (
	layerBaseA = "[\"logging.a\"]\n[logging.a]\ndriver = \"json-file\"\n"
	layerBaseB = "\n[logging.a]\ndriver = \"json-file\"\n"
	layerUpper = "[\"logging.a\"]\ndriver = \"local\"\n"
)

// treeNode is a Node with each child flattened to the fields the test
// compares, so a Scalar's Kind does not enter the expected values.
type treeNode struct {
	Path     []string
	Text     string
	Line     int
	Implicit bool
	Inline   bool
	Children []treeChild
}

type treeChild struct {
	Kind ChildKind
	Key  string
	Node int
	Text string
	Line int
}

func flatTree(tr *Tree) []treeNode {
	var out []treeNode
	for i, n := range tr.Nodes {
		fn := treeNode{Path: n.Path, Text: n.Text, Line: n.Line, Implicit: n.Implicit, Inline: n.Inline}
		if i == 0 {
			// The root's line is not part of the behaviour.
			fn.Line = 0
		}
		for _, c := range n.Children {
			fc := treeChild{Kind: c.Kind, Key: c.Key}
			switch c.Kind {
			case ChildNode:
				fc.Node = c.Node
			case ChildRow:
				fc.Text, fc.Line = c.Row.Value.Text, c.Row.Line
			case ChildDeferred:
			}
			fn.Children = append(fn.Children, fc)
		}
		out = append(out, fn)
	}
	return out
}

// tablesOf walks the tree depth first in Children order and lists the Text
// of every non-root node whose text starts `logging`, the bridge's
// `--tables` walk (toml_bridge.py _emit_tables).
func tablesOf(tr *Tree) []string {
	var out []string
	var walk func(i int)
	walk = func(i int) {
		for _, c := range tr.Nodes[i].Children {
			if c.Kind != ChildNode {
				continue
			}
			if strings.HasPrefix(tr.Nodes[c.Node].Text, "logging") {
				out = append(out, tr.Nodes[c.Node].Text)
			}
			walk(c.Node)
		}
	}
	walk(0)
	return out
}

// emitRows walks the tree depth first in Children order and prints
// `Text<TAB>Key<TAB>value` for each row, the bridge's `--kv` walk
// (toml_bridge.py _emit_table, the loop at line 407).
func emitRows(tr *Tree) []string {
	var out []string
	var walk func(i int)
	walk = func(i int) {
		for _, c := range tr.Nodes[i].Children {
			switch c.Kind {
			case ChildNode:
				walk(c.Node)
			case ChildRow:
				out = append(out, tr.Nodes[i].Text+"\t"+c.Key+"\t"+c.Row.Value.Text)
			case ChildDeferred:
			}
		}
	}
	walk(0)
	return out
}

// mergeTrees merges upper into a copy of base the way _merge_tables
// (toml_bridge.py:914) merges two parsed layers: a key that is a table on
// both sides recurses; any other key is assigned, which keeps an existing
// key's position and appends a new one.
func mergeTrees(t *testing.T, base, upper *Tree) *Tree {
	t.Helper()
	out := &Tree{}
	var cp func(src *Tree, i int) int
	cp = func(src *Tree, i int) int {
		n := src.Nodes[i]
		at := len(out.Nodes)
		out.Nodes = append(out.Nodes, Node{
			Path: append([]string(nil), n.Path...), Text: n.Text, Line: n.Line,
			Implicit: n.Implicit, Inline: n.Inline,
		})
		for _, c := range n.Children {
			if c.Kind == ChildDeferred {
				t.Fatalf("layer fixture holds a deferred value at %q", c.Key)
			}
			if c.Kind == ChildNode {
				c.Node = cp(src, c.Node)
			}
			out.Nodes[at].Children = append(out.Nodes[at].Children, c)
		}
		return at
	}
	cp(base, 0)
	var merge func(di int, si int)
	merge = func(di int, si int) {
		for _, c := range upper.Nodes[si].Children {
			if c.Kind == ChildDeferred {
				t.Fatalf("layer fixture holds a deferred value at %q", c.Key)
			}
			found := -1
			for j, d := range out.Nodes[di].Children {
				if d.Key == c.Key {
					found = j
					break
				}
			}
			if found >= 0 && c.Kind == ChildNode && out.Nodes[di].Children[found].Kind == ChildNode {
				merge(out.Nodes[di].Children[found].Node, c.Node)
				continue
			}
			if c.Kind == ChildNode {
				c.Node = cp(upper, c.Node)
			}
			if found >= 0 {
				out.Nodes[di].Children[found] = c
			} else {
				out.Nodes[di].Children = append(out.Nodes[di].Children, c)
			}
		}
	}
	merge(0, 0)
	return out
}

// The node tree Decode returns keeps every accepted table node in creation
// order, empty ones included, and is enough to merge two layers the way
// the bridge does (base#1442, design r4 cycle 12d). Base A and base B give
// the same service rows, but A's empty quoted `["logging.a"]` node decides
// the merged order, so a model without it cannot reproduce the layered
// answer.
//
// Expected values: the `--tables` and `--merge --kv` blocks are the real
// bridge's output for these bytes (design r4 section 1q, bridge_c1.out):
// A `logging.a|logging|logging.a`, B `logging|logging.a`; A+upper
// `logging.a>driver>local | logging.a>driver>json-file`, B+upper
// `logging.a>driver>json-file | logging.a>driver>local`. The resolved
// drivers are the shell's `_conf_load_layers` + `_conf_get` (layers_c1.out):
// A+upper json-file, B+upper local. Node lines are counted from the bytes.
func TestDecodeTreeKeepsEmptyNodesAndMergesLayers(t *testing.T) {
	decode := func(name, src string) *Config {
		t.Helper()
		cfg, refusals := Decode([]byte(src))
		if len(refusals) != 0 {
			t.Fatalf("%s: Decode refusals = %d (%+v), want none", name, len(refusals), refusals)
		}
		return cfg
	}
	a := decode("base A", layerBaseA)
	b := decode("base B", layerBaseB)
	up := decode("upper", layerUpper)

	// (a) one layer: exact nodes, and the bridge's --tables walk.
	wantA := []treeNode{
		{Children: []treeChild{{Kind: ChildNode, Key: "logging.a", Node: 1}, {Kind: ChildNode, Key: "logging", Node: 2}}},
		{Path: []string{"logging.a"}, Text: "logging.a", Line: 1},
		{Path: []string{"logging"}, Text: "logging", Line: 2, Implicit: true,
			Children: []treeChild{{Kind: ChildNode, Key: "a", Node: 3}}},
		{Path: []string{"logging", "a"}, Text: "logging.a", Line: 2,
			Children: []treeChild{{Kind: ChildRow, Key: "driver", Text: "json-file", Line: 3}}},
	}
	wantB := []treeNode{
		{Children: []treeChild{{Kind: ChildNode, Key: "logging", Node: 1}}},
		{Path: []string{"logging"}, Text: "logging", Line: 2, Implicit: true,
			Children: []treeChild{{Kind: ChildNode, Key: "a", Node: 2}}},
		{Path: []string{"logging", "a"}, Text: "logging.a", Line: 2,
			Children: []treeChild{{Kind: ChildRow, Key: "driver", Text: "json-file", Line: 3}}},
	}
	for _, tc := range []struct {
		name   string
		cfg    *Config
		nodes  []treeNode
		tables []string
	}{
		{"base A", a, wantA, []string{"logging.a", "logging", "logging.a"}},
		{"base B", b, wantB, []string{"logging", "logging.a"}},
	} {
		if got := flatTree(&tc.cfg.Tree); !reflect.DeepEqual(got, tc.nodes) {
			t.Errorf("%s: Tree = %+v, want %+v", tc.name, got, tc.nodes)
		}
		if got := tablesOf(&tc.cfg.Tree); !reflect.DeepEqual(got, tc.tables) {
			t.Errorf("%s: tables walk = %q, want %q", tc.name, got, tc.tables)
		}
		svc := tc.cfg.Logging.Services["a"]
		if svc == nil || len(svc.Rows) != 1 || svc.Rows[0].Key != "driver" ||
			svc.Rows[0].Field.Value.Text != "json-file" || svc.Rows[0].Field.Line != 3 {
			t.Errorf("%s: Services[a] = %+v, want one row driver json-file line 3", tc.name, svc)
		}
	}

	// (b) merge with upper: the bridge's --merge --kv rows; (c) the
	// projection of the merged tree gives the shell's layered driver.
	for _, tc := range []struct {
		name   string
		base   *Config
		rows   []string
		driver string
	}{
		{"A+upper", a, []string{"logging.a\tdriver\tlocal", "logging.a\tdriver\tjson-file"}, "json-file"},
		{"B+upper", b, []string{"logging.a\tdriver\tjson-file", "logging.a\tdriver\tlocal"}, "local"},
	} {
		merged := mergeTrees(t, &tc.base.Tree, &up.Tree)
		if got := emitRows(merged); !reflect.DeepEqual(got, tc.rows) {
			t.Errorf("%s: merged rows = %q, want %q", tc.name, got, tc.rows)
		}
		svc := ProjectServices(merged)["a"]
		if svc == nil || svc.Driver.State != Set || svc.Driver.Value.Text != tc.driver {
			t.Errorf("%s: ProjectServices(merged)[a] = %+v, want Driver %q", tc.name, svc, tc.driver)
		}
	}
}
