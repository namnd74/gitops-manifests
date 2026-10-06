"""Exercise the main release gate with real Git and Kustomize."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
IMAGE = 'ghcr.io/example/be-service'


class MainReleaseTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        for name in ('apps', 'scripts'):
            shutil.copytree(ROOT/name, self.root/name)
        (self.root/'scripts/verify-image.sh').write_text(
            '#!/bin/sh\nprintf "%s\\n" "$1" >> "$CALLS"\nexit "${VERIFY_EXIT:-0}"\n')
        self.env = dict(os.environ, IMAGE=IMAGE, SOURCE_REPO='example/be-service',
                        RUNNER_TEMP=str(self.root), CALLS=str(self.root/'calls'),
                        BASE_ENV='main', HEAD_BRANCH='release-be-service-main')
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('add', 'apps')
        self.git('commit', '-qm', 'main baseline')
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        subprocess.run(['kustomize', 'edit', 'set', 'image', IMAGE+'='+IMAGE+'@sha256:'+'a'*64],
                       cwd=self.root/'apps/be-service/base', check=True)

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def prepare(self, **env):
        script = subprocess.check_output(['yq', '-r',
            '.jobs.validate.steps[] | select(.name == "Validate release branch PR") | .run',
            str(ROOT/'.github/workflows/validate.yaml')], text=True)
        return subprocess.run(['bash', '-c', script], cwd=self.root,
                              env=dict(self.env, **env), capture_output=True, text=True)

    def test_verified_main_release_is_accepted(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(IMAGE+'@sha256:'+'a'*64, (self.root/'calls').read_text())

    def test_release_cannot_change_environment_settings(self):
        path = self.root/'apps/be-service/envs/dev/deployment-env-patch.yaml'
        path.write_text(path.read_text()+'\n# unexpected environment change\n')
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Environment configuration differs', result.stderr)
        self.assertFalse((self.root/'calls').exists())

    def test_signature_failure_rejects_release(self):
        result = self.prepare(VERIFY_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root/'calls').exists())

    def test_environment_branch_is_rejected(self):
        result = self.prepare(BASE_ENV='dev', HEAD_BRANCH='release-be-service-dev')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root/'calls').exists())


if __name__ == '__main__':
    unittest.main()
