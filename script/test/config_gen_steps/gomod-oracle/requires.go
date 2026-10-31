// Command requires prints the requirements Go read from a go.mod, given
// the output of `go mod edit -json` on stdin, one per line:
//
//	require<TAB><path><TAB><version><TAB><indirect>
//
// It is the Go half of script/test/config_gen_steps/20-gomod-oracle.sh,
// which compares these records with the pin registry's go.mod scanner
// (base#1463). Standard library only: the oracle runs with no network.
package main

import (
	"encoding/json"
	"fmt"
	"os"
)

type goMod struct {
	Require []struct {
		Path     string
		Version  string
		Indirect bool
	}
}

func main() {
	var m goMod
	if err := json.NewDecoder(os.Stdin).Decode(&m); err != nil {
		fmt.Fprintln(os.Stderr, "requires:", err)
		os.Exit(1)
	}
	for _, r := range m.Require {
		fmt.Printf("require\t%s\t%s\t%t\n", r.Path, r.Version, r.Indirect)
	}
}
