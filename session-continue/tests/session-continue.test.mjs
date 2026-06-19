import assert from 'node:assert/strict';
import test from 'node:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { pathToFileURL } from 'node:url';

const helperPath = path.resolve('session-continue/skills/session-continue/scripts/session-continue.mjs');
const helper = await import(pathToFileURL(helperPath).href);

function makeSession(id, source, cwd = '/tmp/project') {
  return {
    id,
    source,
    cwd,
    repo: 'test/repo',
    branch: 'main',
    summary: `${source} session ${id}`,
    lines: 12,
    bytes: 1000,
    createdAt: new Date('2026-06-01T10:00:00.000Z'),
    updatedAt: new Date('2026-06-01T11:00:00.000Z'),
    originalPath: `/tmp/${source}/${id}.jsonl`,
  };
}

function makeContext(session, markdown = '# Session Handoff Context\n\nbody') {
  return {
    session,
    recentMessages: [{ role: 'user', content: 'Continue the task.' }],
    filesModified: [],
    pendingTasks: [],
    toolSummaries: [],
    markdown,
  };
}

test('parseInvocation accepts natural command text', () => {
  const parsed = helper.parseInvocation(['from', 'claude', 'session', 'id:', 'abc123', '--', 'finish the plugin']);

  assert.equal(parsed.from, 'claude');
  assert.equal(parsed.sessionId, 'abc123');
  assert.equal(parsed.task, 'finish the plugin');
  assert.equal(parsed.preset, 'standard');
  assert.equal(parsed.redact, true);
});

test('parseInvocation accepts one quoted argument string', () => {
  const parsed = helper.parseInvocation(['from codex "abc 123" -- continue the task']);

  assert.equal(parsed.from, 'codex');
  assert.equal(parsed.sessionId, 'abc 123');
  assert.equal(parsed.task, 'continue the task');
});

test('parseInvocation rejects unknown source tools', () => {
  assert.throws(() => helper.parseInvocation(['from', 'not-a-tool', 'abc123']), /Unsupported source/);
});

test('resolveSession prefers exact id before prefix matches', async () => {
  const exact = makeSession('abc', 'claude');
  const prefixMatch = makeSession('abcdef', 'claude');
  const calls = [];
  const api = {
    async getSessionsBySource(source, rebuild) {
      calls.push([source, rebuild]);
      return [prefixMatch, exact];
    },
  };

  const resolved = await helper.resolveSession(api, 'claude', 'abc', false);

  assert.equal(resolved, exact);
  assert.deepEqual(calls, [['claude', false]]);
});

test('resolveSession reports ambiguous prefixes with candidates', async () => {
  const api = {
    async getSessionsBySource() {
      return [makeSession('abc111', 'codex'), makeSession('abc222', 'codex')];
    },
  };

  await assert.rejects(() => helper.resolveSession(api, 'codex', 'abc', false), /abc111[\s\S]*abc222/);
});

test('resolveSessionWithFallback forces one rebuild on miss', async () => {
  const found = makeSession('codex-hit', 'codex');
  const calls = [];
  const api = {
    async getSessionsBySource(source, rebuild) {
      calls.push([source, rebuild]);
      return rebuild ? [found] : [];
    },
  };

  const resolved = await helper.resolveSessionWithFallback(api, 'codex', 'codex-hit');

  assert.equal(resolved, found);
  assert.deepEqual(calls, [
    ['codex', false],
    ['codex', true],
  ]);
});

test('buildHandoff redacts likely secrets', async () => {
  const session = makeSession('secret-session', 'claude');
  const api = {
    getPreset(preset) {
      return { preset };
    },
    async extractContext() {
      return makeContext(
        session,
        [
          '# Session Handoff Context',
          '',
          'OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890',
          'Authorization: Bearer ghp_abcdefghijklmnopqrstuvwxyz123456',
        ].join('\n'),
      );
    },
  };

  const output = await helper.buildHandoff(api, session, {
    preset: 'standard',
    redact: true,
    task: 'keep going',
    currentCwd: '/tmp/project',
    requireCwd: false,
  });

  assert.match(output, /\[REDACTED_SECRET\]/);
  assert.doesNotMatch(output, /sk-proj-abcdefghijklmnopqrstuvwxyz1234567890/);
  assert.doesNotMatch(output, /ghp_abcdefghijklmnopqrstuvwxyz123456/);
});

test('buildHandoff warns on cwd mismatch by default', async () => {
  const session = makeSession('other-cwd', 'codex', '/tmp/other-project');
  const api = {
    getPreset(preset) {
      return { preset };
    },
    async extractContext() {
      return makeContext(session);
    },
  };

  const output = await helper.buildHandoff(api, session, {
    preset: 'minimal',
    redact: false,
    task: '',
    currentCwd: '/tmp/current-project',
    requireCwd: false,
  });

  assert.match(output, /Working-directory mismatch/);
  assert.match(output, /\/tmp\/other-project/);
  assert.match(output, /\/tmp\/current-project/);
});

// --- multi-account / cross-tool resolution ---------------------------------

const ID_A = 'aaaaaaaa-0000-0000-0000-000000000001';
const ID_B = 'bbbbbbbb-0000-0000-0000-000000000002';
const CODEX_ID = 'dddddddd-0000-0000-0000-000000000004';
const ID_DUP = 'eeeeeeee-0000-0000-0000-000000000005';

// Build a throwaway $HOME with two live Claude accounts, a migration backup that
// duplicates an id, a config dir with no projects/, and a Codex session.
function buildFixture(t) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sc-home-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const touch = (rel) => {
    const full = path.join(home, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, '{"type":"summary","summary":"x"}\n');
  };
  touch(`.claude/projects/projA/${ID_A}.jsonl`);
  touch(`.claude/projects/projA/${ID_DUP}.jsonl`);
  touch('.claude/projects/projA/ambig-1111-0000-0000-0000-000000000001.jsonl');
  touch(`.claude-personal/projects/projB/${ID_B}.jsonl`);
  touch(`.claude-personal/projects/projB/${ID_DUP}.jsonl`);
  touch('.claude-personal/projects/projB/ambig-2222-0000-0000-0000-000000000002.jsonl');
  touch(`.claude-migration-backup-test/projects/projA/${ID_A}.jsonl`);
  fs.mkdirSync(path.join(home, '.claude-shared'), { recursive: true });
  touch(`.codex/sessions/2026/01/02/rollout-2026-01-02T03-04-05-${CODEX_ID}.jsonl`);
  return home;
}

const dir = (home, name) => path.join(home, name);

test('parseInvocation no longer requires a source', () => {
  const parsed = helper.parseInvocation([ID_A, '--', 'keep going']);

  assert.equal(parsed.from, undefined);
  assert.equal(parsed.sessionId, ID_A);
  assert.equal(parsed.task, 'keep going');
});

test('claudeConfigDirs auto-discovers live dirs, excluding backups and no-projects dirs', (t) => {
  const home = buildFixture(t);

  assert.deepEqual(helper.claudeConfigDirs({}, home), [dir(home, '.claude'), dir(home, '.claude-personal')]);
});

test('claudeConfigDirs lists the active CLAUDE_CONFIG_DIR first', (t) => {
  const home = buildFixture(t);

  const dirs = helper.claudeConfigDirs({ CLAUDE_CONFIG_DIR: dir(home, '.claude-personal') }, home);

  assert.deepEqual(dirs, [dir(home, '.claude-personal'), dir(home, '.claude')]);
});

test('claudeConfigDirs honours the SESSION_CONTINUE_CLAUDE_DIRS override order and drops missing dirs', (t) => {
  const home = buildFixture(t);
  const env = {
    SESSION_CONTINUE_CLAUDE_DIRS: [dir(home, '.claude-personal'), dir(home, '.claude'), dir(home, '.nope')].join(':'),
  };

  assert.deepEqual(helper.claudeConfigDirs(env, home), [dir(home, '.claude-personal'), dir(home, '.claude')]);
});

test('locateSession finds a Claude id owned by a non-active account', (t) => {
  const home = buildFixture(t);
  const env = { CLAUDE_CONFIG_DIR: dir(home, '.claude-personal') };

  assert.deepEqual(helper.locateSession(ID_A, undefined, env, home), {
    source: 'claude',
    configDir: dir(home, '.claude'),
    id: ID_A,
  });
});

test('locateSession resolves the active account too', (t) => {
  const home = buildFixture(t);
  const env = { CLAUDE_CONFIG_DIR: dir(home, '.claude-personal') };

  const located = helper.locateSession(ID_B, undefined, env, home);

  assert.equal(located.source, 'claude');
  assert.equal(located.configDir, dir(home, '.claude-personal'));
});

test('locateSession auto-detects Codex sessions', (t) => {
  const home = buildFixture(t);

  const located = helper.locateSession(CODEX_ID, undefined, {}, home);

  assert.equal(located.source, 'codex');
  assert.equal(located.id, CODEX_ID);
});

test('locateSession honours scan order for duplicate ids (first wins)', (t) => {
  const home = buildFixture(t);

  const personalFirst = { SESSION_CONTINUE_CLAUDE_DIRS: [dir(home, '.claude-personal'), dir(home, '.claude')].join(':') };
  assert.equal(helper.locateSession(ID_DUP, undefined, personalFirst, home).configDir, dir(home, '.claude-personal'));

  const claudeFirst = { SESSION_CONTINUE_CLAUDE_DIRS: [dir(home, '.claude'), dir(home, '.claude-personal')].join(':') };
  assert.equal(helper.locateSession(ID_DUP, undefined, claudeFirst, home).configDir, dir(home, '.claude'));
});

test('locateSession resolves a unique prefix', (t) => {
  const home = buildFixture(t);

  assert.equal(helper.locateSession(ID_A.slice(0, 8), undefined, {}, home).id, ID_A);
});

test('locateSession rejects an ambiguous prefix with candidates', (t) => {
  const home = buildFixture(t);

  assert.throws(
    () => helper.locateSession('ambig', undefined, {}, home),
    (err) => {
      assert.match(err.message, /Ambiguous/);
      assert.match(err.message, /ambig-1111/);
      assert.match(err.message, /ambig-2222/);
      return true;
    },
  );
});

test('locateSession returns null when nothing matches', (t) => {
  const home = buildFixture(t);

  assert.equal(helper.locateSession('zzzzzzzz-nope', undefined, {}, home), null);
});

test('locateSession rejects ids containing path separators', (t) => {
  const home = buildFixture(t);

  assert.throws(() => helper.locateSession('../escape', undefined, {}, home), /Invalid session id/);
  assert.throws(() => helper.locateSession('a/b', undefined, {}, home), /Invalid session id/);
});

test('locateSession with explicit from=claude ignores Codex ids', (t) => {
  const home = buildFixture(t);

  assert.equal(helper.locateSession(CODEX_ID, 'claude', {}, home), null);
});
