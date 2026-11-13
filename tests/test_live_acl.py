"""Opt-in ACL regression against an existing SagePod notebook mount.

SAGEQUEUE_LIVE_NOTEBOOKS=$HOME/Jupyter .venv/bin/python -m unittest discover
-s tests -p test_live_acl.py -v
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.getenv('SAGEQUEUE_LIVE_NOTEBOOKS'),'Requires an explicit live notebook mount.')
class LiveACLTests(unittest.TestCase):
    def command(self,*args):
        result=subprocess.run(list(map(str,args)),capture_output=True,text=True,timeout=60)
        self.assertEqual(result.returncode,0,(args,result.stdout,result.stderr))
        return result.stdout

    def test_held_submissions_preserve_access_and_repair_local_imports(self):
        notebooks=Path(os.environ['SAGEQUEUE_LIVE_NOTEBOOKS']).resolve()
        container=os.getenv('SAGEQUEUE_LIVE_CONTAINER','sagepod')
        mount=Path(os.getenv('SAGEQUEUE_LIVE_MOUNT','/home/sage/notebooks'))
        uid=int(self.command('podman','exec',container,'id','-u'))
        gids=list(map(int,self.command('podman','exec',container,'id','-G').split()))
        with tempfile.TemporaryDirectory(prefix='sagequeue-acl-test-',dir=notebooks) as tmp:
            base=Path(tmp)
            self.command('setfacl','-b',base);self.command('setfacl','-k',base)
            base.chmod(0o700)
            work=base/'results';work.mkdir()
            queue=base/'queue'
            private=base/'private';private.mkdir(mode=0o700)
            secret=private/'secret.py';secret.write_text('SECRET=True\n');secret.chmod(0o600)
            private_before=self.command('podman','unshare','getfacl','-cpn',private,secret)
            for mode in ('ordinary','group','traversal'):
                with self.subTest(mode=mode):
                    source=base/mode;source.mkdir(mode=0o755)
                    script=source/'run.py'
                    script.write_text('import sys\nfrom pathlib import Path\n'
                                      'sys.path.insert(0,str(Path(__file__).resolve().parent))\n'
                                      'import local_helper\nprint(local_helper.VALUE)\n')
                    helper=source/'local_helper.py';helper.write_text('VALUE=42\n')
                    (source/'linked').symlink_to(private,target_is_directory=True)
                    if mode=='group':
                        source.chmod(0o700)
                        self.command('podman','unshare','setfacl','-m',f'g:{gids[0]}:r-x',source)
                    elif mode=='traversal':
                        self.command('podman','unshare','setfacl','-m',f'u:{uid}:--x',source)
                    remote=str(mount/source.relative_to(notebooks))
                    probe=('import os,sys,json,importlib.util; p=sys.argv[1]; '
                           'sys.path.insert(0,p); print(json.dumps([os.access(p,os.R_OK),'
                           'importlib.util.find_spec("local_helper") is not None]))')
                    # Give only search access through the private test ancestor.
                    self.command('podman','unshare','setfacl','-m',f'u:{uid}:--x',base)
                    prefix=['podman','exec','-e','PYTHONDONTWRITEBYTECODE=1',container,'/sage/sage','-python']
                    before=json.loads(self.command(*prefix,'-c',probe,remote))
                    self.assertEqual(before,[mode!='traversal']*2)
                    owner_before=(source.stat().st_uid,source.stat().st_gid)
                    self.command(sys.executable,ROOT/'sagequeue.py','--notebooks',notebooks,
                                 '--container-notebooks',mount,'--container',container,'--root',queue,
                                 'tasks','submit','--hold','--cwd',work,script)
                    after=json.loads(self.command(*prefix,'-c',probe,remote))
                    self.assertEqual(after,[True,True])
                    code=('import os,sys,pathlib; p=pathlib.Path(sys.argv[1]); '
                          'print(os.listdir(p)); print((p/"local_helper.py").read_text()); '
                          'sys.path.insert(0,str(p)); import local_helper; assert local_helper.VALUE==42')
                    self.command('podman','exec','-e','PYTHONDONTWRITEBYTECODE=1','-w',
                                 mount/work.relative_to(notebooks),container,'/sage/sage','-python','-c',code,remote)
                    self.assertEqual(owner_before,(source.stat().st_uid,source.stat().st_gid))
                    source_acl=self.command('podman','unshare','getfacl','-cpn',source)
                    self.assertNotIn('default:',source_acl)
                    self.assertNotIn(f'user:{uid}:rwx',source_acl)
            base_acl=self.command('podman','unshare','getfacl','-cpn',base)
            self.assertIn(f'user:{uid}:--x',base_acl)
            self.assertEqual(private_before,self.command('podman','unshare','getfacl','-cpn',private,secret))


if __name__=='__main__':unittest.main()
