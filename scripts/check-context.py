"""Check frozen context, bounded excerpts and specialist routing without provider calls."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
binary = str(Path(sys.argv[1]).resolve())
source = (root / 'Sources/AIReviewerWatcher/main.swift').read_text()

with tempfile.TemporaryDirectory(prefix='ai-reviewer-context-') as temporary:
    home = Path(temporary)
    repo = home / 'repo'
    repo.mkdir()
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()
    git('init', '-q')
    git('config', 'user.name', 'Context test')
    git('config', 'user.email', 'context@example.invalid')
    def put(path, text):
        file = repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
    put('AGENTS.md', 'FROZEN instruction\n')
    put('ledger.md', '# Ledger\nIntro\n## Shell\nSHELL\n## Links\nLINKS\n## Other\nSECRET-OTHER\n')
    put('large.md', 'x' * 80000)
    for number in range(4):
        put(f'budget{number}.md', 'y' * 80000)
    put('src/helper.ts', 'export const value = "FROZEN dependency";\n')
    put('src/excluded.ts', 'EXCLUDED dependency\n')
    put('app/main.ts', 'export {};\n')
    git('add', '.')
    git('commit', '-qm', 'foundation')
    put('app/main.ts', 'import {value} from "../src/helper.js";\nimport "../src/excluded.js";\nconsole.log(value);\n')
    git('add', '.')
    git('commit', '-qm', 'UI change')
    commit = git('rev-parse', 'HEAD')
    # Dirty working files must never become review evidence.
    put('AGENTS.md', 'DIRTY instructions\n')
    put('src/helper.ts', 'DIRTY dependency\n')
    profile = dict(schemaVersion=1, name='test', ignorePaths=['src/excluded.ts'], globalInstructions='test',
                   agents=[dict(id='ui',title='UI',category='ui',instructions='test',alwaysRun=False,runIfPathPrefixes=['app/'])],
                   contextRules=[dict(paths=['AGENTS.md','missing.md']),
                                 dict(paths=['ledger.md'],headings=['## Shell'],whenPathPrefixes=['app/']),
                                 dict(paths=['ledger.md'],headings=['## Links'],whenPathPrefixes=['app/']),
                                 dict(paths=['large.md']),
                                 dict(paths=['inactive.md'],whenPathPrefixes=['backend/'])])
    profile_path = home / 'profile.json'
    profile_path.write_text(json.dumps(profile))
    config = json.loads((root / 'config/local.example.json').read_text())
    config.update(repoPath=str(repo), reportsPath=str(home/'reports'), reviewCachePath=str(home/'cache'),
                  reviewProfilePath=str(profile_path), instructionSet=None)
    config_path = home / 'config.json'
    config_path.write_text(json.dumps(config))
    def materialize():
        result = subprocess.run([binary, 'materialize-head', '--config', str(config_path)], capture_output=True,text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        return Path(next(line.removeprefix('materialized: ') for line in result.stdout.splitlines() if line.startswith('materialized: ')))
    bundle = materialize()
    text = (bundle/'context.txt').read_text()
    inventory = {item['path']:item for item in json.loads((bundle/'context-files.json').read_text())}
    assert json.loads((bundle/'bundle.json').read_text())['commit'] == commit
    assert 'FROZEN instruction' in text and 'FROZEN dependency' in text and 'DIRTY' not in text, (inventory, text[:1000], text[-1000:])
    assert 'SHELL' in text and 'LINKS' in text and 'SECRET-OTHER' not in text
    assert 'ledger.md:5 (selected section)' in text
    assert 'EXCLUDED' not in text and 'src/excluded.ts' not in inventory
    assert inventory['missing.md']['status'] == 'missing-at-commit'
    assert inventory['large.md']['status'] == 'capped' and inventory['large.md']['bytes'] == 65536
    assert 'inactive.md' not in inventory
    assert 'src/helper.ts' in inventory
    # Whole-file context overrides section rules regardless of declaration order.
    profile['contextRules'].append(dict(paths=['ledger.md']))
    profile_path.write_text(json.dumps(profile))
    assert 'SECRET-OTHER' in (materialize()/'context.txt').read_text()
    # Aggregate budget exhaustion is explicit and cannot grow prompt content indefinitely.
    profile['contextRules'] = [dict(paths=[f'budget{number}.md' for number in range(4)])]
    profile_path.write_text(json.dumps(profile))
    budget = json.loads((materialize()/'context-files.json').read_text())
    assert sum(item['bytes'] for item in budget) <= 196608
    assert len((materialize()/'context.txt').read_bytes()) <= 196608
    assert next(item for item in budget if item['path']=='budget3.md')['status'] == 'omitted-budget'
    # A context path cannot escape the bundle/source boundary.
    profile['contextRules'] = [dict(paths=['../escape'])]
    profile_path.write_text(json.dumps(profile))
    result = subprocess.run([binary,'materialize-head','--config',str(config_path)],capture_output=True,text=True)
    assert result.returncode != 0

    def declaration(start, end):
        return source[source.index(start):source.index(end, source.index(start))]
    harness = home/'routing.swift'
    harness.write_text('import Foundation\n'
        + declaration('struct ChangedFile:', 'struct BundleManifest:')
        + declaration('struct ReviewAgentProfile:', 'struct ReviewRecord:')
        + declaration('struct ReviewProfile:', 'struct ReviewContextRule:')
        + declaration('struct ReviewContextRule:', 'struct ReviewContextFile:')
        + 'enum AIProvider: String { case codex }\n'
        + declaration('func runnableAgents(', 'func requiredFindings(') + '''
let decoder = JSONDecoder()
let profile = try decoder.decode(ReviewProfile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
func ids(_ path: String, old: String? = nil, diff: String = "") -> Set<String> {
    Set(runnableAgents(profile: profile, changedFiles: [ChangedFile(status: "M", path: path, oldPath: old, snapshotPath: nil, snapshotBytes: nil, snapshotCapped: false)], diffText: diff).map(\\.id))
}
let ui = ids("app/components/links/link-settings.tsx", diff: "variantLink Shopify fulfilment cancellation")
precondition(ui.contains("ui") && !ui.contains("integrator") && !ui.contains("workflow"))
precondition(ids("src/modules/channels/internal/adapter.ts").contains("integrator"))
precondition(ids("src/modules/orders/public.ts").contains("workflow"))
precondition(!ids("docs/architecture/example.md").contains("ui"))
precondition(ids("other.ts", old: "app/routes/links.tsx").contains("ui"))
print("Specialist routing passed")
''')
    executable = home/'routing'
    subprocess.run(['swiftc',str(harness),'-o',str(executable)],check=True)
    subprocess.run([str(executable),str(root/'profiles/dsinfra-review.json')],check=True)
print('Context checks passed (frozen evidence, sections, imports, omissions, caps, traversal and routing).')
