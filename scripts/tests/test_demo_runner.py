"""Contract tests for resumable release automation; no GitHub/cluster writes."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DemoRunnerTests(unittest.TestCase):
    def run_bash(self, code, **env):
        return subprocess.run(['bash', '-c', code], cwd=ROOT, env=dict(os.environ, **env),
                              text=True, capture_output=True, timeout=20)

    def helper(self, code, gh_body):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            gh = path/'gh'
            gh.write_text('#!/bin/bash\n'+gh_body)
            gh.chmod(0o755)
            return self.run_bash('set -Eeuo pipefail; source scripts/demo-github.sh; '
                                 'fail() { echo "$*" >&2; exit 1; }; '
                                 'POLL_SECONDS=0; WAIT_SECONDS=1; '+code,
                                 PATH=tmp+':'+os.environ['PATH'])

    def test_help_does_not_need_auth_or_docker(self):
        result = self.run_bash('bash scripts/demo.sh --help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--count', result.stdout)
        self.assertIn('--resume', result.stdout)

    def test_invalid_count_and_path_rejected_before_external_actions(self):
        for args in ('--count 0', '--count -1', '--count x', '--resume ../x', '--count 1 --resume x', '--scenario broken', '--scenario happy --resume x'):
            result = self.run_bash('bash scripts/demo.sh '+args)
            self.assertNotEqual(result.returncode, 0, args)
            self.assertNotIn('Missing tool', result.stderr)

    def test_wait_checks_rejects_empty_or_failed_checks(self):
        for payload in ('[]', '[{"bucket":"fail"}]', '[{"bucket":"cancel"}]',
                        '[{"bucket":"skipping"}]'):
            result = self.helper('wait_checks example/repo 5 >/dev/null',
                                 "printf '%s\\n' '"+payload+"'\n")
            self.assertNotEqual(result.returncode, 0, payload)

    def test_wait_checks_accepts_all_pass(self):
        result = self.helper('wait_checks example/repo 5', 'echo \'[{"bucket":"pass","name":"validate"}]\'\n')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failure_must_be_exact_docker_step_not_scan(self):
        good = {'jobs': [
            {'name': 'Test, race, vet, and format', 'conclusion': 'success'},
            {'name': 'Build once and security gate', 'conclusion': 'failure', 'steps': [
                {'name': 'Build the single local image', 'conclusion': 'failure'}]},
            {'name': 'Publish immutable image and release metadata', 'conclusion': 'skipped'},
            {'name': 'Propose image update', 'conclusion': 'skipped'}]}
        result = self.helper('verify_build_failure example/repo 8',
                             "if [[ \"$*\" == *--log-failed* ]]; then echo '#8 0.123 SEMINAR: intentional prod build failure'; else echo '"+json.dumps(good)+"'; fi\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        good['jobs'][1]['steps'][0]['name'] = 'Security gate (fixed and unfixed HIGH/CRITICAL)'
        result = self.helper('verify_build_failure example/repo 8',
                             "if [[ \"$*\" == *--log-failed* ]]; then echo '#8 0.123 SEMINAR: intentional prod build failure'; else echo '"+json.dumps(good)+"'; fi\n")
        self.assertNotEqual(result.returncode, 0)

    def test_thousand_version_increments_are_unique(self):
        result = self.run_bash('source scripts/demo-cycle.sh; v=v1.3.2; '
            'for ((i=1;i<=1000;i++)); do v=$(next_version "$v"); printf "%s\\n" "$v"; done')
        self.assertEqual(result.returncode, 0, result.stderr)
        versions = result.stdout.splitlines()
        self.assertEqual(len(set(versions)), 1000)
        self.assertEqual(versions[-1], 'v1.3.1002')

    def test_wrong_dispatch_branch_is_rejected(self):
        result = self.helper('CYCLE_DIR=$(mktemp -d); SOURCE_REPO=example/repo; '
            'wait_run 8 abc workflow_dispatch prod',
            'echo \'{"status":"completed","headSha":"abc","event":"workflow_dispatch","headBranch":"dev"}\'\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Wrong run', result.stderr)

    def test_empty_checkpoint_cannot_be_replaced_by_a_successful_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)/'state.json'; state.write_text('')
            result = self.run_bash('set -Eeuo pipefail; source scripts/demo-cycle.sh; '
                'fail() { echo "$*" >&2; exit 1; }; CYCLE_DIR="$TEST_DIR"; '
                'CYCLE="$CYCLE_DIR/state.json"; put stage 7', TEST_DIR=tmp)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(state.read_text(), '')

    def test_version_handles_patch_and_rejects_bad_semver(self):
        for old, expected in [('v1.3.2', 'v1.3.3'), ('v1.3.999', 'v1.3.1000')]:
            result = self.run_bash('source scripts/demo-cycle.sh; next_version "$OLD"', OLD=old)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)
        result = self.run_bash('source scripts/demo-cycle.sh; fail() { exit 1; }; next_version v1.2')
        self.assertNotEqual(result.returncode, 0)


class DemoIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root/'bin'; self.bin.mkdir()
        self.lab = self.root/'lab'; self.lab.mkdir()
        shutil.copytree(ROOT/'scripts', self.lab/'scripts')
        shutil.copytree(ROOT/'apps', self.lab/'apps')
        self.command(['git', 'init', '-q', str(self.lab)])
        self.command(['git', '-C', str(self.lab), 'remote', 'add', 'origin', 'https://github.com/fixture/manifests.git'])
        for repo in ('backend', 'manifests'):
            src = self.root/('src-'+repo); src.mkdir()
            self.command(['git', 'init', '-q', str(src)])
            for key, value in [('user.name', 'Fixture'), ('user.email', 'fixture@example.invalid'), ('commit.gpgsign', 'false')]:
                self.command(['git', '-C', str(src), 'config', key, value])
            if repo == 'backend':
                (src/'main.go').write_text('package main\nvar x = struct { ServiceName string }{\nServiceName: "Old",\n}\n')
                (src/'VERSION').write_text('v1.3.1\n')
                (src/'scripts').mkdir(); (src/'scripts/check-quality.sh').write_text('exit 0\n')
            else:
                shutil.copytree(ROOT/'apps', src/'apps')
                shutil.copytree(ROOT/'scripts', src/'scripts')
                self.command(['kustomize', 'edit', 'set', 'image', 'ghcr.io/example/be-service=ghcr.io/fixture/backend@sha256:'+'a'*64], cwd=src/'apps/be-service/base')
            self.command(['git', '-C', str(src), 'add', '.'])
            self.command(['git', '-C', str(src), 'commit', '-qm', 'baseline'])
            self.command(['git', '-C', str(src), 'branch', '-M', 'main'])
            for branch in ('dev','stg','prod'):
                self.command(['git', '-C', str(src), 'branch', branch])
            self.command(['git', 'clone', '-q', '--bare', str(src), str(self.root/repo)])
        baseline = 'ghcr.io/fixture/backend@sha256:'+'a'*64
        (self.root/'api.json').write_text(json.dumps(dict(prs=[], runs=[], artifacts={}, variables={},
            images={baseline:dict(version='v1.3.1',source_sha='b'*40)}, baseline_prod=baseline)))
        (self.lab/'.env.local').write_text('SOURCE_REPO=fixture/backend\nCONFIG_REPO_URL=https://github.com/fixture/manifests.git\n')
        fixture = self.bin/'fixture.py'
        shutil.copy(ROOT/'scripts/tests/demo_fixture.py', fixture); fixture.chmod(0o755)
        for tool in ('gh','kubectl','curl','check-fixture'):
            (self.bin/tool).symlink_to(fixture)
        for tool in ('go','gofmt','docker'):
            p = self.bin/tool; p.write_text('#!/bin/bash\nexit 0\n'); p.chmod(0o755)
        real_git = shutil.which('git')
        git_wrapper = self.bin/'git'
        git_wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\n'
            'args=[os.environ["DEMO_FIXTURE"]+"/"+a.split("/")[-1][:-4] if a.startswith("https://github.com/fixture/") and a.endswith(".git") else a for a in sys.argv[1:]]\n'
            'os.execv('+repr(real_git)+', ["git"]+args)\n')
        git_wrapper.chmod(0o755)
        (self.lab/'scripts/check.sh').write_text('#!/bin/bash\ncheck-fixture\n')
        self.env = dict(os.environ, DEMO_FIXTURE=str(self.root), DEMO_POLL_SECONDS='1', DEMO_WAIT_SECONDS='10', PATH=str(self.bin)+':'+os.environ['PATH'])
        for key in ('STATE_DIR','SOURCE_REPO','CONFIG_REPO_URL','BE_SOURCE_DIR','CLUSTER_NAME','HTTP_PORT','HTTPS_PORT'):
            self.env.pop(key, None)

    def command(self, args, **kwargs):
        return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)

    def run_demo(self, *args, **env):
        return subprocess.run(['bash', 'scripts/demo.sh', *args], cwd=self.lab,
                              env=dict(self.env, **env), text=True, capture_output=True, timeout=90)

    def test_unfinished_session_reports_the_existing_resume_id(self):
        existing = self.lab/'.local/demos/existing-session'
        existing.mkdir(parents=True)
        (existing/'session.json').write_text('{"complete":false}')
        result = self.run_demo('--scenario','failure','--count','1')
        self.assertNotEqual(result.returncode, 0)
        output = result.stdout+result.stderr
        self.assertIn('Unfinished session', output)
        self.assertIn('Resume: bash scripts/demo.sh --resume existing-session', output)
        self.assertEqual(len(list((self.lab/'.local/demos').glob('*/session.json'))), 1)
        self.assertEqual(json.loads((self.root/'api.json').read_text())['prs'], [])

    def test_editing_entry_file_during_run_does_not_reexecute_it(self):
        result = self.run_demo('--scenario','happy','--count','1',
                               DEMO_MUTATE_ENTRY=str(self.lab/'scripts/demo.sh'))
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        session = next((self.lab/'.local/demos').glob('*/session.json')).parent
        self.assertTrue(json.loads((session/'session.json').read_text())['complete'])
        self.assertEqual(len(json.loads((self.root/'api.json').read_text())['prs']), 6)

    def test_happy_case_resumes_prod_and_releases_all_environments(self):
        result = self.run_demo('--scenario','happy','--count','1', DEMO_INTERRUPT='prod')
        self.assertNotEqual(result.returncode, 0)
        session = next((self.lab/'.local/demos').glob('*/session.json')).parent
        self.assertEqual(json.loads((session/'0001/state.json').read_text())['stage'], '3')
        resumed = self.run_demo('--resume', session.name)
        self.assertEqual(resumed.returncode, 0, resumed.stdout+resumed.stderr)
        verified = json.loads((session/'0001/prod-deployed.json').read_text())['environments']
        self.assertEqual({v['version'] for v in verified.values()}, {'v1.3.2'})
        state = json.loads((session/'0001/state.json').read_text())
        self.assertEqual(state['stage'], '7')
        self.assertNotIn('bad_merge', state)
        self.assertNotIn('prod_failed_run', state)
        data = json.loads((self.root/'api.json').read_text())
        self.assertEqual(len(data['prs']), 6)
        self.assertEqual(len(data['runs']), 3)
        self.assertTrue(all(r['conclusion'] == 'success' for r in data['runs']))
        self.assertNotIn('true', data.get('fault_values', []))

    def test_default_repeats_happy_then_failure_with_new_prod_baselines(self):
        result = self.run_demo('--count','2')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        session = next((self.lab/'.local/demos').glob('*/session.json')).parent
        self.assertEqual(json.loads((session/'session.json').read_text())['scenario'], 'all')
        previous = None
        for i, good_version, candidate in [(1,'v1.3.2','v1.3.3'), (2,'v1.3.4','v1.3.5')]:
            slot = f'{i:04d}'
            happy = json.loads((session/f'{slot}-happy/prod-deployed.json').read_text())['environments']
            baseline = json.loads((session/f'{slot}-failure/baseline.json').read_text())['environments']
            rollback = json.loads((session/f'{slot}-failure/rollback-verified.json').read_text())['environments']
            self.assertEqual(baseline['prod'], happy['prod'])
            self.assertEqual(rollback['prod']['image'], happy['prod']['image'])
            self.assertEqual(rollback['prod']['version'], good_version)
            self.assertEqual(rollback['dev']['version'], candidate)
            self.assertEqual(rollback['staging']['version'], candidate)
            if previous:
                before = json.loads((session/f'{slot}-happy/baseline.json').read_text())['environments']
                self.assertEqual(before, previous)
            previous = rollback
        data = json.loads((self.root/'api.json').read_text())
        self.assertEqual(len(data['prs']), 28)
        self.assertEqual(len(data['runs']), 14)
        resumed = self.run_demo('--resume', session.name)
        self.assertEqual(resumed.returncode, 0, resumed.stdout+resumed.stderr)
        self.assertEqual(json.loads((self.root/'api.json').read_text())['prs'], data['prs'])

    def test_two_complete_cycles_and_completed_resume_do_not_duplicate_prs(self):
        result = self.run_demo('--scenario','failure','--count','2')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        sessions = list((self.lab/'.local/demos').glob('*/session.json'))
        self.assertEqual(len(sessions), 1)
        session = sessions[0].parent
        self.assertTrue(json.loads(sessions[0].read_text())['complete'])
        for i, version in [(1,'v1.3.2'), (2,'v1.3.3')]:
            cycle = session/f'{i:04d}'
            state = json.loads((cycle/'state.json').read_text())
            self.assertEqual(state['stage'], '7')
            self.assertEqual(state['version'], version)
            verified = json.loads((cycle/'rollback-verified.json').read_text())['environments']
            self.assertEqual(verified['dev']['version'], version)
            self.assertEqual(verified['staging']['version'], version)
            self.assertEqual(verified['prod']['version'], 'v1.3.1')
            self.assertTrue((cycle/'prod-degraded.json').exists())
        data = json.loads((self.root/'api.json').read_text())
        self.assertEqual(len(data['prs']), 16)
        self.assertEqual(len(data['runs']), 8)
        self.assertEqual(data['variables']['DEMO_FAIL_PROD_BUILD'], 'false')
        resumed = self.run_demo('--resume', session.name)
        self.assertEqual(resumed.returncode, 0, resumed.stdout+resumed.stderr)
        self.assertEqual(json.loads((self.root/'api.json').read_text())['prs'], data['prs'])

    def test_dispatch_response_loss_resumes_without_duplicate_build(self):
        result = self.run_demo('--scenario','failure','--count','1', DEMO_INTERRUPT='dispatch')
        self.assertNotEqual(result.returncode, 0)
        session = next((self.lab/'.local/demos').glob('*/session.json')).parent
        self.assertEqual(json.loads((session/'0001/state.json').read_text())['stage'], '4')
        resumed = self.run_demo('--resume', session.name)
        self.assertEqual(resumed.returncode, 0, resumed.stdout+resumed.stderr)
        data = json.loads((self.root/'api.json').read_text())
        self.assertEqual(len(data['runs']), 4)
        self.assertEqual(len(data['prs']), 8)

    def test_rollout_interruption_resumes_then_reverts_exact_merge(self):
        result = self.run_demo('--scenario','failure','--count','1', DEMO_INTERRUPT='rollout')
        self.assertNotEqual(result.returncode, 0)
        session = next((self.lab/'.local/demos').glob('*/session.json')).parent
        self.assertEqual(json.loads((session/'0001/state.json').read_text())['stage'], '5')
        resumed = self.run_demo('--resume', session.name)
        self.assertEqual(resumed.returncode, 0, resumed.stdout+resumed.stderr)
        data = json.loads((self.root/'api.json').read_text())
        self.assertEqual(len(data['prs']), 8)
        self.assertEqual(data['variables']['DEMO_FAIL_PROD_BUILD'], 'false')

    def test_interruption_at_staging_resumes_existing_pr(self):
        result = self.run_demo('--scenario','failure','--count','1', DEMO_INTERRUPT='stg')
        self.assertNotEqual(result.returncode, 0)
        session = next((self.lab/'.local/demos').glob('*/session.json')).parent
        state = json.loads((session/'0001/state.json').read_text())
        self.assertEqual(state['stage'], '2')
        resumed = self.run_demo('--resume', session.name)
        self.assertEqual(resumed.returncode, 0, resumed.stdout+resumed.stderr)
        data = json.loads((self.root/'api.json').read_text())
        self.assertEqual(len(data['prs']), 8)
        self.assertEqual(len(data['runs']), 4)


if __name__ == '__main__':
    unittest.main()
