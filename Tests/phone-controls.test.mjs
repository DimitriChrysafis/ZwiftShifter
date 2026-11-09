import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

// Import the shipped browser code; Node needs no browser or third-party packages.
const source = await readFile(new URL('../Sources/ZwiftShiftCore/Web/app.js', import.meta.url), 'utf8');
const {PressRepeater} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

test('release during an in-flight press completes only that press', async () => {
  let calls = 0;
  let complete;
  const repeater = new PressRepeater({
    send: () => { calls++; return new Promise(resolve => { complete = resolve; }); },
    interval: () => 400,
  });
  const running = repeater.press('up');
  repeater.release();
  complete();
  await running;
  assert.equal(calls, 1);
  assert.equal(repeater.running, false);
});

test('held presses obey the interval, never overlap, and ignore a second direction', async () => {
  let time = 0;
  const calls = [];
  const repeater = new PressRepeater({
    now: () => time, interval: () => 400,
    sleep: async delay => { time += delay; },
    send: async direction => {
      calls.push([direction, time]);
      await repeater.press('down');
      time += 250;
      if (calls.length === 4) repeater.release();
    },
  });
  await repeater.press('up');
  assert.deepEqual(calls, [['up', 0], ['up', 400], ['up', 800], ['up', 1200]]);
});

test('network or unconfirmed failure stops holds without retrying', async () => {
  let calls = 0;
  let failure;
  const repeater = new PressRepeater({
    interval: () => 400,
    send: async () => { calls++; throw new Error('Confirmation unavailable'); },
    failed: error => { failure = error.message; },
  });
  await repeater.press('up');
  assert.equal(calls, 1);
  assert.equal(failure, 'Confirmation unavailable');
  assert.equal(repeater.held, false);
});

test('holds stop at thirty seconds even without a release event', async () => {
  let time = 0;
  let calls = 0;
  const repeater = new PressRepeater({
    now: () => time, interval: () => 1000,
    sleep: async delay => { time += delay; }, send: async () => { calls++; },
  });
  await repeater.press('down');
  assert.equal(calls, 30);
  assert.equal(repeater.running, false);
});
