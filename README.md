# sagequeue

`sagequeue` runs long SageMath experiments inside a **rootless Podman** container on **Ubuntu (WSL2)** using **podman-compose**, and executes partitions of the workload via a **durable on-disk queue** with workers supervised by **systemd --user**.

Primary target workload: stride/offset partitioned runs of `rank_boundary_sat_v18.sage` (e.g. `STRIDE=8`, offsets `0..7`) for mod-2 boundary rank distribution experiments (e.g. Shrikhande graph, then rook graph).

## What this repository contains

### 1) Container stack

- `podman-compose.yml` runs the SageMath container (Jupyter exposed on port `8888`).
- `man-up.sh` / `man-down.sh` start/stop the stack.
- `run-bash.sh` opens an interactive shell in the container.
- `bin/fix-bind-mounts.sh` + `bin/show-mapped-ids.sh` help resolve host permission issues with rootless Podman bind mounts on WSL2.

**Notebook location:** `rank_boundary_sat_v18.sage` is expected to exist on the host at:

- Linux/WSL path: `${HOME}/Jupyter/rank_boundary_sat_v18.sage`
- Windows path (same directory): `~\Jupyter\rank_boundary_sat_v18.sage`

That directory is bind-mounted by the compose file as:

- container path: `/home/sage/notebooks/rank_boundary_sat_v18.sage`

### 2) Queue runner (sagequeue)

The queue system adds reboot tolerance and operational control:

- Durable job queue on disk: `var/<JOBSET>/queue/{pending,running,done,failed}`
- N workers supervised by `systemd --user` (`sagequeue@.service`)
- Periodic orphan recovery (`sagequeue-recover.timer`), to requeue jobs stuck in `running/` after reboots/crashes
- Per-offset logs under `var/<JOBSET>/log/`

### 3) Idempotent setup utility

- `bin/setup.sh` performs a one-time (and repeatable) local setup up through enabling user lingering:
  - sanity checks (`podman`, `systemctl --user`)
  - creates bind-mount directories (using `.sagequeue-*` names)
  - verifies `${HOME}/Jupyter/rank_boundary_sat_v18.sage` exists
  - runs `bin/fix-bind-mounts.sh` to fix ownership/perms/ACLs for bind mounts
  - ensures `podman-compose` is available (builds `.venv` via `./venvfix.sh` if needed)
  - if needed, symlinks `podman-compose` into `/usr/local/bin` so it is visible to `systemd --user` (may prompt for `sudo`)
  - brings up the container stack (`podman-compose up -d sagemath`)
  - ensures repo scripts are executable
  - enables `loginctl enable-linger $USER` (best-effort; may use `sudo`)

## Quick start

### 0) WSL2 prerequisite: enable systemd

Rootless Podman needs a working per-user runtime directory (`/run/user/<uid>`). On WSL2, this is reliably available with systemd enabled.

Edit `/etc/wsl.conf` (merge with existing sections; do not delete them):

```ini
[boot]
systemd=true
```

Then from **Windows PowerShell**:

```powershell
wsl.exe --shutdown
```

Open Ubuntu again and sanity-check:

```bash
ps -p 1 -o comm=
podman ps
```

If `podman ps` works as the normal user, the environment is usable.

### 1) Run the idempotent setup script

From the repository root:

```bash
chmod +x bin/setup.sh
bin/setup.sh
```

Optional toggles:

- `FIX_PERMS=0 bin/setup.sh` (skip permission fix)
- `DO_COMPOSE_UP=0 bin/setup.sh` (skip container up)
- `DO_LINGER=0 bin/setup.sh` (skip enabling linger)

### 2) Enable the queue services (Shrikhande jobset)

```bash
chmod +x bin/*.sh
make CONFIG=config/shrikhande_r3.mk enable
```

### 3) Enqueue the stride offsets (`0..STRIDE-1`)

```bash
make CONFIG=config/shrikhande_r3.mk enqueue-stride
```

### 4) Monitor

```bash
make CONFIG=config/shrikhande_r3.mk progress
make CONFIG=config/shrikhande_r3.mk logs
# or:
make CONFIG=config/shrikhande_r3.mk journal
```

Logs land in:

- `var/shri_r3/log/shri_r3_off0.log`
- …
- `var/shri_r3/log/shri_r3_off7.log`

## Switching to rook

```bash
make CONFIG=config/rook_r3.mk env restart
make CONFIG=config/rook_r3.mk enqueue-stride
```

State remains separated by jobset:

- `var/shri_r3/...`
- `var/rook_r3/...`

## Queue model

Each queued job is a small env file containing job parameters (currently `OFFSET=<k>`). Workers:

1. claim a job by atomically moving it `pending -> running`
2. run Sage inside the container with configured base flags plus `--stride STRIDE --offset OFFSET`
3. move the job file to `done/` or `failed/`

### Configuration contract

`SAGE_BASE_ARGS` must not include `--stride` or `--offset`.

- `STRIDE` is configured in `config/*.mk`
- `OFFSET` is stored in each queued job file
- the worker injects both `--stride "$STRIDE" --offset "$OFFSET"`

If `SAGE_BASE_ARGS` contains either `--stride` or `--offset`, workers exit with a configuration error.

## Operational commands

Stop-gating (prevents claiming *new* jobs; running Sage jobs may stop if the script honors `--stop_file`):

```bash
make CONFIG=config/shrikhande_r3.mk request-stop
make CONFIG=config/shrikhande_r3.mk clear-stop
```

Requeue jobs:

```bash
make CONFIG=config/shrikhande_r3.mk requeue-running
make CONFIG=config/shrikhande_r3.mk retry-failed
```

Destructive queue clear (jobset only):

```bash
make CONFIG=config/shrikhande_r3.mk purge-queue
```

Disable services:

```bash
make CONFIG=config/shrikhande_r3.mk disable
```

## Optional: XOR-capable CryptoMiniSat backend (pycryptosat)

If Sage’s `cryptominisat` SAT backend is used with native XOR constraints, `pycryptosat` bindings may be needed inside Sage’s Python environment.

### 1) Install build toolchain in the container (one-time)

```bash
podman exec -u 0 -it sagemath bash -lc \
  'apt-get update && apt-get install -y --no-install-recommends \
     build-essential cmake pkg-config \
   && rm -rf /var/lib/apt/lists/*'
```

### 2) Install pycryptosat inside Sage (pinned)

Run as the normal container user (no `-u 0`):

```bash
podman exec -it sagemath bash -lc \
  'cd /sage && ./sage -pip uninstall -y pycryptosat || true'
```

Then force a source build and pin a known working version:

```bash
podman exec -it sagemath bash -lc \
  'cd /sage && ./sage -pip install --no-binary=pycryptosat pycryptosat==5.11.21'
```

### 3) Verify bindings

```bash
podman exec -it sagemath bash -lc \
  'cd /sage && ./sage -python -c "from pycryptosat import Solver; s=Solver(); s.add_clause([1]); print(s.solve())"'
```

Optional: verify Sage can instantiate the solver wrapper:

```bash
podman exec -it sagemath bash -lc 'cd /sage && ./sage -python - <<'"'"'PY'"'"'
from sage.sat.solvers.satsolver import SAT
S = SAT(solver="cryptominisat")
S.add_clause((1,))
print(S())
PY'
```

## Troubleshooting

### Permission errors under `/home/sage/.local` or `/home/sage/.sage`

Usually caused by missing bind mounts or missing host directories. If in doubt, re-run:

```bash
bin/setup.sh
```

### `RunRoot ... is not writable` / `/run/user/<uid>: permission denied`

Usually indicates systemd is not enabled under WSL2. Re-check the WSL2 systemd prerequisite.

### Jupyter URL / token

Jupyter URL:

- `http://localhost:8888`

Token extraction (note `2>&1`, because Jupyter token lines may appear on stderr in `podman logs` output):

```bash
podman logs --tail 2000 sagemath 2>&1 | grep -Eo 'token=[0-9a-f]+' | tail -n 1
```

URL with token:

```bash
TOKEN="$(podman logs --tail 2000 sagemath 2>&1 | grep -Eo 'token=[0-9a-f]+' | tail -n 1)"
echo "http://localhost:8888/tree?${TOKEN}"
```

## License

MIT. See `LICENSE`.
