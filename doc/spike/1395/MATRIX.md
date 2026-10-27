# base#1395 slice 1: compatibility matrix

SPIKE ONLY. This branch is never merged.

What the shipped TOML bridge does today for each behaviour a replacement
engine must reproduce or change on purpose, next to what the Go
prototype (`go-proto/`) does with the same input.

- **Bridge** means `origin/main` at `f2a0fd1e`, `dockerfile/toml_bridge.py`
  taken with `git show` (not the spike's patched copy). It runs inside the
  bridge runtime image (python 3.13.13-alpine3.22 + tomli 2.4.1), the same
  way the shim runs it.
- **Go** means the prototype binary, built from `go-proto/` by
  `measure.sh setup`.
- Every cell below comes from `probe-matrix.sh`. Its full output, with
  each command and exit status, is in `results/matrix-output.txt`. The
  shared base layer sets `network.mode`, `network.ipc`, one
  `[[network.ports]]`, `deploy.gpu_mode`, `deploy.gpu_runtime` and
  `gui.mode`. `gui.mode` is there only because the Go prototype requires
  it.

| # | Case | Bridge today (observed) | Go prototype (observed) | Same? |
|---|---|---|---|---|
| 1 | **Missing layer**: `--merge --kv base.toml absent.toml` | rc 0. Rows come from `base.toml` only, and the absent layer is skipped. The shim's `toml_bridge_merge` also drops absent layers before the bridge sees them: a chain where every layer is absent gives rc 0, no output and no engine call. | rc 1: `absent.toml: cannot read: open ...: no such file or directory` | **No** |
| 2a | **Partial layer**, one key: upper layer `[network] mode = "host"` | rc 0. `network mode host`, with `ipc private` and `port_1 8080:80` inherited. The merge is key by key. | `get network.ipc` gives `private`. `get --json network.ports` gives `[{"container":80,"host":8080}]` (inherited). | Yes |
| 2b | **Partial layer**, array: upper layer has one `[[network.ports]]` 9090:90 | rc 0. Only `port_1 9090:90` is left, so the array is replaced as a whole. | `[{"container":90,"host":9090}]`, also replaced as a whole | Yes |
| 3 | **Unknown array** `[[network.bogus]]` | `--kv`: rc 1, `network.bogus is an array, and no numbered family ... carries an array by that name`. JSON mode: rc 0, and the output includes `"bogus": [{"x": 1}]`. `--entries`: rc 1, with the same message (since #1404). `--tables`: rc 0 and lists `network` only. `--empty-families`: rc 0 with no output. | rc 1: `unk.toml:4:3: unknown key "network.bogus"` (with a position) | Refusal: yes. JSON mode: **no** |
| 4a | **Legacy alias**: upper layer sets only `[deploy] runtime = "runc"` over `gpu_runtime = "auto"` | rc 0. `deploy runtime runc`. The inherited `gpu_runtime` row is **gone**, and the value is not renamed. | rc 1: `legacy.toml:2:1: unknown key "deploy.runtime"` | **No** |
| 4b | Layer sets both `runtime = "runc"` and `gpu_runtime = "nvidia"` | rc 0. Both rows are emitted: `gpu_runtime nvidia` and `runtime runc`. | (not probed separately; 4a already refuses the key) | n/a |
| 5a | **`[stage:<name>]`**, written bare: `[stage:devel]` | rc 1: `Expected ']' at the end of a table declaration (at line 1, column 7)`. This is invalid TOML. | (not probed: it is a parse error for any engine) | n/a |
| 5b | `["stage:devel"]` and `["stage:devel".deploy]` | `--kv`: `stage:devel gpu true` and `stage:devel.deploy runtime runc`. `--tables` lists both tables. A self-merge has the same rows. | rc 1: `stage.toml:1:2: unknown key "stage:devel"` and `stage.toml:4:2: unknown key "stage:devel.deploy"` | **No** |
| 6a | **Empty versus absent**, array: `[network] ports = []` | `--kv`: rc 0, no row. `--empty-arrays`: `network	network.ports`. `--empty-families`: `network	port_1	network.ports`. Merged over the base, the `port_1` row disappears, so the merged `--kv` view cannot tell cleared from never-set. Only the per-layer views can. | `[]` over the base, and the inherited value when the key is absent (2a). The two stay distinct in one merged result. | Result: yes. View: **different shape** |
| 6b | Empty table `[environment]` | `--kv`: rc 0, no row. `--tables`: `environment`. | `{}`, rc 0. When absent: rc 3, `get: environment: not set` | Distinguishable in both, by different views |
| 7a | **Scalar type**: int `host = 8080`, string `container = "80"`, bool, int, float | rc 0. `port_1 8080:80`, `privileged true`, `max_file 3`, `max_size 1.5`. A string port is accepted on purpose (`_field`, toml_bridge.py:150, rationale at :22-32 on main). | rc 1: `types.toml:6:13: network.ports.container: cannot decode TOML string into ... int64` | **No** |
| 7b | Wrong type: `privileged = "yes"` | rc 0. `security privileged yes` is passed through. This probe did not check what the shell reader does with it. | rc 1: `wrongtype.toml:2:14: security.privileged: cannot decode TOML string into ... bool` | **No** |
| 7c | Date: `[project] name = 1979-05-27` | rc 0. `project name 1979-05-27` | rc 1: `date.toml:2:8: project.name: cannot decode TOML local date into ... string` | **No** |

## Reading

- The prototype matches the bridge on the two **merge rules** (2a, 2b:
  key-level tables, whole-array replace) and on **refusing an unknown
  array** (3) in the views the shell reads.
- It diverges in **seven** of the probed rows: 1, the JSON mode of 3, 4a,
  5b, 7a, 7b and 7c. Each of these is a behaviour decision, not a bug
  the prototype fixes. Row 1 is final-en.md sec. 9 decision 2. Rows 4a
  and 5b are features the prototype does not model. Rows 7a-7c reject
  input the bridge accepts on purpose today.
- Row 6a is the subtle one. The bridge's merged `--kv` view loses the
  difference between an emptied array and a never-set one, and the shell
  recovers it from the per-layer `--empty-arrays` / `--empty-families`
  views. Any batched or replacement engine has to keep supplying those
  per-layer views, or supply the difference some other way. The
  batching patch on this branch keeps them (`--batch` emits
  `empty-arrays` and `empty-families` for each layer).
