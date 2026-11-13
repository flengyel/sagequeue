# Commands

The main commands are `tasks`, `partitions`, and `workers`. Global options
precede them. Task options precede the script; script arguments follow it.

The installed command uses the checkout's `.venv/bin/python`; no activation
is needed. `bin/setup.sh` creates that host environment from
`requirements.txt`, and `bin/venvfix.sh` repairs it. Task scripts run in
SagePod's Sage environment, independently of both projects' host virtual
environments. Host requirements do not install packages into SagePod.

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
The launcher prepends the script's directory to the container's Python
import path and retains existing Python import paths. Local helper modules
therefore remain importable when `--cwd` selects a separate result directory.
This requires no environment variables in the submission command.

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

Before launching a task, the scheduler assigns distinct logical CPU IDs
from SagePod's allowed CPU affinity. Assignment and the task claim happen
under the same queue lock. Concurrent tasks in this queue and container
receive disjoint sets, including tasks with different `--cpus` requests.
Tasks wait in `queued` state when too few CPUs are free; a smaller later
task may use the remaining CPUs. Completion, failure, cancellation, or
timeout releases the reservation when its completion record is reconciled.
A request exceeding the container's entire allowed set fails before launch.

The assignment appears as `cpu_ids` in `tasks status ID --json` and the
attempt's `runtime.json`. Worker replacement retains the running task's
assignment. Running tasks started by older SageQueue versions keep their
original first-N-CPU binding; new workers reserve those CPUs without
restarting the computation. Upgrade existing workers before they launch
further tasks: `workers stop` lets their current tasks finish before they
exit, then `workers start` loads the updated scheduler.

CPU reservations are scoped to one queue and container. Other queue roots,
Jupyter sessions, and external processes can use the same CPUs. The pool
is discovered from the container when a worker first needs it; restart
workers after changing the container's allowed CPU set. Linux affinity
controls eligible logical CPUs, without guaranteeing exclusive hardware
cores or CPU time.

## Types of parallelism

| Type | How to use it | Program requirements |
| --- | --- | --- |
| Concurrent independent tasks | Submit separate tasks with distinct output directories, then start several workers. | Each task runs independently. Workers and available CPUs determine concurrency. |
| Job-array partitions | Submit `--partitions N` or `--array RANGE`, then start several workers. | The script reads the partition environment variables and divides its own work. Each task needs separate output/checkpoint files. |
| Threads or child processes within a task | Request `--cpus N`; descendants inherit the assigned CPU set and numerical-library thread settings. | The program or library must implement parallel execution. Requesting CPUs does not create threads or subprocesses. |
| Several workers cooperating on one search frontier | Requires an application that distributes and combines search work. | SageQueue supplies no shared-frontier or clause-sharing protocol. |

For the involutivity proof program, the current grounder is sequential and
its CryptoMiniSat backend explicitly uses one solver thread. Extra workers,
array partitions, or a larger `--cpus` request do not divide that search.
Independent searches can explore different settings, such as `--order goal`
and `--order source`, with separate output directories. Their checkpoints
remain separate; changing rule order requires a fresh output directory.
Successful certificates are checked independently. More concurrent searches
increase exploration rather than guaranteeing a proportional speedup.

## Limits

Defaults are one CPU, 2048 MiB per process, and one hour per task. `--time`
accepts seconds or suffixes `s`, `m`, `h`, and `d`; `--memory` accepts MiB or
suffixes `M` and `G`. A task's process group is terminated on cancellation
or timeout. Child processes inherit a Linux address-space limit and CPU
affinity. Numerical library thread counts follow the CPU request.
CPU IDs are chosen by the scheduler; each task receives exactly its
requested number from the currently unreserved set. A program can still
choose to use fewer CPUs.

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

SageQueue prepares ACLs automatically during submission, worker startup,
and `doctor`. It reads SagePod's configured numeric user ID and runs its
ACL helper in Podman's rootless user namespace. The host account and the
SagePod user receive the access needed for queue records and task files.
The helper uses the container's actual group IDs when preserving access
that previously came from group ACL entries.
The host `acl` package supplies `setfacl` and `getfacl`.

The repair covers:

- Read/write access to queue records and attempt logs, with traversal of
  queue directories.
- Default ACLs on queue directories, so new records and directories inherit
  shared access.
- Access and default ACLs on the task's declared working directory, plus
  read access to its script and read/search access to the script directory.
- Traversal of the necessary ancestors within the notebook mount.

The queue tree is repaired on first use. Its permission record avoids a
full history scan on each submission; every new attempt is prepared before
launch. `doctor` also repairs existing queue files. This handles private
test directories created with `mktemp -d`.

Ownership and file contents are preserved. Existing effective permissions
are preserved when named-user entries are introduced or the ACL mask is
enlarged. A matching named-user entry overrides group and `other` access;
the helper retains the user's previous effective grant before adding the
requested bits. Existing traversal-only entries on the script directory
are upgraded to read/search, because Python lists that directory to find
local modules even when it is explicitly present in `sys.path`. Other
ancestors receive only the additional search access they need. The
helper skips queue-tree symlinks and rejects requested paths outside the
configured notebook mount. It does not recursively change other project
files or the whole notebook tree. Arbitrary additional input/output paths
belong to the submitted program's file-access requirements.
Local helper files must already be readable by the container user; the
script-directory repair does not recursively grant access to project files.

For the opt-in regression against a running SagePod and its real ACLs:

```bash
SAGEQUEUE_LIVE_NOTEBOOKS="$HOME/Jupyter" .venv/bin/python -m unittest discover -s tests -v
```

This uses a disposable directory and its own held queue, with separate
source and result directories. It checks ordinary readable directories,
group-granted access, existing traversal-only user entries, local imports,
and preservation of private ancestors and unrelated paths.

If ACL preparation fails, the command reports the path or missing tool.
Tasks are not launched before shared queue access is checked. Use
`tasks logs ID --launch` for container-launcher diagnostics.
