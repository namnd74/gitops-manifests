import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
REF = 'ghcr.io/namnd74/be-service@sha256:' + 'a'*64
SHA = 'b'*40

class VerifyImageTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = pathlib.Path(self.directory.name)
        self.env = dict(os.environ, PATH=str(self.path)+':'+os.environ['PATH'],
                        CALLS=str(self.path/'calls'), IMAGE_LABELS=json.dumps({'config': {'Labels': {
                            'org.opencontainers.image.revision': SHA,
                            'org.opencontainers.image.version': 'v1.2.3',
                            'org.opencontainers.image.source': 'https://github.com/namnd74/be-service'}}}))
        for name, body in {
            'docker': 'printf "docker\\n" >> "$CALLS"; printf "%s\\n" "$IMAGE_LABELS"',
            'gh': 'printf "gh %s\\n" "$*" >> "$CALLS"; exit "${GH_EXIT:-0}"',
            'cosign': 'printf "cosign %s\\n" "$*" >> "$CALLS"; exit "${COSIGN_EXIT:-0}"',
        }.items():
            file = self.path/name
            file.write_text('#!/bin/sh\n'+body+'\n')
            file.chmod(0o755)

    def verify(self, ref=REF, repo='namnd74/be-service'):
        return subprocess.run(['bash', str(ROOT/'scripts/verify-image.sh'), ref, repo],
                              env=self.env, capture_output=True, text=True)

    def calls(self):
        file = self.path/'calls'
        return file.read_text() if file.exists() else ''

    def test_mutable_tag_rejected_before_external_calls(self):
        result = self.verify('ghcr.io/namnd74/be-service:latest')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), '')

    def test_other_repository_rejected_before_external_calls(self):
        result = self.verify(REF.replace('namnd74', 'untrusted'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), '')

    def test_provenance_failure_stops_before_cosign(self):
        self.env['GH_EXIT'] = '1'
        self.assertNotEqual(self.verify().returncode, 0)
        self.assertIn('gh ', self.calls())
        self.assertNotIn('cosign ', self.calls())

    def test_wrong_source_label_rejected(self):
        self.env['IMAGE_LABELS'] = self.env['IMAGE_LABELS'].replace('namnd74', 'untrusted')
        self.assertNotEqual(self.verify().returncode, 0)
        self.assertNotIn('gh ', self.calls())

    def test_signature_failure_rejected(self):
        self.env['COSIGN_EXIT'] = '1'
        self.assertNotEqual(self.verify().returncode, 0)

    def test_verifies_digest_source_sha_main_and_signer(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        for required in (REF, '--source-digest '+SHA, '--source-ref refs/heads/main',
                         '--signer-workflow namnd74/be-service/.github/workflows/ci.yaml',
                         'ci.yaml@refs/heads/main', 'https://token.actions.githubusercontent.com'):
            self.assertIn(required, self.calls())

if __name__ == '__main__':
    unittest.main()
