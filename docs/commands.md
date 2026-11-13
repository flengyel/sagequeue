# Commands

The main commands are `tasks`, `partitions`, and `workers`. Global options
precede them. Task options precede the script; script arguments follow it.

## Tasks

```bash
sagequeue tasks submit --name involution --cpus 1 --memory 2G --time 2h \
  ~/Jupyter/Free-Classical-Proof-Categories/experiments/involutivity/proof_search/sat/run_sat_proof.py \
  --output results/involution --backend cryptominisat
sagequeue tasks
sagequeue tasks status 1 --json
sagequeue tasks logs 1 --follow
sagequeue tasks logs 1 --stderr
sagequeue tasks logs 1 --launch
sagequeue tasks cancel 1
sagequeue tasks retry 1
```

Submission starts one background worker unless `--hold` is present. A task
runs in the script's directory unless `--cwd DIRECTORY` selects another
directory on the notebook mount. Python scripts use `/sage/sage -python`;
Sage scripts use `/sage/sage`. Script arguments are passed literally,
without shell evaluation. Absolute arguments under `~/Jupyter` are mapped
to SagePod paths. Relative arguments resolve against the task directory.

The `--launch` option reads container-launcher diagnostics. If a failed task
has no output, the log command also shows its recorded error and available
error/launcher output.

Logs belong to individual tasks. Each retry creates a new attempt and
retains prior output. Retrying an array queues only its failed, cancelled,
or timed-out tasks; successful tasks remain complete.

## Partitions and job arrays

```bash
sagequeue tasks submit --hold --partitions 8 ~/Jupyter/project/search.py
sagequeue partitions 2
sagequeue tasks logs 2.3 --follow
sagequeue tasks cancel 2.3
sagequeue tasks retry 2
```

A partition count submits all IDs from zero through one less than the count.
For selected task IDs, use an array expression:

```bash
sagequeue tasks submit --array 0-31:2 ~/Jupyter/project/search.py
sagequeue tasks submit --array 1,4,9-12 ~/Jupyter/project/search.py
```

Ranges are inclusive, and the optional third number is the step. An array
may contain at most 100000 distinct tasks. Duplicate IDs and decreasing
ranges are rejected. Array records become visible together after their
submission records are written.

The task environment provides:

| Variable | Meaning |
| --- | --- |
| `SAGEQUEUE_JOB_ID` | Parent job ID. |
| `SAGEQUEUE_TASK_ID` | Selected array task ID; zero for a single task. |
| `SAGEQUEUE_TASK_COUNT` | Number of tasks submitted in this job. |
| `SAGEQUEUE_PARTITION` | Partition assigned to this task, equal to its task ID. |
| `SAGEQUEUE_PARTITIONS` | Partition-domain size: the requested count, or one more than the largest array range endpoint. |

For `--array 0-31:2`, sixteen tasks are selected from a partition domain of
size 32. The script decides which cases belong to each partition. SageQueue
neither rewrites its command-line arguments nor assumes how its data are
partitioned. The included `Jupyter/template.sage` demonstrates a partitioned
experiment with checkpoints and a stop file.

## Workers

```bash
sagequeue workers
sagequeue workers start --workers 2
sagequeue workers stop
```

A worker executes one task at a time. Starting N workers starts slots zero
through N minus one. Existing slots are protected by locks. To reduce
concurrency, stop workers, let active tasks finish, then start the desired
number. Workers survive terminal closure; the host and SagePod must remain
running. The supplied user-service template provides optional supervision.

## Limits

Defaults are one CPU, 2048 MiB per process, and one hour per task. `--time`
accepts seconds or suffixes `s`, `m`, `h`, and `d`; `--memory` accepts MiB or
suffixes `M` and `G`. A task's process group is terminated on cancellation
or timeout. Child processes inherit a Linux address-space limit and CPU
affinity. Numerical library thread counts follow the CPU request.

Memory is limited per process, rather than across the whole process tree.
Workers do not reserve aggregate host RAM. Tasks share SagePod's permissions
and mounted files; these controls are not job isolation.

## State and dependency

The default queue is `~/Jupyter/sagequeue-runs`. Locks protect worker slots
and task claims. A replacement worker adopts an orphaned task while its
container process continues. If the runtime disappears without a completion
record, the task fails and can be retried. Native solver checkpoints remain
the experiment's responsibility.

Global options select an existing container and mount:

```bash
sagequeue --root ~/Jupyter/other-queue --container sagepod tasks
```

`--notebooks`, `--container-notebooks`, and `--sage-bin` select a different
existing mount or Sage executable. SageQueue does not alter SagePod.

## Shared-directory access

SagePod's mapped user must be able to traverse the queue's parent directories
and write the queue directory. Worker startup and `doctor` check this access
inside SagePod before tasks are claimed. The queue does not change ownership
or permissions automatically.

Create test directories with `mkdir` under the configured notebook mount so
that its shared default permissions can be inherited. A private directory
created by `mktemp -d` normally has mode 0700 and may block the container user.
When startup fails, inspect the path and permission error reported by
`doctor`; task launch diagnostics are available with `tasks logs ID --launch`.
