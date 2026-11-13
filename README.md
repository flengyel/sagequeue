# SageQueue

SageQueue manages batch tasks in a running
[SagePod](https://github.com/flengyel/sagepod) instance. SagePod supplies
SageMath 10.10, CryptoMiniSat, Jupyter, and the container. SageQueue supplies
task submission, partitions, workers, resource controls, and logs.

## Install

Install and start SagePod first. Its default container is `sagepod`, with
`~/Jupyter` mounted at `/home/sage/notebooks`. Then install the queue command:

```bash
git clone https://github.com/flengyel/sagequeue.git ~/src/sagequeue
cd ~/src/sagequeue
bin/setup.sh
sagequeue doctor
```

SageQueue needs Python 3.10 or newer, the host's virtual-environment support
(`python3-venv` on Debian/Ubuntu), rootless Podman, and the host `acl` package
on Linux or WSL2. Setup creates the repository's `.venv`, installs
`~/.local/bin/sagequeue`, prepares shared queue ACLs, and checks the SagePod
connection. The installed command selects `.venv/bin/python` automatically;
activation and environment variables are not required.

The host scheduler currently has no third-party Python dependencies;
[`requirements.txt`](requirements.txt) records this explicitly. To create or
repair its environment separately, run `bin/venvfix.sh`. Existing environment
files are retained. Existing workers keep their interpreter until they stop;
restart workers after changing the host environment.

| Environment | Dependencies and purpose |
| --- | --- |
| SageQueue host `.venv` | The scheduler, workers, and ACL helper use Python's standard library. Podman and ACL utilities are host system packages. |
| SagePod host `.venv` | Compose and its pinned Python dependencies are managed by SagePod's own `requirements.txt` and `venvfix.sh`. |
| SagePod container | `/sage/sage -python` supplies SageMath and solver packages, including `pycryptosat`. Experiment dependencies belong here. |

Rebuilding either host environment does not install Python packages into the
container. Local experiment modules must be importable by the experiment's
entry point when its working directory differs from its source directory.

## Tasks, partitions, and workers

A **partition** is a numbered portion of an experiment. A **task** is a
scheduled execution of a script, optionally assigned a partition. A
**worker** runs one task at a time. Eight partitions can run through two
workers; partition count and concurrency are separate choices.

Keep scripts and their imported project files under `~/Jupyter`:

```bash
sagequeue tasks submit --name experiment --cpus 1 --memory 2G --time 2h \
  ~/Jupyter/project/search.py --resume
sagequeue tasks
sagequeue tasks logs 1 --follow
sagequeue tasks cancel 1
sagequeue tasks retry 1
```

Submission prints a numeric job ID. Options before the script configure
the task; later arguments belong to the script. The default working
directory is the script's directory. Both `.py` and `.sage` scripts run
with SagePod's Sage environment.

For a partitioned job array:

```bash
sagequeue tasks submit --hold --partitions 8 ~/Jupyter/project/search.py
sagequeue partitions 2
sagequeue workers start --workers 2
sagequeue tasks logs 2.3 --follow
sagequeue tasks cancel 2
```

The array receives one job ID, here `2`; its tasks are `2.0` through `2.7`.
`cancel 2` affects the array, while `cancel 2.3` affects one task. To select
an arithmetic progression, use `--array 0-31:2`; comma-separated IDs and
ranges are also accepted. The script receives partition and task IDs as
environment variables. See [commands](docs/commands.md).

| Command | Purpose |
| --- | --- |
| `sagequeue tasks submit SCRIPT [ARGS...]` | Submit a task or job array. |
| `sagequeue tasks [status] [ID...]` | List task states. |
| `sagequeue tasks logs ID [-f] [--stderr]` | Read or follow a task log. |
| `sagequeue tasks cancel ID` | Cancel a job array or one task. |
| `sagequeue tasks retry ID` | Retry failed, cancelled, or timed-out tasks. |
| `sagequeue partitions [ID...]` | Inspect partition assignments. |
| `sagequeue workers [status]` | Inspect worker slots. |
| `sagequeue workers start --workers N` | Start worker slots. |
| `sagequeue workers stop` | Stop workers after their current tasks. |
| `sagequeue doctor` | Prepare shared queue ACLs and check SagePod and solver versions. |

## Resource controls and recovery

The defaults are one worker, one CPU per task, a 2048 MiB address-space
limit per process, and a one-hour wall limit. Workers do not reserve total
host memory; choose concurrency to fit the machine and notebook workload.
The [command reference](docs/commands.md) states the resource limits.

SageQueue sets access and default ACLs for the host account and SagePod
user automatically. The queue and declared task paths receive the required
access; other notebook contents are not recursively changed. See
[shared-directory access](docs/commands.md#shared-directory-access).

Jobs and attempt logs are saved under `~/Jupyter/sagequeue-runs`.
Retries retain earlier logs. Atomic claims prevent duplicate execution.
A replacement worker can adopt a task whose container process is still
running. A lost runtime is recorded as a failure and is retried on request.
Experiments retain responsibility for their own solver checkpoints.

Workers run in the background or under the supplied
[user-service template](systemd/sagequeue-worker@.service). SagePod must be
running before workers start. Queue commands do not build, restart, or
remove the SagePod container.

## Validation

```bash
.venv/bin/python -m unittest discover -s tests -v
sagequeue doctor
```

Automated tests cover submission, arrays, cancellation, timeouts, concurrent
claims, retries, worker recovery, and ACL scope and inheritance. Queue
process tests use a Podman substitute; native ACL tests run when the local
filesystem and user mapping support them. The [live smoke test](docs/smoke-test.md)
checks SagePod execution and automatic repair of a fresh private directory.
Launcher diagnostics are available with `tasks logs ID --launch`.

[Migration guide](docs/migration.md) · [License](LICENSE)
