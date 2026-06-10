import assert from 'node:assert/strict';
import test from 'node:test';
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
