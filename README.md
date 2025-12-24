# sagequeue

`sagequeue` runs long SageMath experiments inside a **rootless Podman** container on **Ubuntu (WSL2)** using **podman-compose**, and executes partitions of the workload via a **durable on-disk queue** with workers supervised by **systemd --user**.

Primary target workload: stride/offset partitioned runs of `rank_boundary_sat_v18.sage` (e.g. `STRIDE=8`, offsets `0..7`) for mod-2 boundary rank distribution experiments (e.g. Shrikhande graph, then rook graph).

## What this repository contains

### 1) Container stack 

- `podman-compose.yml` runs the SageMath container (Jupyter exposed on port `8888`).
- `man-up.sh` / `man-down.sh` start/stop the stack.
- `run-bash.sh` opens an interactive shell in the container.
- `bin/fix_bind_mounts.sh` + `bin/show-mapped-ids.sh` help resolve host permission issues with rootless Podman bind mounts on WSL2.

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

### 1) Create bind-mount directories (one-time)

The compose file bind-mounts the following host directories:

- `${HOME}/Jupyter` → `/home/sage/notebooks`
- `${HOME}/.jupyter` → `/home/sage/.jupyter`

And (Sage/Jupyter runtime state):

- `${HOME}/.sagequeue-dot_sage` → `/home/sage/.sage`  (sets `DOT_SAGE`)
- `${HOME}/.sagequeue-local` → `/home/sage/.local`
- `${HOME}/.sagequeue-config` → `/home/sage/.config`
- `${HOME}/.sagequeue-cache` → `/home/sage/.cache`

Create them:

```bash
mkdir -p "${HOME}/Jupyter" "${HOME}/.jupyter"          "${HOME}/.sagequeue-dot_sage" "${HOME}/.sagequeue-local"          "${HOME}/.sagequeue-config" "${HOME}/.sagequeue-cache"

chmod 700 "${HOME}/.sagequeue-dot_sage" "${HOME}/.sagequeue-local"           "${HOME}/.sagequeue-config" "${HOME}/.sagequeue-cache"
```

#### Make `${HOME}/Jupyter` and `${HOME}/.jupyter` host-writable (recommended)

Rootless Podman uses user namespaces, so container UID/GID `1000:1000` may appear as different numeric IDs on the host. To avoid “mystery UID” friction on the host:

```bash
chmod +x fix_bind_mounts.sh
./fix_bind_mounts.sh
```

This script computes the host-mapped UID/GID for container `1000:1000`, fixes ownership, and installs ACLs so the host user keeps `rwX` access.

### 2) podman-compose via venv (assumed)

This repository assumes `podman-compose`. A local venv is supported via `venvfix.sh`, which creates `.venv/` and installs `podman-compose` (from `requirements.txt`).

```bash
chmod +x venvfix.sh
./venvfix.sh
```

Activation (optional):

```bash
source .venv/bin/activate
```

**Important repository convention:** this repo uses `bin/` for its own scripts; the venv lives in `.venv/` (not `./bin`).

> If `man-up.sh` / `man-down.sh` were copied from a repo that looked for `./bin/podman-compose`,
> update them to look for `./.venv/bin/podman-compose` instead.

### 3) Start / stop the container stack

```bash
chmod +x man-up.sh man-down.sh run-bash.sh

./man-up.sh --open
# Windows browser: http://localhost:8888

./man-down.sh
```

Interactive shell inside the running container:

```bash
./run-bash.sh
```

**Tip:** avoid running `podman-compose` with `sudo`. If `~` expands to `/root`, the wrong notebook directory gets mounted.

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

## Running the experiments

### Enable boot persistence (recommended)

To keep `systemd --user` services running across reboot even without an interactive login:

```bash
loginctl enable-linger "$USER"
```

### Shrikhande (rank 3, stride 8)

Start/enable the queue services for the Shrikhande jobset:

```bash
chmod +x bin/*.sh
make CONFIG=config/shrikhande_r3.mk enable
```

Enqueue offsets `0..7`:

```bash
make CONFIG=config/shrikhande_r3.mk enqueue-stride
```

Monitor:

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

### Switch to rook

```bash
make CONFIG=config/rook_r3.mk env restart
make CONFIG=config/rook_r3.mk enqueue-stride
```

State remains separated by jobset:

- `var/shri_r3/...`
- `var/rook_r3/...`

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
podman exec -u 0 -it sagemath bash -lc   'apt-get update && apt-get install -y --no-install-recommends      build-essential cmake pkg-config    && rm -rf /var/lib/apt/lists/*'
```

### 2) Install pycryptosat inside Sage (pinned)

Run as the normal container user (no `-u 0`):

```bash
podman exec -it sagemath bash -lc   'cd /sage && ./sage -pip uninstall -y pycryptosat || true'
```

Then force a source build and pin a known working version:

```bash
podman exec -it sagemath bash -lc   'cd /sage && ./sage -pip install --no-binary=pycryptosat pycryptosat==5.11.21'
```

### 3) Verify bindings

```bash
podman exec -it sagemath bash -lc   'cd /sage && ./sage -python -c "from pycryptosat import Solver; s=Solver(); s.add_clause([1]); print(s.solve())"'
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

Usually caused by missing bind mounts or missing host directories. Re-check that the host directories were created and that `podman-compose.yml` includes the corresponding volume mounts.

### `RunRoot ... is not writable` / `/run/user/<uid>: permission denied`

Usually indicates systemd is not enabled under WSL2. Re-check the WSL2 systemd prerequisite.

### Jupyter URL / token

Jupyter URL:

- `http://localhost:8888`

Token extraction:

```bash
podman logs sagemath | grep -Eo 'token=[0-9a-f]+' | tail -n 1
```

## Creating the GitHub repository locally and pushing

Given an empty GitHub repository at:

- `https://github.com/flengyel/sagequeue`

From the local `sagequeue/` directory containing the project files:

```bash
git init -b main
git add .
git commit -m "Initial import"

git remote add origin https://github.com/flengyel/sagequeue.git
git push -u origin main
```

Note on executable bits:
- To preserve `chmod +x` on shell scripts, commit from a Linux filesystem (including WSL) where executable bits are supported.

## License

MIT. See `LICENSE`.
# sagequeue
