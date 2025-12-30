#!/usr/bin/env python3
"""
sagequeue-progress.py

Monitor sagequeue progress using:
  - per-offset state files (canonical, crash-safe, deterministic)
  - per-offset logs (optional: timing + best-effort attribution to systemd worker id)

By default, if ~/.config/sagequeue/sagequeue.env exists, this script loads it and infers:
  JOBSET, STRIDE, PROJECT_ROOT, STOP_FILE_HOST, and graph/rank from SAGE_BASE_ARGS.

Usage examples:
  python3 sagequeue-progress.py
  python3 sagequeue-progress.py --env-file ~/.config/sagequeue/sagequeue.env
  python3 sagequeue-progress.py --jobset shri_r3 --graph shrikhande --rank 3 --stride 8 --var-dir ~/sagequeue/var

Notes:
  - Total cases = C(dim,kdim) where dim = N-1, kdim = dim-rank.
  - State files store the last DONE global index (gidx). This is the source of truth for cases_done.
  - Per-worker ("systemd worker id") case counts are inferred from logs by attributing Sage DONE lines
    to the most recent "[worker N] start ..." line in each offset log.
"""

from __future__ import annotations

import argparse
import math
import os
import re
import shlex
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Set


@dataclass
class WorkerState:
    offset: int
    stride: int
    last_gidx: Optional[int] = None  # last completed global index (gidx)
    cases_done: int = 0
    cases_total: int = 0
    last_timestamp: Optional[datetime] = None
    recent_times: List[float] = field(default_factory=list)  # seconds per case
    status: str = "unknown"  # running, idle, not_started, completed


@dataclass
class JobProgress:
    jobset: str
    graph: str
    rank: int
    n_vertices: int
    dim: int
    kdim: int
    total_cases: int
    stride: int
    workers: List[WorkerState] = field(default_factory=list)

    @property
    def cases_done(self) -> int:
        return sum(w.cases_done for w in self.workers)

    @property
    def cases_remaining(self) -> int:
        return max(0, self.total_cases - self.cases_done)

    @property
    def pct_complete(self) -> float:
        if self.total_cases == 0:
            return 100.0
        return 100.0 * self.cases_done / self.total_cases


def sanitize_for_filename(s: str) -> str:
    # Mirrors rank_boundary_sat_v18.sage behavior: keep alnum and ._- ; replace others with "_".
    return "".join(c if (c.isalnum() or c in "._-") else "_" for c in str(s))


def parse_env_file(path: Path) -> Dict[str, str]:
    env: Dict[str, str] = {}
    txt = path.read_text()
    for raw in txt.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip()
        if len(v) >= 2 and ((v[0] == v[-1] == '"') or (v[0] == v[-1] == "'")):
            v = v[1:-1]
        env[k] = v
    return env


def infer_from_base_args(sage_base_args: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    try:
        tokens = shlex.split(sage_base_args)
    except ValueError:
        return out
    for i, t in enumerate(tokens):
        if t == "--graph" and i + 1 < len(tokens):
            out["graph"] = tokens[i + 1]
        if t == "--rank" and i + 1 < len(tokens):
            out["rank"] = tokens[i + 1]
    return out


def get_n_vertices(graph: str) -> int:
    # Known graphs used in this repo. Unknown graphs must provide --n.
    if graph in ("shrikhande", "rook"):
        return 16
    if graph == "petersen":
        return 10
    raise ValueError(f"Unknown graph: {graph} (provide --n)")


def parse_state_file(path: Path) -> Optional[int]:
    # rank_boundary_sat_v18.sage reads int(first_token).
    if not path.exists():
        return None
    try:
        text = path.read_text().strip()
        if not text:
            return None
        return int(text.split()[0])
    except (ValueError, OSError):
        return None


_DONE_RE = re.compile(
    r'\[(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[+-]\d{2}:\d{2})?)\]\s+DONE\s+.*\bgidx=(?P<gidx>\d+)\b.*\bdt=(?P<dt>\d+\.?\d*)s\b'
)
_TS_BRACKET_RE = re.compile(
    r'\[(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[+-]\d{2}:\d{2})?)\]'
)
_WORKER_START_RE = re.compile(r'^\[worker\s+(?P<wid>\d+)\]\s+start\s+offset=(?P<off>\d+)\b')
_WORKER_DONE_RE = re.compile(r'^\[worker\s+(?P<wid>\d+)\]\s+(done|failed)\s+offset=(?P<off>\d+)\b')


def parse_log_times(path: Path, max_lines: int = 2000) -> List[Tuple[datetime, float]]:
    """Extract (timestamp, duration) from Sage DONE lines in recent log lines."""
    results: List[Tuple[datetime, float]] = []
    if not path.exists():
        return results
    try:
        lines = path.read_text(errors="replace").splitlines()[-max_lines:]
    except OSError:
        return results

    for line in lines:
        m = _DONE_RE.search(line)
        if not m:
            continue
        try:
            ts = datetime.fromisoformat(m.group("ts"))
            dt = float(m.group("dt"))
        except ValueError:
            continue
        results.append((ts, dt))
    return results


def get_last_activity(path: Path, max_lines: int = 2000) -> Optional[datetime]:
    """Return timestamp of last bracketed timestamp line (START or DONE) in the log."""
    if not path.exists():
        return None
    try:
        lines = path.read_text(errors="replace").splitlines()[-max_lines:]
    except OSError:
        return None

    for line in reversed(lines):
        m = _TS_BRACKET_RE.search(line)
        if not m:
            continue
        try:
            return datetime.fromisoformat(m.group("ts"))
        except ValueError:
            continue
    return None


def cases_for_offset(offset: int, stride: int, total: int) -> int:
    # Count gidx values handled by this offset: offset, offset+stride, ...
    count = 0
    gidx = offset
    while gidx < total:
        count += 1
        gidx += stride
    return count


def cases_done_for_offset(last_gidx: Optional[int], offset: int, stride: int) -> int:
    if last_gidx is None:
        return 0
    if last_gidx < offset:
        return 0
    if ((last_gidx - offset) % stride) != 0:
        # Incompatible state file (mirrors Sage script behavior: ignore).
        return 0
    return (last_gidx - offset) // stride + 1


def scan_queue_dirs(var_dir: Path, jobset: str) -> Dict[str, int]:
    qdir = var_dir / jobset / "queue"
    counts = {}
    for name in ("pending", "running", "done", "failed"):
        d = qdir / name
        if not d.exists():
            counts[name] = 0
            continue
        counts[name] = len([p for p in d.glob("*.env") if p.is_file()])
    return counts


def analyze_job(
    jobset: str,
    graph: str,
    rank: int,
    n_vertices: int,
    stride: int,
    notebook_dir: Path,
    var_dir: Path,
    log_max_lines: int,
) -> JobProgress:
    dim = n_vertices - 1
    kdim = dim - rank
    total_cases = math.comb(dim, kdim)

    progress = JobProgress(
        jobset=jobset,
        graph=graph,
        rank=rank,
        n_vertices=n_vertices,
        dim=dim,
        kdim=kdim,
        total_cases=total_cases,
        stride=stride,
    )

    graph_sanitized = sanitize_for_filename(graph)

    for offset in range(stride):
        state_file = notebook_dir / f"state_{graph_sanitized}_r{rank}_stride{stride}_off{offset}.txt"
        log_file = var_dir / jobset / "log" / f"{jobset}_off{offset}.log"

        last_gidx = parse_state_file(state_file)
        cases_total = cases_for_offset(offset, stride, total_cases)
        cases_done = cases_done_for_offset(last_gidx, offset, stride)

        times = parse_log_times(log_file, max_lines=log_max_lines)
        recent_times = [dt for _, dt in times[-50:]]  # last 50 cases (if present)
        last_ts = get_last_activity(log_file, max_lines=log_max_lines)

        # Status heuristic:
        if cases_done >= cases_total and cases_total > 0:
            status = "completed"
        elif cases_done == 0 and last_gidx is None:
            status = "not_started"
        else:
            status = "running"

        worker = WorkerState(
            offset=offset,
            stride=stride,
            last_gidx=last_gidx,
            cases_done=cases_done,
            cases_total=cases_total,
            last_timestamp=last_ts,
            recent_times=recent_times,
            status=status,
        )
        progress.workers.append(worker)

    return progress


def worker_case_breakdown_from_logs(
    progress: JobProgress,
    var_dir: Path,
    log_max_lines: int,
) -> Tuple[Dict[int, Set[int]], Set[int]]:
    """
    Best-effort attribution:
      - Track last seen "[worker N] start ..." in each offset log.
      - Attribute Sage "[ts] DONE ... gidx=..." lines to that worker id.
    Returns:
      per_worker_gidx: worker_id -> set of gidx values
      all_gidx: set of all gidx values seen in logs
    """
    per_worker: Dict[int, Set[int]] = {}
    all_gidx: Set[int] = set()

    jobset = progress.jobset
    for w in progress.workers:
        log_file = var_dir / jobset / "log" / f"{jobset}_off{w.offset}.log"
        if not log_file.exists():
            continue
        try:
            lines = log_file.read_text(errors="replace").splitlines()[-log_max_lines:]
        except OSError:
            continue

        current_wid: Optional[int] = None

        for line in lines:
            mws = _WORKER_START_RE.match(line)
            if mws:
                try:
                    current_wid = int(mws.group("wid"))
                except ValueError:
                    current_wid = None
                continue

            md = _DONE_RE.search(line)
            if md:
                try:
                    gidx = int(md.group("gidx"))
                except ValueError:
                    continue
                all_gidx.add(gidx)
                wid = current_wid if current_wid is not None else 0
                per_worker.setdefault(wid, set()).add(gidx)
                continue

            # Optional: clear current_wid when job ends (does not change attribution of already-seen DONE lines)
            if _WORKER_DONE_RE.match(line):
                current_wid = None

    return per_worker, all_gidx


def format_duration(seconds: float) -> str:
    seconds = max(0.0, float(seconds))
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}h{m:02d}m{s:02d}s"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def print_progress(
    progress: JobProgress,
    queue_counts: Dict[str, int],
    var_dir: Path,
    show_worker_breakdown: bool,
    log_max_lines: int,
) -> None:
    print("=" * 80)
    print(f"Jobset: {progress.jobset}")
    print(f"Graph:  {progress.graph} (N={progress.n_vertices})")
    print(f"Rank:   ≤ {progress.rank} (dim={progress.dim}, kdim={progress.kdim})")
    print(f"Total:  C({progress.dim},{progress.kdim}) = {progress.total_cases}")
    print(f"Stride: {progress.stride}")
    print("=" * 80)

    print(f"\nQueue: pending={queue_counts['pending']} running={queue_counts['running']} done={queue_counts['done']} failed={queue_counts['failed']}")

    print(f"\nOverall: {progress.cases_done}/{progress.total_cases} ({progress.pct_complete:.1f}%) | remaining: {progress.cases_remaining}")

    # Per-offset summary
    header = f"\n{'Off':>3} {'Status':>10} {'Done':>6} {'Total':>6} {'Pct':>6} {'LastGidx':>8} {'AvgDt':>7} {'LastActive':>19}"
    print(header)
    print("-" * len(header))

    all_times: List[float] = []

    for w in progress.workers:
        pct = 100.0 * w.cases_done / w.cases_total if w.cases_total else 100.0
        avg_dt = (sum(w.recent_times) / len(w.recent_times)) if w.recent_times else None
        all_times.extend(w.recent_times)

        last_gidx_str = str(w.last_gidx) if w.last_gidx is not None else "-"
        avg_dt_str = f"{avg_dt:5.1f}s" if avg_dt is not None else "   -  "
        last_ts_str = w.last_timestamp.isoformat(timespec="seconds") if w.last_timestamp else "-"
        print(f"{w.offset:3d} {w.status:>10} {w.cases_done:6d} {w.cases_total:6d} {pct:5.1f}% {last_gidx_str:>8} {avg_dt_str:>7} {last_ts_str:>19}")

    # ETA (only if we have dt samples)
    if all_times and progress.cases_remaining > 0:
        avg_time = sum(all_times) / len(all_times)
        max_remaining = max((w.cases_total - w.cases_done) for w in progress.workers)
        eta_seconds = max_remaining * avg_time
        print(f"\nETA (slowest offset): ~{format_duration(eta_seconds)} (avg {avg_time:.1f}s/case, max_remaining={max_remaining})")

    if show_worker_breakdown:
        per_worker, all_gidx = worker_case_breakdown_from_logs(progress, var_dir=var_dir, log_max_lines=log_max_lines)

        # counts
        rows = sorted(((wid, len(gset)) for wid, gset in per_worker.items()), key=lambda x: (-x[1], x[0]))
        print("\nCases completed by systemd worker id (best-effort from logs, unique gidx):")
        if not rows:
            print("  (no DONE lines found in logs)")
        else:
            for wid, n in rows:
                label = f"worker {wid}" if wid != 0 else "worker ?"
                print(f"  {label:8s} {n:4d}  ({100.0*n/progress.total_cases:5.1f}%)")

        # sanity check
        if all_gidx:
            print(f"\nLog-derived unique cases: {len(all_gidx)}/{progress.total_cases}")
        if all_gidx and len(all_gidx) != progress.cases_done:
            print("NOTE: state-file progress and log-derived unique gidx differ.")
            print("      State files are canonical; logs may be truncated or missing DONE lines.")

    print()


def main() -> None:
    ap = argparse.ArgumentParser(description="Scan sagequeue progress")

    ap.add_argument("--env-file", type=str, default=None,
                    help="Path to ~/.config/sagequeue/sagequeue.env (auto-used if present)")

    ap.add_argument("--jobset", type=str, default=None, help="Jobset name (e.g., shri_r3)")
    ap.add_argument("--graph", type=str, default=None, help="Graph name (e.g., shrikhande)")
    ap.add_argument("--rank", type=int, default=None, help="Target rank bound (integer)")
    ap.add_argument("--stride", type=int, default=None, help="Stride (integer)")

    ap.add_argument("--n", type=int, default=None, help="Number of vertices (required for unknown graphs)")
    ap.add_argument("--notebook-dir", type=str, default=None, help="Path to notebook dir with state files (default: inferred or ~/Jupyter)")
    ap.add_argument("--var-dir", type=str, default=None, help="Path to var dir (default: inferred or ./var)")

    ap.add_argument("--no-worker-breakdown", action="store_true", help="Do not attempt per-worker case attribution from logs")
    ap.add_argument("--log-max-lines", type=int, default=2000, help="Max tail lines to read from each log (default: 2000)")

    args = ap.parse_args()

    # Auto-pick env file if present
    env_path: Optional[Path] = None
    if args.env_file:
        env_path = Path(args.env_file).expanduser()
    else:
        p = Path("~/.config/sagequeue/sagequeue.env").expanduser()
        if p.exists():
            env_path = p

    env: Dict[str, str] = {}
    inferred: Dict[str, str] = {}
    if env_path is not None and env_path.exists():
        env = parse_env_file(env_path)
        if "SAGE_BASE_ARGS" in env:
            inferred = infer_from_base_args(env["SAGE_BASE_ARGS"])

    jobset = args.jobset or env.get("JOBSET")
    stride = args.stride or (int(env["STRIDE"]) if "STRIDE" in env else None)

    # Infer PROJECT_ROOT and var_dir
    var_dir: Optional[Path] = Path(args.var_dir).expanduser() if args.var_dir else None
    if var_dir is None:
        if "PROJECT_ROOT" in env:
            var_dir = Path(env["PROJECT_ROOT"]) / "var"
        elif "STATE_DIR" in env:
            # STATE_DIR = .../var/<jobset>
            var_dir = Path(env["STATE_DIR"]).parent
        else:
            var_dir = Path("./var")

    notebook_dir: Optional[Path] = Path(args.notebook_dir).expanduser() if args.notebook_dir else None
    if notebook_dir is None:
        if "STOP_FILE_HOST" in env:
            notebook_dir = Path(env["STOP_FILE_HOST"]).expanduser().parent
        else:
            notebook_dir = Path("~/Jupyter").expanduser()

    graph = args.graph or inferred.get("graph")
    rank = args.rank if args.rank is not None else (int(inferred["rank"]) if "rank" in inferred else None)

    if jobset is None:
        ap.error("Missing --jobset (or provide JOBSET in env file)")
    if graph is None:
        ap.error("Missing --graph (or provide --graph in SAGE_BASE_ARGS in env file)")
    if rank is None:
        ap.error("Missing --rank (or provide --rank in SAGE_BASE_ARGS in env file)")
    if stride is None:
        ap.error("Missing --stride (or provide STRIDE in env file)")

    # n_vertices
    if args.n is not None:
        n_vertices = args.n
    else:
        n_vertices = get_n_vertices(graph)

    progress = analyze_job(
        jobset=jobset,
        graph=graph,
        rank=int(rank),
        n_vertices=int(n_vertices),
        stride=int(stride),
        notebook_dir=notebook_dir,
        var_dir=var_dir,
        log_max_lines=int(args.log_max_lines),
    )

    queue_counts = scan_queue_dirs(var_dir, jobset)

    print_progress(
        progress,
        queue_counts,
        var_dir=var_dir,
        show_worker_breakdown=(not args.no_worker_breakdown),
        log_max_lines=int(args.log_max_lines),
    )


if __name__ == "__main__":
    main()
