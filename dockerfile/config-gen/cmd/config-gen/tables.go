package main

import (
	"errors"
	"io"
	"os"
	"os/signal"
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
// exits 1 with one `no_such_file` frame; an fstat error on the opened
// descriptor is the not-regular frame. Any other open or read error
// (EACCES, EPERM, ...) exits 1 with one
// `config_gen_input_unreadable` frame. The answer is
// one stdout write; a write error or a short count exits 4 with one
// `config_gen_output_failed` frame. That includes a stdout pipe whose
// reader is gone: SIGPIPE is routed to a channel here, so the write
// returns EPIPE instead of the Go runtime killing the process (os/signal);
// only this command does so, other commands keep the default.
func tablesCmd(args []string, stdout, stderr io.Writer) error {
	signal.Notify(make(chan os.Signal, 1), syscall.SIGPIPE)
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
	if err != nil {
		return refuseInput(stderr, label, err)
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
		if err == nil {
			err = io.ErrShortWrite
		}
		return fail(stderr, exitOutput, diag.Frame{
			Event: "config_gen_output_failed",
			File:  label,
			Text:  err.Error(),
		})
	}
	return exitOK
}

// refuseInput writes the one frame for readRegular's error err about the
// input labelled label and returns exit 1 (base#1469 Input). open(2)
// answers ENXIO for a socket and ENODEV for a device node with no driver
// behind it: neither names a regular file, so both are the not-regular
// frame, as a type fstat reports that is not S_IFREG is.
func refuseInput(stderr io.Writer, label string, err error) int {
	switch {
	case errors.Is(err, errNotRegular) || errors.Is(err, syscall.ENXIO) || errors.Is(err, syscall.ENODEV):
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
	default:
		return fail(stderr, exitError, diag.Frame{
			Event: "config_gen_input_unreadable",
			File:  label,
			Text:  err.Error(),
		})
	}
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

// readRegular opens path without blocking (a FIFO with no writer, a socket
// or a device does not hold open(2)), checks the opened descriptor is a
// regular file, and reads it. A descriptor that is not one is
// errNotRegular, including one fstat(2) can not describe: what it names is
// not known to be a regular file (base#1469). An open error is returned as
// open(2) gave it; refuseInput classifies it.
func readRegular(path string) ([]byte, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	f := os.NewFile(uintptr(fd), path)
	defer func() { _ = f.Close() }()
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil || st.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return nil, errNotRegular
	}
	return io.ReadAll(f)
}
