package main

// reportedError is an error a command has already reported on stderr,
// with the exit status it stands for (base#1442). It is how a command
// reaches ADR-00000039's rc 2 (usage) and rc 4 (I/O) with stderr wholly
// frames; invoke in main.go reads it, the one main.go edit the base#1442
// scope update allows (issuecomment-6590495685).
type reportedError struct {
	status int
	err    error
}

func (e *reportedError) Error() string { return e.err.Error() }

func (e *reportedError) Unwrap() error { return e.err }

// reported wraps err so invoke exits with status and writes nothing more.
func reported(status int, err error) error {
	return &reportedError{status: status, err: err}
}
