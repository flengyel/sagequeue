#!/usr/bin/env python3
"""A durable, local batch queue using an existing SagePod container."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

TERMINAL = {'done', 'failed', 'cancelled', 'timed_out'}

# Executed by SagePod's Python. Logs and completion records are on its notebook
# mount, so a replacement host worker can observe a still-running job.
SUPERVISOR = r'''
import json, os, resource, signal, subprocess, sys, time
from pathlib import Path
p = json.loads(sys.argv[1])
d = Path(p['attempt_dir'])
def atomic(name, value):
    t = d/(name+'.tmp')
    with t.open('w') as f:
        json.dump(value, f); f.flush(); os.fsync(f.fileno())
    t.replace(d/name)
def limit():
    os.setsid()
    if p['memory_mib']:
        n = p['memory_mib']*1024**2
        resource.setrlimit(resource.RLIMIT_AS, (n,n))
    if hasattr(os, 'sched_getaffinity'):
        available = sorted(os.sched_getaffinity(0))
        os.sched_setaffinity(0, available[:p['cpus']])
env = dict(os.environ)
for k in ('OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS'):
    env[k] = str(p['cpus'])
atomic('runtime.json', {'pid':os.getpid(), 'token':p['token']})
start = time.monotonic()
child = None
outcome = 'failed'
error = None
def interrupt(signum, frame):
    raise KeyboardInterrupt
signal.signal(signal.SIGTERM, interrupt)
def stop():
    if child is not None:
        try: os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError: return
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try: os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            child.wait()
try:
    with (d/'stdout.log').open('wb') as out, (d/'stderr.log').open('wb') as err:
        child = subprocess.Popen(p['argv'], cwd=p['cwd'], env=env,
                                 stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                 preexec_fn=limit)
        while child.poll() is None:
            if Path(p['cancel_file']).exists():
                outcome = 'cancelled'; stop(); break
            if p['seconds'] and time.monotonic()-start >= p['seconds']:
                outcome = 'timed_out'; stop(); break
            time.sleep(0.2)
        else:
            outcome = 'done' if child.returncode == 0 else 'failed'
except KeyboardInterrupt:
    outcome = 'cancelled'; stop()
except BaseException as e:
    error = str(e); stop()
finally:
    stop()
    atomic('result.json', {'state':outcome, 'returncode':child.returncode if child else None,
                          'wall_seconds':time.monotonic()-start, 'error':error,
                          'token':p['token']})
'''


def stamp():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name+'.'+uuid.uuid4().hex+'.tmp')
    with temp.open('w') as f:
        json.dump(data, f, indent=2)
        f.write('\n'); f.flush(); os.fsync(f.fileno())
    temp.replace(path)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def duration(text):
    match = re.fullmatch(r'(\d+(?:\.\d+)?)([smhd]?)', text)
    if not match:
        raise argparse.ArgumentTypeError('Use seconds or a duration such as 30m or 2h.')
    return float(match[1])*{'':1, 's':1, 'm':60, 'h':3600, 'd':86400}[match[2]]


def memory(text):
    match = re.fullmatch(r'(\d+)([mMgG]?)', text)
    if not match:
        raise argparse.ArgumentTypeError('Use MiB or a size such as 2048M or 2G.')
    return int(match[1])*(1024 if match[2].lower() == 'g' else 1)


def identity(pid=None):
    pid = pid or os.getpid()
    try:
        # /proc stat's comm field can contain spaces and parentheses.
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        if fields[0] == 'Z':
            return None
        return {'pid':pid, 'start':fields[19],
                'boot':Path('/proc/sys/kernel/random/boot_id').read_text().strip()}
    except (OSError, IndexError):
        return None


class Queue:
    def __init__(self, args):
        self.args = args
        self.notebooks = args.notebooks.expanduser().resolve()
        self.root = (args.root or self.notebooks/'sagequeue-runs').expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root/'jobs').mkdir(exist_ok=True)
        self.to_container(self.root)

    def to_container(self, path):
        path = Path(path).expanduser().resolve()
        try:
            return str(Path(self.args.container_notebooks)/path.relative_to(self.notebooks))
        except ValueError:
            raise ValueError(f'{path} is outside the notebook mount {self.notebooks}.')

    @contextmanager
    def locked(self):
        with (self.root/'queue.lock').open('a+') as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            yield

    def path(self, jobid):
        if not str(jobid).isdigit() or int(jobid) < 1:
            raise ValueError('A job ID must be a positive integer.')
        return self.root/'jobs'/f'{int(jobid):06d}'/'job.json'

    def read(self, jobid):
        path = self.path(jobid)
        if not path.exists():
            raise ValueError(f'Unknown job {jobid}.')
        return json.loads(path.read_text())

    def jobs(self):
        return [json.loads(p.read_text()) for p in sorted((self.root/'jobs').glob('*/job.json'))]

    def save(self, job):
        job['updated'] = stamp()
        atomic(self.path(job['id']), job)

    def reconcile(self, job):
        if job['state'] != 'running':
            return job
        result = self.path(job['id']).parent/f"attempt-{job['attempt']:04d}"/'result.json'
        if result.exists():
            data = json.loads(result.read_text())
            if data.get('token') != job['token'] or data.get('state') not in TERMINAL:
                raise ValueError(f"Invalid completion record for job {job['id']}.")
            job.update(data, finished=stamp())
            self.save(job)
        return job

    def probe(self):
        result = subprocess.run(['podman','container','inspect','--format','{{.State.Running}}',
                                 self.args.container], capture_output=True, text=True, timeout=15)
        if result.returncode or result.stdout.strip() != 'true':
            raise ValueError(f'SagePod container {self.args.container!r} is not running. Start SagePod first.')

    def worker_command(self, slot):
        return [sys.executable, str(Path(__file__).resolve()), '--root',str(self.root),
                '--notebooks',str(self.notebooks), '--container-notebooks',self.args.container_notebooks,
                '--container',self.args.container, '--sage-bin',self.args.sage_bin,
                'worker','--slot',str(slot)]

    def start(self, workers=1):
        if workers < 1:
            raise ValueError('Use at least one worker.')
        self.probe()
        (self.root/'workers.stop').unlink(missing_ok=True)
        for slot in range(workers):
            with (self.root/f'worker-{slot}.log').open('ab') as log:
                subprocess.Popen(self.worker_command(slot), stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=log, start_new_session=True)

    def submit(self, args):
        script = Path(args.script).expanduser().resolve()
        if not script.is_file() or script.suffix not in ('.py','.sage'):
            raise ValueError('Submit an existing .py or .sage script.')
        remote = self.to_container(script)
        cwd = Path(args.cwd).expanduser().resolve() if args.cwd else script.parent
        if not cwd.is_dir():
            raise ValueError(f'Working directory does not exist: {cwd}')
        if args.cpus < 1 or args.memory < 64 or args.time <= 0:
            raise ValueError('Use positive CPUs/time and at least 64 MiB of memory.')
        if not args.hold:
            self.probe()
        forwarded = []
        for arg in args.arguments:
            if arg == '--' and not forwarded:
                continue
            prefix, sep, value = arg.partition('=') if arg.startswith('--') else ('','',arg)
            if value.startswith('/') and not value.startswith(self.args.container_notebooks+'/'):
                value = self.to_container(value)
            forwarded.append(prefix+sep+value)
        argv = [self.args.sage_bin]+(['-python'] if script.suffix == '.py' else [])+[remote]+forwarded
        with self.locked():
            counter = self.root/'next-id.json'
            jobid = json.loads(counter.read_text()) if counter.exists() else 1
            atomic(counter, jobid+1)
            job = {'id':jobid,'name':args.name or script.stem,'state':'queued','submitted':stamp(),
                   'container':self.args.container,'sage_bin':self.args.sage_bin,
                   'argv':argv,'cwd':self.to_container(cwd),'cpus':args.cpus,
                   'memory_mib':args.memory,'seconds':args.time,'attempt':0,
                   'script':str(script),'script_sha256':hashlib.sha256(script.read_bytes()).hexdigest()}
            self.save(job)
        if not args.hold:
            self.start()
        print(f"Job {jobid} queued ({job['name']}).")
        return jobid

    def claim(self):
        with self.locked():
            for job in self.jobs():
                job = self.reconcile(job)
                orphan = job['state'] == 'running' and identity(job['owner']['pid']) != job['owner']
                if job['state'] != 'queued' and not orphan:
                    continue
                if not orphan:
                    job.update(state='running',attempt=job['attempt']+1,started=stamp(),token=uuid.uuid4().hex)
                job['owner'] = identity()
                self.save(job)
                return job, orphan
        return None, False

    def remote_alive(self, job, attempt):
        runtime = attempt/'runtime.json'
        if not runtime.exists():
            return False
        r = json.loads(runtime.read_text())
        if r.get('token') != job['token']:
            return False
        code = 'import pathlib,sys; p=pathlib.Path("/proc/"+sys.argv[1]+"/cmdline"); sys.exit(0 if p.exists() and sys.argv[2].encode() in p.read_bytes() else 1)'
        check = subprocess.run(['podman','exec',job['container'],job['sage_bin'],'-python',
                                '-c',code,str(r['pid']),job['token']],capture_output=True,timeout=20)
        return check.returncode == 0

    def execute(self, job, adopted=False):
        directory = self.path(job['id']).parent
        attempt = directory/f"attempt-{job['attempt']:04d}"
        attempt.mkdir(exist_ok=True)
        payload = {k:job[k] for k in ('argv','cwd','cpus','memory_mib','seconds','token')}
        payload.update(attempt_dir=self.to_container(attempt),cancel_file=self.to_container(directory/'cancel'))
        process = None
        if not adopted:
            with (attempt/'launch.log').open('ab') as log:
                process = subprocess.Popen(['podman','exec',job['container'],job['sage_bin'],'-python',
                                            '-c',SUPERVISOR,json.dumps(payload)],stdin=subprocess.DEVNULL,
                                           stdout=log,stderr=log,start_new_session=True)
        last_probe = 0
        try:
            while True:
                with self.locked():
                    current = self.reconcile(self.read(job['id']))
                    if current['state'] in TERMINAL:
                        return
                if process is not None and process.poll() is not None:
                    # A lost Podman client does not imply the container job stopped.
                    adopted = True
                    process = None
                if adopted and time.monotonic()-last_probe > 5:
                    last_probe = time.monotonic()
                    if not self.remote_alive(job, attempt):
                        with self.locked():
                            current = self.reconcile(self.read(job['id']))
                            if current['state'] not in TERMINAL:
                                current.update(state='failed',error='Runtime disappeared without a completion record.',finished=stamp())
                                self.save(current)
                        return
                time.sleep(0.25)
        finally:
            if process is not None and process.poll() is not None:
                process.wait()

    def worker(self, args):
        if args.slot < 0:
            raise ValueError('Worker slots must be nonnegative.')
        with (self.root/f'worker-{args.slot}.lock').open('a+') as lock:
            try:
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:
                return
            stopping = False
            def stop(signum, frame):
                nonlocal stopping
                stopping = True
            signal.signal(signal.SIGTERM,stop)
            signal.signal(signal.SIGINT,stop)
            while not stopping and not (self.root/'workers.stop').exists():
                self.probe()
                job, adopted = self.claim()
                if job is None:
                    if args.once:
                        return
                    time.sleep(1)
                    continue
                print(json.dumps({'job':job['id'],'event':'adopt' if adopted else 'start'}),flush=True)
                self.execute(job,adopted)
                if args.once:
                    return

    def cancel(self, jobid):
        with self.locked():
            job = self.reconcile(self.read(jobid))
            if job['state'] == 'queued':
                job.update(state='cancelled',finished=stamp())
            elif job['state'] == 'running':
                (self.path(jobid).parent/'cancel').touch()
                job['cancel_requested'] = stamp()
            self.save(job)
        print(f"Job {jobid}: {job['state']}"+(' (cancellation requested)' if job['state']=='running' else ''))

    def retry(self, jobid):
        with self.locked():
            job = self.reconcile(self.read(jobid))
            if job['state'] not in TERMINAL-{'done'}:
                raise ValueError('Retry requires a failed, cancelled, or timed-out job.')
            (self.path(jobid).parent/'cancel').unlink(missing_ok=True)
            for key in ('error','returncode','finished','wall_seconds','cancel_requested'):
                job.pop(key,None)
            job.update(state='queued',submitted=stamp())
            self.save(job)
        self.start()
        print(f'Job {jobid} queued for retry; earlier attempt logs are retained.')

    def status(self, args):
        with self.locked():
            jobs = [self.reconcile(self.read(x)) for x in args.ids] if args.ids else [self.reconcile(j) for j in self.jobs()]
        if args.json:
            print(json.dumps(jobs,indent=2)); return
        print(f"{'ID':>6}  {'STATE':<10}  {'CPUS':>4}  {'MEM MiB':>7}  NAME")
        for job in jobs:
            state = 'cancelling' if job.get('cancel_requested') and job['state']=='running' else job['state']
            print(f"{job['id']:6}  {state:<10}  {job['cpus']:4}  {job['memory_mib']:7}  {job['name']}")

    def logs(self, args):
        position = 0
        while True:
            job = self.read(args.id)
            if job['attempt']:
                file = self.path(args.id).parent/f"attempt-{job['attempt']:04d}"/('stderr.log' if args.stderr else 'stdout.log')
                if file.exists():
                    with file.open('rb') as stream:
                        stream.seek(position); data=stream.read(); position=stream.tell()
                    sys.stdout.buffer.write(data); sys.stdout.buffer.flush()
            with self.locked():
                job = self.reconcile(self.read(args.id))
            if not args.follow or job['state'] in TERMINAL:
                break
            time.sleep(0.25)


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=os.environ.get('SAGEQUEUE_ROOT'))
    p.add_argument('--notebooks',type=Path,default=Path.home()/'Jupyter')
    p.add_argument('--container-notebooks',default='/home/sage/notebooks')
    p.add_argument('--container',default=os.environ.get('SAGEPOD_CONTAINER','sagepod'))
    p.add_argument('--sage-bin',default='/sage/sage')
    sub = p.add_subparsers(dest='action',required=True)
    s = sub.add_parser('submit',help='Queue a Sage or Python script.')
    s.add_argument('-J','--name');s.add_argument('--cwd')
    s.add_argument('-n','--cpus',type=int,default=1)
    s.add_argument('-M','--memory',type=memory,default=2048)
    s.add_argument('-W','--time',type=duration,default=3600)
    s.add_argument('--hold',action='store_true',help='Queue without starting workers.')
    s.add_argument('script');s.add_argument('arguments',nargs=argparse.REMAINDER)
    s = sub.add_parser('status',aliases=['jobs'],help='List jobs and their states.')
    s.add_argument('ids',nargs='*');s.add_argument('--json',action='store_true')
    s = sub.add_parser('logs',help='Read a job output log.')
    s.add_argument('id');s.add_argument('-f','--follow',action='store_true');s.add_argument('--stderr',action='store_true')
    for action in ('cancel','retry'):
        s=sub.add_parser(action);s.add_argument('id')
    s=sub.add_parser('start',help='Start background workers.');s.add_argument('-j','--workers',type=int,default=1)
    sub.add_parser('stop',help='Stop workers after their current jobs.')
    s=sub.add_parser('worker',help='Run a foreground worker, suitable for systemd.')
    s.add_argument('--slot',type=int,default=0);s.add_argument('--once',action='store_true')
    sub.add_parser('doctor',help='Check the SagePod connection and Sage/SAT versions.')
    return p


def main(argv=None):
    args=parser().parse_args(argv)
    try:
        q=Queue(args)
        if args.action=='submit':q.submit(args)
        elif args.action in ('status','jobs'):q.status(args)
        elif args.action=='logs':q.logs(args)
        elif args.action=='cancel':q.cancel(args.id)
        elif args.action=='retry':q.retry(args.id)
        elif args.action=='start':q.start(args.workers)
        elif args.action=='stop':(q.root/'workers.stop').touch();print('Workers will stop after their current jobs.')
        elif args.action=='worker':q.worker(args)
        elif args.action=='doctor':
            q.probe()
            code='from sage.env import SAGE_VERSION; import pycryptosat; print("Sage",SAGE_VERSION,"CryptoMiniSat",pycryptosat.__version__)'
            return subprocess.call(['podman','exec',args.container,args.sage_bin,'-python','-c',code])
        return 0
    except (ValueError,OSError,subprocess.SubprocessError) as error:
        print(f'sagequeue: {error}',file=sys.stderr);return 2


if __name__=='__main__':
    sys.exit(main())
