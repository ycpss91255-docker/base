package locate

import (
	"fmt"
	"os"
	"testing"
	"time"
)

// terminationBound is how long Index may take on one of
// terminationInputs. Each input is a few dozen bytes, so a scan that is
// still running after it is one that never ends.
const terminationBound = time.Second

// terminationInputs holds one short document per form the scanner reads,
// each with something after it, so a loop that stops advancing over that
// form never returns: indentation and a comment line, a dotted header with
// a basic and a literal component, a dotted key, a plain value, a
// multi-line basic string holding an escaped byte and a line-ending
// backslash, a multi-line literal string, basic strings holding each
// escape form, an inline array spread over spaces, commas and a newline,
// an inline table, and an inline table holding a byte that is neither a
// key nor `=`, which the package contract says still ends the scan.
var terminationInputs = []string{
	" \t\r# comment\n\n[a]\n",
	"[a.\"b\\tc\".'d']\nk = 1\n",
	"x.y.z = 1\nw = 2\n",
	"k = 12345\nw = 2\n",
	"k = \"\"\"l1\n\\q\\\n\"\"\"\nw = 2\n",
	"k = '''l1\nl2'''\nw = 2\n",
	"k = \"a\\b\\t\\n\\f\\r\\e\\\"\\\\\\x41\\u0041\\U0001F600\"\nw = 2\n",
	"k = [ 1 , 2,\n  3 , ]\nw = 2\n",
	"k = { a = 1, b.c = 'x', d = [ \"y\" ] }\nw = 2\n",
	"k = { @ }\nw = 2\n",
}

// TestMain checks, before any test of the package runs, that Index
// returns on every one of terminationInputs within terminationBound, and
// fails the run when one does not (base#1467: the S1f mutation gate
// counted 17 mutants that turn a scan loop into one that never ends as
// timed out, because no test bounded how long Index may run). It runs
// first so that no other test reaches a scan that never ends before it.
func TestMain(m *testing.M) {
	for _, src := range terminationInputs {
		done := make(chan struct{})
		go func() {
			defer close(done)
			Index([]byte(src))
		}()
		select {
		case <-done:
		case <-time.After(terminationBound):
			_, _ = fmt.Fprintf(os.Stderr, "Index(%q) did not return within %v\n", src, terminationBound)
			os.Exit(1)
		}
	}
	os.Exit(m.Run())
}
