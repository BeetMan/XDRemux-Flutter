import assert from 'node:assert/strict';
import {
  attachBatchExportTargets,
  batchExportUriLeaf,
  buildBatchExportPlan,
  markBatchExportNotStarted,
  runBatchExport,
  summarizeBatchExport
} from '../entry/src/main/ets/queue/BatchExport.ts';
import { QueueController } from '../entry/src/main/ets/queue/QueueController.ts';

const conversion = (overrides = {}) => ({
  success: true,
  mode: 'oppo',
  family: 'test',
  edrScale: 1,
  gainMapMax: 2,
  errorMessage: null,
  ...overrides
});

const hasOwn = (value, key) => Object.prototype.hasOwnProperty.call(value, key);

const result = (id, overrides = {}) => ({
  outputPath: `/sandbox/outputs/${id}.heic`,
  modeKey: 'oppo',
  modeLabel: 'OPPO 兼容',
  conversion: conversion(),
  ...overrides
});

const queueItem = (id, overrides = {}) => {
  const outputPath = overrides.result?.outputPath ?? `/sandbox/outputs/${id}.heic`;
  const inputPath = overrides.inputPath ?? `/sandbox/inputs/${id}.photo`;
  const itemResult = hasOwn(overrides, 'result') ? overrides.result : result(id);
  return {
    id,
    revision: 0,
    displayName: overrides.displayName ?? `display-${id}`,
    sourceUri: overrides.sourceUri ?? `file://docs/storage/Users/currentUser/Download/${id}.heic`,
    inputPath,
    status: overrides.status ?? 'succeeded',
    attemptStatus: overrides.attemptStatus ?? 'succeeded',
    externalBusy: overrides.externalBusy ?? false,
    progress: { stage: 3, current: 1, total: 1 },
    result: itemResult,
    exportedUri: overrides.exportedUri ?? '',
    errorMessage: overrides.errorMessage ?? '',
    lastAttemptModeKey: 'oppo',
    lastAttemptModeLabel: 'OPPO 兼容',
    cleanupStatus: overrides.cleanupStatus ?? 'none',
    cleanupErrorMessage: '',
    ownedPaths: overrides.ownedPaths ?? [inputPath, outputPath]
  };
};

const entry = (id, overrides = {}) => ({
  id,
  displayName: `display-${id}`,
  sourceUri: `file://docs/storage/Users/currentUser/Download/${id}.heic`,
  outputPath: `/sandbox/outputs/${id}.heic`,
  ownedPaths: [`/sandbox/inputs/${id}.photo`, `/sandbox/outputs/${id}.heic`],
  fileName: `xdremux-batch-${id}-oppo-edge-1.heic`,
  targetUri: '',
  status: 'waiting',
  copySucceeded: false,
  exported: false,
  errorMessage: '',
  ...overrides
});

const expectThrow = (operation, pattern) => {
  assert.throws(operation, (error) => {
    assert.ok(error instanceof Error);
    if (pattern !== undefined) assert.match(error.message, pattern);
    return true;
  });
};

const saveUri = (leaf, directory = 'file://docs/storage/Users/currentUser/Download') => (
  `${directory}/${leaf}`
);

const testPlanFilteringAndDefensiveSnapshot = () => {
  const eligible = queueItem('job-1');
  const failedWithOldResult = queueItem('job-2', { status: 'failed', attemptStatus: 'failed' });
  const pendingWithOldResult = queueItem('job-3', { status: 'pending', attemptStatus: 'pending' });
  const running = queueItem('job-4', { status: 'running', attemptStatus: 'running' });
  const externallyBusy = queueItem('job-5', { externalBusy: true });
  const alreadyExported = queueItem('job-6', {
    exportedUri: saveUri('already-exported.heic')
  });
  const cleanupPending = queueItem('job-7', { cleanupStatus: 'pending' });
  const cleanupFailed = queueItem('job-8', { cleanupStatus: 'failed' });
  const failedWithoutResult = queueItem('job-9', { status: 'failed', result: undefined });
  const sourceItems = [
    eligible,
    failedWithOldResult,
    pendingWithOldResult,
    running,
    externallyBusy,
    alreadyExported,
    cleanupPending,
    cleanupFailed,
    failedWithoutResult
  ];

  const plan = buildBatchExportPlan(sourceItems, 'P3/edge token');
  assert.deepEqual(plan.map((item) => item.id), ['job-1', 'job-2', 'job-3']);
  assert.equal(plan.every((item) => item.status === 'waiting' && item.targetUri === ''), true);
  assert.equal(plan.every((item) => item.copySucceeded === false && item.exported === false), true);
  assert.equal(plan[0].fileName, 'xdremux-batch-job-1-oppo-P3_edge_token-1.heic');
  assert.equal(plan[1].fileName, 'xdremux-batch-job-2-oppo-P3_edge_token-2.heic');
  assert.equal(plan[2].fileName, 'xdremux-batch-job-3-oppo-P3_edge_token-3.heic');

  plan[0].ownedPaths.push('/sandbox/outputs/mutated.heic');
  plan[0].status = 'failed';
  plan[0].displayName = 'mutated plan copy';
  assert.deepEqual(eligible.ownedPaths, [eligible.inputPath, eligible.result.outputPath]);
  assert.equal(eligible.status, 'succeeded');
  assert.equal(eligible.displayName, 'display-job-1');

  eligible.ownedPaths.push('/sandbox/inputs/late-path.photo');
  eligible.result.outputPath = '/sandbox/outputs/changed-after-plan.heic';
  assert.equal(plan[0].ownedPaths.includes('/sandbox/inputs/late-path.photo'), false);
  assert.equal(plan[0].outputPath, '/sandbox/outputs/job-1.heic');
};

const testUriLeafDecoding = () => {
  assert.equal(batchExportUriLeaf(saveUri('photo.heic')), 'photo.heic');
  assert.equal(batchExportUriLeaf(saveUri('%78dremux.heic')), 'xdremux.heic');
  assert.equal(batchExportUriLeaf(saveUri('photo%20one.heic')), 'photo one.heic');
  assert.equal(batchExportUriLeaf('file://docs/storage/Users/currentUser/Download/no-trailing-slash'), 'no-trailing-slash');
  for (const uri of [
    '',
    ' file://docs/storage/Users/currentUser/Download/photo.heic',
    'file://docs/storage/Users/currentUser/Download/',
    'photo.heic',
    'file://docs/storage/Users/currentUser/Download/photo%2Fchild.heic',
    'file://docs/storage/Users/currentUser/Download/photo%5Cchild.heic',
    'file://docs/storage/Users/currentUser/Download/%E0%A4%A'
  ]) {
    assert.equal(batchExportUriLeaf(uri), '', `expected invalid leaf for ${uri}`);
  }
};

const testOutOfOrderAndEncodedTargetMapping = () => {
  const entries = [
    entry('job-1', { fileName: 'xdremux-batch-job-1-oppo-edge-1.heic' }),
    entry('job-2', { fileName: 'xdremux-batch-job-2-apple-edge-2.heic' }),
    entry('job-3', { fileName: 'xdremux-batch-job-3-oppo-edge-3.heic' })
  ];
  const shuffled = [
    saveUri(entries[2].fileName, 'file://docs/storage/Users/currentUser/Documents'),
    saveUri(entries[0].fileName.replace('xdremux', '%78dremux'), 'file://docs/storage/Users/currentUser/Download'),
    saveUri(entries[1].fileName, 'file://docs/storage/Users/currentUser/Pictures')
  ];
  const mapped = attachBatchExportTargets(entries, shuffled);
  assert.deepEqual(mapped.map((item) => item.id), ['job-1', 'job-2', 'job-3']);
  assert.equal(mapped[0].targetUri, shuffled[1]);
  assert.equal(mapped[1].targetUri, shuffled[2]);
  assert.equal(mapped[2].targetUri, shuffled[0]);
  assert.equal(entries.every((item) => item.targetUri === ''), true);
  mapped[0].ownedPaths.push('/sandbox/changed-after-map');
  assert.equal(entries[0].ownedPaths.includes('/sandbox/changed-after-map'), false);
};

const testTargetCardinalityDuplicatesUnknownAndProtectedPaths = () => {
  const entries = [entry('job-1'), entry('job-2')];
  expectThrow(
    () => attachBatchExportTargets(entries, [saveUri(entries[0].fileName)]),
    /数量.*不符.*未写入任何图片/
  );
  expectThrow(
    () => attachBatchExportTargets(entries, [saveUri(entries[0].fileName), saveUri(entries[1].fileName), saveUri('unknown.heic')]),
    /数量.*不符.*未写入任何图片/
  );
  expectThrow(
    () => attachBatchExportTargets(entries, [saveUri(entries[0].fileName), saveUri(entries[0].fileName)]),
    /重复 URI/
  );
  expectThrow(
    () => attachBatchExportTargets(entries, [
      saveUri(entries[0].fileName),
      saveUri(entries[0].fileName.replace('xdremux', '%78dremux'))
    ]),
    /重复 URI/
  );
  expectThrow(
    () => attachBatchExportTargets(entries, [saveUri(entries[0].fileName), saveUri('unknown.heic')]),
    /无法与批量文件名可靠对应/
  );
  assert.equal(entries.every((item) => item.targetUri === ''), true);

  const sourceConflict = entry('job-source', {
    sourceUri: 'file://docs/storage/Users/currentUser/Download/source.heic',
    fileName: 'source.heic'
  });
  expectThrow(
    () => attachBatchExportTargets([sourceConflict], [saveUri('source.heic')]),
    /输入或应用沙盒路径/
  );
  const encodedSourceConflict = entry('job-source-encoded', {
    sourceUri: 'file://docs/storage/Users/currentUser/Download/source%2Eheic',
    fileName: 'source-encoded.heic'
  });
  expectThrow(
    () => attachBatchExportTargets([encodedSourceConflict], [saveUri('source.heic')]),
    /输入或应用沙盒路径/
  );

  const ownedConflict = entry('job-owned', {
    sourceUri: 'file://docs/storage/Users/currentUser/Download/other.heic',
    ownedPaths: ['file://docs/storage/Users/currentUser/Download/owned.heic'],
    fileName: 'owned.heic'
  });
  expectThrow(
    () => attachBatchExportTargets([ownedConflict], [saveUri('owned.heic')]),
    /输入或应用沙盒路径/
  );
  const encodedOwnedConflict = entry('job-owned-encoded', {
    sourceUri: 'file://docs/storage/Users/currentUser/Download/other-encoded.heic',
    ownedPaths: ['file://docs/storage/Users/currentUser/Download/owned%2Eheic'],
    fileName: 'owned-encoded.heic'
  });
  expectThrow(
    () => attachBatchExportTargets([encodedOwnedConflict], [saveUri('owned.heic')]),
    /输入或应用沙盒路径/
  );

  // A target must also be rejected when it aliases an owned path from an item
  // excluded from this batch.  The picker may return file:/// while the queue
  // journal stores the corresponding local path.
  const excludedOwnedLeaf = entries[0].fileName;
  const excludedOwnedPath = `/sandbox/outputs/${excludedOwnedLeaf}`;
  expectThrow(
    () => attachBatchExportTargets(
      [entry('job-participating', { fileName: excludedOwnedLeaf })],
      [`file:///sandbox/outputs/${excludedOwnedLeaf}`],
      ['file://localhost' + excludedOwnedPath]
    ),
    /输入或应用沙盒路径/
  );
};

const testSerialCopyFailureIsolationAndSnapshots = async () => {
  const entries = [entry('job-1'), entry('job-2'), entry('job-3')];
  const calls = [];
  const checkpoints = [];
  const snapshots = [];
  let active = 0;
  let maxActive = 0;
  const resultEntries = await runBatchExport(entries, {
    copy: async (current) => {
      calls.push(current.id);
      active += 1;
      maxActive = Math.max(maxActive, active);
      await Promise.resolve();
      active -= 1;
      if (current.id === 'job-2') throw new Error('synthetic copy failure');
    },
    checkpoint: async (current) => {
      checkpoints.push(current.id);
    },
    onStatus: (current) => {
      snapshots.push(current);
      if (snapshots.length === 1) {
        current[0].status = 'failed';
        current[0].ownedPaths.push('/caller-mutation');
      }
    }
  });
  assert.deepEqual(calls, ['job-1', 'job-2', 'job-3']);
  assert.deepEqual(checkpoints, ['job-1', 'job-3']);
  assert.equal(maxActive, 1);
  assert.deepEqual(resultEntries.map((item) => item.status), ['succeeded', 'failed', 'succeeded']);
  assert.deepEqual(resultEntries.map((item) => [item.copySucceeded, item.exported]), [
    [true, true],
    [false, false],
    [true, true]
  ]);
  assert.match(resultEntries[1].errorMessage, /synthetic copy failure/);
  assert.equal(resultEntries[0].ownedPaths.includes('/caller-mutation'), false);
  assert.equal(entries[0].status, 'waiting');
  assert.equal(entries[0].targetUri, '');
  assert.deepEqual(summarizeBatchExport(resultEntries), {
    total: 3,
    waiting: 0,
    copying: 0,
    succeeded: 2,
    failed: 1,
    journalFailed: 0,
    canceled: 0,
    exported: 2
  });
};

const testStopCancelsOnlyLaterEntries = async () => {
  const entries = [entry('job-1'), entry('job-2'), entry('job-3')];
  let stop = false;
  const copied = [];
  const checkpoints = [];
  const resultEntries = await runBatchExport(entries, {
    shouldStop: () => stop,
    copy: async (current) => {
      copied.push(current.id);
      stop = true;
    },
    checkpoint: async (current) => {
      checkpoints.push(current.id);
    }
  });
  assert.deepEqual(copied, ['job-1']);
  assert.deepEqual(checkpoints, ['job-1']);
  assert.deepEqual(resultEntries.map((item) => item.status), ['succeeded', 'canceled', 'canceled']);
  assert.deepEqual(resultEntries.map((item) => [item.copySucceeded, item.exported]), [
    [true, true],
    [false, false],
    [false, false]
  ]);
  assert.match(resultEntries[1].errorMessage, /停止后续/);
  assert.match(resultEntries[2].errorMessage, /停止后续/);
  assert.deepEqual(summarizeBatchExport(resultEntries), {
    total: 3,
    waiting: 0,
    copying: 0,
    succeeded: 1,
    failed: 0,
    journalFailed: 0,
    canceled: 2,
    exported: 1
  });
};

const testCheckpointFailurePreservesExportFactAndStopsLater = async () => {
  const entries = [
    entry('job-1', { targetUri: saveUri('xdremux-batch-job-1-oppo-edge-1.heic') }),
    entry('job-2', { targetUri: saveUri('xdremux-batch-job-2-oppo-edge-2.heic') }),
    entry('job-3', { targetUri: saveUri('xdremux-batch-job-3-oppo-edge-3.heic') })
  ];
  const copied = [];
  const checkpoints = [];
  const resultEntries = await runBatchExport(entries, {
    copy: async (current) => {
      copied.push(current.id);
    },
    checkpoint: async (current) => {
      checkpoints.push(current.id);
      throw new Error('synthetic journal failure after copy');
    }
  });
  assert.deepEqual(copied, ['job-1']);
  assert.deepEqual(checkpoints, ['job-1']);
  assert.equal(resultEntries[0].status, 'journal-failed');
  assert.equal(resultEntries[0].copySucceeded, true);
  assert.equal(resultEntries[0].exported, true);
  assert.equal(resultEntries[0].targetUri, entries[0].targetUri);
  assert.equal(resultEntries[0].outputPath, entries[0].outputPath);
  assert.match(resultEntries[0].errorMessage, /synthetic journal failure/);
  assert.equal(resultEntries[1].status, 'canceled');
  assert.equal(resultEntries[2].status, 'canceled');
  assert.deepEqual(summarizeBatchExport(resultEntries), {
    total: 3,
    waiting: 0,
    copying: 0,
    succeeded: 0,
    failed: 0,
    journalFailed: 1,
    canceled: 2,
    exported: 1
  });
};

const testInitialNonWaitingEntriesRemainUntouched = async () => {
  const entries = [
    entry('job-waiting'),
    entry('job-succeeded', { status: 'succeeded' }),
    entry('job-copying', { status: 'copying' }),
    entry('job-failed', { status: 'failed', errorMessage: 'prior failure' }),
    entry('job-journal', { status: 'journal-failed', errorMessage: 'prior journal failure' }),
    entry('job-canceled', { status: 'canceled', errorMessage: 'prior stop' })
  ];
  const copied = [];
  const resultEntries = await runBatchExport(entries, {
    copy: async (current) => copied.push(current.id),
    checkpoint: async () => undefined
  });
  assert.deepEqual(copied, ['job-waiting']);
  assert.deepEqual(resultEntries.map((item) => item.status), [
    'succeeded', 'succeeded', 'copying', 'failed', 'journal-failed', 'canceled'
  ]);
  assert.equal(resultEntries[3].errorMessage, 'prior failure');
  assert.equal(resultEntries[4].errorMessage, 'prior journal failure');
  assert.equal(resultEntries[5].errorMessage, 'prior stop');
};

const waitForPersistenceIdle = async (controller) => {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (!controller.isPersistenceBusy) return;
    await Promise.resolve();
  }
  throw new Error('timed out waiting for persistence idle');
};

const testBulkExternalLockIsAtomicAndOneJournalPerTransition = async () => {
  const writes = [];
  const controller = new QueueController({
    captureMode: () => ({
      modeKey: 'oppo',
      modeLabel: 'OPPO 兼容',
      config: {
        oppoCompat: 2,
        oppoCameraTail: 255,
        strictTmap: 0,
        applePhotographicStyles: 0,
        applePortrait: 0
      }
    }),
    execute: async () => ({
      outputPath: '/sandbox/outputs/unexpected.heic',
      modeKey: 'oppo',
      modeLabel: 'OPPO 兼容',
      conversion: conversion()
    }),
    persistence: async (snapshot) => {
      writes.push(snapshot);
      await Promise.resolve();
    }
  });
  controller.attach();
  const first = controller.add({
    displayName: 'first',
    sourceUri: 'file://docs/storage/Users/currentUser/Download/first.heic',
    inputPath: '/sandbox/inputs/first.photo'
  });
  const second = controller.add({
    displayName: 'second',
    sourceUri: 'file://docs/storage/Users/currentUser/Download/second.heic',
    inputPath: '/sandbox/inputs/second.photo'
  });
  const third = controller.add({
    displayName: 'third',
    sourceUri: 'file://docs/storage/Users/currentUser/Download/third.heic',
    inputPath: '/sandbox/inputs/third.photo'
  });
  await waitForPersistenceIdle(controller);
  writes.length = 0;

  assert.throws(
    () => controller.beginExternalBatch([first.id, 'job-missing']),
    /queue item not found/
  );
  assert.equal(controller.get(first.id).externalBusy, false);
  assert.equal(controller.get(second.id).externalBusy, false);
  await waitForPersistenceIdle(controller);
  assert.equal(writes.length, 0);

  controller.beginExternalBatch([first.id, second.id]);
  await waitForPersistenceIdle(controller);
  assert.equal(writes.length, 1);
  assert.equal(controller.get(first.id).externalBusy, true);
  assert.equal(controller.get(second.id).externalBusy, true);
  assert.equal(controller.get(third.id).externalBusy, false);
  assert.equal(writes[0].items.filter((item) => item.externalBusy).length, 2);
  assert.equal(writes[0].items.find((item) => item.id === third.id).externalBusy, false);

  writes.length = 0;
  controller.endExternalBatch([first.id, second.id, first.id, 'job-missing']);
  await waitForPersistenceIdle(controller);
  assert.equal(writes.length, 1);
  assert.equal(controller.get(first.id).externalBusy, false);
  assert.equal(controller.get(second.id).externalBusy, false);
  assert.equal(controller.get(third.id).externalBusy, false);
  assert.equal(writes[0].items.some((item) => item.externalBusy), false);
};

const testUnstartedBatchFactsAreExplicit = () => {
  const entries = [entry('job-1'), entry('job-2')];
  const canceled = markBatchExportNotStarted(entries, 'canceled', 'picker canceled');
  assert.deepEqual(canceled.map((item) => item.status), ['canceled', 'canceled']);
  assert.deepEqual(canceled.map((item) => [item.copySucceeded, item.exported]), [
    [false, false],
    [false, false]
  ]);
  assert.equal(canceled.every((item) => item.errorMessage === 'picker canceled'), true);
  assert.equal(entries.every((item) => item.status === 'waiting' && item.errorMessage === ''), true);
};

testPlanFilteringAndDefensiveSnapshot();
testUriLeafDecoding();
testOutOfOrderAndEncodedTargetMapping();
testTargetCardinalityDuplicatesUnknownAndProtectedPaths();
await testSerialCopyFailureIsolationAndSnapshots();
await testStopCancelsOnlyLaterEntries();
await testCheckpointFailurePreservesExportFactAndStopsLater();
await testInitialNonWaitingEntriesRemainUntouched();
await testBulkExternalLockIsAtomicAndOneJournalPerTransition();
testUnstartedBatchFactsAreExplicit();

console.log('Harmony batch export edge tests passed: plan/snapshot/uri-mapping/cardinality/alias/protection/serial-failure/stop/journal-failure/exported-facts/bulk-lock');
