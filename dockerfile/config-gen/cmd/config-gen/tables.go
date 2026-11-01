package main

import (
	"io"
	"os"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/diag"
	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/tables"
)

func init() {
	Register("tables", tablesCmd)
}

// tablesCmd is `config-gen tables --name <label> <path>`: it prints the
// dotted path of every table the file at path declares, in the order the
// bridge's `toml_bridge.py --tables` prints them (base#1469). Wrong argv
// exits 2 with one `config_gen_usage_invalid` frame on stderr and nothing
// on stdout.
func tablesCmd(args []string, stdout, stderr io.Writer) error {
	if len(args) != 3 || args[0] != "--name" {
		_, _ = stderr.Write(diag.Encode(diag.Frame{
			Sev:   "error",
			Event: "config_gen_usage_invalid",
			Text:  "usage: tables --name <label> <path>",
		}))
		osExit(exitUsage)
		return nil
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
