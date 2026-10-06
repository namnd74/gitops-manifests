#!/usr/bin/env python3
"""Local GitHub/cluster simulator for the demo runner's integration test."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ['DEMO_FIXTURE'])
store = root/'api.json'
data = json.loads(store.read_text())
args = sys.argv[1:]
command = Path(sys.argv[0]).name


def git(repo, *argv):
    return subprocess.check_output(['git', '-C', str(root/repo), *argv], text=True).strip()


def option(name, default=None):
    return args[args.index(name)+1] if name in args else default


def name():
    return option('--repo', 'fixture/backend').split('/')[-1]


def sha(repo, branch):
    return git(repo, 'rev-parse', branch)


def version(commit):
    return git('backend', 'show', commit+':VERSION')


def emit(value):
    query = option('--jq')
    if query:
        result = subprocess.run(['jq', '-r', query], input=json.dumps(value), text=True,
                                capture_output=True, check=True)
        print(result.stdout.strip())
    elif isinstance(value, str):
        print(value)
    else:
        print(json.dumps(value))


def worker(repo):
    work = root/('work-'+repo)
    if not work.exists():
        subprocess.run(['git', 'clone', '-q', str(root/repo), str(work)], check=True)
        for key, value in [('user.name', 'Fixture'), ('user.email', 'fixture@example.invalid'), ('commit.gpgsign', 'false')]:
            subprocess.run(['git', '-C', str(work), 'config', key, value], check=True)
    subprocess.run(['git', '-C', str(work), 'fetch', '-q', 'origin'], check=True)
    return work


def workgit(work, *argv):
    subprocess.run(['git', '-C', str(work), *argv], check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)


def create_pr(repo, base, head, title):
    number = len(data['prs'])+1
    pr = dict(number=number, repo=repo, baseRefName=base, headRefName=head, title=title,
              state='OPEN', headRefOid=sha(repo, head), mergeCommit=None,
              url=f'https://github.com/fixture/{repo}/pull/{number}')
    data['prs'].append(pr)
    git(repo, 'update-ref', f'refs/pull/{number}/head', pr['headRefOid'])
    return pr


def make_run(branch, commit, event):
    failed = branch == 'prod' and data['variables'].get('DEMO_FAIL_PROD_BUILD') == 'true'
    run_id = len(data['runs'])+1
    jobs = [dict(name='Test, race, vet, and format', conclusion='success'),
            dict(name='Build once and security gate', conclusion='failure' if failed else 'success',
                 steps=[dict(name='Build the single local image', conclusion='failure' if failed else 'success')]),
            dict(name='Publish immutable image and release metadata', conclusion='skipped' if failed else 'success'),
            dict(name='Propose image update', conclusion='skipped' if failed else 'success')]
    data['runs'].append(dict(databaseId=run_id, headSha=commit, event=event, headBranch=branch,
                            status='completed', conclusion='failure' if failed else 'success', jobs=jobs,
                            url=f'https://github.com/fixture/backend/actions/runs/{run_id}'))
    if not failed:
        digest = 'sha256:'+hashlib.sha256(commit.encode()).hexdigest()
        image = 'ghcr.io/fixture/backend@'+digest
        data['artifacts'][str(run_id)] = dict(image='ghcr.io/fixture/backend', digest=digest,
            source_sha=commit, version=version(commit), source_run_url=f'https://github.com/fixture/backend/actions/runs/{run_id}')
        data['images'][image] = dict(version=version(commit), source_sha=commit)
        work = worker('manifests')
        head = 'release-be-service-'+branch
        workgit(work, 'checkout', '-B', head, 'origin/'+branch)
        subprocess.run(['kustomize', 'edit', 'set', 'image', 'ghcr.io/example/be-service='+image],
                       cwd=work/'apps/be-service/base', check=True)
        workgit(work, 'add', 'apps'); workgit(work, 'commit', '-qm', 'ci: '+commit)
        # Simulates the CI bot's own reusable image branch; runner never force-pushes.
        workgit(work, 'push', '-q', '--force', 'origin', head)
        create_pr('manifests', branch, head, 'release('+branch+'): '+version(commit))


def rendered(env):
    branch = 'stg' if env == 'staging' else env
    base = git('manifests', 'show', branch+':apps/be-service/base/kustomization.yaml')
    image = subprocess.check_output(['yq', '-r', '.images[0].newName + "@" + .images[0].digest'],
                                    input=base, text=True).strip()
    patch = git('manifests', 'show', branch+':apps/be-service/envs/'+env+'/deployment-env-patch.yaml')
    fault = '8081' in patch
    return branch, image, fault


if command == 'gh':
    if args[:2] == ['auth', 'status']:
        pass
    elif args[0] == 'api':
        if args[1] == 'user':
            emit(dict(login='fixture', id=42))
        else:
            parts = args[1].split('/')
            emit(dict(commit=dict(sha=sha(parts[2], parts[-1]))))
    elif args[:2] == ['secret', 'list']:
        emit([dict(name='CONFIG_REPO_PAT')])
    elif args[:2] == ['variable', 'get']:
        defaults = dict(ENABLE_GITOPS_RELEASE='true', CONFIG_REPO='fixture/manifests', SOURCE_REPO='fixture/backend', IMAGE='ghcr.io/fixture/backend')
        emit(data['variables'].get(args[2], defaults.get(args[2], 'false')))
    elif args[:2] == ['variable', 'list']:
        emit([dict(name=k, value=v) for k, v in data['variables'].items()])
    elif args[:2] == ['variable', 'set']:
        data['variables'][args[2]] = option('--body')
    elif args[:2] == ['pr', 'list']:
        rows = [p for p in data['prs'] if p['repo'] == name()]
        for flag, key in [('--base', 'baseRefName'), ('--head', 'headRefName')]:
            if option(flag):
                rows = [p for p in rows if p[key] == option(flag)]
        state = option('--state', 'open')
        if state != 'all':
            rows = [p for p in rows if p['state'].lower() == state]
        emit(rows)
    elif args[:2] == ['pr', 'create']:
        emit(create_pr(name(), option('--base'), option('--head'), option('--title'))['url'])
    elif args[0] == 'pr':
        pr = next(p for p in data['prs'] if p['number'] == int(args[2]))
        if args[1] == 'view':
            emit(pr)
        elif args[1] == 'checks':
            if os.environ.get('DEMO_INTERRUPT') == pr['baseRefName'] and pr['repo'] == 'backend' and not data.get('interrupted'):
                data['interrupted'] = True; store.write_text(json.dumps(data)); sys.exit(7)
            if pr['repo'] == 'backend':
                emit([dict(bucket='pass', name='Test, race, vet, and format'),
                      dict(bucket='pass', name='Build once and security gate'),
                      dict(bucket='skipping', name='Publish immutable image and release metadata'),
                      dict(bucket='skipping', name='Propose image update')])
            else:
                emit([dict(bucket='pass', name='validate', link=pr['url'])])
        elif args[1] == 'close':
            pr['state'] = 'CLOSED'
        elif args[1] == 'diff':
            emit(git(pr['repo'], 'diff', '--name-only', pr['baseRefName'], pr['headRefName']))
        elif args[1] == 'merge':
            assert option('--match-head-commit') == pr['headRefOid']
            work = worker(pr['repo'])
            workgit(work, 'checkout', '-B', pr['baseRefName'], 'origin/'+pr['baseRefName'])
            workgit(work, 'merge', '--no-ff', '-m', pr['title'], 'origin/'+pr['headRefName'])
            workgit(work, 'push', '-q', 'origin', pr['baseRefName'])
            pr['state'] = 'MERGED'; pr['mergeCommit'] = dict(oid=sha(pr['repo'], pr['baseRefName']))
            if pr['repo'] == 'backend':
                make_run(pr['baseRefName'], pr['mergeCommit']['oid'], 'push')
    elif args[:2] == ['run', 'list']:
        emit([r for r in data['runs'] if (not option('--branch') or r['headBranch'] == option('--branch')) and (not option('--commit') or r['headSha'] == option('--commit')) and (not option('--event') or r['event'] == option('--event'))])
    elif args[:2] == ['run', 'view'] and '--log-failed' in args:
        print('#8 0.123 SEMINAR: intentional prod build failure')
    elif args[:2] == ['run', 'view']:
        emit(next(r for r in data['runs'] if r['databaseId'] == int(args[2])))
    elif args[:2] == ['run', 'download']:
        (Path(option('--dir'))/'release.json').write_text(json.dumps(data['artifacts'][args[2]]))
    elif args[:2] == ['workflow', 'run']:
        make_run('prod', sha('backend', 'prod'), 'workflow_dispatch')
        if os.environ.get('DEMO_INTERRUPT') == 'dispatch' and not data.get('interrupted'):
            data['interrupted'] = True; store.write_text(json.dumps(data)); sys.exit(7)
    else:
        raise AssertionError(args)
elif command == 'kubectl':
    env = option('-n')
    if 'annotate' not in args:
        kind = args[args.index('get')+1]
        if kind == 'application':
            env = args[args.index('get')+2].removeprefix('be-service-')
        branch, image, fault = rendered(env)
        if fault and os.environ.get('DEMO_INTERRUPT') == 'rollout' and not data.get('interrupted'):
            data['interrupted'] = True; store.write_text(json.dumps(data)); sys.exit(7)
        if kind == 'application':
            emit(dict(status=dict(sync=dict(status='Synced', revision=sha('manifests', branch)),
                                  health=dict(status='Degraded' if fault else 'Healthy'))))
        elif kind == 'deployment':
            emit(dict(metadata=dict(annotations={'seminar.gitops.io/scenario':'prod-readiness-failure'} if fault else {}),
                spec=dict(template=dict(spec=dict(containers=[dict(image=image,
                     readinessProbe=dict(httpGet=dict(port=8081 if fault else 8080)),
                     livenessProbe=dict(httpGet=dict(port=8080)))]))),
                status=dict(conditions=[dict(type='Progressing', status='False', reason='ProgressDeadlineExceeded')] if fault else [])))
        elif kind == 'pods':
            old = data['baseline_prod']
            def pod(ref, ready):
                return dict(metadata={}, spec=dict(containers=[dict(image=ref)]),
                            status=dict(phase='Running', containerStatuses=[dict(ready=ready, restartCount=0)]))
            emit(dict(items=[pod(old, True) for _ in range(3)]+[pod(image, False)]))
elif command == 'curl':
    emit(dict(version=data['images'][data['baseline_prod']]['version'], git_commit=data['images'][data['baseline_prod']]['source_sha']))
elif command == 'check-fixture':
    envs = {}
    for env in ['dev', 'staging', 'prod']:
        branch, image, fault = rendered(env)
        assert not fault, 'check cannot pass during readiness fault'
        envs[env] = dict(branch=branch, image=image, revision=sha('manifests', branch), **data['images'][image])
    state = Path(os.environ['STATE_DIR'])
    (state/'release.json').write_text(json.dumps(dict(environments=envs)))
else:
    raise AssertionError(command)
store.write_text(json.dumps(data))
