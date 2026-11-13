# Queue commands

SageQueue runs Sage and Python scripts in a running SagePod container. Its
default container is `sagepod`; its default data mount is
`~/Jupyter` on the host and `/home/sage/notebooks` in SagePod.

## Submit and inspect a job

Keep the script and its imported project files under `~/Jupyter`. Submit
from any directory:

```bash
sagequeue submit --name involution --cpus 1 --memory 2G --time 2h \
  ~/Jupyter/Free-Classical-Proof-Categories/experiments/involutivity/proof_search/sat/run_sat_proof.py \
  --output results/involution --backend cryptominisat
sagequeue status
sagequeue logs 1 --follow
sagequeue logs 1 --stderr
sagequeue cancel 1
sagequeue retry 1
```

The submission prints a numeric job ID. Options before the script configure
the job; arguments after the script are passed literally to it. No shell
interprets script arguments. Python scripts use `/sage/sage -python`;
Sage scripts use `/sage/sage`. The default working directory is the script's
directory; `--cwd DIRECTORY` chooses another directory on the notebook mount.
Absolute arguments on that mount are translated to container paths.
Relative arguments resolve against the job's working directory.

| Command | Effect |
| --- | --- |
| `submit SCRIPT [ARGS...]` | Queue a script and start a background worker. |
| `submit --hold SCRIPT [ARGS...]` | Queue without starting workers. |
| `status [ID...]` | List states, resource requests, and job names. |
| `status --json` | Return complete job records. |
| `logs ID [-f] [--stderr]` | Read standard output or standard error. |
| `cancel ID` | Cancel a queued job or request termination of a running job. |
| `retry ID` | Queue another attempt of a failed, cancelled, or timed-out job. |
| `start --workers N` | Start up to N background worker slots. |
| `stop` | Stop workers after their current jobs finish. |
| `worker --slot N` | Run a worker in the foreground, suitable for a service. |
| `doctor` | Check the connection and report Sage and CryptoMiniSat versions. |

## Resource controls

The defaults are one worker, one CPU per job, 2048 MiB per process, and a
one-hour wall limit. `--time` accepts seconds or suffixes `s`, `m`, `h`, and
`d`. `--memory` accepts MiB or suffixes `M` and `G`.

Each job's process group is terminated on cancellation or timeout. Child
processes inherit a Linux address-space limit and CPU affinity. Numerical
library thread counts are set to the CPU request. The memory limit applies
to each process, rather than the sum of a process tree. Workers do not
reserve host RAM or provide a cluster scheduler's aggregate resource
accounting. Set worker concurrency to fit available memory; the default
executes jobs serially alongside any notebooks already using SagePod.

Jobs run with SagePod's existing permissions and access to its mounted
files. Queue resource limits do not isolate a job from other SagePod work.

## State and recovery

Queue records and attempt logs are saved under `~/Jupyter/sagequeue-runs`.
Each job retains every attempt's output and completion record. A directory
lock protects job claims, and each worker slot has a process lock. A
replacement worker can adopt an orphaned job while the container process
continues. It does not launch a second copy. If the runtime disappears
without a completion record, the job fails and can be retried explicitly.
Program-level checkpoints remain the experiment's responsibility.

Background workers survive closing a terminal. The host and SagePod must
remain running. For service supervision, install `systemd/sagequeue-worker@.service`
as a user unit and set the paths in its environment file; see the template.

Global options precede the command. For example:

```bash
sagequeue --root ~/Jupyter/other-queue --container sagepod status
```

`--notebooks`, `--container-notebooks`, and `--sage-bin` select a different
existing mount or Sage executable. Changing these flags does not modify
SagePod. SageQueue does not create, rebuild, stop, or remove its container.
