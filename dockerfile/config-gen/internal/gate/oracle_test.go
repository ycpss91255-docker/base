package gate

import (
	"errors"
	"os"
	"strings"
)

// loadOracleVerdicts reads the live tomllib verdicts file that
// CONFIG_GEN_TOML_ORACLE names (base#1851). An empty path or a file it
// cannot read fails closed with noOracleMsg.
func loadOracleVerdicts(path string) ([]string, error) {
	if path == "" {
		return nil, errors.New(noOracleMsg)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New(noOracleMsg + ": " + err.Error())
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n"), nil
}
