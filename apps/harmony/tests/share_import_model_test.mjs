import assert from 'node:assert/strict';
import { QueueController } from '../entry/src/main/ets/queue/QueueController.ts';
import { decodeQueueSnapshot, serializeQueueSnapshot } from '../entry/src/main/ets/queue/QueuePersistence.ts';
import { QueueSandbox, SandboxPathPolicy } from '../entry/src/main/ets/queue/QueueSandbox.ts';
import {
  SHARE_IMPORT_ACTION,
  addShareInboxItem,
  emptyShareInboxSnapshot,
  filterSharedImages,
  persistQueueBeforeInboxRemoval,
  serializeShareInboxSnapshot,
  updateShareInboxItem,
  validateShareInboxSnapshot,
  WantReferenceGuard
} from '../entry/src/main/ets/queue/ShareImportModel.ts';

const inputPath = '/sandbox/inputs/share-1.heic';
const candidates = [
  { utd: 'general.heic', uri: 'file://provider/holiday.heic', title: 'Holiday' },
  { utd: 'general.image', uri: 'file://provider/portrait.jpeg?token=temporary' },
  { utd: 'general.image', uri: 'file://provider/unsupported.png' },
  { utd: 'general.text', content: 'ignore this text record' },
  { utd: 'general.heic', uri: 'file://provider/holiday.heic' },
  { utd: 'general.heic', uri: 'file://provider/mismatch.jpg' },
  { utd: 'general.jpeg', uri: 'file://provider/jpeg-without-suffix' }
];
const filtered = filterSharedImages(candidates);
assert.deepEqual(filtered.images.map((image) => image.extension), ['.heic', '.jpeg', '.jpg']);
assert.equal(filtered.images[0].displayName, 'Holiday');
assert.equal(filtered.ignored, 4);
assert.equal(filtered.truncated, 0);

const many = Array.from({ length: 17 }, (_, index) => ({
  utd: 'general.heic', uri: `file://provider/${index}.heic`
}));
const bounded = filterSharedImages(many);
assert.equal(bounded.images.length, 15);
assert.equal(bounded.truncated, 2);

assert.equal(SHARE_IMPORT_ACTION, 'ohos.want.action.sendData');
const wantGuard = new WantReferenceGuard();
const originalWant = { action: SHARE_IMPORT_ACTION };
assert.equal(wantGuard.claim(originalWant), true);
assert.equal(wantGuard.claim(originalWant), false);
assert.equal(wantGuard.claim({ action: SHARE_IMPORT_ACTION }), true);

let inbox = emptyShareInboxSnapshot();
const appended = addShareInboxItem(inbox, filtered.images[0], '/sandbox');
inbox = appended.snapshot;
assert.equal(appended.item.id, 'share-1');
assert.equal(appended.item.status, 'copying');
assert.equal(appended.item.inputPath, inputPath);
inbox = updateShareInboxItem(inbox, 'share-1', 'ready', inputPath, '');
const persistedInbox = serializeShareInboxSnapshot(inbox, '/sandbox');
assert.equal(validateShareInboxSnapshot(JSON.parse(persistedInbox), '/sandbox').items[0].status, 'ready');
assert.throws(() => validateShareInboxSnapshot({
  schema: 1,
  nextId: 2,
  notice: '',
  items: [{ ...inbox.items[0], inputPath: '/sandbox/inputs/share-9.heic' }]
}, '/sandbox'), /路径无效/);
assert.throws(() => validateShareInboxSnapshot({
  schema: 1, nextId: 2, notice: '', items: [{ ...inbox.items[0], status: 'ready', inputPath: '' }]
}, '/sandbox'), /状态与路径/);
assert.throws(() => serializeShareInboxSnapshot({ ...inbox, nextId: 1 }, '/sandbox'), /nextId/);

const handoffOrder = [];
await persistQueueBeforeInboxRemoval(
  async () => { handoffOrder.push('queue-commit'); },
  async () => { handoffOrder.push('inbox-remove'); }
);
assert.deepEqual(handoffOrder, ['queue-commit', 'inbox-remove']);
let inboxRemovedAfterFailedCommit = false;
await assert.rejects(persistQueueBeforeInboxRemoval(
  async () => { throw new Error('queue journal failed'); },
  async () => { inboxRemovedAfterFailedCommit = true; }
), /queue journal failed/);
assert.equal(inboxRemovedAfterFailedCommit, false);

const queue = new QueueController({
  captureMode: () => ({ modeKey: 'apple', modeLabel: 'Apple', config: {
    oppoCompat: 0, oppoCameraTail: 0, strictTmap: 0, applePhotographicStyles: 0, applePortrait: 0
  } }),
  execute: async () => { throw new Error('not run by this test'); }
});
const queued = queue.add({
  displayName: 'Holiday',
  sourceUri: inputPath,
  inputPath,
  sourceKind: 'share',
  sourceToken: 'share-1'
});
const roundTrip = decodeQueueSnapshot(serializeQueueSnapshot(queue.snapshot()));
assert.equal(roundTrip.corrupt, false);
assert.equal(roundTrip.snapshot.items[0].sourceKind, 'share');
assert.equal(roundTrip.snapshot.items[0].sourceToken, 'share-1');
assert.equal(queued.ownedPaths[0], inputPath);

const openedSources = [];
const executed = [];
const recoveryQueue = new QueueController({
  captureMode: () => ({ modeKey: 'apple', modeLabel: 'Apple', config: {
    oppoCompat: 0, oppoCameraTail: 0, strictTmap: 0, applePhotographicStyles: 0, applePortrait: 0
  } }),
  prepare: async (item) => {
    openedSources.push(item.sourceUri);
    throw new Error('unmaterialized shared URI must not be opened by queue retry');
  },
  execute: async (item) => {
    executed.push({ id: item.id, inputPath: item.inputPath, sourceUri: item.sourceUri });
    return {
      outputPath: '/sandbox/outputs/reselected.heic', modeKey: 'apple', modeLabel: 'Apple', conversion: {}
    };
  }
});
recoveryQueue.attach();
const staleShare = recoveryQueue.add({
  displayName: 'Holiday', sourceUri: 'file://expired/holiday.heic', sourceKind: 'share', sourceToken: 'share-2'
});
recoveryQueue.beginExternal(staleShare.id);
recoveryQueue.markPreparationFailed(staleShare.id, '分享授权已过期');
recoveryQueue.endExternal(staleShare.id);
assert.throws(() => recoveryQueue.retry(staleShare.id), /重新选择/);
assert.equal(openedSources.length, 0);
recoveryQueue.beginExternal(staleShare.id);
recoveryQueue.replaceFailedShareSource(staleShare.id, 'file://picker/fresh/holiday.heic');
recoveryQueue.setPrepared(staleShare.id, '/sandbox/inputs/share-2.heic', {}, {});
recoveryQueue.endExternal(staleShare.id);
assert.equal(recoveryQueue.get(staleShare.id).id, staleShare.id);
assert.equal(recoveryQueue.get(staleShare.id).sourceUri, '/sandbox/inputs/share-2.heic');
await recoveryQueue.start();
assert.deepEqual(openedSources, []);
assert.deepEqual(executed, [{
  id: staleShare.id, inputPath: '/sandbox/inputs/share-2.heic', sourceUri: '/sandbox/inputs/share-2.heic'
}]);
assert.equal(recoveryQueue.get(staleShare.id).status, 'succeeded');

const policy = new SandboxPathPolicy('/sandbox');
assert.equal(policy.kindOf(inputPath), 'input');
assert.equal(policy.isArtifactCandidate(inputPath), true);
assert.equal(policy.artifactPath('input', 'share-1.heic'), inputPath);

const files = new Map([[inputPath, { size: 100, isFile: true, isDirectory: false, isSymbolicLink: false }]]);
const io = {
  async stat(path) {
    if (path === '/sandbox' || path === '/sandbox/inputs' || path === '/sandbox/outputs') {
      return { size: 0, isFile: false, isDirectory: true, isSymbolicLink: false };
    }
    if (!files.has(path)) {
      const error = new Error('missing');
      error.code = 13900002;
      throw error;
    }
    return files.get(path);
  },
  async list(path) {
    if (path === '/sandbox/inputs') return ['share-1.heic'];
    return [];
  },
  async unlink(path) { files.delete(path); }
};
const sandbox = new QueueSandbox('/sandbox', io);
const protectedWhilePending = await sandbox.cleanupOrphans(new Set([inputPath]), false);
assert.deepEqual(protectedWhilePending.deletedPaths, []);
assert.equal(files.has(inputPath), true);
const removedAfterTransfer = await sandbox.cleanupOrphans(new Set(), false);
assert.deepEqual(removedAfterTransfer.deletedPaths, [inputPath]);
assert.equal(files.has(inputPath), false);

console.log('Share import tests passed: image filtering, duplicate Want guards, durable inbox paths, queue ownership transfer, and orphan protection');
