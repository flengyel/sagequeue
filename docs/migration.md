# Migration to SagePod

Stop queue workers before changing the runtime. Save any active notebook
work. Complete running experiments or retain their own checkpoints; a
queue record cannot reconstruct a solver's in-memory state.

## Stop installed queue services

Inspect the installed instances:

```bash
systemctl --user list-units 'sagequeue@*.service'
```

Stop and disable the listed instances and the old container/recovery
units. For an installation with eight worker instances:

```bash
systemctl --user disable --now sagequeue@{1..8}.service
systemctl --user disable --now sagequeue-recover.timer sagequeue-container.service
```

Do not start the old service definitions after updating the checkout.
Install the current worker unit if persistent service supervision is needed.

## Connect SagePod

Install and verify [SagePod](https://github.com/flengyel/sagepod). Its defaults
are container `sagepod`, SageMath 10.10, and the existing `~/Jupyter` notebook
directory. Then run:

```bash
bin/setup.sh
sagequeue doctor
```

Submitted jobs now use `sagepod`. Queue state for the current interface is
under `~/Jupyter/sagequeue-runs`. Existing `var/<jobset>` records remain in
place. Submit partitioned experiments through `tasks submit --partitions N`.
The included experiment scripts read partition IDs from the task environment.
For an existing experiment checkpoint, pass its explicit `--state_file`
path rather than relying on a generated default filename. Check the saved
partition assignment before resuming.

## Removed wrappers

SageQueue no longer ships `man-up.sh`, `man-down.sh`, or `run-bash.sh`.
The first two had become worker-command aliases after container management
moved to SagePod. Use these replacements:

| Former SageQueue script | Replacement |
| --- | --- |
| `./man-up.sh` | `sagequeue workers start` |
| `./man-down.sh` | `sagequeue workers stop` |
| `./run-bash.sh` | Run `./run-bash.sh` from the SagePod checkout. |

Start and stop the container using SagePod's own `man-up.sh` and
`man-down.sh`. Stopping queue workers lets their current tasks finish;
stopping the SagePod container interrupts the computations inside it.
SageQueue's `bin/venvfix.sh` remains responsible for its own host Python
environment.

## Remove an unused container

After confirming no experiment or notebook still uses container `sagemath`,
it may be stopped and removed explicitly:

```bash
podman stop sagemath
podman rm sagemath
```

These commands do not delete `~/Jupyter`. Keep other former mount
directories and images until their contents have been checked. SageQueue's
setup performs none of these removals.
