# Deprecations

Items kept for backward compatibility behind a permanent alias / shim,
scheduled for removal at the next major version (**v1.0.0**). This is the
W3 strategy: rather than a short N-release deprecation window (which a
downstream that upgrades infrequently would skip straight past, breaking
on the removal), the legacy form is kept working indefinitely and a
deprecation warning nudges migration. **Grep this file before cutting
v1.0.0** and remove every entry's legacy path.

| Deprecated | Replacement | Since | Remove at | Ref |
|---|---|---|---|---|
| `[deploy] runtime` | `[deploy] gpu_runtime` | v0.41.0 | v1.0.0 | #481 |

## `[deploy] runtime` -> `[deploy] gpu_runtime`

- **Deprecated:** v0.41.0 (#481)
- **Why:** `runtime` was an overloaded word in `setup.conf` (file preamble
  "runtime configuration", `[environment]` "runtime env vars", and this
  GPU-runtime key). Renaming to `gpu_runtime` puts it in the GPU family
  (`gpu_mode` / `gpu_count` / `gpu_capabilities` / `gpu_runtime`) and
  removes the collision.
- **Alias behaviour:** `setup.sh` reads `gpu_runtime` first; if absent but
  `[deploy] runtime` is present, it consumes the legacy value and emits a
  `_log_warn` deprecation. The `.env` variable name stays `RUNTIME`
  (downstream back-compat). `gpu_runtime` wins when both are present.
- **Precedence across layers:** "absent" is decided per LAYER, never on
  the merged result. `setup.toml` is a three-file chain (template / repo /
  `setup.local.toml`) whose tables merge key by key, and the template
  always ships `gpu_runtime = "auto"`, so the merged view always carries
  the canonical key. Decided there, the "canonical absent" branch could
  never fire and a repo writing `runtime = "runc"` resolved silently to
  `auto`. The rule the merge applies instead: **a layer that supplies ONLY
  the legacy spelling un-inherits the canonical value from the layers
  below**, so the highest layer that spells the setting out is the layer
  that decides it. A canonical key the layer supplies itself is kept,
  whether or not the same layer also supplies the legacy one -- that is
  where "`gpu_runtime` wins when both are present" applies. The
  deprecation warning is unchanged: it fires on the legacy key's presence
  in ANY layer, because a chain that still carries it has a half-finished
  migration. The pairs are declared in `dockerfile/toml_bridge.py`'s
  `_LEGACY_ALIASES`.
- **Action at removal (v1.0.0):** drop the legacy-key fallback branch in
  `setup.sh`'s deploy resolution, drop `deploy.runtime` from
  `_validate_stage_override_key`, drop the per-stage `deploy.runtime`
  fallback resolve, drop the `_setup_msg_deploy runtime_deprecated`
  message, and drop the pair from `dockerfile/toml_bridge.py`'s
  `_LEGACY_ALIASES`. Downstream `setup.conf` still carrying `runtime` will
  then error -- the v1.0.0 downstream-upgrade workflow must rewrite the
  key first.
