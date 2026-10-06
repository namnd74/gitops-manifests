import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

class ManifestTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        for name in ('apps', 'scripts', 'cmd'):
            if (ROOT/name).exists():
                shutil.copytree(ROOT/name, self.root/name)
        for name in ('go.mod', 'go.sum'):
            if (ROOT/name).exists():
                shutil.copy(ROOT/name, self.root/name)

    def edit(self, path, expression):
        subprocess.run(['yq', '-i', expression, str(self.root/path)], check=True)

    def validate(self):
        return subprocess.run(['bash', str(self.root/'scripts/validate-manifests.sh')],
                              capture_output=True, text=True, env=dict(os.environ, IMAGE="ghcr.io/example/be-service"))

    def test_all_overlays_inherit_branch_release_digest(self):
        self.edit('apps/be-service/base/kustomization.yaml',
                  'del(.images[0].newTag) | .images[0].digest = "sha256:'+'a'*64+'"')
        for env in ('dev', 'staging', 'prod'):
            rendered = subprocess.check_output(['kustomize', 'build', str(self.root/f'apps/be-service/envs/{env}')], text=True)
            self.assertIn('ghcr.io/example/be-service@sha256:'+'a'*64, rendered)

    def test_accepts_bootstrap(self):
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_dev_fault_without_release_metadata(self):
        for env in ('dev', 'staging', 'prod'):
            self.edit(f'apps/be-service/envs/{env}/kustomization.yaml', 'del(.commonAnnotations)')
        self.edit('apps/be-service/envs/dev/deployment-env-patch.yaml',
                  '(.spec.template.spec.containers[0].env[] | select(.name == "DEMO_FAULT").value) = "true"')
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_wrong_replicas(self):
        self.edit('apps/be-service/envs/staging/deployment-env-patch.yaml', '.spec.replicas = 1')
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_prod_demo_mode(self):
        self.edit('apps/be-service/envs/prod/deployment-env-patch.yaml',
                  '(.spec.template.spec.containers[0].env[] | select(.name == "DEMO_MODE").value) = "true"')
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_optional_secret(self):
        self.edit('apps/be-service/base/deployment.yaml',
                  '(.spec.template.spec.containers[0].env[] | select(.name == "DB_PASSWORD").valueFrom.secretKeyRef.optional) = true')
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_plaintext_secret(self):
        path = self.root/'apps/be-service/base/secret.yaml'
        path.write_text('apiVersion: v1\nkind: Secret\nmetadata:\n  name: leaked\nstringData:\n  password: leaked\n')
        self.edit('apps/be-service/base/kustomization.yaml', '.resources += ["secret.yaml"]')
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_unapproved_mutable_tag(self):
        self.edit('apps/be-service/base/kustomization.yaml', '.images[0].newTag = "latest"')
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_unapproved_image(self):
        self.edit('apps/be-service/base/kustomization.yaml', '.images[0].newName = "example.com/untrusted/app"')
        self.assertNotEqual(self.validate().returncode, 0)

if __name__ == '__main__':
    unittest.main()
