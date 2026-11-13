# A partitioned experiment for SageQueue, with experiment-level checkpoints.
import argparse
import os
from pathlib import Path
import time

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--partitions', type=int, default=int(os.environ.get('SAGEQUEUE_PARTITIONS', '1')))
    p.add_argument('--partition', type=int, default=int(os.environ.get('SAGEQUEUE_PARTITION', '0')))
    p.add_argument('--total_cases', type=int, required=True)
    p.add_argument('--resume', action='store_true')
    p.add_argument('--stop_file', type=Path)
    p.add_argument('--state_prefix', default='template_job'+os.environ.get('SAGEQUEUE_JOB_ID', 'manual'))
    p.add_argument('--work_secs', type=float, default=0.05)
    a = p.parse_args()
    if a.partitions < 1 or not 0 <= a.partition < a.partitions or a.total_cases < 1:
        p.error('Use a positive case/partition count and a partition ID in range.')
    if not a.state_prefix or any(c in a.state_prefix for c in '/\0'):
        p.error('The state prefix must be a filename component.')
    path = Path(__file__).resolve().parent / ('state_'+a.state_prefix+'_partition'+str(a.partition)+'_of'+str(a.partitions)+'.txt')
    last = int(path.read_text()) if a.resume and path.exists() else None
    if last is not None and (not 0 <= last < a.total_cases or last % a.partitions != a.partition):
        p.error('Checkpoint does not belong to this partition.')
    first = a.partition if last is None else last+a.partitions
    for case in range(first, a.total_cases, a.partitions):
        if a.stop_file and a.stop_file.exists():
            print('Paused partition', a.partition, flush=True)
            return
        print('Partition', a.partition, 'case', case, flush=True)
        time.sleep(a.work_secs)
        tmp = path.with_suffix('.tmp')
        with tmp.open('w') as f:
            f.write(str(case)+'\n');f.flush();os.fsync(f.fileno())
        tmp.replace(path)
    print('Completed partition', a.partition, flush=True)

if __name__ == '__main__':
    main()
