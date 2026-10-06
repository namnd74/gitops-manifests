import os
import pathlib
import shutil
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

class ConnectTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = pathlib.Path(self.directory.name)
        self.repo = self.path/'repo'
        for name in ('scripts', 'apps', 'argocd'):
            shutil.copytree(ROOT/name, self.repo/name)
        # Fixtures must not inherit whichever release the checkout currently uses.
        subprocess.run(['kustomize', 'edit', 'set', 'image',
                        'ghcr.io/namnd74/be-service=ghcr.io/namnd74/be-service:sha-9912c6b'],
                       cwd=self.repo/'apps/be-service/base', check=True)
        self.bin = self.path/'bin'
        self.bin.mkdir()
        self.calls = self.path/'calls'
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'], CALLS=str(self.calls))
        self.snapshots = self.path/'snapshots'
        for env in ('dev', 'staging', 'prod'):
            shutil.copytree(self.repo, self.snapshots/env)
        self.env['GIT_FIXTURES'] = str(self.snapshots)
        self.digest('dev', 'a')
        for name, body in {
             'git': 'case "$1" in status|fetch) ;; rev-parse) echo "${2##*/}" ;; archive) branch="${2##*/}"; tar -C "$GIT_FIXTURES/$branch" -cf - apps scripts argocd ;; esac',
            'gh': 'exit 0',
            'kubeseal': 'exit 0',
            'docker': '''echo '{"config":{"Labels":{"org.opencontainers.image.revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","org.opencontainers.image.version":"v1.2.3","org.opencontainers.image.source":"https://github.com/namnd74/be-service"}}}' ''',
            'cosign': 'case "$*" in *"${FAIL_DIGEST:-never}"*) echo SIGNATURE_REJECTED >&2; exit 1 ;; esac',
            'kubectl': 'printf "%s\\n" "$*" >> "$CALLS"',
        }.items():
            file = self.bin/name
            file.write_text('#!/bin/sh\n'+body+'\n')
            file.chmod(0o755)

    def digest(self, env, character):
        subprocess.run(['kustomize', 'edit', 'set', 'image',
                        'ghcr.io/namnd74/be-service=ghcr.io/namnd74/be-service@sha256:'+character*64],
                       cwd=self.snapshots/env/'apps/be-service/base', check=True)

    def connect(self):
        return subprocess.run(['bash', str(self.repo/'scripts/demo.sh'), 'connect'], env=self.env, capture_output=True, text=True)

    def applied(self):
        return self.calls.read_text() if self.calls.exists() else ''

    def test_bootstrap_staging_and_prod_are_not_connected(self):
        result = self.connect()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('be-service-dev.yaml', self.applied())
        self.assertNotIn('be-service-staging.yaml', self.applied())
        self.assertNotIn('be-service-prod.yaml', self.applied())

    def test_unverified_staging_prevents_any_application_apply(self):
        self.digest('staging', 'c')
        self.env['FAIL_DIGEST'] = 'sha256:'+'c'*64
        result = self.connect()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SIGNATURE_REJECTED', result.stderr)
        self.assertEqual(self.applied(), '')

    def test_verified_promoted_environments_are_connected(self):
        self.digest('staging', 'c')
        self.digest('prod', 'd')
        result = self.connect()
        self.assertEqual(result.returncode, 0, result.stderr)
        for env in ('dev', 'staging', 'prod'):
            self.assertIn(f'be-service-{env}.yaml', self.applied())
if __name__ == '__main__': unittest.main()
