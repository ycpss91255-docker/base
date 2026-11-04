package schema

import "testing"

// A well-formed shell address `<section>.<prefix>_<N>` reads into its
// section, its family's numbered prefix and its entry number, the digits
// read as a decimal (leading zeros included), and a prefix that itself
// carries an underscore keeps it (base#1443, design r1 cycle 16).
//
// Expected values: `_conf_toml_aot_nskey` (dist/script/docker/lib/conf.sh)
// writes the N-th `[[<path>]]` block as `<section>.<prefix>_N` --
// `volumes` as `volumes.mount_N`, `devices.cgroup_rules` as
// `devices.cgroup_rule_N`, `network.ports` as `network.port_N`,
// `security.cap_add` as `security.cap_add_N`, `tmpfs` as `tmpfs.tmpfs_N`,
// `additional_contexts` as `additional_contexts.context_N`; the shell's
// key check (`_setup_known_key`, r3 p1443/known.out) accepts
// `volumes mount_2`, `network port_3` and `devices cgroup_rule_1`; the
// bridge reads `rest` with `int(rest)` (dockerfile/toml_bridge.py), so
// `01` is 1 [spec].
func TestParseAddressWellFormed(t *testing.T) {
	cases := []struct {
		in   string
		want Address
	}{
		{"volumes.mount_2", Address{Section: "volumes", Prefix: "mount", Index: 2}},
		{"volumes.mount_01", Address{Section: "volumes", Prefix: "mount", Index: 1}},
		{"network.port_3", Address{Section: "network", Prefix: "port", Index: 3}},
		{"devices.cgroup_rule_1", Address{Section: "devices", Prefix: "cgroup_rule", Index: 1}},
		{"security.cap_add_12", Address{Section: "security", Prefix: "cap_add", Index: 12}},
		{"tmpfs.tmpfs_4", Address{Section: "tmpfs", Prefix: "tmpfs", Index: 4}},
		{"additional_contexts.context_1", Address{Section: "additional_contexts", Prefix: "context", Index: 1}},
	}
	for _, c := range cases {
		got, err := ParseAddress(c.in)
		if err != nil {
			t.Errorf("ParseAddress(%q) error = %v, want nil", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("ParseAddress(%q) = %+v, want %+v", c.in, got, c.want)
		}
	}
}
