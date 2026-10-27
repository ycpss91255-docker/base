#!/usr/bin/env bash
# probe-matrix.sh -- base#1395 slice 1 compatibility probes. SPIKE ONLY.
#
# Runs each compatibility case against:
#   bridge  origin/main's dockerfile/toml_bridge.py (git show, NOT the
#           spike's patched copy) inside the bridge runtime image
#           (python 3.13 + tomli), exactly as the shim runs it
#   shim    toml_bridge_merge from origin/main's toml_bridge.sh, for the
#           one case the shell decides before the bridge sees it
#   go      the Go prototype binary (doc/spike/1395/go-proto), built by
#           measure.sh setup into $SPIKE_WORK/setupgen
# and prints each command and its full output and exit status.
#
# usage: SPIKE_WORK=<dir> probe-matrix.sh > matrix-output.txt
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BASE="$(cd -- "${HERE}/../../.." && pwd -P)"
WORK="${SPIKE_WORK:?set SPIKE_WORK}"
GO="${WORK}/setupgen"
[[ -x "${GO}" ]] || { echo "run measure.sh setup first" >&2; exit 2; }

P="${WORK}/probe"
rm -rf -- "${P}"
mkdir -p -- "${P}/main/lib" "${P}/main/dockerfile"
REF="$(git -C "${BASE}" rev-parse origin/main)"
git -C "${BASE}" show "${REF}:dockerfile/toml_bridge.py" > "${P}/main/toml_bridge.py"
IMG="$(bash -c 'source "$1/dist/script/docker/lib/toml_bridge.sh"; _toml_bridge_resolve_image >/dev/null && echo "$_TOML_BRIDGE_RESOLVED"' _ "${BASE}")"
[[ -n "${IMG}" ]] || { echo "no bridge image" >&2; exit 2; }

# The bridge as the shim runs it, with main's script mounted over the
# image's copy and the probe dir mounted at its own path for --merge.
bridge() {
  docker run --rm -i -v "${P}/main/toml_bridge.py:/usr/local/bin/toml-bridge:ro" \
    -v "${P}:${P}:ro" "${IMG}" "$@"
}

show() {
  printf '\n$ %s\n' "$*"
  local _rc=0
  "$@" 2>&1 || _rc=$?
  printf '[rc=%s]\n' "${_rc}"
}

case_hdr() { printf '\n==== %s ====\n' "$*"; }

cd -- "${P}" || exit 2
printf '# probe-matrix.sh output\n# origin/main = %s\n# bridge image = %s (main toml_bridge.py mounted over it)\n# go = %s\n' \
  "${REF}" "${IMG}" "${GO}"

# ── base layer used by several cases ──────────────────────────────────
cat > base.toml <<'T'
[network]
mode = "bridge"
ipc = "private"

[[network.ports]]
host = 8080
container = 80

[deploy]
gpu_mode = "auto"
gpu_runtime = "auto"

[gui]
mode = "auto"
T
# gui.mode is here because the Go prototype requires it on the merged
# result; without it every Go probe stops at that check instead of
# reaching the property it is meant to show.
cat base.toml

case_hdr "1. missing layer"
show bridge --merge --kv "${P}/base.toml" "${P}/absent.toml"
show bash -c "source <(git -C '${BASE}' show '${REF}:dist/script/docker/lib/toml_bridge.sh' | sed 's|^_toml_bridge_dir=.*|_toml_bridge_dir=${BASE}/dist/script/docker/lib|'); TOML_BRIDGE_IMAGE=${IMG} toml_bridge_merge --kv '${P}/absent.toml'; echo \"shim rc=\$?\""
show "${GO}" env "${P}/base.toml" "${P}/absent.toml"

case_hdr "2. partial layer (one key of a table; arrays replace whole)"
printf '[network]\nmode = "host"\n' > partial.toml
cat partial.toml
show bridge --merge --kv "${P}/base.toml" "${P}/partial.toml"
show "${GO}" get network.ipc "${P}/base.toml" "${P}/partial.toml"
show "${GO}" get --json network.ports "${P}/base.toml" "${P}/partial.toml"
printf '[[network.ports]]\nhost = 9090\ncontainer = 90\n' > ports.toml
cat ports.toml
show bridge --merge --kv "${P}/base.toml" "${P}/ports.toml"
show "${GO}" get --json network.ports "${P}/base.toml" "${P}/ports.toml"

case_hdr "3. unknown array (a family _ARRAY_SPEC does not carry)"
printf '[network]\nmode = "bridge"\n\n[[network.bogus]]\nx = 1\n' > unk.toml
cat unk.toml
show bridge --kv < unk.toml
show bridge < unk.toml
show bridge --entries < unk.toml
show bridge --tables < unk.toml
show bridge --empty-families < unk.toml
show "${GO}" validate "${P}/base.toml" "${P}/unk.toml"

case_hdr "4. legacy alias (deploy.runtime -> deploy.gpu_runtime)"
printf '[deploy]\nruntime = "runc"\n' > legacy.toml
cat legacy.toml
show bridge --merge --kv "${P}/base.toml" "${P}/legacy.toml"
printf '[deploy]\nruntime = "runc"\ngpu_runtime = "nvidia"\n' > both.toml
cat both.toml
show bridge --merge --kv "${P}/base.toml" "${P}/both.toml"
show "${GO}" validate "${P}/base.toml" "${P}/legacy.toml"

case_hdr "5. [stage:<name>] table"
printf '[stage:devel]\ngpu = true\n' > stage-bare.toml
cat stage-bare.toml
show bridge --kv < stage-bare.toml
printf '["stage:devel"]\ngpu = true\n\n["stage:devel".deploy]\nruntime = "runc"\n' > stage.toml
cat stage.toml
show bridge --kv < stage.toml
show bridge --tables < stage.toml
show bridge --merge --kv "${P}/stage.toml" "${P}/stage.toml"
show "${GO}" validate "${P}/base.toml" "${P}/stage.toml"

case_hdr "6. empty versus absent"
printf '[network]\nports = []\n' > empty.toml
cat empty.toml
show bridge --kv < empty.toml
show bridge --empty-arrays < empty.toml
show bridge --empty-families < empty.toml
show bridge --merge --kv "${P}/base.toml" "${P}/empty.toml"
show "${GO}" get --json network.ports "${P}/base.toml" "${P}/empty.toml"
printf '[environment]\n' > envempty.toml
show bridge --kv < envempty.toml
show bridge --tables < envempty.toml
show "${GO}" get --json environment "${P}/base.toml" "${P}/envempty.toml"
show "${GO}" get --json environment "${P}/base.toml"

case_hdr "7. scalar type"
cat > types.toml <<'T'
[network]
mode = "bridge"

[[network.ports]]
host = 8080
container = "80"

[security]
privileged = true

[logging]
max_file = 3
max_size = 1.5
T
cat types.toml
show bridge --kv < types.toml
show "${GO}" validate "${P}/base.toml" "${P}/types.toml"
printf '[security]\nprivileged = "yes"\n' > wrongtype.toml
cat wrongtype.toml
show bridge --kv < wrongtype.toml
show "${GO}" validate "${P}/base.toml" "${P}/wrongtype.toml"
printf '[project]\nname = 1979-05-27\n' > date.toml
cat date.toml
show bridge --kv < date.toml
show "${GO}" validate "${P}/base.toml" "${P}/date.toml"
