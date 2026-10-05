"""Execute actual workflow shell steps against disposable Git/config repositories."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
IMAGE = 'ghcr.io/namnd74/be-service'

class ReleaseWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        for name in ('apps', 'scripts'):
            shutil.copytree(ROOT/name, self.root/name)
        # Registry verification has its own failure-path tests; these tests use real Git and Kustomize.
        (self.root/'scripts/verify-image.sh').write_text(
            '#!/bin/sh\nprintf "%s\\n" "$1" >> "$CALLS"\nexit "${VERIFY_EXIT:-0}"\n')
        self.env = dict(os.environ, IMAGE=IMAGE, SOURCE_REPO='namnd74/be-service',
                        RUNNER_TEMP=str(self.root), CALLS=str(self.root/'calls'))
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def pin(self, env, letter):
        subprocess.run(['kustomize', 'edit', 'set', 'image', IMAGE+'='+IMAGE+'@sha256:'+letter*64],
                       cwd=self.root/f'apps/be-service/envs/{env}', check=True)

    def edit_fault(self, env, value):
        subprocess.run(['yq', '-i',
                        '(.spec.template.spec.containers[0].env[] | select(.name == "DEMO_FAULT").value) = "'+value+'"',
                        str(self.root/f'apps/be-service/envs/{env}/deployment-env-patch.yaml')], check=True)

    def prepare(self, workflow, name, **env):
        job = 'promote' if workflow == 'promote' else 'restore'
        expression = f'.jobs.{job}.steps[] | select(.name == "{name}") | .run'
        script = subprocess.check_output(['yq', '-r', expression, str(ROOT/f'.github/workflows/{workflow}.yaml')], text=True)
        return subprocess.run(['bash', '-c', script], cwd=self.root, env=dict(self.env, **env),
                              capture_output=True, text=True)

    def test_promotion_changes_only_target_image(self):
        self.pin('dev', 'a')
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in (self.root/'apps').rglob('*.yaml')}
        result = self.prepare('promote', 'Prepare verified promotion', FROM_ENV='dev', TO_ENV='staging')
        self.assertEqual(result.returncode, 0, result.stderr)
        changed = [path for path, content in before.items() if (self.root/path).read_bytes() != content]
        self.assertEqual(changed, ['apps/be-service/envs/staging/kustomization.yaml'])
        rendered = subprocess.check_output(['kustomize', 'build', 'apps/be-service/envs/staging'], cwd=self.root, text=True)
        self.assertIn(IMAGE+'@sha256:'+'a'*64, rendered)

    def test_faulted_source_cannot_promote(self):
        self.pin('dev', 'a')
        self.edit_fault('dev', 'true')
        target = self.root/'apps/be-service/envs/staging/kustomization.yaml'
        before = target.read_bytes()
        result = self.prepare('promote', 'Prepare verified promotion', FROM_ENV='dev', TO_ENV='staging')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cannot promote', result.stderr)
        self.assertEqual(target.read_bytes(), before)
        self.assertFalse((self.root/'calls').exists())

    def test_unsupported_pair_does_not_change_configuration(self):
        result = self.prepare('promote', 'Prepare verified promotion', FROM_ENV='dev', TO_ENV='prod')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root/'calls').exists())

    def test_verification_failure_stops_promotion(self):
        self.pin('dev', 'a')
        self.env['VERIFY_EXIT'] = '1'
        target = self.root/'apps/be-service/envs/staging/kustomization.yaml'
        before = target.read_bytes()
        self.assertNotEqual(self.prepare('promote', 'Prepare verified promotion', FROM_ENV='dev', TO_ENV='staging').returncode, 0)
        self.assertEqual(target.read_bytes(), before)

    def test_restore_recovers_image_and_fault_without_reverting_secret(self):
        self.pin('dev', 'a')
        self.git('add', 'apps')
        self.git('commit', '-qm', 'known good')
        good = self.git('rev-parse', 'HEAD')
        self.pin('dev', 'b')
        self.edit_fault('dev', 'true')
        secret = self.root/'apps/be-service/envs/dev/sealed-secret.yaml'
        secret.write_text(secret.read_text()+'\n# rotated ciphertext after release\n')
        before = secret.read_bytes()
        result = self.prepare('rollback', 'Prepare verified restore', RESTORE_ENV='dev', REVISION=good)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(secret.read_bytes(), before)
        self.assertEqual(self.git('diff', '--name-only'), 'apps/be-service/envs/dev/sealed-secret.yaml')
        self.assertIn(IMAGE+'@sha256:'+'a'*64, (self.root/'calls').read_text())

    def test_invalid_revision_stops_before_changes(self):
        result = self.prepare('rollback', 'Prepare verified restore', RESTORE_ENV='dev', REVISION='main;echo unsafe')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root/'calls').exists())

    def test_faulted_rollback_target_is_rejected(self):
        self.pin('dev', 'a')
        self.edit_fault('dev', 'true')
        self.git('add', 'apps')
        self.git('commit', '-qm', 'faulted')
        good = self.git('rev-parse', 'HEAD')
        result = self.prepare('rollback', 'Prepare verified restore', RESTORE_ENV='dev', REVISION=good)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Rollback target is faulted', result.stderr)
        self.assertFalse((self.root/'calls').exists())

    def test_missing_pat_fails_explicit_credential_gate(self):
        result = self.prepare('promote', 'Require config repository credential', CONFIG_REPO_PAT='')
        self.assertNotEqual(result.returncode, 0)

if __name__ == '__main__':
    unittest.main()
