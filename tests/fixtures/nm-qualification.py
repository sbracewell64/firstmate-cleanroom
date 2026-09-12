import json, os, re, sys, hashlib

args = sys.argv[1:]
def arg(key):
    return args[args.index(key) + 1] if key in args else ''
canonical = os.environ.get('FM_FAKE_AXI_STATUS', '')
if os.environ.get('FM_COMPLETION_TEST_CANONICAL'):
    with open(os.environ['FM_COMPLETION_TEST_CANONICAL']) as f:
        canonical = f.read()
def field(key):
    m = re.search(r'^\s*' + key + r':\s*(.*?)\s*$', canonical, re.M)
    return m[1].strip('"') if m else ''
status = field('status')
if not (status == 'completed' and field('outcome') in ('checks-passed', 'passed') or
        status == 'ci' and 'all CI checks passed' in os.environ.get('FM_FAKE_CI_LOGS', '')):
    sys.exit(1)
pr = field('pr') or {'01ENG': 'https://github.com/o/r/pull/8', '01ISOLATED': 'https://github.com/o/r/pull/9'}.get(field('id'), '')
evidence = dict(provider='github', host='github.com', repository='o/r', pr=pr, declared_no_ci=False,
                checks=[dict(name='portable contract fixture', bucket='pass')])
q = dict(schema='no-mistakes/ci-qualification/v1', run=field('id'), repo='portable-fixture', branch=field('branch'),
         head=field('head'), status='running' if status == 'ci' else 'completed', attempt='producer:0', generation='qualification-1',
         push_generation=1, evidence=evidence, evidence_sha256=hashlib.sha256(json.dumps(evidence).encode()).hexdigest(),
         validity='current-at-read; revocable; bind exact identity and revalidate before downstream use')
if os.environ.get('FM_TEST_QUALIFICATION_FILE'):
    with open(os.environ['FM_TEST_QUALIFICATION_FILE']) as f:
        q = json.load(f)
if any(arg(flag) and arg(flag) != q[key] for flag, key in
       [('--run', 'run'), ('--head', 'head'), ('--attempt', 'attempt'), ('--generation', 'generation')]):
    sys.exit(1)
print(json.dumps(q, separators=(',', ':')))
