import assert from 'node:assert/strict';
import {
  buildBatchExportPlan,
  attachBatchExportTargets,
  markBatchExportWaiting,
  runBatchExport,
  summarizeBatchExport
} from '../entry/src/main/ets/queue/BatchExport.ts';
import { copyBatchOutput } from '../entry/src/main/ets/queue/BatchExportCopy.ts';
import { restoreQueueSnapshot } from '../entry/src/main/ets/queue/QueuePersistence.ts';

function item(id, status = 'succeeded', outputPath = `/sandbox/outputs/${id}.heic`) {
  return {
    id,
    revision: 0,
    displayName: `${id}.jpg`,
    sourceUri: `file://source/${id}.jpg`,
    inputPath: `/sandbox/inputs/${id}.jpg`,
    status,
    attemptStatus: status === 'succeeded' ? 'succeeded' : 'failed',
    externalBusy: false,
    progress: { stage: 0, current: 0, total: 0 },
    result: {
      outputPath,
      modeKey: 'oppo',
      modeLabel: 'OPPO',
      conversion: { success: true, mode: 'oppo', family: 'heic', edrScale: 1, gainMapMax: 1, errorMessage: null }
    },
    exportedUri: '',
    errorMessage: '',
    lastAttemptModeKey: 'oppo',
    lastAttemptModeLabel: 'OPPO',
    cleanupStatus: 'none',
    cleanupErrorMessage: '',
    ownedPaths: [`/sandbox/inputs/${id}.jpg`, outputPath]
  };
}

const planned = buildBatchExportPlan([
  item('job-1'),
  item('job-2', 'failed'),
  { ...item('job-3'), exportedUri: 'file://already/exported.heic' },
  { ...item('job-4'), externalBusy: true },
  { ...item('job-5'), cleanupStatus: 'failed' }
], 'p3');
assert.equal(planned.length, 2);
assert.notEqual(planned[0].fileName, planned[1].fileName);
const shuffled = attachBatchExportTargets(
  planned,
  [`content://out/${planned[1].fileName}`, `content://out/${planned[0].fileName}`],
  ['/sandbox/inputs/job-3.jpg', '/sandbox/outputs/job-3.heic']
);
assert.equal(shuffled[0].targetUri.endsWith(planned[0].fileName), true);
assert.equal(shuffled[1].targetUri.endsWith(planned[1].fileName), true);
assert.throws(() => attachBatchExportTargets(
  planned,
  [`file:///sandbox/inputs/job-3.jpg`, `content://out/${planned[1].fileName}`],
  ['/sandbox/inputs/job-3.jpg']
));

const order = [];
let active = 0;
let maxActive = 0;
let checkpointCount = 0;
const runResult = await runBatchExport(shuffled, {
  copy: async (entry) => {
    active += 1;
    maxActive = Math.max(maxActive, active);
    order.push(`copy:${entry.id}`);
    await Promise.resolve();
    active -= 1;
    if (entry.id === 'job-2') throw new Error('target rejected');
  },
  checkpoint: async (entry) => {
    checkpointCount += 1;
    order.push(`checkpoint:${entry.id}`);
  },
  onStatus: () => { throw new Error('detached view'); }
});
assert.equal(maxActive, 1);
assert.deepEqual(order, ['copy:job-1', 'checkpoint:job-1', 'copy:job-2']);
assert.equal(checkpointCount, 1);
assert.equal(runResult[0].status, 'succeeded');
assert.equal(runResult[0].exported, true);
assert.equal(runResult[1].status, 'failed');
assert.equal(runResult[1].exported, false);
assert.equal(summarizeBatchExport(runResult).exported, 1);

const stopEntries = planned.map((entry) => ({ ...entry, status: 'waiting', copySucceeded: false, exported: false }));
let copies = 0;
const stopped = await runBatchExport(stopEntries, {
  copy: async () => { copies += 1; },
  checkpoint: async () => {},
  shouldStop: () => copies > 0
});
assert.equal(copies, 1);
assert.equal(stopped[0].status, 'succeeded');
assert.equal(stopped[1].status, 'canceled');

const waitingMarked = markBatchExportWaiting(runResult, 'failed', 'setup failed');
assert.equal(waitingMarked[0].status, 'succeeded');
assert.equal(waitingMarked[1].status, 'failed');

const interruptedExport = { ...item('job-6'), externalBusy: true };
const restoredExport = restoreQueueSnapshot(
  { nextId: 7, items: [interruptedExport] },
  { status: (path) => path === interruptedExport.inputPath || path === interruptedExport.result.outputPath ? 'file' : 'missing' }
);
assert.equal(restoredExport.snapshot.items[0].status, 'succeeded');
assert.equal(restoredExport.snapshot.items[0].attemptStatus, 'succeeded');
assert.ok(restoredExport.snapshot.items[0].result);
assert.match(restoredExport.snapshot.items[0].errorMessage, /转换结果仍保留/);

function fakeIo({ targetSize = 0, copiedSize = 12, sourceSize = 12, failCopy = false, failClose = false } = {}) {
  const calls = [];
  return {
    calls,
    openUri: async (uri) => { calls.push(['open', uri]); return 7; },
    statPath: async (path) => { calls.push(['statPath', path]); return { size: sourceSize }; },
    statFd: async (fd) => {
      calls.push(['statFd', fd]);
      return { size: calls.filter((entry) => entry[0] === 'copy').length === 0 ? targetSize : copiedSize };
    },
    copyPathToFd: async (path, fd) => {
      calls.push(['copy', path, fd]);
      if (failCopy) throw new Error('copy failed');
    },
    close: async (fd) => {
      calls.push(['close', fd]);
      if (failClose) throw new Error('close failed');
    }
  };
}
const goodIo = fakeIo();
await copyBatchOutput(goodIo, '/sandbox/out.heic', 'content://new/out.heic', 'content://source/in.jpg');
assert.equal(goodIo.calls.at(-1)[0], 'close');
const nonEmptyIo = fakeIo({ targetSize: 2 });
await assert.rejects(() => copyBatchOutput(nonEmptyIo, '/sandbox/out.heic', 'content://old/out.heic', 'content://source/in.jpg'));
assert.equal(nonEmptyIo.calls.some((entry) => entry[0] === 'copy'), false);
const failedIo = fakeIo({ failCopy: true });
await assert.rejects(() => copyBatchOutput(failedIo, '/sandbox/out.heic', 'content://new/out.heic', 'content://source/in.jpg'));
assert.equal(failedIo.calls.filter((entry) => entry[0] === 'close').length, 1);
assert.equal(failedIo.calls.some((entry) => entry[0] === 'unlink'), false);
const mismatchIo = fakeIo({ copiedSize: 11 });
await assert.rejects(() => copyBatchOutput(mismatchIo, '/sandbox/out.heic', 'content://new/out.heic', 'content://source/in.jpg'));
assert.equal(mismatchIo.calls.filter((entry) => entry[0] === 'close').length, 1);
const closeFailIo = fakeIo({ failClose: true });
await assert.rejects(() => copyBatchOutput(closeFailIo, '/sandbox/out.heic', 'content://new/out.heic', 'content://source/in.jpg'));
assert.equal(closeFailIo.calls.some((entry) => entry[0] === 'copy'), true);
const emptySourceIo = fakeIo({ sourceSize: 0 });
await assert.rejects(() => copyBatchOutput(emptySourceIo, '/sandbox/out.heic', 'content://new/out.heic', 'content://source/in.jpg'));
assert.equal(emptySourceIo.calls.some((entry) => entry[0] === 'open'), false);

console.log('P3 batch export tests passed: snapshot/mapping/serial/callback-isolation/stop/waiting-mark/FD-copy');
