package schema

import (
	"fmt"
	"reflect"
	"testing"
)

// Each document is judged by one rule of Decode's contract that no other
// test reached (base#1467: the S1f mutation gate left a mutant of each
// alive). The refusals are the whole list Decode returns, each line and
// column counted by hand from the input bytes.
func TestDecodeRefusalPaths(t *testing.T) {
	for _, c := range []struct {
		name string
		src  string
		want []Refusal
	}{
		{
			// A scalar under a `["stage:<name>"]` table is judged on its
			// stage-relative text (base#1443): foo, split at its last dot,
			// is the empty section and foo, which the shell's
			// _setup_known_key refuses (rc 1), so it is conf_unknown_key.
			name: "an unknown key under a stage table is refused",
			src:  "[\"stage:dev\"]\nfoo = 1\n",
			want: []Refusal{{Event: "conf_unknown_key", Path: []string{"stage:dev", "foo"}, Line: 2, Col: 1}},
		},
		{
			// The array is refused at its key, and nothing under a refused
			// path is judged: the newline in its string is not refused too.
			name: "a refused array's strings are not judged",
			src:  "[build]\nrules = [\"a\\nb\"]\n",
			want: []Refusal{{Event: "conf_unknown_key", Path: []string{"build", "rules"}, Line: 2, Col: 1}},
		},
		{
			// A root array at no section name written as `[[k]]` headers is
			// a table, refused as conf_unknown_table at its header.
			name: "a root array of tables is an unknown table",
			src:  "[[foo]]\nx = 1\n",
			want: []Refusal{{Event: "conf_unknown_table", Path: []string{"foo"}, Line: 1, Col: 1}},
		},
		{
			// The same name written as an inline array is a root key.
			name: "a root inline array is a top-level key",
			src:  "foo = [1]\n",
			want: []Refusal{{Event: "conf_top_level_key", Path: []string{"foo"}, Line: 1, Col: 1}},
		},
		{
			// A key of digits only has no `<prefix>_` before its number, so
			// it names no numbered family and is unknown.
			name: "a key of digits only is unknown",
			src:  "[network]\n10 = 1\n",
			want: []Refusal{{Event: "conf_unknown_key", Path: []string{"network", "10"}, Line: 2, Col: 1}},
		},
		{
			// The empty string stays the default empty policy's at a typed
			// key: max_file takes an int, and "" is not refused.
			name: "an empty string at an int key is not refused",
			src:  "[logging]\nmax_file = \"\"\n",
		},
	} {
		t.Run(c.name, func(t *testing.T) {
			_, got := Decode([]byte(c.src))
			if fmt.Sprint(got) != fmt.Sprint(c.want) {
				t.Errorf("Decode(%q) refusals = %+v, want %+v", c.src, got, c.want)
			}
		})
	}
}

// Only an array at a known section name is accepted at the root, and an
// array under an accepted table is deferred whatever its name (base#1467:
// the S1f mutation gate left alive a mutant that swapped the two).
// In the document below the root foo is refused and left out, and
// security.cap_add is the one deferred array.
func TestDecodeDeferredArrayPaths(t *testing.T) {
	cfg, _ := Decode([]byte("foo = [1]\n[security]\ncap_add = [\"NET_ADMIN\"]\n"))
	var got [][]string
	for _, d := range cfg.Deferred {
		got = append(got, d.Path)
	}
	if want := [][]string{{"security", "cap_add"}}; !reflect.DeepEqual(got, want) {
		t.Errorf("Deferred paths = %q, want %q", got, want)
	}
}
