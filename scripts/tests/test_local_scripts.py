"""Exercise the Bash local lab using real Git/Kustomize and isolated CLI fixtures."""
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class LocalScriptsTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name).resolve()
        shutil.copytree(ROOT/'scripts', self.root/'scripts')
        shutil.copytree(ROOT/'apps', self.root/'apps')
        self.bin = self.root/'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'])
        for key in ('CLUSTER_NAME', 'HTTP_PORT', 'HTTPS_PORT', 'BE_SOURCE_DIR', 'STATE_DIR','SOURCE_REPO','CONFIG_REPO_URL'):
            self.env.pop(key, None)
        self.fixture('python3', 'echo PYTHON_RUNTIME_CALLED >&2\nexit 99\n')
        subprocess.run(['git','init','-q',str(self.root)],check=True)
        subprocess.run(['git','-C',str(self.root),'remote','add','origin','https://github.com/example/gitops-manifests.git'],check=True)

    def fixture(self, name, body):
        path = self.bin/name
        path.write_text('#!/bin/bash\nset -e\n'+body)
        path.chmod(0o755)

    def run_script(self, name, *args, **env):
        return subprocess.run(['bash', str(self.root/'scripts'/name), *args],
                              cwd='/tmp', env=dict(self.env, **env), capture_output=True,
                              text=True, timeout=20)

    def config(self, **env):
        return subprocess.run(['bash', '-c', 'source "$1"; load_config; config_json', 'bash',
                               str(self.root/'scripts/local-common.sh')],
                              cwd='/tmp', env=dict(self.env, **env), capture_output=True,
                              text=True, timeout=10)

    def test_help_for_each_step_needs_no_docker_or_python(self):
        self.fixture('docker', 'echo DOCKER_CALLED >&2\nexit 99\n')
        for script in ('setup.sh', 'build.sh', 'render.sh', 'deploy.sh', 'check.sh'):
            with self.subTest(script=script):
                result = self.run_script(script, '--help')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Usage:', result.stdout)
                self.assertNotIn('CALLED', result.stderr)
                result = self.run_script(script, '--bad')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Unknown option', result.stderr)

    def test_config_is_relative_to_repo_and_process_env_wins(self):
        (self.root/'.env.local').write_text('HTTP_PORT=8099\nBE_SOURCE_DIR=../backend\n')
        result = self.config(HTTP_PORT='8100')
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout)
        self.assertEqual(config['HTTP_PORT'], '8100')
        self.assertEqual(config['BE_SOURCE_DIR'], str(self.root.parent/'backend'))
        self.assertEqual(config['STATE_DIR'], str(self.root/'.local'))

    def test_config_rejects_invalid_ports_state_and_does_not_eval_shell(self):
        for env in ({'HTTP_PORT': '0'}, {'HTTP_PORT': '8443'}, {'STATE_DIR': '../elsewhere'},
                    {'STATE_DIR': '.local/../apps'}, {'CLUSTER_NAME': 'Bad Name'}):
            with self.subTest(env=env):
                self.assertNotEqual(self.config(**env).returncode, 0)
        marker = self.root/'executed'
        (self.root/'.env.local').write_text(f'CLUSTER_NAME=$(touch {marker})\n')
        self.assertNotEqual(self.config().returncode, 0)
        self.assertFalse(marker.exists())

    def test_state_symlink_cannot_redirect_generated_files(self):
        (self.root/'.local').symlink_to(self.root/'apps', target_is_directory=True)
        self.assertNotEqual(self.config().returncode, 0)

    def test_render_creates_github_applications_and_cluster_secrets_without_local_git(self):
        self.fixture('kubeseal', """case " $* " in
  *' --fetch-cert '*) echo PUBLIC_CERT ;;
  *' --validate '*) cat >/dev/null ;;
  *) jq '{apiVersion:"bitnami.com/v1alpha1",kind:"SealedSecret",metadata:.metadata,
          spec:{encryptedData:{DB_PASSWORD:"cipher-fixture"},template:{metadata:.metadata,type:"Opaque"}}}' ;;
esac
""")
        before = {str(p.relative_to(self.root)):p.read_bytes() for p in (self.root/'apps').rglob('*.yaml')}
        cached = {}
        for attempt in range(2):
            result = self.run_script('render.sh')
            self.assertEqual(result.returncode, 0, result.stderr)
            for env in ('dev','staging','prod'):
                app = subprocess.check_output(['yq','-o=json','.',str(self.root/f'.local/bootstrap/applications/be-service-{env}.yaml')],text=True)
                source = json.loads(app)['spec']['source']
                self.assertEqual(source['repoURL'], 'https://github.com/example/gitops-manifests.git')
                self.assertEqual(source['targetRevision'], 'stg' if env == 'staging' else env)
                self.assertEqual(source['path'], f'apps/be-service/envs/{env}')
                secret = self.root/f'.local/bootstrap/secrets/{env}-sealed.yaml'
                self.assertTrue(secret.exists())
                if attempt == 0:
                    cached[env] = secret.read_bytes()
                else:
                    self.assertEqual(cached[env], secret.read_bytes())
        after = {str(p.relative_to(self.root)):p.read_bytes() for p in (self.root/'apps').rglob('*.yaml')}
        self.assertEqual(before, after)
        self.assertFalse((self.root/'.local/git/config.git').exists())

    def test_deploy_configures_github_source_without_a_git_server(self):
        self.fixture('kubeseal', """case " $* " in
  *' --fetch-cert '*) echo PUBLIC_CERT ;;
  *' --validate '*) cat >/dev/null ;;
  *) jq '{kind:"SealedSecret",metadata:.metadata,spec:{encryptedData:{DB_PASSWORD:"cipher"}}}' ;;
esac
""")
        self.assertEqual(self.run_script('render.sh').returncode, 0)
        calls = self.root/'calls'
        self.fixture('kubectl', f'echo "$*" >> "{calls}"\n')
        result = self.run_script('deploy.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        invoked=calls.read_text()
        self.assertNotIn('gitops-system', invoked)
        for env in ('dev','staging','prod'):
            self.assertIn(f'bootstrap/secrets/{env}-sealed.yaml', invoked)
            self.assertIn(f'bootstrap/applications/be-service-{env}.yaml', invoked)
        self.assertIn('argocd.argoproj.io/tracking-id-', invoked)
        self.assertIn('wait --for=condition=Synced sealedsecret/be-service-secret', invoked)

    def test_build_configures_release_variables_and_dispatches_github_ci(self):
        calls = self.root/'gh-calls'
        self.fixture('docker', 'echo aarch64\n')
        self.fixture('gh', f'echo "$*" >> "{calls}"\n'+"""if [[ "$1 $2" == 'secret list' ]]; then
  if [[ "${MISSING_SECRET:-}" == 1 ]]; then echo '[]'; else echo '[{"name":"CONFIG_REPO_PAT"}]'; fi
fi
""")
        result=self.run_script('build.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        invoked=calls.read_text()
        self.assertIn('variable set ENABLE_GITOPS_RELEASE --repo example/be-service --body true',invoked)
        self.assertIn('variable set IMAGE_ARCH --repo example/be-service --body arm64',invoked)
        self.assertIn('workflow run ci.yaml --repo example/be-service --ref dev',invoked)
        calls.unlink()
        result=self.run_script('build.sh',MISSING_SECRET='1')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('variable set',calls.read_text())
        self.assertNotIn('workflow run',calls.read_text())

    def test_check_matches_github_digest_commit_and_rejects_wrong_runtime(self):
        digest = 'sha256:'+'a'*64
        image = 'ghcr.io/example/be-service@'+digest
        subprocess.run(['kustomize','edit','set','image','ghcr.io/example/be-service='+image],
                       cwd=self.root/'apps/be-service/base',check=True)
        for args in (['config','user.name','Fixture'],['config','user.email','fixture@example.invalid'],
                     ['config','commit.gpgsign','false'],['add','apps'],['commit','-qm','release'],['branch','-M','main']):
            subprocess.run(['git','-C',str(self.root),*args],check=True)
        revision=subprocess.check_output(['git','-C',str(self.root),'rev-parse','HEAD'],text=True).strip()
        for branch in ('dev','stg','prod'):
            subprocess.run(['git','-C',str(self.root),'branch',branch],check=True)
        real_git=shutil.which('git')
        self.fixture('git', '''
if [[ " $* " == *' clone '* ]]; then
  branch=''
  for ((i=1;i<=$#;i++)); do if [[ "${!i}" == --branch ]]; then j=$((i+1)); branch=${!j}; fi; done
  exec "$REAL_GIT" clone --quiet --branch "$branch" "$FIXTURE_REPO" "${!#}"
fi
exec "$REAL_GIT" "$@"
''')
        self.fixture('docker', '''
if [[ "$1" == buildx ]]; then
  jq -n '{config:{Labels:{"org.opencontainers.image.version":"v1.3.1","org.opencontainers.image.revision":("b"*40)}}}'
else
  jq -n '{status:{id:("sha256:"+("d"*64)),repoDigests:[("ghcr.io/example/be-service@sha256:"+("a"*64))]}}'
fi
''')
        self.fixture('kubectl', '''
namespace=''
while (($#)); do
  case "$1" in
    -n) namespace=$2; shift 2 ;;
    annotate) exit 0 ;;
    get) kind=$2; if [[ "$kind" == application ]]; then namespace=${3#be-service-}; fi; break ;;
    *) shift ;;
  esac
done
case "$kind" in
application) jq -n --arg env "$namespace" --arg revision "$REVISION" '{spec:{source:{repoURL:"https://github.com/example/gitops-manifests.git",targetRevision:(if $env == "staging" then "stg" else $env end),path:("apps/be-service/envs/"+$env)},destination:{namespace:$env}},status:{sync:{status:"Synced",revision:$revision},health:{status:"Healthy"}}}' ;;
deployment) jq -n --arg env "$namespace" '{spec:{replicas:({dev:1,staging:2,prod:3}[$env]),template:{spec:{containers:[{image:("ghcr.io/example/be-service@sha256:"+("a"*64))}]}}}}' ;;
pods) jq -n --arg env "$namespace" --arg id "${POD_ID:-d}" '{items:[range({dev:1,staging:2,prod:3}[$env]) | {metadata:{},spec:{nodeName:"node-1",containers:[{image:("ghcr.io/example/be-service@sha256:"+("a"*64))}]},status:{containerStatuses:[{ready:true,imageID:("containerd://sha256:"+($id*64))}]}}]}' ;;
esac
''')
        self.fixture('curl', '''
if [[ "$*" == *'/version'* ]]; then
  while (($#)); do if [[ "$1" == -H ]]; then host=$2; break; fi; shift; done
  host=${host#Host: }; env=${host%%.*}
  jq -n --arg env "$env" '{env:$env,version:"v1.3.1",git_commit:("b"*40)}'
else echo OK; fi
''')
        self.env.update(REAL_GIT=real_git,FIXTURE_REPO=str(self.root),REVISION=revision)
        result=self.run_script('check.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        for env in ('dev','staging','prod'):
            self.assertIn('[PASS] '+env,result.stdout)
        release=json.loads((self.root/'.local/release.json').read_text())
        self.assertEqual(release['environments']['dev']['image'],image)
        self.assertEqual(release['environments']['dev']['revision'],revision)
        self.assertEqual(release['environments']['dev']['source_sha'],'b'*40)
        result=self.run_script('check.sh',POD_ID='c')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('runtime image content mismatch',result.stderr)

    def test_up_stops_after_failed_step(self):
        calls = self.root/'calls'
        for step in ('setup','build','render','deploy','check'):
            body = f'echo {step} >> "{calls}"\n'
            if step == 'render':
                body += 'exit 7\n'
            (self.root/f'scripts/{step}.sh').write_text('#!/bin/bash\n'+body)
        result = self.run_script('local-dev.sh', 'up')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(calls.read_text().splitlines(), ['setup','render'])


if __name__ == '__main__':
    unittest.main()
