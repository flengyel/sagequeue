import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EnvironmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.project = Path(cls.temp.name) / 'queue checkout'
        (cls.project / 'bin').mkdir(parents=True)
        for name in ('bin/sagequeue', 'bin/venvfix.sh', 'requirements.txt'):
            shutil.copy2(ROOT / name, cls.project / name)
        (cls.project / 'sagequeue.py').write_text(
            'import json,sys\n'
            'print(json.dumps({"prefix":sys.prefix,"base":sys.base_prefix,"argv":sys.argv[1:]}))\n')
        p = subprocess.run(['bash', str(cls.project / 'bin/venvfix.sh'), sys.executable],
                           capture_output=True, text=True, timeout=60)
        if p.returncode:
            raise AssertionError((p.stdout, p.stderr))

    def test_local_environment_has_no_broken_dependencies(self):
        python = self.project / '.venv/bin/python'
        p = subprocess.run([str(python), '-m', 'pip', '--disable-pip-version-check', 'check'],
                           capture_output=True, text=True, timeout=20)
        self.assertEqual(p.returncode, 0, (p.stdout, p.stderr))

    def test_installed_symlink_uses_repository_environment_and_literal_arguments(self):
        link = Path(self.temp.name) / 'installed-command'
        link.symlink_to(self.project / 'bin/sagequeue')
        args = ['tasks', 'argument with spaces', '$(touch bad)', '--value=two words']
        p = subprocess.run([sys.executable, str(link), *args], cwd=self.temp.name,
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(p.returncode, 0, (p.stdout, p.stderr))
        result = json.loads(p.stdout)
        self.assertEqual(Path(result['prefix']), self.project / '.venv')
        self.assertNotEqual(result['prefix'], result['base'])
        self.assertEqual(result['argv'], args)
        self.assertFalse((Path(self.temp.name) / 'bad').exists())

    def test_repair_preserves_existing_environment_files(self):
        keep = self.project / '.venv/keep.txt'
        keep.write_text('retained')
        p = subprocess.run(['bash', str(self.project / 'bin/venvfix.sh'), sys.executable],
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, (p.stdout, p.stderr))
        self.assertEqual(keep.read_text(), 'retained')

    def test_missing_environment_has_actionable_error(self):
        project = Path(self.temp.name) / 'not installed'
        (project / 'bin').mkdir(parents=True)
        shutil.copy2(ROOT / 'bin/sagequeue', project / 'bin/sagequeue')
        p = subprocess.run([sys.executable, str(project / 'bin/sagequeue'), '--help'],
                           capture_output=True, text=True, timeout=10)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(str(project / 'bin/setup.sh'), p.stderr)


if __name__ == '__main__':
    unittest.main()
