package buildgate

import (
	"reflect"
	"testing"
)

// IgnoredInputs (base#1467): one config_gen_mutation_ignored_input event
// per listed module path the build context holds, in list order, the
// C-quoted spelling read back and the value encoded as every event's is.
func TestIgnoredInputs(t *testing.T) {
	const sha = "\t" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	list := "dockerfile/config-gen/cmd/x/zz.go" + sha + "\n" +
		"dockerfile/config-gen/gone.txt" + sha + "\n" +
		`"dockerfile/config-gen/testdata/a\tb.txt"` + sha + "\n" +
		"elsewhere/zz.go" + sha + "\n" +
		"dockerfile/config-gen/" + sha + "\n"
	var asked []string
	present := func(rel string) bool {
		asked = append(asked, rel)
		return rel != "gone.txt"
	}
	got := IgnoredInputs(list, present)
	var lines []string
	for _, e := range got {
		lines = append(lines, e.String())
	}
	want := []string{
		"cg_event config_gen_mutation_ignored_input file=dockerfile/config-gen/cmd/x/zz.go",
		"cg_event config_gen_mutation_ignored_input file=dockerfile/config-gen/testdata/a%09b.txt",
	}
	if !reflect.DeepEqual(lines, want) {
		t.Errorf("IgnoredInputs = %q, want %q", lines, want)
	}
	if wantAsked := []string{"cmd/x/zz.go", "gone.txt", "testdata/a\tb.txt"}; !reflect.DeepEqual(asked, wantAsked) {
		t.Errorf("present asked %q, want %q", asked, wantAsked)
	}
	if got := IgnoredInputs("", present); got != nil {
		t.Errorf("IgnoredInputs of an empty list = %v, want none", got)
	}
}
