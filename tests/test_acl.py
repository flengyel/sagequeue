import importlib.util
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('queue_acl',ROOT/'queue_acl.py')
acl=importlib.util.module_from_spec(spec);spec.loader.exec_module(acl)


class ACLModel:
    def __init__(self):self.values={};self.changed=[]

    def checked(self,command,**kwargs):
        path=Path(command[-1])
        if command[0]=='getfacl':
            if path not in self.values:
                mode=stat.S_IMODE(path.stat().st_mode)
                self.values[path]={(False,'user',''):(mode>>6)&7,
                                   (False,'group',''):(mode>>3)&7,(False,'other',''):mode&7}
            return acl.acl_text(self.values[path])
        if command[0]=='setfacl':
            assert '--physical' in command and '--no-mask' in command
            self.values[path]=acl.parse_acl(kwargs['input']);self.changed.append(path)
            return ''
        raise AssertionError(command)


class ACLTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name)
        self.notebooks=self.base/'notebooks';self.notebooks.mkdir()
        self.private=self.notebooks/'private';self.private.mkdir(mode=0o700)
        self.queue=self.private/'queue';self.queue.mkdir(mode=0o700)
        self.model=ACLModel()
        self.checked=patch.object(acl,'checked',side_effect=self.model.checked)
        self.checked.start();self.addCleanup(self.checked.stop)
        self.which=patch.object(acl.shutil,'which',return_value='/usr/bin/acl-tool')
        self.which.start();self.addCleanup(self.which.stop)

    def test_private_queue_records_and_default_acl(self):
        directory=self.queue/'attempt';directory.mkdir(mode=0o700)
        record=directory/'record.json';record.write_text('{}');record.chmod(0o600)
        before=record.stat().st_uid,record.stat().st_gid,record.read_bytes()
        acl.repair(self.notebooks,self.queue,1000)
        for path in (self.queue,directory):
            for uid in (0,1000):
                self.assertEqual(self.model.values[path][(False,'user',str(uid))],7)
                self.assertEqual(self.model.values[path][(True,'user',str(uid))],7)
        self.assertEqual(self.model.values[record][(False,'user','1000')],6)
        self.assertEqual(self.model.values[self.private][(False,'user','1000')],1)
        self.assertEqual(before,(record.stat().st_uid,record.stat().st_gid,record.read_bytes()))

    def test_preserve_effective_rights_when_increasing_mask(self):
        initial=acl.parse_acl('user::rwx\nuser:33:rwx\nuser:1000:rwx\ngroup::rwx\nmask::---\nother::---\n')
        updated=acl.merge_acl(initial,0,{1000:1})
        self.assertEqual(updated[(False,'user','33')],0)
        self.assertEqual(updated[(False,'group','')],0)
        self.assertEqual(updated[(False,'user','1000')],1)
        self.assertEqual(updated[(False,'other','')],0)

    def test_new_named_user_preserves_other_access(self):
        initial=acl.parse_acl('user::rwx\ngroup::r-x\nother::r-x\n')
        updated=acl.merge_acl(initial,0,{0:1,1000:1})
        self.assertEqual(updated[(False,'user','1000')],5)

    def test_new_named_user_preserves_only_matching_group_access(self):
        initial=acl.parse_acl('user::rwx\ngroup::rwx\ngroup:44:r--\ngroup:55:rwx\nmask::r-x\nother::-w-\n')
        for groups,expected in (({44},5),({20},5),({66},3),({44,20},5)):
            with self.subTest(groups=groups):
                updated=acl.merge_acl(initial,0,{1000:1},user_groups={1000:groups},owning_group=20)
                self.assertEqual(updated[(False,'user','1000')],expected)
                self.assertEqual(updated[(False,'group','55')],5)
        # A matching group with no effective rights prevents fallback to other.
        initial=acl.parse_acl('user::rwx\ngroup::---\nother::rwx\n')
        updated=acl.merge_acl(initial,0,{1000:1},user_groups={1000:{20}},owning_group=20)
        self.assertEqual(updated[(False,'user','1000')],1)

    def test_existing_named_user_does_not_gain_other_or_group_rights(self):
        initial=acl.parse_acl('user::rwx\nuser:1000:--x\ngroup::rwx\nmask::rwx\nother::rwx\n')
        updated=acl.merge_acl(initial,0,{1000:1},user_groups={1000:{20}},owning_group=20)
        self.assertEqual(updated[(False,'user','1000')],1)

    def test_separate_script_directory_repairs_traversal_only_entry(self):
        project=self.private/'source';project.mkdir(mode=0o700)
        script=project/'run.py';script.write_text('import local_helper\n');script.chmod(0o600)
        helper=project/'local_helper.py';helper.write_text('value=42\n');helper.chmod(0o644)
        self.model.values[project]=acl.parse_acl('user::rwx\nuser:1000:--x\ngroup::---\nmask::--x\nother::---\n')
        acl.repair(self.notebooks,self.queue,1000,self.private,script)
        entries=self.model.values[project]
        self.assertEqual(entries[(False,'user','1000')],5)
        self.assertFalse(any(key[0] for key in entries))
        self.assertNotIn(helper,self.model.changed)
        self.assertEqual(self.model.values[self.notebooks][(False,'user','1000')],1)

    def test_script_read_access_and_workdir_defaults_are_scoped(self):
        project=self.private/'project';project.mkdir(mode=0o700)
        script=project/'run.py';script.write_text('pass\n');script.chmod(0o600)
        unrelated=project/'unrelated';unrelated.write_text('private\n');unrelated.chmod(0o600)
        acl.repair(self.notebooks,self.queue,1000,project,script)
        self.assertEqual(self.model.values[script][(False,'user','1000')],4)
        self.assertEqual(self.model.values[project][(True,'user','1000')],7)
        self.assertNotIn(unrelated,self.model.changed)

    def test_queue_symlinks_do_not_grant_access_to_other_paths(self):
        outside=self.base/'outside';outside.mkdir()
        secret=outside/'secret';secret.write_text('secret')
        (self.queue/'linked-directory').symlink_to(outside,target_is_directory=True)
        (self.queue/'linked-file').symlink_to(secret)
        acl.repair(self.notebooks,self.queue,1000)
        self.assertNotIn(outside,self.model.values);self.assertNotIn(secret,self.model.values)
        self.assertNotIn(self.queue/'linked-file',self.model.values)

    def test_outside_task_path_is_rejected_before_any_acl_change(self):
        outside=self.base/'outside.py';outside.write_text('pass')
        with self.assertRaisesRegex(ValueError,'outside the notebook mount'):
            acl.repair(self.notebooks,self.queue,1000,self.private,outside)
        self.assertFalse(self.model.changed)

    def test_cached_queue_still_repairs_a_new_private_attempt(self):
        acl.repair(self.notebooks,self.queue,1000)
        old=self.queue/'old.log';old.write_text('old')
        attempt=self.queue/'attempt';attempt.mkdir(mode=0o700)
        record=attempt/'result.json';record.write_text('{}');record.chmod(0o600)
        self.model.changed=[]
        acl.repair(self.notebooks,self.queue,1000,tree=attempt)
        self.assertIn(attempt,self.model.changed);self.assertIn(record,self.model.changed)
        self.assertNotIn(old,self.model.values)

    def test_missing_acl_dependency_is_actionable(self):
        with patch.object(acl.shutil,'which',return_value=None):
            with self.assertRaisesRegex(ValueError,'install the host acl package'):
                acl.repair(self.notebooks,self.queue,1000)

    def test_unsupported_acl_filesystem_leaves_shared_paths_untouched(self):
        def fail(command,**kwargs):
            if command[0]=='setfacl':raise ValueError('Operation not supported')
            return self.model.checked(command,**kwargs)
        with patch.object(acl,'checked',side_effect=fail):
            with self.assertRaisesRegex(ValueError,'Operation not supported'):
                acl.repair(self.notebooks,self.queue,1000)
        self.assertFalse(self.model.changed)
        self.assertFalse(list(self.queue.glob('permissions-probe.*')))

    def test_executable_files_keep_execution_permissions(self):
        script=self.queue/'executable';script.write_text('exit 0\n');script.chmod(0o700)
        acl.repair(self.notebooks,self.queue,1000)
        self.assertEqual(self.model.values[script][(False,'user','1000')],7)

    def test_same_host_and_container_principal_is_valid(self):
        acl.repair(self.notebooks,self.queue,0)
        self.assertEqual(self.model.values[self.queue][(False,'user','0')],7)


class NativeACLTests(unittest.TestCase):
    def setUp(self):
        if not shutil.which('setfacl') or not shutil.which('getfacl'):
            self.skipTest('Native host acl utilities are unavailable.')
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name)
        self.notebooks=self.base/'notebooks';self.notebooks.mkdir()
        self.private=self.notebooks/'private';self.private.mkdir(mode=0o700)
        self.queue=self.private/'queue';self.queue.mkdir(mode=0o700)
        probe=subprocess.run(['setfacl','-m','u:65534:--x',str(self.private)],capture_output=True,text=True)
        if probe.returncode:self.skipTest('Native ACLs unavailable on this filesystem/user mapping: '+probe.stderr.strip())

    def read(self,path):
        return acl.parse_acl(subprocess.check_output(['getfacl','-cpn','--',str(path)],text=True))

    def test_private_directory_repair_and_inherited_file_access(self):
        acl.repair(self.notebooks,self.queue,65534)
        child=self.queue/'new';child.mkdir()
        record=child/'result.json';record.write_text('{}')
        entries=self.read(record)
        self.assertEqual(entries[(False,'user','65534')]&entries[(False,'mask','')],6)
        self.assertFalse(record.stat().st_mode&0o111)
        self.assertEqual(self.read(self.private)[(False,'user','65534')],1)

    def test_no_chown_and_preserve_existing_effective_rights(self):
        subprocess.run(['setfacl','-m','u:65533:rwx,m::---',str(self.private)],check=True)
        before=self.private.stat().st_uid,self.private.stat().st_gid
        acl.repair(self.notebooks,self.queue,65534)
        entries=self.read(self.private)
        self.assertEqual(entries[(False,'user','65533')]&entries[(False,'mask','')],0)
        self.assertEqual(before,(self.private.stat().st_uid,self.private.stat().st_gid))

    def test_new_named_user_keeps_readable_directory_access(self):
        source=self.private/'source';source.mkdir(mode=0o755)
        script=source/'run.py';script.write_text('pass\n')
        acl.repair(self.notebooks,self.queue,65534,self.private,script)
        entries=self.read(source)
        self.assertEqual(entries[(False,'user','65534')]&entries[(False,'mask','')],5)
        subprocess.run(['setfacl','-m','u:65534:--x',str(source)],check=True)
        acl.repair(self.notebooks,self.queue,65534,self.private,script)
        entries=self.read(source)
        self.assertEqual(entries[(False,'user','65534')]&entries[(False,'mask','')],5)


class GNUACLTextTests(unittest.TestCase):
    def test_generated_acl_is_accepted_by_gnu_setfacl(self):
        if not shutil.which('setfacl'):self.skipTest('GNU setfacl is unavailable.')
        initial=acl.parse_acl('user::rwx\ngroup::---\nother::---\n')
        updated=acl.merge_acl(initial,0,{0:7,1000:7})
        updated=acl.merge_acl(updated,0,{0:7,1000:7},default=True)
        with tempfile.TemporaryDirectory() as directory:
            result=subprocess.run(['setfacl','--test','--no-mask','--set-file=-',directory],
                                  input=acl.acl_text(updated),capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':unittest.main()
