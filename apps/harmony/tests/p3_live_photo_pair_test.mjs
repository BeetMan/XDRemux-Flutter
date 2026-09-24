import assert from 'node:assert/strict';
import {
  buildLivePhotoPairPathPlan,
  runLivePhotoPairPipeline
} from '../entry/src/main/ets/queue/LivePhotoPairModel.ts';
import {
  attachLivePhotoExportTargets,
  buildLivePhotoExportPlan,
  runLivePhotoPairExport,
  summarizeLivePhotoExport
} from '../entry/src/main/ets/queue/LivePhotoPairExport.ts';
import { QueueController } from '../entry/src/main/ets/queue/QueueController.ts';
import { decodeQueueSnapshot, serializeQueueSnapshot } from '../entry/src/main/ets/queue/QueuePersistence.ts';
import { SandboxPathPolicy } from '../entry/src/main/ets/queue/QueueSandbox.ts';

const root = '/sandbox';
const source = '/sandbox/inputs/input-job-1.photo';
const converted = '/sandbox/outputs/apple-job-1.heic';
const plan = buildLivePhotoPairPathPlan(root, 'job-1', 1700000000000, 1, source, converted);
const id = '12345678-1234-4abc-8abc-123456789abc';
const stat = (size) => ({ size, isFile: true, isDirectory: false, isSymbolicLink: false });
assert.equal(plan.ownedPaths.length, 3);
assert.equal(plan.stillPath.endsWith('.heic'), true);
assert.equal(plan.movPath.endsWith('.mov'), true);
assert.equal(plan.scratchInputPath.endsWith('.photo'), true);
assert.equal(new Set(plan.ownedPaths).size, 3);
assert.throws(() => buildLivePhotoPairPathPlan(root, 'job/1', 1, 1, source, converted), /字符|无效/);
assert.throws(() => buildLivePhotoPairPathPlan(root, 'job-1', 1, 1, source, source), /来源路径不一致/);

function makeHooks({
  collision = '',
  persistError = false,
  makeError = false,
  badPath = false,
  valid = true,
  cleanupError = false
} = {}) {
  const files = new Map([[source, stat(500)], [converted, stat(800)]]);
  const calls = [];
  const registered = [];
  const cleanupCalls = [];
  const hooks = {
    files,
    calls,
    registered,
    cleanupCalls,
    status: async (path) => {
      calls.push(['status', path]);
      if (path === collision) return 'file';
      if (!files.has(path)) return 'missing';
      return files.get(path).size > 0 ? 'file' : 'empty';
    },
    stat: async (path) => {
      calls.push(['stat', path]);
      if (!files.has(path)) throw new Error('missing ' + path);
      return files.get(path);
    },
    register: (paths) => { calls.push(['register']); registered.push(...paths); },
    persist: async () => {
      calls.push(['persist']);
      if (persistError) throw new Error('journal failed');
    },
    copy: async (src, dst) => {
      calls.push(['copy', src, dst]);
      files.set(dst, stat(files.get(src).size));
    },
    makeLivePhoto: async (src, still, outputDirectory) => {
      calls.push(['make', src, still, outputDirectory]);
      if (!files.has(plan.scratchInputPath)) throw new Error('source was not materialized');
      if (makeError) {
        files.set(plan.stillPath, stat(120));
        throw new Error('second output write failed');
      }
      files.set(plan.stillPath, stat(120));
      files.set(plan.movPath, stat(900));
      return JSON.stringify({
        success: true,
        stillPath: badPath ? '/sandbox/outputs/other.heic' : plan.stillPath,
        videoPath: plan.movPath,
        contentIdentifier: id
      });
    },
    pairValid: async (still, mov) => {
      calls.push(['valid', still, mov]);
      assert.ok(files.get(still).size > 0 && files.get(mov).size > 0);
      return valid;
    },
    cleanup: async (paths) => {
      calls.push(['cleanup', ...paths]);
      cleanupCalls.push(paths.slice());
      if (cleanupError) throw new Error('cleanup failed');
      for (const path of paths) files.delete(path);
    }
  };
  return hooks;
}

const hooks = makeHooks();
const paired = await runLivePhotoPairPipeline(
  { plan, sourceInputPath: source, convertedStillPath: converted },
  hooks
);
assert.equal(paired.contentIdentifier, id);
assert.equal(paired.stillSize, 120);
assert.equal(paired.movSize, 900);
assert.deepEqual(hooks.registered, plan.ownedPaths);
assert.deepEqual(hooks.cleanupCalls, [[plan.scratchInputPath]]);
const copyIndex = hooks.calls.findIndex((call) => call[0] === 'copy');
const registerIndex = hooks.calls.findIndex((call) => call[0] === 'register');
const persistIndex = hooks.calls.findIndex((call) => call[0] === 'persist');
const nativeIndex = hooks.calls.findIndex((call) => call[0] === 'make');
assert.ok(registerIndex >= 0 && persistIndex > registerIndex && copyIndex > persistIndex && nativeIndex > copyIndex);

const collisionHooks = makeHooks({ collision: plan.movPath });
await assert.rejects(() => runLivePhotoPairPipeline(
  { plan, sourceInputPath: source, convertedStillPath: converted }, collisionHooks), /必须不存在/);
assert.deepEqual(collisionHooks.registered, []);
assert.deepEqual(collisionHooks.cleanupCalls, []);
assert.equal(collisionHooks.calls.some((call) => call[0] === 'copy'), false);

const persistHooks = makeHooks({ persistError: true });
await assert.rejects(() => runLivePhotoPairPipeline(
  { plan, sourceInputPath: source, convertedStillPath: converted }, persistHooks), /journal failed/);
assert.equal(persistHooks.calls.some((call) => call[0] === 'copy'), false);
assert.equal(persistHooks.calls.some((call) => call[0] === 'make'), false);
assert.deepEqual(persistHooks.cleanupCalls, []);

for (const failure of [
  { options: { makeError: true }, expected: /second output write failed/ },
  { options: { badPath: true }, expected: /报告路径/ },
  { options: { valid: false }, expected: /Rust 未确认/ }
]) {
  const failingHooks = makeHooks(failure.options);
  await assert.rejects(() => runLivePhotoPairPipeline(
    { plan, sourceInputPath: source, convertedStillPath: converted }, failingHooks), failure.expected);
  assert.deepEqual(failingHooks.cleanupCalls, [plan.ownedPaths]);
  assert.equal(failingHooks.files.has(source), true);
  assert.equal(failingHooks.files.has(converted), true);
}

const cleanupWarningHooks = makeHooks({ cleanupError: true });
const cleanupWarningPair = await runLivePhotoPairPipeline(
  { plan, sourceInputPath: source, convertedStillPath: converted }, cleanupWarningHooks);
assert.match(cleanupWarningPair.cleanupWarning, /cleanup failed/);

const exportPlan = buildLivePhotoExportPlan(paired);
assert.equal(exportPlan.length, 2);
assert.equal(exportPlan[0].fileName.replace(/\.heic$/, ''), exportPlan[1].fileName.replace(/\.mov$/, ''));
const unorderedUris = [
  'content://provider/document/' + exportPlan[1].fileName,
  'content://provider/document/' + exportPlan[0].fileName
];
const mapped = attachLivePhotoExportTargets(exportPlan, unorderedUris, [source, converted, ...plan.ownedPaths]);
assert.equal(mapped[0].targetUri, unorderedUris[1]);
assert.equal(mapped[1].targetUri, unorderedUris[0]);
assert.throws(() => attachLivePhotoExportTargets(exportPlan, [unorderedUris[0]], []), /两个目标/);
assert.throws(() => attachLivePhotoExportTargets(exportPlan, [unorderedUris[0], unorderedUris[0]], []), /重复/);
assert.throws(() => attachLivePhotoExportTargets(exportPlan, [
  'file:///sandbox/outputs/' + encodeURIComponent(plan.stillPath.split('/').at(-1)),
  unorderedUris[1]
], [source, converted, ...plan.ownedPaths]), /不能覆盖/);
assert.throws(() => attachLivePhotoExportTargets(exportPlan, [
  'content://provider/document/wrong.heic', unorderedUris[1]
], []), /无法按文件名/);

const copyCalls = [];
const completed = await runLivePhotoPairExport(mapped, async (entry) => {
  copyCalls.push(entry.kind);
  if (entry.kind === 'still') throw new Error('HEIC destination already contains data');
});
assert.deepEqual(copyCalls, ['still', 'video']);
assert.equal(completed[0].status, 'failed');
assert.equal(completed[1].status, 'succeeded');
assert.deepEqual(summarizeLivePhotoExport(completed), { total: 2, succeeded: 1, failed: 1, waiting: 0 });

const policy = new SandboxPathPolicy(root);
assert.equal(policy.isArtifactCandidate(plan.stillPath), true);
assert.equal(policy.isArtifactCandidate(plan.movPath), true);

const controller = new QueueController({
  captureMode: () => ({ modeKey: 'apple', modeLabel: 'Apple', config: {
    oppoCompat: 0, oppoCameraTail: 0, strictTmap: 0, applePhotographicStyles: 0, applePortrait: 0
  } }),
  execute: async () => ({
    outputPath: converted,
    modeKey: 'apple',
    modeLabel: 'Apple',
    conversion: { success: true, mode: 'apple', family: 'test', edrScale: 1, gainMapMax: 2, errorMessage: null }
  })
});
const item = controller.add({ displayName: 'motion', sourceUri: 'content://source', inputPath: source });
controller.attach();
await controller.start();
assert.equal(controller.get(item.id).result.sourceInputPath, source);
const encoded = JSON.parse(serializeQueueSnapshot(controller.snapshot()));
assert.equal(encoded.items[0].result.sourceInputPath, source);
delete encoded.items[0].result.sourceInputPath;
const legacy = decodeQueueSnapshot(JSON.stringify(encoded));
assert.equal(legacy.corrupt, false);
assert.equal(legacy.snapshot.items[0].result.sourceInputPath, undefined);

controller.beginExternal(item.id);
const replacement = '/sandbox/inputs/input-job-1-replacement.photo';
controller.setPrepared(item.id, replacement, { success: true }, {
  modeKey: 'apple', folderName: 'Apple', status: 'ok', rawUserComment: null,
  hasTagFlags: false, tagFlags: 0n, unknownFlags: 0n, hdrKind: null, family: null
});
assert.equal(controller.get(item.id).result.sourceInputPath, source);
assert.notEqual(controller.get(item.id).result.sourceInputPath, controller.get(item.id).inputPath);
controller.endExternal(item.id);

console.log('P3 Live Photo pair tests passed: exact source binding, persisted ownership, native reports, preflight, cleanup, pair validation, URI mapping, and partial serial export');
