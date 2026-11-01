package main

import (
	"fmt"
	"io"
	"os"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/tables"
)

func init() {
	Register("tables", tablesCmd)
}

// tablesCmd is `config-gen tables --name <label> <path>`: it prints the
// dotted path of every table the file at path declares, in the order the
// bridge's `toml_bridge.py --tables` prints them (base#1469).
func tablesCmd(args []string, stdout, stderr io.Writer) error {
	if len(args) != 3 || args[0] != "--name" {
		return fmt.Errorf("usage: tables --name <label> <path>")
	}
	src, err := os.ReadFile(args[2])
	if err != nil {
		return err
	}
	out, err := tables.Emit(src)
	if err != nil {
		return err
	}
	_, err = stdout.Write(out)
	return err
}
