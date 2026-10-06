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

        self.edit('apps/be-service/base/kustomization.yaml', '.images = [{"name":"ghcr.io/example/be-service","newTag":"bootstrap"}]')

    def edit(self, path, expression):
        subprocess.run(['yq', '-i', expression, str(self.root/path)], check=True)

    def validate(self):
        return subprocess.run(['bash', str(self.root/'scripts/validate-manifests.sh')],
                              capture_output=True, text=True, env=dict(os.environ, IMAGE="ghcr.io/example/be-service"))

    def test_each_environment_loads_its_own_configmap(self):
        for environment in ('dev', 'staging', 'prod'):
            rendered = subprocess.check_output(['kustomize', 'build', str(self.root/f'apps/be-service/envs/{environment}')], text=True)
            objects = subprocess.check_output(['yq', '-o=json', '.', '-'], input=rendered, text=True)
            import json
            decoder = json.JSONDecoder()
            parsed = []
            while objects.strip():
                item, length = decoder.raw_decode(objects.lstrip())
                parsed.append(item)
                objects = objects.lstrip()[length:]
            self.assertTrue(any(o["kind"] == "ConfigMap" for o in parsed))
            config = next(o for o in parsed if o['kind'] == 'ConfigMap')
            deployment = next(o for o in parsed if o['kind'] == 'Deployment')
            container = deployment['spec']['template']['spec']['containers'][0]
            self.assertEqual(config['data']['APP_ENV'], environment)
            self.assertEqual(container['envFrom'], [{'configMapRef': {'name': config['metadata']['name']}}])
            self.assertEqual([e['name'] for e in container['env']], ['DB_PASSWORD'])

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
        path = self.root/'apps/be-service/envs/dev/environment.env'
        path.write_text(path.read_text().replace('DEMO_FAULT=false','DEMO_FAULT=true'))
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_readiness_failure_requires_explicit_prod_seminar_marker(self):
        path = 'apps/be-service/envs/prod/deployment-env-patch.yaml'
        self.edit(path, 'del(.metadata.annotations."seminar.gitops.io/scenario") | .spec.template.spec.containers[0].name = "app" | .spec.template.spec.containers[0].readinessProbe.httpGet.port = 8081')
        self.assertNotEqual(self.validate().returncode, 0)
        self.edit(path, '.metadata.annotations."seminar.gitops.io/scenario" = "prod-readiness-failure"')
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_readiness_demo_cannot_disable_liveness_or_old_pod_availability(self):
        self.edit('apps/be-service/envs/prod/deployment-env-patch.yaml',
                  '.metadata.annotations."seminar.gitops.io/scenario" = "prod-readiness-failure" | .spec.template.spec.containers[0].name = "app" | .spec.template.spec.containers[0].readinessProbe.httpGet.port = 8081 | .spec.template.spec.containers[0].livenessProbe.httpGet.port = 8081')
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_wrong_replicas(self):
        self.edit('apps/be-service/envs/staging/deployment-env-patch.yaml', '.spec.replicas = 1')
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_prod_demo_mode(self):
        path = self.root/'apps/be-service/envs/prod/environment.env'
        path.write_text(path.read_text().replace('DEMO_MODE=false','DEMO_MODE=true'))
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_optional_secret(self):
        self.edit('apps/be-service/base/deployment.yaml',
                  '(.spec.template.spec.containers[0].env[] | select(.name == "DB_PASSWORD").valueFrom.secretKeyRef.optional) = true')
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_cluster_ciphertext_in_shared_source(self):
        import json
        path = self.root/'apps/be-service/envs/dev/sealed-secret.yaml'
        metadata = {'name': 'be-service-secret', 'namespace': 'dev'}
        path.write_text(json.dumps({'apiVersion': 'bitnami.com/v1alpha1', 'kind': 'SealedSecret',
            'metadata': metadata, 'spec': {'encryptedData': {'DB_PASSWORD': 'a'*128},
            'template': {'metadata': metadata, 'type': 'Opaque'}}}))
        self.edit('apps/be-service/envs/dev/kustomization.yaml', '.resources += ["sealed-secret.yaml"]')
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
