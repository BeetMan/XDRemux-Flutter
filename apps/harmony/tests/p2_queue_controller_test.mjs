import assert from 'node:assert/strict';
import { QueueController } from '../entry/src/main/ets/queue/QueueController.ts';

const mode = (modeKey) => ({
  modeKey,
  modeLabel: modeKey === 'apple' ? 'Apple 标准' : 'OPPO 兼容',
  config: modeKey === 'apple'
    ? { oppoCompat: 0, oppoCameraTail: 0, strictTmap: 0, applePhotographicStyles: 0, applePortrait: 0 }
    : { oppoCompat: 2, oppoCameraTail: 255, strictTmap: 0, applePhotographicStyles: 0, applePortrait: 0 }
});

const successfulResult = (item, snapshot) => ({
  outputPath: '/sandbox/' + item.id + '-' + snapshot.modeKey + '.heic',
  modeKey: snapshot.modeKey,
  modeLabel: snapshot.modeLabel,
  conversion: {
    success: true,
    mode: snapshot.modeKey,
    family: 'test',
    edrScale: 1,
    gainMapMax: 2,
    errorMessage: null
  }
});

const waitFor = async (predicate, label) => {
  for (let i = 0; i < 100; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error('timed out waiting for ' + label);
};

const makeController = (execute, captureMode = () => mode('oppo'), cleanup, prepare) => {
  const controller = new QueueController({ captureMode, execute, cleanup, prepare });
  controller.attach();
  return controller;
};

const item = (displayName) => ({ displayName, sourceUri: 'uri://' + displayName, inputPath: '/input/' + displayName });

async function testEmptyStartAddStart() {
  const calls = [];
  const controller = makeController(async (job, snapshot) => {
    calls.push(job.displayName);
    return successfulResult(job, snapshot);
  });
  const first = controller.start();
  const added = controller.add(item('after-empty'));
  const second = controller.start();
  assert.strictEqual(first, second);
  await first;
  assert.deepEqual(calls, ['after-empty']);
  assert.equal(added.status, 'succeeded');
}

async function testModeConfigDefensiveCopy() {
  const sharedConfig = {
    oppoCompat: 2,
    oppoCameraTail: 255,
    strictTmap: 0,
    applePhotographicStyles: 0,
    applePortrait: 0
  };
  const sharedMode = { modeKey: 'oppo', modeLabel: 'OPPO 兼容', config: sharedConfig };
  let release;
  const deferred = new Promise((resolve) => { release = resolve; });
  const captured = [];
  const controller = makeController(
    async (job, snapshot) => {
      captured.push({ id: job.id, compat: snapshot.config.oppoCompat });
      if (job.displayName === 'first') await deferred;
      return successfulResult(job, snapshot);
    },
    () => sharedMode
  );
  const first = controller.add(item('first'));
  controller.add(item('second'));
  const runner = controller.start();
  await waitFor(() => controller.activeItemId === first.id, 'defensive mode first');
  // Mutating the provider's shared object during an active job must not alter
  // the already captured native configuration.
  sharedConfig.oppoCompat = 6;
  release();
  await runner;
  assert.deepEqual(captured.map((entry) => entry.compat), [2, 6]);
}

async function testCleanupFailureIsExplicitAndRetryOnlyRemoves() {
  let cleanupCalls = 0;
  const controller = makeController(
    async (job, snapshot) => successfulResult(job, snapshot),
    () => mode('oppo'),
    async (job) => {
      cleanupCalls += 1;
      if (cleanupCalls === 1) {
        // Simulate a partial unlink: the remaining owned path is still
        // recorded and the user can retry removal explicitly.
        throw new Error('second unlink failed');
      }
    }
  );
  const job = controller.add(item('cleanup-failure'));
  const secondOwnedPath = '/sandbox/cleanup-failure-output.heic';
  job.ownedPaths.push(secondOwnedPath);
  await assert.rejects(controller.remove(job.id), /second unlink failed/);
  const failed = controller.get(job.id);
  assert.equal(failed.status, 'failed');
  assert.equal(failed.cleanupStatus, 'failed');
  assert.equal(controller.hasPendingItems, false);
  assert.throws(() => controller.retry(job.id), /cleanup failed/);
  assert.throws(() => controller.reconvert(job.id), /cleanup failed/);
  assert.throws(() => controller.beginExternal(job.id), /cleanup failed/);
  await controller.remove(job.id);
  assert.equal(controller.get(job.id), undefined);
}

async function testDetachStopsLaterItems() {
  let release;
  const deferred = new Promise((resolve) => { release = resolve; });
  const calls = [];
  const controller = makeController(async (job, snapshot) => {
    calls.push(job.displayName);
    if (job.displayName === 'first') await deferred;
    return successfulResult(job, snapshot);
  });
  const first = controller.add(item('first'));
  const second = controller.add(item('second'));
  const runner = controller.start();
  await waitFor(() => controller.activeItemId === first.id, 'detach active item');
  controller.detach();
  release();
  await runner;
  assert.deepEqual(calls, ['first']);
  assert.equal(second.status, 'pending');
  controller.attach();
  await controller.start();
  assert.deepEqual(calls, ['first', 'second']);
  assert.equal(second.status, 'succeeded');
}

async function testMissingInputRetryRematerializes() {
  let prepareCalls = 0;
  let executeCalls = 0;
  const controller = makeController(
    async (job, snapshot) => {
      executeCalls += 1;
      assert.equal(job.inputPath, '/sandbox/rematerialized.photo');
      return successfulResult(job, snapshot);
    },
    () => mode('oppo'),
    undefined,
    async () => {
      prepareCalls += 1;
      if (prepareCalls === 1) throw new Error('source copy failed');
      return {
        inputPath: '/sandbox/rematerialized.photo',
        details: { success: true },
        classification: { modeKey: 'oppo', folderName: 'test', status: 'ok', hasTagFlags: false, tagFlags: 0n, unknownFlags: 0n }
      };
    }
  );
  const job = controller.add({ displayName: 'needs-copy', sourceUri: 'uri://needs-copy' });
  await controller.start();
  assert.equal(job.status, 'failed');
  assert.equal(executeCalls, 0);
  controller.retry(job.id);
  await controller.start();
  assert.equal(prepareCalls, 2);
  assert.equal(executeCalls, 1);
  assert.equal(job.status, 'succeeded');
}

async function testSerialFailureContinuation() {
  const calls = [];
  let active = 0;
  let maxActive = 0;
  const controller = makeController(async (job, snapshot, report) => {
    active += 1;
    maxActive = Math.max(maxActive, active);
    calls.push(job.displayName);
    report({ stage: 1, current: 1, total: 4 });
    await Promise.resolve();
    active -= 1;
    if (job.displayName === 'bad') throw new Error('synthetic failure');
    return successfulResult(job, snapshot);
  });
  const bad = controller.add(item('bad'));
  const good = controller.add(item('good'));
  await controller.start();
  assert.deepEqual(calls, ['bad', 'good']);
  assert.equal(maxActive, 1);
  assert.equal(bad.status, 'failed');
  assert.match(bad.errorMessage, /synthetic failure/);
  assert.equal(good.status, 'succeeded');
  assert.deepEqual(good.progress, { stage: 1, current: 1, total: 4 });
}

async function testDoubleStartSameRunner() {
  let release;
  let active = 0;
  let maxActive = 0;
  const deferred = new Promise((resolve) => { release = resolve; });
  const controller = makeController(async (job, snapshot) => {
    active += 1;
    maxActive = Math.max(maxActive, active);
    await deferred;
    active -= 1;
    return successfulResult(job, snapshot);
  });
  const job = controller.add(item('one'));
  const first = controller.start();
  await waitFor(() => controller.activeItemId === job.id, 'first runner');
  const second = controller.start();
  assert.strictEqual(first, second);
  release();
  await first;
  assert.equal(maxActive, 1);
  assert.equal(job.status, 'succeeded');
}

async function testStopAfterCurrent() {
  let release;
  const deferred = new Promise((resolve) => { release = resolve; });
  const calls = [];
  const controller = makeController(async (job, snapshot) => {
    calls.push(job.displayName);
    if (job.displayName === 'first') await deferred;
    return successfulResult(job, snapshot);
  });
  const first = controller.add(item('first'));
  const second = controller.add(item('second'));
  const runner = controller.start();
  await waitFor(() => controller.activeItemId === first.id, 'stop test active item');
  controller.stop();
  release();
  await runner;
  assert.deepEqual(calls, ['first']);
  assert.equal(first.status, 'succeeded');
  assert.equal(second.status, 'pending');
  await controller.start();
  assert.deepEqual(calls, ['first', 'second']);
  assert.equal(second.status, 'succeeded');
}

async function testModeSnapshotAtEachStart() {
  let currentMode = 'oppo';
  let release;
  const deferred = new Promise((resolve) => { release = resolve; });
  const snapshots = [];
  const controller = makeController(
    async (job, snapshot) => {
      snapshots.push({ id: job.id, modeKey: snapshot.modeKey, compat: snapshot.config.oppoCompat });
      if (job.displayName === 'first') await deferred;
      return successfulResult(job, snapshot);
    },
    () => mode(currentMode)
  );
  const first = controller.add(item('first'));
  const second = controller.add(item('second'));
  const runner = controller.start();
  await waitFor(() => controller.activeItemId === first.id, 'mode snapshot first');
  currentMode = 'apple';
  release();
  await runner;
  assert.deepEqual(snapshots.map((entry) => entry.modeKey), ['oppo', 'apple']);
  assert.equal(first.result.modeKey, 'oppo');
  assert.equal(second.result.modeKey, 'apple');
}

async function testRetryReconvertAndRemoveBoundaries() {
  const attempts = new Map();
  const cleaned = [];
  let release;
  const deferred = new Promise((resolve) => { release = resolve; });
  const controller = makeController(async (job, snapshot) => {
    if (job.displayName === 'active') await deferred;
    const count = (attempts.get(job.id) ?? 0) + 1;
    attempts.set(job.id, count);
    if (job.displayName === 'retry' && count === 1) throw new Error('retry me');
    if (job.displayName === 'reconvert' && count === 2) throw new Error('reconvert failed');
    return successfulResult(job, snapshot);
  }, () => mode('oppo'), async (job) => {
    cleaned.push({ id: job.id, input: job.inputPath, output: job.result?.outputPath ?? '' });
  });

  const retry = controller.add(item('retry'));
  await controller.start();
  assert.equal(retry.status, 'failed');
  controller.retry(retry.id);
  await controller.start();
  assert.equal(retry.status, 'succeeded');

  const reconvert = controller.add(item('reconvert'));
  await controller.start();
  const priorOutput = reconvert.result.outputPath;
  controller.reconvert(reconvert.id);
  await controller.start();
  assert.equal(reconvert.status, 'failed');
  assert.equal(reconvert.result.outputPath, priorOutput);
  assert.match(reconvert.errorMessage, /reconvert failed/);

  const pending = controller.add(item('pending'));
  await controller.remove(pending.id);
  assert.equal(controller.get(pending.id), undefined);
  await controller.remove(retry.id);
  await controller.remove(reconvert.id);
  assert.deepEqual(cleaned.map((entry) => entry.id), [pending.id, retry.id, reconvert.id]);

  const active = controller.add(item('active'));
  const runner = controller.start();
  await waitFor(() => controller.activeItemId === active.id, 'active removal boundary');
  await assert.rejects(controller.remove(active.id), /active item/);
  assert.throws(() => controller.retry(active.id), /active item/);
  assert.throws(() => controller.beginExternal(active.id), /active item/);
  controller.stop();
  release();
  await runner;

  controller.beginExternal(active.id);
  await assert.rejects(controller.remove(active.id), /active item/);
  controller.endExternal(active.id);
  await controller.remove(active.id);
}

await testEmptyStartAddStart();
await testModeConfigDefensiveCopy();
await testCleanupFailureIsExplicitAndRetryOnlyRemoves();
await testDetachStopsLaterItems();
await testMissingInputRetryRematerializes();
await testSerialFailureContinuation();
await testDoubleStartSameRunner();
await testStopAfterCurrent();
await testModeSnapshotAtEachStart();
await testRetryReconvertAndRemoveBoundaries();
console.log('P2 queue controller tests passed: serial/failure/empty-start/double-start/stop/mode/copy/cleanup/detach/prepare/retry/reconvert/remove');
