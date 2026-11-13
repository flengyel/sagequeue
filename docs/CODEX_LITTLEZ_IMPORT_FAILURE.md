# Diagnose the queued SagePod import failure on LITTLEZ

Reproduce and fix the failed proof-search launch in the live SagePod
environment. Work from `~/src/sagequeue`; also inspect
`~/Jupyter/Free-Classical-Proof-Categories` and, when necessary,
`~/src/sagepod`. Read the applicable repository instructions before editing.
Preserve local changes, queue records, attempt logs, and search checkpoints.

## Current state

- SagePod is running as container `sagepod`, with SageMath 10.10 and
  CryptoMiniSat 5.11.21. The host notebook mount is `~/Jupyter`, exposed as
  `/home/sage/notebooks`.
- SageQueue is at `05cfd2c62f3522a5c36aa1016861096afcc0e10a` or later.
  Its installed command selects `~/src/sagequeue/.venv/bin/python`.
  Its host requirements contain no third-party packages. SagePod's host
  `.venv` manages Compose; task solvers belong to Sage's Python in the image.
- The proof-category repository is at
  `12b9904e6efaeaac6db65e153b2f1af39ba39f5e` or later.
  Its entry points explicitly prepend their own directory to `sys.path`.
- Before those launcher changes, all 26 source tests passed inside the
  real SagePod container in 25.660 seconds. Host regressions after the
  changes passed 28 source tests and 14 proof tests. SageQueue's host
  virtual environment passed 34 tests, with three ACL checks unavailable
  in the remote development environment.
- Retried queue job `1` still fails before proof-search initialization:

```text
File "/home/sage/notebooks/Free-Classical-Proof-Categories/experiments/involutivity/proof_search/sat/run_sat_proof.py", line 25, in <module>
    from syntax import (...)
ModuleNotFoundError: No module named 'syntax'
```

The line number confirms that the revised entry point was executed. Another
blind `sys.path` insertion or dependency reinstall is insufficient evidence
of a repair.

The original job uses a separate working directory, `~/Jupyter/fcpc-runs`,
and these script arguments:

```text
--input /home/sage/notebooks/Free-Classical-Proof-Categories/experiments/involutivity/source/full_source.p
--output littlez-proof
--backend cryptominisat
--term-nodes 8192
--instances 1000000
--rounds 100
--seconds 43200
--solver-seconds 120
--memory-mib 4096
--stop-file littlez-proof/STOP
--resume
```

## Concrete ACL lead

Inspect `queue_acl.py`, especially `merge_acl`, `ancestors`, and the
`script` branch of `repair`. That branch grants traversal on all script
ancestors, including its containing directory, and read access to the
script file. With a separate working directory, the source directory does
not receive the working-directory ACL treatment.

The following behavior was reproduced directly in the ACL model:

```text
Initial: user::rwx, group::r-x, other::r-x
Call:    merge_acl(entries, owner=0, users={0:1, 1000:1})
Result:  user:1000:--x, mask::r-x
```

A matching named-user ACL takes precedence over `other`, so adding it can
remove the user's previous directory-read access. An already present
`user:1000:--x` entry also remains traversal-only when the requested grant
is only traversal. Python's `FileFinder._fill_cache` calls `os.listdir`
and treats `PermissionError` as an empty module directory. An explicit
`sys.path` entry therefore does not resolve an unreadable directory.

This establishes an ACL defect to investigate; it is not yet a measurement
of the failing directory on LITTLEZ.

## Diagnose before editing

1. Save the relevant job and attempt records. Record both repository HEADs,
   the installed command's resolved target, and worker process command lines.
   Request that workers stop, then verify that every worker has stopped;
   the earlier output still showed worker 0 running after the stop request.
   Do not kill an unrelated running computation.
2. Record `podman exec sagepod id`, the rootless namespace mappings, and
   numeric access/default ACLs for the source directory, its ancestors,
   `run_sat_proof.py`, `syntax.py`, and the selected result directory.
   Use `podman unshare getfacl -cpn` on the corresponding host paths so
   the numeric IDs match the container namespace. Do not assume that
   host UID 1000 is container UID 1000.
3. In SagePod, as the normal container user and with the job's actual cwd,
   inspect `sys.executable`, `sys.prefix`, `sys.path`, `PYTHONPATH`,
   the resolved script directory, directory read/search access, and file
   readability. Try `os.listdir` on the source directory, open `syntax.py`,
   explicitly prepend the source directory, and evaluate
   `importlib.util.find_spec('syntax')` followed by the import. Capture the
   actual exceptions. Check siblings such as `equality.py` as well.
4. Compare access before and after a held submission. Reproduce in an
   isolated directory under `~/Jupyter` with the same separate-source and
   separate-result layout. Test both ordinary readable directories and
   a pre-existing traversal-only named ACL. This must exercise real ACLs
   and the actual SagePod user, not only a Podman substitute.

## Fix and verify

Apply the smallest supported repair. Source import directories need read
and search access, and imported files must be readable. Preserve existing
effective access when introducing named ACL entries. Preserve unrelated
principals, restrictive ancestor permissions, ownership, symlink boundaries,
and the existing queue/work-directory sharing policy. Do not make the whole
notebook tree world-readable or writable, and do not use recursive `chmod`
as the repair. Determine the required scope from the measured failure.

Add regressions for named-user ACL shadowing, source-directory listing and
local imports with a distinct cwd, and repairing an existing traversal-only
entry. Keep the import-path regressions. Run tests with the real local
virtual environment and the actual container where relevant.

Acceptance requires all of the following:

1. A small known-positive proof runs through SageQueue and SagePod with a
   separate cwd, produces `status: proved`, and its certificate replays.
2. A small finite model control runs through the same path and produces
   `model_verified`. This is a model control, not an involution countermodel.
3. The complete source file runs with a short time/instance budget and
   creates a search checkpoint. `open` or `paused` is an acceptable
   mathematical outcome for this launch test; an import failure is not.
4. Stop that short run cleanly and verify resume. Then retry the original
   job `1` using its existing arguments and observe it pass initialization
   and make checkpointed progress. Do not infer success only from a queued
   state, passing `--help`, or a direct Python invocation outside SageQueue.

Do not change the categorical axioms, solver versions, or mathematical
claims to address this launch failure. Do not rebuild SagePod or recreate
environments unless the measurements identify an independent problem.

Commit necessary fixes, tests, and accurate documentation to remote `main`
in the affected repositories; read back the commits and changed files.
Do not commit generated SAT formulas, queue state, or large run logs.
Report the measured cause, exact changed permissions, tests executed,
repository commits, and observed status/frontier of the live proof job.
