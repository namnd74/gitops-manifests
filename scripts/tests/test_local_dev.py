"""Portable local GitOps contracts: configuration, Argo routing and real Git state."""
import importlib.util
import pathlib
import json
import shutil
from unittest.mock import patch
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class LocalDevTest(unittest.TestCase):
    def module(self):
        path = ROOT / 'scripts/local_dev.py'
        self.assertTrue(path.exists(), 'Portable local launcher is missing')
        spec = importlib.util.spec_from_file_location('local_dev', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_config_resolves_relative_backend_and_rejects_invalid_port(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'config'
            root.mkdir()
            (root / '.env.local').write_text('BE_SOURCE_DIR=../backend\nHTTP_PORT=8099\n')
            config = m.load_config(root, {})
            self.assertEqual(config['BE_SOURCE_DIR'], str((root.parent / 'backend').resolve()))
            self.assertEqual(config['HTTP_PORT'], '8099')
            (root / '.env.local').write_text('HTTP_PORT=0\n')
            with self.assertRaises(ValueError):
                m.load_config(root, {})

    def test_each_application_tracks_main_and_its_overlay(self):
        m = self.module()
        for env in ('dev', 'staging', 'prod'):
            app = m.application(env)
            self.assertEqual(app['spec']['source']['targetRevision'], 'main')
            self.assertEqual(app['spec']['source']['path'], f'apps/be-service/envs/{env}')
            self.assertEqual(app['spec']['destination']['namespace'], env)
            self.assertEqual(app['spec']['source']['repoURL'],
                             'git://gitops-source.gitops-system.svc.cluster.local/config.git')

    def test_runtime_identity_accepts_cri_digest_and_rejects_another_image(self):
        m = self.module()
        digest = 'sha256:' + 'a'*64
        status = {'id': 'sha256:' + 'b'*64, 'repoDigests': ['be-service@' + digest]}
        identities = m.runtime_identities(status)
        self.assertIn(m.content_id('docker-pullable://be-service@' + digest), identities)
        self.assertNotIn(m.content_id('containerd://sha256:' + 'c'*64), identities)
        with self.assertRaises(ValueError):
            m.runtime_identities({'id': 'missing'})

    def test_native_architecture_is_explicit_and_unknown_arch_is_rejected(self):
        m = self.module()
        self.assertEqual(m.image_arch('aarch64'), 'arm64')
        self.assertEqual(m.image_arch('x86_64'), 'amd64')
        with self.assertRaises(ValueError):
            m.image_arch('unknown')

    def test_state_cannot_overwrite_source_or_escape_ignored_directory(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for state in ('apps', '../backend', '.'):
                with self.assertRaises(ValueError):
                    m.load_config(root, {'STATE_DIR': state})

    def test_snapshot_rejects_plaintext_secret_serializations(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / 'rendered'
            source.mkdir()
            for name, content in [('secret.json', '{"kind":"Secret"}'),
                                  ('secret.yaml', 'kind: "Secret"\n'),
                                  ('secret.yaml', "kind: 'Secret' # password\n")]:
                target = source / name
                target.write_text(content)
                with self.assertRaises(ValueError):
                    m.publish_snapshot(source, source.parent / 'config.git')
                target.unlink()

    def test_local_render_generates_cluster_secret_without_source_ciphertext(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            shutil.copytree(ROOT/'apps', root/'apps')
            self.assertFalse(list((root/'apps').rglob('sealed-secret.yaml')))
            m.ROOT = root
            original = m.run
            def run(args, **kwargs):
                if args[0] == 'kubeseal':
                    if '--fetch-cert' in args:
                        return 'PUBLIC_CERT_FIXTURE'
                    secret = json.loads(kwargs['input'])
                    return json.dumps({'apiVersion': 'bitnami.com/v1alpha1', 'kind': 'SealedSecret',
                        'metadata': secret['metadata'], 'spec': {'encryptedData': {'DB_PASSWORD': 'a'*88},
                        'template': {'metadata': secret['metadata'], 'type': 'Opaque'}}})
                return original(args, **kwargs)
            with patch.object(m, 'run', side_effect=run):
                m.prepare_manifests(m.load_config(root, {}), 'be-service:local-fixture')
            for env in ('dev', 'staging', 'prod'):
                manifest = subprocess.check_output(['kustomize', 'build',
                    str(root/f'.local/rendered/apps/be-service/envs/{env}')], text=True)
                self.assertEqual(manifest.count('kind: SealedSecret'), 1)
                self.assertIn('image: be-service:local-fixture', manifest)

    def test_snapshot_uses_real_main_and_excludes_private_runtime_files(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source, bare = root / 'rendered', root / 'config.git'
            source.mkdir()
            (source / 'deployment.json').write_text('{"kind":"Deployment"}')
            (source / 'secret-private.key').write_text('MUST_NOT_ENTER_GIT')
            with self.assertRaises(ValueError):
                m.publish_snapshot(source, bare)
            (source / 'secret-private.key').unlink()
            revision = m.publish_snapshot(source, bare)
            self.assertEqual(subprocess.check_output(['git', '--git-dir', str(bare),
                              'rev-parse', 'main'], text=True).strip(), revision)
            self.assertEqual(m.publish_snapshot(source, bare), revision)
            before = revision
            (source / 'deployment.json').write_text('{"kind":"Deployment","replicas":2}')
            after = m.publish_snapshot(source, bare)
            self.assertNotEqual(before, after)
            self.assertEqual(subprocess.check_output(['git', '--git-dir', str(bare),
                              'show', 'main:deployment.json'], text=True),
                             '{"kind":"Deployment","replicas":2}')


if __name__ == '__main__':
    unittest.main()
