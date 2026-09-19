import assert from 'node:assert/strict';
import { QueueController } from '../entry/src/main/ets/queue/QueueController.ts';

const mode = () => ({
  modeKey: 'oppo',
  modeLabel: 'OPPO 兼容',
  config: {
    oppoCompat: 2,
    oppoCameraTail: 255,
    strictTmap: 0,
    applePhotographicStyles: 0,
    applePortrait: 0
  }
});

const input = (name) => ({
  displayName: name,
  sourceUri: 'uri://' + name,
  inputPath: '/sandbox/inputs/' + name + '.jpg'
});

const result = (job, snapshot) => ({
  outputPath: '/sandbox/outputs/' + job.id + '.heic',
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

const flush = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await new Promise((resolve) => setTimeout(resolve, 0));
};

const makeController = (options) => {
  const controller = new QueueController({
    captureMode: mode,
    execute: options.execute || (async (job, snapshot) => result(job, snapshot)),
    cleanup: options.cleanup,
    persistence: options.persistence
  });
  controller.attach();
  return controller;
};

async function testFailureLatchSkipsQueuedWritesAndAllowsExplicitRetry() {
  const writes = [];
  let calls = 0;
  let releaseFirst;
  let started;
  const firstStarted = new Promise((resolve) => { started = resolve; });
  const firstResult = new Promise((resolve) => { releaseFirst = resolve; });
  const controller = makeController({
    persistence: async (snapshot) => {
      calls += 1;
      writes.push(snapshot);
      if (calls === 1) {
        started();
        await firstResult;
        throw new Error('journal unavailable');
      }
    }
  });

  const first = controller.add(input('first'));
  await firstStarted;
  const held = writes[0];
  controller.add(input('second'));
  controller.beginExternal(first.id);
  controller.endExternal(first.id);
  assert.equal(held.items[0].externalBusy, false, 'queued snapshot must be immutable');
  releaseFirst();
  await flush();

  assert.equal(calls, 1, 'a latched write failure must skip later queued writes');
  assert.equal(controller.hasPersistenceError, true);
  await assert.rejects(controller.persist(), (error) => /队列记录保存失败/.test(error.message) && error.cause && error.cause.message === 'journal unavailable');

  await controller.retryPersistence();
  assert.equal(calls, 2, 'explicit retry is the only way to invoke the writer again');
  assert.equal(controller.hasPersistenceError, false);
};

async function testSuccessfulNativeResultSurvivesPostResultJournalFailure() {
  const writes = [];
  const executed = [];
  const controller = makeController({
    persistence: async (snapshot) => {
      writes.push(snapshot);
      if (snapshot.items.some((item) => item.result !== undefined)) {
        throw new Error('result checkpoint unavailable');
      }
    },
    execute: async (job, snapshot) => {
      executed.push(job.displayName);
      return result(job, snapshot);
    }
  });
  const first = controller.add(input('native-success'));
  const second = controller.add(input('must-wait'));
  await flush();

  await controller.start();
  const firstView = controller.get(first.id);
  const secondView = controller.get(second.id);
  assert.deepEqual(executed, ['native-success']);
  assert.equal(controller.hasPersistenceError, true);
  assert.equal(firstView.status, 'failed', 'durability failure requires manual retry');
  assert.ok(firstView.result, 'successful native output must remain in memory');
  assert.equal(secondView.status, 'pending', 'later items must not start after journal failure');
  assert.equal(writes.some((snapshot) => snapshot.items.some((item) => item.result !== undefined)), true);
};

async function testDeleteIntentFailureNeverTouchesSandbox() {
  let failWrites = false;
  let cleanupCalls = 0;
  const controller = makeController({
    persistence: async () => {
      if (failWrites) {
        throw new Error('delete journal unavailable');
      }
    },
    cleanup: async () => {
      cleanupCalls += 1;
    }
  });
  const item = controller.add(input('delete-me'));
  await flush();
  failWrites = true;

  await assert.rejects(controller.remove(item.id), (error) => error.cause && error.cause.message === 'delete journal unavailable');
  assert.equal(cleanupCalls, 0, 'cleanup must wait for durable deletion intent');
  assert.equal(controller.get(item.id).cleanupStatus, 'failed');
  assert.equal(controller.hasPersistenceError, true);
};

async function testProgressTicksStayInMemory() {
  const writes = [];
  let progressStarted;
  const progressReady = new Promise((resolve) => { progressStarted = resolve; });
  let releaseConversion;
  const conversionGate = new Promise((resolve) => { releaseConversion = resolve; });
  const controller = makeController({
    persistence: async (snapshot) => {
      writes.push(snapshot);
    },
    execute: async (job, snapshot, reportProgress) => {
      const writesBeforeProgress = writes.length;
      reportProgress({ stage: 1, current: 1, total: 4 });
      reportProgress({ stage: 2, current: 2, total: 4 });
      progressStarted(writesBeforeProgress);
      await conversionGate;
      return result(job, snapshot);
    }
  });
  controller.add(input('progress'));
  await flush();
  const run = controller.start();
  const writesBeforeProgress = await progressReady;
  await flush();
  assert.equal(writes.length, writesBeforeProgress, 'progress ticks must not enqueue journal writes');
  releaseConversion();
  await run;
};

async function testRestoreWaitsForPriorJournalWrite() {
  let releaseWrite;
  let writeStarted;
  const writeReady = new Promise((resolve) => { writeStarted = resolve; });
  const writeGate = new Promise((resolve) => { releaseWrite = resolve; });
  const controller = makeController({
    persistence: async () => {
      writeStarted();
      await writeGate;
    }
  });
  controller.add(input('old-session'));
  await writeReady;
  let restored = false;
  const restore = controller.restore({ nextId: 1, items: [] }).then(() => {
    restored = true;
  });
  await flush();
  assert.equal(restored, false, 'restore must wait for an in-flight journal write');
  releaseWrite();
  await restore;
  assert.equal(restored, true);
  assert.deepEqual(controller.items(), []);
};
await testFailureLatchSkipsQueuedWritesAndAllowsExplicitRetry();
await testSuccessfulNativeResultSurvivesPostResultJournalFailure();
await testDeleteIntentFailureNeverTouchesSandbox();
await testProgressTicksStayInMemory();
await testRestoreWaitsForPriorJournalWrite();
console.log('P2 queue controller persistence tests passed: immutable/latch/retry/result-retention/delete-intent/progress/restore');