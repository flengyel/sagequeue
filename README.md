# sagequeue

`sagequeue` runs long SageMath experiments inside a rootless Podman container on WSL2 and executes stride/offset partitions through a durable on-disk queue supervised by `systemd --user`.

Current restore model:

- WSL2 distro: Debian or Ubuntu
- container runtime: rootless Podman
- compose runner: repo-local `podman-compose` in `.venv`
- networking: `slirp4netns`
- notebook directory on host: `${HOME}/Jupyter`
- Jupyter URL from Windows: `http://localhost:8888`
- container name: `sagemath`
- Sage image: `localhost/sagequeue-sagemath:10.7-pycryptosat`

Primary workload: stride/offset partitioned runs of `rank_boundary_sat_v18.sage`, for example Shrikhande graph rank 3 with `STRIDE=8`.

## Repository layout

Top level:

```text
Containerfile          builds the local Sage image with pycryptosat
podman-compose.yml     runs the sagemath container
Makefile               jobset selection, queue operations, systemd user service control
config/*.mk            jobset configs
systemd/               user unit files installed into ~/.config/systemd/user
var/                   durable queue and logs; gitignored
man-up.sh              manual container/Jupyter startup helper
man-down.sh            manual compose-down helper
run-bash.sh            interactive container shell helper
requirements.txt       repo-local Python venv requirements
sagequeue-progress.py  progress monitor
```

`bin/`:

```text
bin/setup.sh                    one-time bootstrap; safe to re-run
bin/build-image.sh              build/rebuild local Sage image
bin/venvfix.sh                  deterministic venv builder; normally called by setup
bin/sagequeue-ensure-container.sh
bin/sagequeue-worker.sh
bin/sagequeue-recover.sh
bin/sagequeue-diag.sh
bin/fix-bind-mounts.sh
bin/show-mapped-ids.sh
```

## Prerequisites

### WSL2 with systemd

Edit `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then from Windows PowerShell:

```powershell
wsl.exe --shutdown
```

Reopen the WSL distro and check:

```bash
ps -p 1 -o comm=
systemctl --user show-environment >/dev/null && echo "systemd --user OK"
podman ps
```

Expected:

```text
systemd
systemd --user OK
```

`podman ps` should run as the normal Linux user, not via `sudo`.

### Required Debian/Ubuntu packages

Install the host-side tools:

```bash
sudo apt update
sudo apt install -y podman slirp4netns acl python3-venv make
```

The Sage build toolchain is installed inside the container image by `Containerfile`; it is not required in the WSL host for normal queue use.

### Rootless Podman defaults for WSL2

For this Debian/Ubuntu WSL2 restore, rootless Podman works best with `cgroupfs`, file logging, and `slirp4netns`.

Create or update:

```bash
mkdir -p ~/.config/containers

cat > ~/.config/containers/containers.conf <<'CONF'
[engine]
cgroup_manager="cgroupfs"
events_logger="file"

[network]
default_rootless_network_cmd="slirp4netns"
CONF
```

Check:

```bash
podman info --format 'cgroupManager={{.Host.CgroupManager}} eventsLogger={{.Host.EventLogger}}'
```

Expected:

```text
cgroupManager=cgroupfs eventsLogger=file
```

## Cloudflare / GHCR TLS note

Building the Sage image pulls the base image from `ghcr.io`. If Podman fails with an x509 error and the certificate issuer is Cloudflare Gateway, add a Cloudflare Zero Trust HTTP “Do Not Inspect” rule for:

```text
ghcr.io
```

Verify from WSL:

```bash
printf '' | openssl s_client -connect ghcr.io:443 -servername ghcr.io -showcerts 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -fingerprint -sha256
```

The issuer should no longer be the Cloudflare Gateway CA.

## Container and notebooks

The main Sage script is expected at:

```text
${HOME}/Jupyter/rank_boundary_sat_v18.sage
```

Windows-visible equivalent:

```text
~\Jupyter\rank_boundary_sat_v18.sage
```

The compose file mounts:

```text
${HOME}/Jupyter              -> /home/sage/notebooks
${HOME}/.jupyter             -> /home/sage/.jupyter
${HOME}/.sagequeue-dot_sage  -> /home/sage/.sage
${HOME}/.sagequeue-local     -> /home/sage/.local/share
${HOME}/.sagequeue-config    -> /home/sage/.config
${HOME}/.sagequeue-cache     -> /home/sage/.cache
```

The experiment uses `--resume`, so state files live alongside the notebook under `${HOME}/Jupyter`.

## Why a custom Sage image exists

The default queue configs use:

```text
--solver sat --sat_backend cryptominisat
```

Sage’s `cryptominisat` backend requires `pycryptosat` inside Sage’s Python environment.

The local image tag is:

```text
localhost/sagequeue-sagemath:10.7-pycryptosat
```

The current Sage 10.7 image installs `pycryptosat` under Sage’s own venv, typically:

```text
/sage/local/var/lib/sage/venv-python3.12.5/lib/python3.12/site-packages
```

`bin/build-image.sh` detects the actual install location. If `pycryptosat` is outside the bind-mounted DOT_SAGE tree, no host DOT_SAGE seeding is needed. If a future/alternate image places it under `/home/sage/.sage`, the script seeds the host DOT_SAGE directory.

## Installation / restore

### 1. Clone the repository

```bash
cd ~/src
git clone git@github.com:flengyel/sagequeue.git
cd ~/src/sagequeue
```

### 2. Run setup

```bash
chmod +x bin/*.sh man-up.sh man-down.sh run-bash.sh
bin/setup.sh
```

`bin/setup.sh` is safe to re-run. It:

- creates bind-mount directories
- fixes rootless Podman bind-mount permissions and ACLs
- creates the repo-local `.venv`
- ensures `.venv/bin/podman-compose` exists
- builds `localhost/sagequeue-sagemath:10.7-pycryptosat` if the image is missing
- starts the `sagemath` container
- verifies that the notebook mount is visible inside the container
- enables user lingering when possible

### 3. Optional explicit image rebuild

Only needed when changing `Containerfile` or forcing a rebuild:

```bash
bin/build-image.sh
```

Do not rebuild while queue workers are running. Use the safe rebuild procedure below.

## Manual Jupyter start/stop

Start the container and print the token:

```bash
./man-up.sh --no-follow
```

Open from Windows:

```text
http://localhost:8888
```

Get the token:

```bash
podman logs --tail 2000 sagemath 2>&1 | grep -Eo 'token=[0-9a-f]+' | tail -n 1
```

Stop the container:

```bash
./man-down.sh
```

Open a shell inside the container:

```bash
podman exec -it sagemath bash
```

## Queue operation

### Enable a jobset

Shrikhande rank-3 jobset:

```bash
make CONFIG=config/shrikhande_r3.mk enable
```

This writes:

```text
~/.config/sagequeue/sagequeue.env
```

and enables/starts:

```text
sagequeue-container.service
sagequeue-recover.timer
sagequeue@1.service ... sagequeue@WORKERS.service
```

### Enqueue stride offsets

```bash
make CONFIG=config/shrikhande_r3.mk enqueue-stride
```

### Monitor

```bash
make CONFIG=config/shrikhande_r3.mk progress
make CONFIG=config/shrikhande_r3.mk logs
python3 sagequeue-progress.py
```

Full diagnostic snapshot:

```bash
make CONFIG=config/shrikhande_r3.mk diag
```

### Stop and restart workers

Stop workers while leaving the container available:

```bash
make CONFIG=config/shrikhande_r3.mk stop
```

Restart workers:

```bash
make CONFIG=config/shrikhande_r3.mk start
```

Disable workers, recover timer, and container unit:

```bash
make CONFIG=config/shrikhande_r3.mk disable
```

## Queue model

A jobset has isolated queue and log directories under:

```text
var/<JOBSET>/
```

For example:

```text
var/shri_r3/queue/pending
var/shri_r3/queue/running
var/shri_r3/queue/done
var/shri_r3/queue/failed
var/shri_r3/log
var/shri_r3/run
```

Each job is a small `.env` file, currently containing an `OFFSET`.

State transitions:

```text
pending -> running -> done
pending -> running -> failed
failed  -> pending   via retry-failed or bounded automatic recovery
running -> pending   via orphan recovery or stop-file pause
```

Workers claim a job by atomic filesystem rename from `pending` to `running`, write an owner sidecar file, execute Sage inside the container, and then move the job to `done` or `failed`.

## Stop file

Request stop-gating for the active jobset:

```bash
make CONFIG=config/shrikhande_r3.mk request-stop
```

Resume:

```bash
make CONFIG=config/shrikhande_r3.mk clear-stop
```

When the stop file exists, workers avoid claiming new jobs. Sage also receives the stop-file path through its command-line arguments and may exit cleanly mid-run.

## Recovery

Requeue orphaned running jobs:

```bash
make CONFIG=config/shrikhande_r3.mk requeue-running
```

Retry failed jobs:

```bash
make CONFIG=config/shrikhande_r3.mk retry-failed
```

The recover timer also retries failed jobs up to the script’s configured maximum and requeues orphaned `running` jobs.

Inspect recovery logs:

```bash
journalctl --user -u sagequeue-recover.service -n 200 -o cat | grep '^\[recover\]'
```

## Safe image rebuild procedure

Rebuilding the image removes/recreates the `sagemath` container. Stop the workers first.

Example for Shrikhande rank 3:

```bash
make CONFIG=config/shrikhande_r3.mk request-stop
make CONFIG=config/shrikhande_r3.mk stop

bin/build-image.sh

make CONFIG=config/shrikhande_r3.mk start
make CONFIG=config/shrikhande_r3.mk retry-failed
make CONFIG=config/shrikhande_r3.mk clear-stop
```

Verify the running image:

```bash
podman inspect sagemath --format 'ImageName={{.ImageName}} ContainerImageID={{.Image}}'
podman image inspect localhost/sagequeue-sagemath:${SAGE_TAG:-10.7}-pycryptosat --format 'BuiltImageID={{.Id}} Tags={{.RepoTags}}'
```

Verify `pycryptosat`:

```bash
podman exec sagemath bash -lc \
  'cd /sage && ./sage -python -c "import pycryptosat; print(pycryptosat.__file__)"'
```

Expected path begins with:

```text
/sage/local/
```

## Template smoke test

The repository includes:

```text
Jupyter/template.sage
config/template.mk
```

Copy the template into the notebook mount:

```bash
cp -f ./Jupyter/template.sage "$HOME/Jupyter/template.sage"
```

Run the template jobset:

```bash
make CONFIG=config/template.mk enable
make CONFIG=config/template.mk enqueue-stride
```

Monitor:

```bash
make CONFIG=config/template.mk progress
make CONFIG=config/template.mk logs
make CONFIG=config/template.mk diag
```

## Switching jobsets

Example: switch to rook rank 3.

```bash
make CONFIG=config/rook_r3.mk env restart
make CONFIG=config/rook_r3.mk enqueue-stride
```

Queue state remains separated:

```text
var/shri_r3/...
var/rook_r3/...
```

## Validation

Check container:

```bash
podman ps --format '{{.Names}}  {{.Ports}}  {{.Image}}'
```

Expected line:

```text
sagemath  0.0.0.0:8888->8888/tcp  localhost/sagequeue-sagemath:10.7-pycryptosat
```

Check Sage and `pycryptosat`:

```bash
podman exec sagemath bash -lc \
  'cd /sage && ./sage -python -c "from sage.all import factor; import pycryptosat; print(factor(2**10-1)); print(pycryptosat.__file__)"'
```

Expected output includes:

```text
3 * 11 * 31
/sage/local/
```

Check workers:

```bash
systemctl --user --no-pager status 'sagequeue@1.service'
make CONFIG=config/shrikhande_r3.mk progress
```

## Troubleshooting

### `make: command not found`

Install `make` on the WSL host:

```bash
sudo apt install -y make
```

### `podman-compose` not executable

Run setup:

```bash
bin/setup.sh
```

This creates `.venv/bin/podman-compose` through `bin/venvfix.sh`.

### `netavark: nftables error`

Use `slirp4netns`. The compose file defaults to:

```yaml
network_mode: ${SAGEQUEUE_NETWORK_MODE:-slirp4netns}
```

Also make sure `~/.config/containers/containers.conf` contains:

```ini
[network]
default_rootless_network_cmd="slirp4netns"
```

### Bad pull from `localhost/sagequeue-sagemath`

This means compose tried to use the local image before it existed.

Current `bin/setup.sh` and `bin/sagequeue-ensure-container.sh` check/build the image first. Re-run:

```bash
bin/setup.sh
```

### Permission errors under `/home/sage`

Run:

```bash
bin/fix-bind-mounts.sh
```

Then open a new shell, or run:

```bash
newgrp sage
```

### Jupyter token

```bash
podman logs --tail 2000 sagemath 2>&1 | grep -Eo 'token=[0-9a-f]+' | tail -n 1
```

URL with token:

```bash
TOKEN="$(podman logs --tail 2000 sagemath 2>&1 | grep -Eo 'token=[0-9a-f]+' | tail -n 1)"
echo "http://localhost:8888/tree?${TOKEN}"
```

## License

MIT
