package locate_test

import (
	"fmt"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/locate"
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
