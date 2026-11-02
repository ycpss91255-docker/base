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
// is O_NONBLOCK so a FIFO with no writer cannot hold it. A path that
// names no file (ENOENT, or ENOTDIR for a name under a regular file)
// exits 1 with one `no_such_file` frame. Any other open, stat or read
// error (EACCES, EPERM, ...) exits 1 with one
// `config_gen_input_unreadable` frame. The answer is
// one stdout write; a write error or a short count exits 4 with one
// `config_gen_output_failed` frame.
func tablesCmd(args []string, stdout, stderr io.Writer) error {
	if rc := runTables(args, stdout, stderr); rc != exitOK {
		osExit(rc)
	}
	return nil
}

// runTables does the work of tablesCmd and returns its exit status; every
// non-zero status has written exactly one frame to stderr.
func runTables(args []string, stdout, stderr io.Writer) int {
	if len(args) != 3 || args[0] != "--name" {
		return fail(stderr, exitUsage, diag.Frame{
			Event: "config_gen_usage_invalid",
			Text:  "usage: tables --name <label> <path>",
		})
	}
	label := args[1]
	src, err := readRegular(args[2])
	switch {
	case errors.Is(err, errNotRegular):
		return fail(stderr, exitError, diag.Frame{
			Event: "config_gen_input_not_regular",
			File:  label,
			Text:  "input is not a regular file",
		})
	case errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ENOTDIR):
		return fail(stderr, exitError, diag.Frame{
			Event: "no_such_file",
			File:  label,
			Text:  "no such file",
		})
	case err != nil:
		return fail(stderr, exitError, diag.Frame{
			Event: "config_gen_input_unreadable",
			File:  label,
			Text:  err.Error(),
		})
	}
	out, err := tables.Emit(src)
	if err != nil {
		var pe toml.ParseError
		errors.As(err, &pe)
		return fail(stderr, exitError, diag.Frame{
			Event: "conf_toml_parse_failed",
			File:  label,
			Line:  strconv.Itoa(pe.Position.Line),
			Col:   strconv.Itoa(pe.Position.Col),
			Text:  err.Error(),
		})
	}
	if n, err := stdout.Write(out); err != nil || n != len(out) {
		text := "short write"
		if err != nil {
			text = err.Error()
		}
		return fail(stderr, exitOutput, diag.Frame{
			Event: "config_gen_output_failed",
			File:  label,
			Text:  text,
		})
	}
	return exitOK
}

// fail writes f to stderr as one error-severity frame and returns rc.
func fail(stderr io.Writer, rc int, f diag.Frame) int {
	f.Sev = "error"
	_, _ = stderr.Write(diag.Encode(f))
	return rc
}

// exitOutput is the status when the answer cannot be written in full.
const exitOutput = 4

var errNotRegular = errors.New("not a regular file")

// fstat is syscall.Fstat; a test swaps it to reach the error no regular
// file on a healthy filesystem gives (base#1469).
var fstat = syscall.Fstat

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
	if err := fstat(fd, &st); err != nil {
		return nil, &os.PathError{Op: "fstat", Path: path, Err: err}
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return nil, errNotRegular
	}
	return io.ReadAll(f)
}
