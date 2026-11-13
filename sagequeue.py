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
        available = os.sched_getaffinity(0)
        assigned = p['cpu_ids']
        if len(set(assigned)) != p['cpus'] or not set(assigned) <= available:
            raise ValueError('Assigned CPUs are no longer available in SagePod.')
        os.sched_setaffinity(0, assigned)
env = dict(os.environ, **p['environment'])
# Preserve ordinary script import semantics even when Sage's launcher omits
# the script directory and the task has an independent working directory.
script_index = 2 if p['argv'][1:2] == ['-python'] else 1
script_dir = str(Path(p['argv'][script_index]).parent)
existing_pythonpath = env.get('PYTHONPATH', '')
env['PYTHONPATH'] = script_dir + (os.pathsep+existing_pythonpath if existing_pythonpath else '')
for k in ('OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS'):
    env[k] = str(p['cpus'])
atomic('runtime.json', {'pid':os.getpid(), 'token':p['token'], 'cpu_ids':p['cpu_ids']})
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
        self.to_container(self.root)
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root/'jobs').mkdir(exist_ok=True)
        (self.root/'arrays').mkdir(exist_ok=True)
        self.container_uid = None
        self.container_groups = None
        self.queue_shared = False
        self.cpu_pools = {}

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
        match = re.fullmatch(r'([1-9]\d*)(?:\.(\d+))?',str(jobid))
        if not match:
            raise ValueError('Use a job ID or an array task ID such as 12.3.')
        base = f'{int(match[1]):06d}'
        if match[2] is not None:
            return self.root/'arrays'/base/'tasks'/f'{int(match[2]):06d}'/'job.json'
        return self.root/'jobs'/base/'job.json'

    def expand(self, jobid):
        if str(jobid).isdigit():
            path = self.root/'arrays'/f'{int(jobid):06d}'/'array.json'
            if path.exists():
                return json.loads(path.read_text())['tasks']
        return [jobid]

    def read(self, jobid):
        path = self.path(jobid)
        if not path.exists():
            raise ValueError(f'Unknown job {jobid}.')
        return json.loads(path.read_text())

    def jobs(self):
        paths = list((self.root/'jobs').glob('*/job.json'))
        paths += list((self.root/'arrays').glob('[0-9]*/tasks/*/job.json'))
        return sorted((json.loads(p.read_text()) for p in paths),key=lambda j:(j['job_id'],j['partition']))

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

    def share(self,workdir=None,script=None,tree=None,force=False):
        if self.container_uid is None:
            result=subprocess.run(['podman','container','inspect','--format','{{.Config.User}}',
                                   self.args.container],capture_output=True,text=True,timeout=15)
            user=result.stdout.strip().split(':',1)[0]
            if result.returncode:
                raise ValueError('Cannot inspect the SagePod user: '+result.stderr.strip())
            if not user.isdigit():
                result=subprocess.run(['podman','exec',self.args.container,'id','-u'],
                                      capture_output=True,text=True,timeout=15)
                user=result.stdout.strip()
                if result.returncode or not user.isdigit():
                    raise ValueError('Cannot determine SagePod\'s numeric user ID.')
            self.container_uid=int(user)
        if self.container_groups is None:
            result=subprocess.run(['podman','exec',self.args.container,'id','-G'],
                                  capture_output=True,text=True,timeout=15)
            groups=result.stdout.split()
            if result.returncode or not groups or not all(g.isdigit() for g in groups):
                raise ValueError('Cannot determine SagePod\'s numeric group IDs: '+result.stderr.strip())
            self.container_groups=sorted(set(map(int,groups)))
        if self.queue_shared and workdir is None and script is None and tree is None and not force:
            return
        command=['podman','unshare',sys.executable,str(Path(__file__).with_name('queue_acl.py')),
                 '--boundary',str(self.notebooks),'--queue',str(self.root),'--uid',str(self.container_uid)]
        for gid in self.container_groups:command.extend(('--gid',str(gid)))
        for flag,value in (('--workdir',workdir),('--script',script),('--tree',tree)):
            if value is not None:command.extend((flag,str(value)))
        if force:command.append('--force')
        result=subprocess.run(command,capture_output=True,text=True,timeout=120)
        if result.returncode:
            raise ValueError('Cannot prepare SageQueue shared permissions: '+
                             (result.stderr.strip() or result.stdout.strip()))
        self.queue_shared=True

    def probe_access(self):
        self.share()
        code = ('import sys,tempfile\n'
                'with tempfile.TemporaryFile(dir=sys.argv[1]) as f:\n'
                '    f.write(b"sagequeue mount check"); f.flush()\n')
        remote = self.to_container(self.root)
        result = subprocess.run(['podman','exec',self.args.container,self.args.sage_bin,
                                 '-python','-c',code,remote],capture_output=True,text=True,timeout=30)
        if result.returncode:
            details = result.stderr.strip() or result.stdout.strip() or f'exit {result.returncode}'
            raise ValueError('SagePod cannot write the queue directory '+remote+'. '
                             'Check permissions on that directory and its ancestors.\n'+details)

    def worker_command(self, slot):
        return [sys.executable, str(Path(__file__).resolve()), '--root',str(self.root),
                '--notebooks',str(self.notebooks), '--container-notebooks',self.args.container_notebooks,
                '--container',self.args.container, '--sage-bin',self.args.sage_bin,
                'worker','--slot',str(slot)]

    def start(self, workers=1):
        if workers < 1:
            raise ValueError('Use at least one worker.')
        self.probe()
        self.probe_access()
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
        if args.partitions is not None:
            if not 1 <= args.partitions <= 100000:
                raise ValueError('Use between 1 and 100000 partitions.')
            selected = list(range(args.partitions)); partition_count = args.partitions
        elif args.array:
            selected, partition_count = array_selection(args.array)
        else:
            selected, partition_count = [0], 1
        is_array = args.array is not None or args.partitions is not None
        self.share(workdir=cwd,script=script)
        with self.locked():
            counter = self.root/'next-id.json'
            jobid = json.loads(counter.read_text()) if counter.exists() else 1
            atomic(counter, jobid+1)
            task_ids = []
            staging = self.root/'arrays'/('.staging-'+str(jobid)+'-'+uuid.uuid4().hex)
            for partition in selected:
                task_id = str(jobid)+'.'+str(partition) if is_array else jobid
                job = {'id':task_id,'job_id':jobid,'partition':partition,
                       'partitions':partition_count,'task_count':len(selected),
                       'name':args.name or script.stem,'state':'queued','submitted':stamp(),
                       'container':self.args.container,'sage_bin':self.args.sage_bin,
                       'argv':argv,'cwd':self.to_container(cwd),'cpus':args.cpus,
                       'memory_mib':args.memory,'seconds':args.time,'attempt':0,
                       'script':str(script),'script_sha256':hashlib.sha256(script.read_bytes()).hexdigest(),
                       'environment':{'SAGEQUEUE_JOB_ID':str(jobid),
                                      'SAGEQUEUE_TASK_ID':str(partition),
                                      'SAGEQUEUE_TASK_COUNT':str(len(selected)),
                                      'SAGEQUEUE_PARTITION':str(partition),
                                      'SAGEQUEUE_PARTITIONS':str(partition_count)}}
                if is_array:
                    job['updated'] = stamp()
                    atomic(staging/'tasks'/f'{partition:06d}'/'job.json',job)
                else:
                    self.save(job)
                task_ids.append(task_id)
            if is_array:
                atomic(staging/'array.json',{'id':jobid,'tasks':task_ids,'partitions':partition_count})
                staging.rename(self.root/'arrays'/f'{jobid:06d}')
        print(f"Job {jobid} queued ({args.name or script.stem}; {len(selected)} task(s)).")
        if not args.hold:
            self.start()
        return jobid

    def allowed_cpus(self, job):
        key = job['container'], job['sage_bin']
        if key not in self.cpu_pools:
            code = ('import json,os; print(json.dumps(sorted(os.sched_getaffinity(0)) '
                    'if hasattr(os,"sched_getaffinity") else list(range(os.cpu_count() or 1))))')
            result = subprocess.run(['podman','exec',*key,'-python','-c',code],
                                    capture_output=True,text=True,timeout=20)
            try:
                pool = json.loads(result.stdout)
            except ValueError:
                pool = None
            if (result.returncode or not isinstance(pool,list) or not pool or
                    any(type(cpu) is not int or cpu < 0 for cpu in pool) or len(set(pool)) != len(pool)):
                raise ValueError('Cannot determine SagePod CPU affinity: '+result.stderr.strip())
            self.cpu_pools[key] = sorted(pool)
        return self.cpu_pools[key]

    def claim(self):
        with self.locked():
            jobs = [self.reconcile(job) for job in self.jobs()]
            for job in jobs:
                orphan = job['state'] == 'running' and identity(job['owner']['pid']) != job['owner']
                if job['state'] != 'queued' and not orphan:
                    continue
                if not orphan:
                    pool = self.allowed_cpus(job)
                    if job['cpus'] > len(pool):
                        job.update(state='failed',finished=stamp(),
                                   error=f"Requested {job['cpus']} CPUs; container {job['container']!r} allows {len(pool)}.")
                        self.save(job)
                        continue
                    occupied = set()
                    for active in jobs:
                        if active['state'] == 'running' and active['container'] == job['container']:
                            # Older launchers pinned every task to the first N CPUs.
                            occupied.update(active.get('cpu_ids',pool[:active['cpus']]))
                    free = [cpu for cpu in pool if cpu not in occupied]
                    if len(free) < job['cpus']:
                        continue
                    job.update(state='running',attempt=job['attempt']+1,started=stamp(),
                               token=uuid.uuid4().hex,cpu_ids=free[:job['cpus']])
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
        if not adopted:
            try:
                self.share(workdir=self.notebooks/Path(job['cwd']).relative_to(self.args.container_notebooks),
                           script=Path(job['script']),tree=attempt)
            except (ValueError,OSError,subprocess.SubprocessError) as error:
                with self.locked():
                    current=self.read(job['id'])
                    current.update(state='failed',error=str(error),finished=stamp())
                    self.save(current)
                return
        payload = {k:job[k] for k in ('argv','cwd','cpus','memory_mib','seconds','token','environment')}
        if not adopted:payload['cpu_ids'] = job['cpu_ids']
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
            atomic(self.root/f'worker-{args.slot}.json',identity())
            signal.signal(signal.SIGTERM,stop)
            signal.signal(signal.SIGINT,stop)
            self.probe_access()
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
            for task in self.expand(jobid):
                job = self.reconcile(self.read(task))
                if job['state'] == 'queued':
                    job.update(state='cancelled',finished=stamp())
                elif job['state'] == 'running':
                    (self.path(task).parent/'cancel').touch()
                    job['cancel_requested'] = stamp()
                self.save(job)
                print(f"Task {task}: {job['state']}"+(' (cancellation requested)' if job['state']=='running' else ''))

    def retry(self, jobid):
        self.share()
        count = 0
        with self.locked():
            targets = self.expand(jobid)
            for task in targets:
                job = self.reconcile(self.read(task))
                if job['state'] not in TERMINAL-{'done'}:
                    continue
                (self.path(task).parent/'cancel').unlink(missing_ok=True)
                for key in ('error','returncode','finished','wall_seconds','cancel_requested','cpu_ids'):
                    job.pop(key,None)
                job.update(state='queued',submitted=stamp())
                self.save(job);count += 1
        if not count:
            raise ValueError('Retry requires a failed, cancelled, or timed-out task.')
        self.start()
        print(f'{count} task(s) queued for retry; earlier attempt logs are retained.')

    def status(self, args):
        with self.locked():
            ids = [t for x in args.ids for t in self.expand(x)]
            jobs = [self.reconcile(self.read(x)) for x in ids] if args.ids else [self.reconcile(j) for j in self.jobs()]
        if args.json:
            print(json.dumps(jobs,indent=2)); return
        print(f"{'TASK':>10}  {'PARTITION':>9}  {'STATE':<10}  {'CPUS':>4}  {'MEM MiB':>7}  NAME")
        for job in jobs:
            state = 'cancelling' if job.get('cancel_requested') and job['state']=='running' else job['state']
            print(f"{str(job['id']):>10}  {job['partition']:9}  {state:<10}  {job['cpus']:4}  {job['memory_mib']:7}  {job['name']}")

    def logs(self, args):
        tasks = self.expand(args.id)
        if len(tasks) != 1:
            raise ValueError('Select one task for logs, for example '+str(tasks[0])+'.')
        args.id = tasks[0]
        position = 0
        while True:
            job = self.read(args.id)
            if job['attempt']:
                name = 'launch.log' if args.launch else 'stderr.log' if args.stderr else 'stdout.log'
                file = self.path(args.id).parent/f"attempt-{job['attempt']:04d}"/name
                if file.exists():
                    with file.open('rb') as stream:
                        stream.seek(position); data=stream.read(); position=stream.tell()
                    sys.stdout.buffer.write(data); sys.stdout.buffer.flush()
            with self.locked():
                job = self.reconcile(self.read(args.id))
            if not args.follow or job['state'] in TERMINAL:
                if position == 0 and job['state'] == 'failed' and not args.launch:
                    if job.get('error'):
                        print('Task '+str(args.id)+': '+job['error'],flush=True)
                    attempt = self.path(args.id).parent/f"attempt-{job['attempt']:04d}"
                    for name in ('stderr.log','launch.log'):
                        path = attempt/name
                        if path.exists() and path.stat().st_size:
                            print('--- '+name+' ---',flush=True)
                            with path.open('rb') as stream:
                                stream.seek(max(0,path.stat().st_size-65536))
                                sys.stdout.buffer.write(stream.read());sys.stdout.buffer.flush()
                break
            time.sleep(0.25)


def array_selection(text):
    selected=[];count=0
    for group in text.split(','):
        m=re.fullmatch(r'(\d+)(?:-(\d+)(?::(\d+))?)?',group)
        if not m:
            raise ValueError('Use an array such as 0-7, 0-31:2, or 1,4,9.')
        first=int(m[1]);last=int(m[2]) if m[2] is not None else first
        step=int(m[3]) if m[3] is not None else 1
        if first>last or step<1:
            raise ValueError('Array ranges must increase and have a positive step.')
        values=range(first,last+1,step)
        if len(selected)+len(values)>100000:
            raise ValueError('An array may contain at most 100000 tasks.')
        selected.extend(values);count=max(count,last+1)
    if len(selected)!=len(set(selected)):
        raise ValueError('Array task IDs must be distinct.')
    return sorted(selected),count


def task_parsers(sub):
    s=sub.add_parser('submit',help='Queue a Sage or Python script.')
    s.add_argument('-J','--name');s.add_argument('--cwd')
    s.add_argument('-n','--cpus',type=int,default=1)
    s.add_argument('-M','--memory',type=memory,default=2048)
    s.add_argument('-W','--time',type=duration,default=3600)
    a=s.add_mutually_exclusive_group()
    a.add_argument('--array',help='Task IDs, e.g. 0-7 or 0-31:2.')
    a.add_argument('--partitions',type=int,help='Submit every partition, numbered from zero.')
    s.add_argument('--hold',action='store_true',help='Queue without starting workers.')
    s.add_argument('script');s.add_argument('arguments',nargs=argparse.REMAINDER)
    s=sub.add_parser('status',aliases=['jobs'],help='List tasks and their states.')
    s.add_argument('ids',nargs='*');s.add_argument('--json',action='store_true')
    s=sub.add_parser('logs',help='Read a task output log.')
    s.add_argument('id');s.add_argument('-f','--follow',action='store_true')
    stream=s.add_mutually_exclusive_group()
    stream.add_argument('--stderr',action='store_true')
    stream.add_argument('--launch',action='store_true',help='Read the container launcher log.')
    for action in ('cancel','retry'):
        s=sub.add_parser(action);s.add_argument('id')


def parser():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=os.environ.get('SAGEQUEUE_ROOT'))
    p.add_argument('--notebooks',type=Path,default=Path.home()/'Jupyter')
    p.add_argument('--container-notebooks',default='/home/sage/notebooks')
    p.add_argument('--container',default=os.environ.get('SAGEPOD_CONTAINER','sagepod'))
    p.add_argument('--sage-bin',default='/sage/sage')
    sub=p.add_subparsers(dest='action',required=True)
    tasks=sub.add_parser('tasks',help='Submit, list, and control tasks.')
    task_parsers(tasks.add_subparsers(dest='task_action'))
    task_parsers(sub)
    parts=sub.add_parser('partitions',help='Inspect partitions and their tasks.')
    parts.add_argument('ids',nargs='*');parts.add_argument('--json',action='store_true')
    workers=sub.add_parser('workers',help='Inspect or change worker concurrency.')
    ws=workers.add_subparsers(dest='worker_action')
    start=ws.add_parser('start');start.add_argument('-j','--workers',type=int,default=1)
    ws.add_parser('stop');ws.add_parser('status')
    s=sub.add_parser('start',help='Start background workers.');s.add_argument('-j','--workers',type=int,default=1)
    sub.add_parser('stop',help='Stop workers after their current tasks.')
    s=sub.add_parser('worker',help='Run a foreground worker, suitable for systemd.')
    s.add_argument('--slot',type=int,default=0);s.add_argument('--once',action='store_true')
    sub.add_parser('doctor',help='Check the SagePod connection and Sage/SAT versions.')
    return p


def main(argv=None):
    args=parser().parse_args(argv)
    action=args.action
    if action=='tasks':
        action=args.task_action or 'status'
        if args.task_action is None:args.ids=[];args.json=False
    elif action=='partitions':action='status'
    elif action=='workers':action=args.worker_action or 'worker-status'
    if args.action=='workers' and action=='status':action='worker-status'
    try:
        q=Queue(args)
        if action=='submit':q.submit(args)
        elif action in ('status','jobs'):q.status(args)
        elif action=='logs':q.logs(args)
        elif action=='cancel':q.cancel(args.id)
        elif action=='retry':q.retry(args.id)
        elif action=='start':q.start(args.workers)
        elif action=='stop':(q.root/'workers.stop').touch();print('Workers will stop after their current tasks.')
        elif action=='worker':q.worker(args)
        elif action=='worker-status':
            print('WORKER  STATE    PID')
            for path in sorted(q.root.glob('worker-*.lock')):
                with path.open('a+') as f:
                    try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);held=False
                    except BlockingIOError:held=True
                meta=path.with_suffix('.json')
                data=json.loads(meta.read_text()) if meta.exists() else {}
                print(path.stem.removeprefix('worker-'), 'running' if held else 'stopped',data.get('pid','-'))
        elif action=='doctor':
            q.probe()
            q.share(force=True)
            q.probe_access()
            code='from sage.env import SAGE_VERSION; import pycryptosat; print("Sage",SAGE_VERSION,"CryptoMiniSat",pycryptosat.__version__)'
            return subprocess.call(['podman','exec',args.container,args.sage_bin,'-python','-c',code])
        return 0
    except (ValueError,OSError,subprocess.SubprocessError) as error:
        print(f'sagequeue: {error}',file=sys.stderr);return 2


if __name__=='__main__':
    sys.exit(main())
