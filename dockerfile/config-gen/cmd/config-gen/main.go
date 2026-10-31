// Command config-gen is the config generator ADR-00000039 makes one typed
// Go program (base#1462). This is its skeleton: a registry of named
// commands and the dispatch every caller reads its exit status from.
//
// Exit statuses:
//
//	0  the command succeeded
//	1  the command returned an error
//	2  usage: no command was named, or the name is not registered;
//	   nothing is written to stdout
//	4  the command panicked
package main

import (
	"fmt"
	"io"
	"os"
	"sort"
)

// Command is one registered sub-command. It writes its answer to stdout,
// its diagnostics to stderr, and returns an error to exit 1.
type Command func(args []string, stdout, stderr io.Writer) error

const (
	exitOK    = 0
	exitError = 1
	exitUsage = 2
	exitPanic = 4
)

var commands = map[string]Command{}

// Register adds cmd under name. A name registered twice is a programming
// error, so it panics rather than letting the later one win silently.
func Register(name string, cmd Command) {
	if _, dup := commands[name]; dup {
		panic(fmt.Sprintf("config-gen: command %q registered twice", name))
	}
	commands[name] = cmd
}

// run dispatches args[0] to its command and returns the exit status.
func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		usage(stderr, "no command given")
		return exitUsage
	}
	cmd, ok := commands[args[0]]
	if !ok {
		usage(stderr, fmt.Sprintf("unknown command %q", args[0]))
		return exitUsage
	}
	return invoke(args[0], cmd, args[1:], stdout, stderr)
}

// invoke runs cmd, turning an error into 1 and a panic into 4.
func invoke(name string, cmd Command, args []string, stdout, stderr io.Writer) (status int) {
	defer func() {
		if r := recover(); r != nil {
			_, _ = fmt.Fprintf(stderr, "config-gen: %s panicked: %v\n", name, r)
			status = exitPanic
		}
	}()
	if err := cmd(args, stdout, stderr); err != nil {
		_, _ = fmt.Fprintf(stderr, "config-gen: %s: %v\n", name, err)
		return exitError
	}
	return exitOK
}

// usage writes why the invocation was refused and the registered names,
// to stderr only.
func usage(stderr io.Writer, why string) {
	names := make([]string, 0, len(commands))
	for name := range commands {
		names = append(names, name)
	}
	sort.Strings(names)
	_, _ = fmt.Fprintf(stderr, "config-gen: %s\nusage: config-gen <command> [args...]\ncommands: %v\n", why, names)
}

// osExit is swapped by the tests so main itself is exercised.
var osExit = os.Exit

func main() {
	osExit(run(os.Args[1:], os.Stdout, os.Stderr))
}
