import os
import pathlib
import subprocess
import tempfile
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
class DemoTest(unittest.TestCase):
    def run_script(self, argument):
        with tempfile.TemporaryDirectory() as directory:
            fake = pathlib.Path(directory) / 'kubectl'
            fake.write_text('#!/bin/sh\necho CLUSTER_TOUCHED >&2\nexit 99\n')
            fake.chmod(0o755)
            return subprocess.run(['bash', str(ROOT/'scripts/demo.sh'), argument], env=dict(os.environ, PATH=directory+':'+os.environ['PATH']), capture_output=True, text=True)
    def test_help_has_no_cluster_side_effects(self):
        result = self.run_script('--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('doctor', result.stdout)
        self.assertNotIn('CLUSTER_TOUCHED', result.stderr)
    def test_invalid_command_has_no_cluster_side_effects(self):
        result = self.run_script('invalid')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('CLUSTER_TOUCHED', result.stderr)
    def test_removed_local_mode_fails_before_docker(self):
        result = subprocess.run(['bash', str(ROOT/'setup.sh'), '--local'],capture_output=True,text=True)
        self.assertEqual(result.returncode, 2)
if __name__ == '__main__': unittest.main()
