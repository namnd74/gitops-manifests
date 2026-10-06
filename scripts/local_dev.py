#!/usr/bin/env python3
"""Build and reconcile a disposable, credential-free local GitOps lab."""
import argparse
import json
import os
import pathlib
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENVS = ('dev', 'staging', 'prod')


def run(args, *, cwd=None, input=None, capture=False, env=None):
    result = subprocess.run([str(a) for a in args], cwd=cwd, input=input, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            check=True, env=env)
    return result.stdout.strip() if capture else ''


def load_config(root=ROOT, environ=None):
    environ = os.environ if environ is None else environ
    values = {'CLUSTER_NAME': 'gitops-local', 'HTTP_PORT': '8088', 'HTTPS_PORT': '8443',
              'BE_SOURCE_DIR': '../be-service', 'STATE_DIR': '.local'}
    path = root / '.env.local'
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            key, separator, value = line.partition('=')
            if not separator or key.strip() not in values:
                raise ValueError(f'Unknown local configuration: {key}')
            values[key.strip()] = value.strip().strip('"\'')
    for key in values:
        values[key] = environ.get(key, values[key])
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,40}', values['CLUSTER_NAME']):
        raise ValueError('CLUSTER_NAME must be a lowercase DNS label')
    for key in ('HTTP_PORT', 'HTTPS_PORT'):
        if not values[key].isdigit() or not 1 <= int(values[key]) <= 65535:
            raise ValueError(f'Invalid {key}')
    if int(values['HTTP_PORT']) == int(values['HTTPS_PORT']):
        raise ValueError('HTTP_PORT and HTTPS_PORT must differ')
    for key in ('BE_SOURCE_DIR', 'STATE_DIR'):
        values[key] = str((root / values[key]).resolve())
    state = pathlib.Path(values['STATE_DIR'])
    allowed = (root / '.local').resolve()
    if state != allowed and allowed not in state.parents:
        raise ValueError('STATE_DIR must be .local or a directory inside .local')
    return values


def image_arch(architecture):
    aliases = {'aarch64': 'arm64', 'arm64': 'arm64', 'x86_64': 'amd64', 'amd64': 'amd64'}
    if architecture not in aliases:
        raise ValueError(f'Unsupported Docker architecture: {architecture}')
    return aliases[architecture]


def content_id(reference):
    match = re.search(r'(sha256:[0-9a-f]{64})$', reference)
    if not match:
        raise ValueError('Runtime image identity is not a SHA256 content identifier')
    return match.group(1)


def runtime_identities(status):
    return sorted({content_id(value) for value in
                   [status['id'], *status.get('repoDigests', [])]})


def imported_identities(config, image):
    nodes = json.loads(kubectl(config, 'get', 'nodes', '-o', 'json', capture=True))['items']
    identities = {}
    for node in nodes:
        name = node['metadata']['name']
        metadata = json.loads(run(['docker', 'exec', name, 'crictl',
                                   'inspecti', '-o', 'json', image], capture=True))
        identities[name] = runtime_identities(metadata['status'])
    if not identities:
        raise ValueError('No Kubernetes nodes found for imported image verification')
    return identities


def application(environment):
    if environment not in ENVS:
        raise ValueError('Unknown environment')
    return {'apiVersion': 'argoproj.io/v1alpha1', 'kind': 'Application',
            'metadata': {'name': f'be-service-{environment}', 'namespace': 'argocd'},
            'spec': {'project': 'default', 'source': {
                'repoURL': 'git://gitops-source.gitops-system.svc.cluster.local/config.git',
                'targetRevision': 'main', 'path': f'apps/be-service/envs/{environment}'},
                'destination': {'server': 'https://kubernetes.default.svc', 'namespace': environment},
                'syncPolicy': {'automated': {'prune': True, 'selfHeal': True},
                               'syncOptions': ['CreateNamespace=true']}}}


def publish_snapshot(source, bare):
    # Only manifest files belong in the served repository; never key/password files.
    for path in source.rglob('*'):
        if not path.is_file() or '.git' in path.relative_to(source).parts:
            continue
        if path.suffix not in ('.yaml', '.json'):
            raise ValueError(f'Non-manifest file in Git snapshot: {path.name}')
        content = path.read_text()
        if re.search(r"^\s*kind:\s*['\"]?Secret['\"]?\s*(?:#.*)?$", content, re.M) or re.search(r'"kind"\s*:\s*"Secret"', content):
            raise ValueError('Plaintext Secret is not allowed in Git')
    if not (source / '.git').exists():
        run(['git', 'init', '-b', 'main', source], capture=True)
    run(['git', 'add', '-A'], cwd=source)
    if run(['git', 'status', '--porcelain'], cwd=source, capture=True):
        run(['git', '-c', 'user.name=Local GitOps', '-c', 'user.email=local@localhost',
             '-c', 'commit.gpgsign=false', 'commit', '-m', 'Update local manifests'],
            cwd=source, capture=True)
    if not bare.exists():
        run(['git', 'init', '--bare', '--initial-branch=main', bare], capture=True)
    run(['git', 'push', str(bare), 'main'], cwd=source, capture=True)
    return run(['git', 'rev-parse', 'HEAD'], cwd=source, capture=True)


def kubectl(config, *args, **kwargs):
    return run(['kubectl', '--context', f"k3d-{config['CLUSTER_NAME']}",
                '--request-timeout=30s', *args], **kwargs)


def apply(config, obj):
    kubectl(config, 'apply', '-f', '-', input=json.dumps(obj))


def git_server(config, image):
    apply(config, {'apiVersion': 'v1', 'kind': 'Namespace',
                   'metadata': {'name': 'gitops-system'}})
    apply(config, {'apiVersion': 'v1', 'kind': 'Service',
                   'metadata': {'name': 'gitops-source', 'namespace': 'gitops-system'},
                   'spec': {'selector': {'app': 'gitops-source'},
                            'ports': [{'port': 9418, 'targetPort': 9418}]}})
    apply(config, {'apiVersion': 'apps/v1', 'kind': 'Deployment',
          'metadata': {'name': 'gitops-source', 'namespace': 'gitops-system'},
          'spec': {'replicas': 1, 'selector': {'matchLabels': {'app': 'gitops-source'}},
                   'template': {'metadata': {'labels': {'app': 'gitops-source'}},
                   'spec': {'nodeSelector': {'kubernetes.io/hostname':
                            f"k3d-{config['CLUSTER_NAME']}-server-0"},
                            'containers': [{'name': 'git', 'image': image,
                                'command': ['git', '-c', 'safe.directory=/git/config.git',
                                    'daemon', '--reuseaddr', '--export-all', '--base-path=/git',
                                    '--listen=0.0.0.0', '--port=9418', '/git'],
                                'readinessProbe': {'tcpSocket': {'port': 9418}},
                                'securityContext': {'readOnlyRootFilesystem': True,
                                    'allowPrivilegeEscalation': False,
                                    'capabilities': {'drop': ['ALL']}},
                                'volumeMounts': [{'name': 'git', 'mountPath': '/git', 'readOnly': True}]}],
                            'volumes': [{'name': 'git', 'hostPath': {'path': '/gitops-source',
                                                                    'type': 'Directory'}}]}}}})
    kubectl(config, '-n', 'gitops-system', 'rollout', 'status', 'deployment/gitops-source', '--timeout=120s')


def prepare_manifests(config, image):
    state = pathlib.Path(config['STATE_DIR'])
    rendered = state / 'rendered'
    rendered.mkdir(parents=True, exist_ok=True)
    destination = rendered / 'apps'
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(ROOT / 'apps', destination)
    # The base image name is a template; substitute its rendered mapping locally.
    base = rendered / 'apps/be-service/base'
    original = run(['yq', '-r', '.images[0].name', base / 'kustomization.yaml'], capture=True)
    run(['kustomize', 'edit', 'set', 'image', f'{original}={image}'], cwd=base)
    public_cert = state / 'controller-cert.pem'
    public_cert.write_text(run(['kubeseal', '--context', f"k3d-{config['CLUSTER_NAME']}",
                               '--fetch-cert'], capture=True) + '\n')
    # Private key is never extracted. Passwords only cross stdin into kubeseal.
    for environment in ENVS:
        secret = {'apiVersion': 'v1', 'kind': 'Secret',
                  'metadata': {'name': 'be-service-secret', 'namespace': environment},
                  'type': 'Opaque', 'stringData': {'DB_PASSWORD': secrets.token_hex(24)}}
        sealed = run(['kubeseal', '--cert', public_cert, '--scope', 'strict', '--format', 'yaml'],
                     input=json.dumps(secret), capture=True)
        target = rendered / f'apps/be-service/envs/{environment}/sealed-secret.yaml'
        # Reuse controller-valid ciphertext across up runs, so a no-op does not rotate passwords.
        cached = state / f'{environment}-sealed.yaml'
        valid = cached.exists() and subprocess.run(
            ['kubeseal', '--context', f"k3d-{config['CLUSTER_NAME']}", '--validate'],
            input=cached.read_text(), text=True, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL).returncode == 0
        if not valid:
            cached.write_text(sealed + '\n')
        shutil.copyfile(cached, target)
        run(['kustomize', 'edit', 'add', 'resource', 'sealed-secret.yaml'], cwd=target.parent)
        app = application(environment)
        app_dir = rendered / 'argocd/applications'
        app_dir.mkdir(parents=True, exist_ok=True)
        (app_dir / f'be-service-{environment}.json').write_text(json.dumps(app, indent=2))
        run(['kustomize', 'build', target.parent], capture=True)
    return publish_snapshot(rendered, state / 'git/config.git')


def up(config):
    for tool in ('docker', 'git', 'k3d', 'kubectl', 'kubeseal', 'kustomize', 'yq'):
        if not shutil.which(tool):
            raise ValueError(f'Missing tool: {tool}')
    backend = pathlib.Path(config['BE_SOURCE_DIR'])
    if not (backend / 'Dockerfile').is_file():
        raise ValueError('BE_SOURCE_DIR must point to the backend checkout')
    state = pathlib.Path(config['STATE_DIR'])
    (state / 'git').mkdir(parents=True, exist_ok=True)
    settings = {key: config[key] for key in ('CLUSTER_NAME', 'HTTP_PORT', 'HTTPS_PORT', 'STATE_DIR')}
    marker = state / 'cluster-settings.json'
    clusters = json.loads(run(['k3d', 'cluster', 'list', '-o', 'json'], capture=True))
    exists = any(cluster['name'] == config['CLUSTER_NAME'] for cluster in clusters)
    if exists and (not marker.exists() or json.loads(marker.read_text()) != settings):
        raise ValueError('Existing cluster has different/unmanaged local settings; choose a new CLUSTER_NAME or delete it explicitly')
    setup_env = dict(os.environ, CLUSTER_NAME=config['CLUSTER_NAME'], HTTP_PORT=config['HTTP_PORT'],
                     HTTPS_PORT=config['HTTPS_PORT'], LOCAL_GIT_VOLUME=str(state / 'git'))
    marker.write_text(json.dumps(settings, indent=2))
    run(['bash', ROOT / 'scripts/setup-lab-k3d.sh'], env=setup_env)
    architecture = image_arch(run(['docker', 'info', '--format', '{{.Architecture}}'], capture=True))
    print(f'[BUILD] Native linux/{architecture}', flush=True)
    run(['docker', 'build', '--provenance=false', '--platform', f'linux/{architecture}', '--build-arg', 'APP_VERSION=local-dev',
         '--build-arg', 'GIT_COMMIT=local-dev', '--build-arg', 'SOURCE_URL=local://be-service',
         '-t', 'be-service:local-build', backend])
    image_id = run(['docker', 'image', 'inspect', 'be-service:local-build', '--format', '{{.Id}}'], capture=True)
    image = 'be-service:local-' + image_id.split(':')[1][:16]
    run(['docker', 'tag', 'be-service:local-build', image])
    run(['k3d', 'image', 'import', image, '-c', config['CLUSTER_NAME']])
    runtime_images = imported_identities(config, image)
    run(['docker', 'build', '--provenance=false', '--platform', f'linux/{architecture}',
         '-t', 'gitops-source:local-build', ROOT / 'scripts/local-git'])
    git_id = run(['docker', 'image', 'inspect', 'gitops-source:local-build',
                  '--format', '{{.Id}}'], capture=True)
    git_image = 'gitops-source:local-' + git_id.split(':')[1][:16]
    run(['docker', 'tag', 'gitops-source:local-build', git_image])
    run(['k3d', 'image', 'import', git_image, '-c', config['CLUSTER_NAME']])
    revision = prepare_manifests(config, image)
    git_server(config, git_image)
    for environment in ENVS:
        apply(config, application(environment))
        kubectl(config, '-n', 'argocd', 'annotate', 'application', f'be-service-{environment}',
                'argocd.argoproj.io/refresh=hard', '--overwrite')
    (state / 'release.json').write_text(json.dumps({'image': image, 'image_id': image_id,
                                                   'revision': revision, 'runtime_images': runtime_images}, indent=2))
    check(config)


def check(config):
    state = pathlib.Path(config['STATE_DIR'])
    release = json.loads((state / 'release.json').read_text())
    for environment, replicas in zip(ENVS, (1, 2, 3)):
        deadline = time.monotonic() + 180
        while True:
            app = json.loads(kubectl(config, '-n', 'argocd', 'get', 'application',
                                    f'be-service-{environment}', '-o', 'json', capture=True))
            status = app.get('status', {})
            if (status.get('sync', {}).get('status') == 'Synced' and
                    status.get('sync', {}).get('revision') == release['revision'] and
                    status.get('health', {}).get('status') == 'Healthy'):
                break
            if time.monotonic() >= deadline:
                raise ValueError(f'{environment}: Argo reconciliation timeout; inspect Application conditions')
            time.sleep(3)
        source = app['spec']['source']
        assert source == application(environment)['spec']['source'], 'Argo source/branch/overlay differs'
        deployment = json.loads(kubectl(config, '-n', environment, 'get', 'deployment', 'be-service',
                                        '-o', 'json', capture=True))
        assert deployment['spec']['replicas'] == replicas, 'Wrong desired replicas'
        pods = json.loads(kubectl(config, '-n', environment, 'get', 'pods', '-l', 'app=be-service',
                                 '-o', 'json', capture=True))['items']
        pods = [p for p in pods if not p['metadata'].get('deletionTimestamp')]
        assert len(pods) == replicas, 'Rollout has not converged to desired replica count'
        for pod in pods:
            container = pod['status']['containerStatuses'][0]
            assert container['ready'] and pod['spec']['containers'][0]['image'] == release['image'], 'Wrong image/readiness'
            assert content_id(container['imageID']) in release['runtime_images'][pod['spec']['nodeName']], 'Runtime image content differs from imported artifact'
        host = f'{environment}.127.0.0.1.nip.io'
        for endpoint in ('healthz', 'version'):
            request = urllib.request.Request(f"http://127.0.0.1:{config['HTTP_PORT']}/{endpoint}",
                                             headers={'Host': host})
            with urllib.request.urlopen(request, timeout=10) as response:
                assert response.status == 200
                if endpoint == 'version':
                    version = json.load(response)
                    assert version['env'] == environment and version['version'] == 'local-dev'
        print(f'[PASS] {environment}: main revision, Argo health, image identity, replicas and HTTP', flush=True)
    print(f"Argo CD: http://localhost:{config['HTTP_PORT']} (admin)")
    for environment in ENVS:
        print(f"{environment}: http://{environment}.127.0.0.1.nip.io:{config['HTTP_PORT']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('up', 'check', 'status', 'down'))
    args = parser.parse_args()
    config = load_config()
    if args.command == 'up':
        up(config)
    elif args.command == 'check':
        check(config)
    elif args.command == 'status':
        kubectl(config, '-n', 'argocd', 'get', 'applications')
    else:
        run(['k3d', 'cluster', 'delete', config['CLUSTER_NAME']])
        print('Local state retained; up validates and reseals secrets for the next cluster.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, AssertionError, subprocess.CalledProcessError, OSError) as error:
        print(f'[ERROR] {error}', file=sys.stderr)
        sys.exit(1)
