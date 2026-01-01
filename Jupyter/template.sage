# template.sage (TEMPLATE / SMOKE TEST)
# Deterministic stride/offset workload with --resume + --stop_file semantics.
#
# State file format: a single integer "last_done_gidx"
# (global index last completed by this offset partition).

import argparse
import os
import sys
import time
from datetime import datetime

def ts():
    return datetime.now().isoformat(timespec="seconds")

def die(msg, rc=2):
    print(msg, file=sys.stderr, flush=True)
    sys.exit(rc)

def atomic_write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)

def parse_args():
    ap = argparse.ArgumentParser(add_help=True)

    # Queue/workload semantics
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--stop_file", default="")
    ap.add_argument("--progress_every", type=int, default=1)

    # Partitioning (required; injected by worker)
    ap.add_argument("--stride", required=True, type=int)
    ap.add_argument("--offset", required=True, type=int)

    # Work size (required; template is not domain-specific)
    ap.add_argument("--total_cases", required=True, type=int)

    # State naming: MUST be workload-centric (e.g. pass JOBSET here)
    default_prefix = os.path.splitext(os.path.basename(__file__))[0]  # "template"
    ap.add_argument("--state_prefix", default=default_prefix)

    # Deterministic simulated work per case
    ap.add_argument("--work_secs", type=float, default=0.05)

    return ap.parse_args()

def main():
    args = parse_args()

    if args.stride <= 0:
        die(f"[err] invalid stride={args.stride}")
    if args.offset < 0 or args.offset >= args.stride:
        die(f"[err] invalid offset={args.offset} for stride={args.stride}")
    if args.total_cases <= 0:
        die(f"[err] invalid total_cases={args.total_cases}")
    if not args.state_prefix or any(c in args.state_prefix for c in "/\0"):
        die(f"[err] invalid state_prefix={args.state_prefix!r}")

    total = args.total_cases

    script_dir = os.path.dirname(os.path.abspath(__file__)) or os.getcwd()
    state_file = os.path.join(
        script_dir,
        f"state_{args.state_prefix}_stride{args.stride}_off{args.offset}.txt",
    )

    # Stop-file semantics: exit 0 if present (pause)
    if args.stop_file and os.path.exists(args.stop_file):
        print(
            f"Stop file exists ({args.stop_file}); exiting off={args.offset} stride={args.stride}.",
            flush=True,
        )
        return 0

    last_done = None
    if args.resume and os.path.exists(state_file):
        raw = open(state_file, "r", encoding="utf-8").read().strip()
        if raw:
            try:
                last_done = int(raw, 10)
            except ValueError:
                die(f"[err] invalid state file (not an int): {state_file} content={raw!r}")

    if last_done is None:
        next_gidx = args.offset
        local_done = 0
    else:
        # Must be in-range and in this offset partition
        if last_done < 0 or last_done >= total or ((last_done - args.offset) % args.stride) != 0:
            die(
                f"[err] corrupt state: state_file={state_file} last_done_gidx={last_done} "
                f"not congruent to offset/stride or out of range"
            )
        local_done = ((last_done - args.offset) // args.stride) + 1
        next_gidx = last_done + args.stride
        print(
            f"Resuming: state_file={state_file} last_done_gidx={last_done} -> start_local={local_done}",
            flush=True,
        )

    gidx = next_gidx
    while gidx < total:
        if args.stop_file and os.path.exists(args.stop_file):
            print(
                f"Stop file exists ({args.stop_file}); exiting off={args.offset} stride={args.stride}.",
                flush=True,
            )
            return 0

        if args.progress_every > 0 and (local_done % args.progress_every) == 0:
            print(
                f"[{ts()}] START gidx={gidx} local={local_done} off={args.offset} stride={args.stride}",
                flush=True,
            )

        if args.work_secs > 0:
            time.sleep(args.work_secs)

        atomic_write(state_file, str(gidx) + "\n")

        if args.progress_every > 0 and (local_done % args.progress_every) == 0:
            print(
                f"[{ts()}] DONE  gidx={gidx} local={local_done} off={args.offset} stride={args.stride}",
                flush=True,
            )

        local_done += 1
        gidx += args.stride

    print(
        f"[{ts()}] COMPLETE total_cases={total} off={args.offset} stride={args.stride} state_file={state_file}",
        flush=True,
    )
    return 0

if __name__ == "__main__":
    sys.exit(main())

