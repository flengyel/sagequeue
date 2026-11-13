# SageQueue

SageQueue submits and manages batch jobs in an existing
[SagePod](https://github.com/flengyel/sagepod) instance. SagePod supplies
SageMath 10.10, CryptoMiniSat, Jupyter, and the container. SageQueue supplies
the durable job queue, workers, resource controls, and logs.

## Install

Install and start SagePod first. Its default container is `sagepod`, with
`~/Jupyter` mounted at `/home/sage/notebooks`. Then install the queue command:

```bash
git clone https://github.com/flengyel/sagequeue.git ~/src/sagequeue
cd ~/src/sagequeue
bin/setup.sh
sagequeue doctor
```

SageQueue needs Python 3.10 or newer and rootless Podman on Linux or WSL2.
It uses Python's standard library. It has no container image, Compose stack,
or Sage installation of its own. Setup installs a command symlink under
`~/.local/bin` and checks the running SagePod dependency.

## Submit a job

Keep scripts and their imported project files under `~/Jupyter`:

```bash
sagequeue submit --name experiment --cpus 1 --memory 2G --time 2h \
  ~/Jupyter/project/search.py --resume
sagequeue status
sagequeue logs 1 --follow
sagequeue cancel 1
sagequeue retry 1
```

Submission prints a numeric job ID and starts a background worker. Options
before the script configure the job; later arguments belong to the script.
The default working directory is the script's directory. Both `.py` and
`.sage` scripts run with SagePod's Sage environment.

| Command | Purpose |
| --- | --- |
| `sagequeue submit SCRIPT [ARGS...]` | Submit and start processing. |
| `sagequeue status [ID...]` | Inspect queue and completion states. |
| `sagequeue logs ID [-f] [--stderr]` | Read output or follow progress. |
| `sagequeue cancel ID` | Cancel a queued or running job. |
| `sagequeue retry ID` | Retry a failed, cancelled, or timed-out job. |
| `sagequeue start --workers N` | Select worker concurrency. |
| `sagequeue stop` | Stop workers after their current jobs. |
| `sagequeue doctor` | Check SagePod and solver versions. |

The defaults are one worker, one CPU, a 2048 MiB address-space limit per
process, and a one-hour wall limit per job. Workers do not reserve total
host memory; choose concurrency to fit the machine and its notebook work.
See [commands and resource controls](docs/commands.md) for full behavior.

## Queue records

Jobs, separate output/error logs, and completion records are stored under
`~/Jupyter/sagequeue-runs`. Each retry retains its preceding attempt's logs.
Atomic claims prevent duplicate execution. If a worker stops while the
container job continues, a replacement worker can adopt that job. A lost
runtime is recorded as a failure and is retried only on request. Experiments
retain responsibility for their own solver checkpoints.

Workers can run in the background or under the supplied
[user-service template](systemd/sagequeue-worker@.service). SagePod must be
running before workers start. Queue commands do not start, rebuild, or stop
SagePod.

## Partitioned jobsets

The Makefile interface supports experiments with stride/offset partitions.
The script must accept `--stride`, `--offset`, and the configured checkpoint
and stop-file options. Place it under `~/Jupyter`, select its settings in a
`config/*.mk` file, and run:

```bash
make CONFIG=config/template.mk enable
make CONFIG=config/template.mk enqueue-stride
make CONFIG=config/template.mk progress
make CONFIG=config/template.mk logs
make CONFIG=config/template.mk request-stop
```

This interface also uses container `sagepod`. Its per-jobset queue and logs
are under `var/<JOBSET>`. Its user services supervise queue workers and
recovery; SagePod supplies the runtime. The generic `submit` interface and
partitioned jobsets have separate queue records. Avoid submitting the same
checkpoint partition through both interfaces.

## Validation

```bash
python3 -m unittest discover -s tests -v
sagequeue doctor
```

The automated tests use a process-level Podman substitute to exercise
submission, literal arguments, logs, cancellation, timeouts, concurrent
claims, retries, and adoption after a host worker is killed. They do not
replace a SagePod runtime check. The setup command and `doctor` perform that
check on the installed machine.

[Migration guide](docs/migration.md) · [License](LICENSE)
