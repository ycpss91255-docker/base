package main

import (
	"errors"
	"io"
	"os"
	"strconv"
	"syscall"

	"github.com/BurntSushi/toml"

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
// on stdout. A file the TOML parser refuses exits 1 with one
// `conf_toml_parse_failed` frame whose `file` is the `--name` label.
// An input that is not a regular file (a directory, a FIFO, a device, a
// socket) exits 1 with one `config_gen_input_not_regular` frame; the open
// is O_NONBLOCK so a FIFO with no writer cannot hold it.
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
	src, err := readRegular(args[2])
	if errors.Is(err, errNotRegular) {
		_, _ = stderr.Write(diag.Encode(diag.Frame{
			Sev:   "error",
			Event: "config_gen_input_not_regular",
			File:  args[1],
			Text:  "input is not a regular file",
		}))
		osExit(exitError)
		return nil
	}
	if err != nil {
		return err
	}
	out, err := tables.Emit(src)
	if err != nil {
		var pe toml.ParseError
		errors.As(err, &pe)
		_, _ = stderr.Write(diag.Encode(diag.Frame{
			Sev:   "error",
			Event: "conf_toml_parse_failed",
			File:  args[1],
			Line:  strconv.Itoa(pe.Position.Line),
			Col:   strconv.Itoa(pe.Position.Col),
			Text:  err.Error(),
		}))
		osExit(exitError)
		return nil
	}
	_, err = stdout.Write(out)
	return err
}

var errNotRegular = errors.New("not a regular file")

// readRegular opens path without blocking (a FIFO with no writer, a socket
// or a device does not hold open(2)), checks the opened descriptor is a
// regular file, and reads it. Anything else is errNotRegular.
func readRegular(path string) ([]byte, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if errors.Is(err, syscall.ENXIO) || errors.Is(err, syscall.ENODEV) {
		return nil, errNotRegular
	}
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	f := os.NewFile(uintptr(fd), path)
	defer func() { _ = f.Close() }()
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return nil, &os.PathError{Op: "fstat", Path: path, Err: err}
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return nil, errNotRegular
	}
	return io.ReadAll(f)
}
