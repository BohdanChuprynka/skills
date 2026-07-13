#!/usr/bin/env node

import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const htmlPath = process.argv[2];
if (!htmlPath) throw new Error('usage: test_review_ui_persistence.mjs <dream-review.html>');
const html = fs.readFileSync(htmlPath, 'utf8');
const match = html.match(/<script>([\s\S]*?)<\/script>/);
assert(match, 'review UI script missing');
const script = match[1].replace(/\nbootstrap\(\);\s*$/, '\n');

function classList(initial = []) {
  const values = new Set(initial);
  return {
    add: (...names) => names.forEach(name => values.add(name)),
    remove: (...names) => names.forEach(name => values.delete(name)),
    contains: name => values.has(name),
  };
}

function element(initialClasses = []) {
  return {
    classList: classList(initialClasses),
    disabled: false,
    textContent: '',
    attrs: {},
    setAttribute(name, value) { this.attrs[name] = value; },
  };
}

const actionbar = element();
const decisionError = element(['hidden']);
const currentCard = element(['card', 'current']);
const actionButtons = [element(['act']), element(['act']), element(['act'])];
const elements = new Map([['actionbar', actionbar], ['decisionError', decisionError]]);
let fetchImpl = null;
let fetchCalls = 0;
const timers = [];
const sandbox = {
  console, Error, JSON, URL, URLSearchParams,
  window: {
    location: { search: '', href: 'http://localhost/' },
    history: { replaceState() {} },
  },
  document: {
    title: 'Dream review',
    addEventListener() {},
    getElementById(id) { return elements.get(id) || element(); },
    querySelector(selector) { return selector === '.card.current' ? currentCard : null; },
    querySelectorAll(selector) { return selector === '.act, .reason-btn' ? actionButtons : []; },
  },
  fetch(...args) { fetchCalls += 1; return fetchImpl(...args); },
  setTimeout(callback) { timers.push(callback); return timers.length; },
};
vm.createContext(sandbox);
vm.runInContext(script, sandbox, { filename: htmlPath });

function setCard(id) {
  vm.runInContext(`
    decisions = {};
    feedback = {};
    QUEUE = [{id: ${JSON.stringify(id)}}];
    VIEW_QUEUE = QUEUE.slice();
    total = 1;
  `, sandbox);
  currentCard.classList = classList(['card', 'current']);
  decisionError.classList = classList(['hidden']);
  decisionError.textContent = '';
  actionButtons.forEach(button => { button.disabled = false; });
}

setCard('c-fail');
fetchCalls = 0;
fetchImpl = async () => ({
  ok: false,
  status: 500,
  async json() { return { ok: false, error: 'review decision could not be persisted' }; },
});
await vm.runInContext(`commitDecision('approve', 'accepted')`, sandbox);
let state = vm.runInContext(`({
  decision: decisions['c-fail'],
  feedback: feedback['c-fail'],
  inFlight: decisionInFlight,
})`, sandbox);
assert.equal(fetchCalls, 1);
assert.equal(state.decision, undefined);
assert.equal(state.feedback, undefined);
assert.equal(state.inFlight, false);
assert.equal(currentCard.classList.contains('swipe-right'), false);
assert.equal(decisionError.classList.contains('hidden'), false);
assert.match(decisionError.textContent, /could not be persisted/i);
assert.match(decisionError.textContent, /card is still pending/i);
assert(actionButtons.every(button => button.disabled === false));

setCard('c-unconfirmed');
fetchImpl = async () => ({ ok: true, status: 200, async json() { return { ok: true, saved: {} }; } });
await vm.runInContext(`commitDecision('defer', 'review_later')`, sandbox);
state = vm.runInContext(`({decision: decisions['c-unconfirmed']})`, sandbox);
assert.equal(state.decision, undefined);
assert.equal(currentCard.classList.contains('swipe-up'), false);
assert.equal(decisionError.classList.contains('hidden'), false);

setCard('c-once');
fetchCalls = 0;
let resolveFetch;
fetchImpl = () => new Promise(resolve => { resolveFetch = resolve; });
const first = vm.runInContext(`commitDecision('approve', 'accepted')`, sandbox);
const duplicate = vm.runInContext(`commitDecision('approve', 'accepted')`, sandbox);
assert.equal(fetchCalls, 1);
assert(actionButtons.every(button => button.disabled === true));
resolveFetch({
  ok: true,
  status: 200,
  async json() { return { ok: true, saved: { 'c-once': 'approve' } }; },
});
await Promise.all([first, duplicate]);
state = vm.runInContext(`({
  decision: decisions['c-once'],
  reason: feedback['c-once'].reason,
  inFlight: decisionInFlight,
})`, sandbox);
assert.equal(state.decision, 'approve');
assert.equal(state.reason, 'accepted');
assert.equal(state.inFlight, false);
assert.equal(currentCard.classList.contains('swipe-right'), true);
assert.equal(decisionError.classList.contains('hidden'), true);
assert(actionButtons.every(button => button.disabled === false));
assert.equal(timers.length, 1);

// The card remains visible for its exit animation after confirmation. A fast
// second click in that window must not submit the already-saved decision again.
await vm.runInContext(`commitDecision('approve', 'accepted')`, sandbox);
assert.equal(fetchCalls, 1);

console.log('test_review_ui_persistence: ok');
