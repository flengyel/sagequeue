import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('sq',ROOT/'sagequeue.py')
sq=importlib.util.module_from_spec(spec);spec.loader.exec_module(sq)


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.notebooks=self.root/'notebooks';self.notebooks.mkdir()
        self.bin=self.root/'bin';self.bin.mkdir()
        self.sage=self.bin/'sage'
        self.sage.write_text('#!'+sys.executable+'\nimport os,sys\na=sys.argv[1:]\nif a[:1]==["-python"]:a=a[1:]\nos.execv(sys.executable,[sys.executable]+a)\n')
        self.sage.chmod(0o755)
        podman=self.bin/'podman'
        podman.write_text('#!'+sys.executable+'\nimport os,sys\na=sys.argv[1:]\nif a[:2]==["container","inspect"]:print("true");sys.exit(0)\nif a[0]=="exec":os.execvp(a[2],a[2:])\nraise SystemExit(2)\n')
        podman.chmod(0o755)
        self.env=patch.dict(os.environ,{'PATH':str(self.bin)+os.pathsep+os.environ['PATH']})
        self.env.start();self.addCleanup(self.env.stop)
        self.base=['--notebooks',str(self.notebooks),'--container-notebooks',str(self.notebooks),
                   '--sage-bin',str(self.sage)]
        self.q=sq.Queue(sq.parser().parse_args(self.base+['status']))

    def submit(self,code,args=(),options=()):
        p=self.notebooks/f'job-{len(self.q.jobs())}.py';p.write_text(code)
        a=sq.parser().parse_args(self.base+['submit','--hold',*options,str(p),*args])
        with contextlib.redirect_stdout(io.StringIO()):return self.q.submit(a)

    def worker(self):
        return subprocess.Popen([sys.executable,str(ROOT/'sagequeue.py'),*self.base,'worker','--once'],
                                stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)

    def wait_state(self,jobid,states,timeout=12):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            with self.q.locked():j=self.q.reconcile(self.q.read(jobid))
            if j['state'] in states:return j
            time.sleep(.05)
        self.fail(f'Job {jobid} did not reach {states}: {j}')

    def finish(self,p):
        stdout,stderr=p.communicate(timeout=15)
        self.assertEqual(p.returncode,0,(stdout,stderr))

    def test_success_preserves_literal_arguments(self):
        jid=self.submit('import sys,json; print(json.dumps(sys.argv[1:]))\n',('space here','$(touch bad)','--value=two words'))
        p=self.worker();self.finish(p)
        self.assertEqual(self.q.read(jid)['state'],'done')
        log=self.q.path(jid).parent/'attempt-0001/stdout.log'
        self.assertEqual(json.loads(log.read_text()),['space here','$(touch bad)','--value=two words'])
        self.assertFalse((self.notebooks/'bad').exists())

    def test_failure_and_retry_keep_attempt_logs(self):
        jid=self.submit('import sys; print("failed attempt"); sys.exit(4)\n')
        self.finish(self.worker());self.assertEqual(self.q.read(jid)['state'],'failed')
        with patch.object(self.q,'start'),contextlib.redirect_stdout(io.StringIO()):self.q.retry(jid)
        self.finish(self.worker());job=self.q.read(jid)
        self.assertEqual((job['state'],job['attempt']),('failed',2))
        self.assertTrue((self.q.path(jid).parent/'attempt-0001/stdout.log').exists())

    def test_wall_limit(self):
        jid=self.submit('import time; time.sleep(30)\n',options=('--time','0.4s'))
        self.finish(self.worker());self.assertEqual(self.q.read(jid)['state'],'timed_out')

    def test_cancel_queued(self):
        jid=self.submit('print("should not run")\n')
        with contextlib.redirect_stdout(io.StringIO()):self.q.cancel(jid)
        self.finish(self.worker());self.assertEqual(self.q.read(jid)['state'],'cancelled')

    def test_cancel_running(self):
        jid=self.submit('import time; print("started",flush=True); time.sleep(30)\n')
        p=self.worker();self.wait_state(jid,{'running'})
        with contextlib.redirect_stdout(io.StringIO()):self.q.cancel(jid)
        self.finish(p);self.assertEqual(self.q.read(jid)['state'],'cancelled')

    def test_adopt_after_host_worker_is_killed(self):
        jid=self.submit('import time; print("one launch",flush=True); time.sleep(2)\n')
        p=self.worker();self.wait_state(jid,{'running'})
        runtime=self.q.path(jid).parent/'attempt-0001/runtime.json'
        end=time.monotonic()+5
        while not runtime.exists() and time.monotonic()<end:time.sleep(.02)
        self.assertTrue(runtime.exists())
        p.kill();p.communicate(timeout=5)
        self.finish(self.worker())
        job=self.q.read(jid);self.assertEqual((job['state'],job['attempt']),('done',1))
        self.assertEqual((runtime.parent/'stdout.log').read_text().count('one launch'),1)

    def test_two_workers_do_not_duplicate_claims(self):
        self.submit('print("first")\n');self.submit('print("second")\n')
        p1=self.worker()
        p2=subprocess.Popen([sys.executable,str(ROOT/'sagequeue.py'),*self.base,'worker','--slot','1','--once'],
                            stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.finish(p1);self.finish(p2)
        self.assertEqual([(j['state'],j['attempt']) for j in self.q.jobs()],[('done',1),('done',1)])

    def test_reject_paths_outside_mount_and_invalid_resources(self):
        with self.assertRaises(ValueError):self.q.to_container(self.root/'outside.py')
        with self.assertRaises(ValueError):self.submit('pass\n',options=('--cpus','0'))
        self.assertEqual(sq.duration('2h'),7200)
        self.assertEqual(sq.memory('2G'),2048)

    def test_submit_hold_does_not_spawn_worker(self):
        with patch.object(self.q,'start') as start:self.submit('pass\n')
        start.assert_not_called()

    def test_completed_job_cannot_be_retried(self):
        jid=self.submit('pass\n');self.finish(self.worker())
        with self.assertRaises(ValueError):self.q.retry(jid)


if __name__=='__main__':unittest.main()
