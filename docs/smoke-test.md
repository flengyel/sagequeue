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
