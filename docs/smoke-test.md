# Live SagePod smoke test

Run this from WSL2 or Linux with SagePod running. Its expected versions are
SageMath 10.10 and CryptoMiniSat 5.11.21. The notebook mount is
`~/Jupyter` on the host and `/home/sage/notebooks` in the container.

Update SageQueue and run its tests:

```bash
cd ~/src/sagequeue
git pull --ff-only
bash bin/setup.sh
python3 -m unittest discover -s tests -v
```

Create a fresh private test directory. The private mode is intentional:
submission must prepare its ACLs automatically.

```bash
SQ_TEST_DIR=$(mktemp -d "$HOME/Jupyter/sagequeue-auto.XXXXXX")
cp "$HOME/src/sagequeue/Jupyter/template.sage" "$SQ_TEST_DIR/test.sage"

sq() {
    "$HOME/.local/bin/sagequeue" --root "$SQ_TEST_DIR/queue" "$@"
}

sq tasks submit --hold --name smoke --partitions 4 \
  --cpus 1 --memory 2G --time 2m \
  "$SQ_TEST_DIR/test.sage" --total_cases 40 --work_secs 0.1

sq doctor
sq workers start --workers 2
sq tasks logs 1.3 --follow
sq tasks status 1
```

Pass criteria: `doctor` reports Sage and CryptoMiniSat, and all four tasks
`1.0` through `1.3` reach `done`. Each task processes ten cases. Repeat
`sq tasks status 1` until all tasks finish, then stop the test workers:

```bash
sq workers stop
```

Logs and experiment checkpoints remain under `$SQ_TEST_DIR`. If a task
fails, inspect its diagnostics:

```bash
sq tasks logs 1.0 --stderr
sq tasks logs 1.0 --launch
```

The reported LITTLEZ run with SageMath 10.10 and CryptoMiniSat 5.11.21
completed all four partitions after explicit ACL preparation. The fresh
directory above tests the automatic preparation path.

## CPU assignment validation

The [LITTLEZ CPU validation record](cpu-validation.json) documents the
2026-11-13 run through the actual SagePod container. With the original
proof job still running on logical CPU 0, two concurrent probe tasks
received `[1]` and `[2, 3]` for requests of one and two CPUs. A subsequent
one-CPU task reused `[1]` after its predecessor completed, while the
two-CPU task was still running. All three probes finished successfully.
Their actual affinities matched `cpu_ids` in both the queue records and
attempt `runtime.json`; numerical-library thread settings matched their
CPU requests. The original proof process and its arguments were retained.

The repository `.venv` passed 50 tests, including concurrent one-CPU and
mixed-request probes, sparse CPU IDs, capacity waiting, oversized-request
failure, reuse after completion, and worker adoption. Native ACL checks
and the opt-in real SagePod import regression were included, with no skips.

For future concurrency checks, inspect `tasks status ID --json` while
tasks overlap: their `cpu_ids` should be disjoint within the same queue
and container. CPU IDs may be reused by later tasks. See the
[parallelism reference](commands.md#types-of-parallelism) for what workers,
arrays, application threads, and independent proof searches can do.
