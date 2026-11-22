import assert from 'node:assert/strict';
import {
  buildMotionSplitPathPlan,
  parseMotionSplitJson,
  runMotionSplitPipeline
} from '../entry/src/main/ets/queue/MotionPhotoSplitModel.ts';
import { SandboxPathPolicy } from '../entry/src/main/ets/queue/QueueSandbox.ts';
import { assertSafeExportDestination } from '../entry/src/main/ets/queue/BatchExport.ts';
import { QueueController } from '../entry/src/main/ets/queue/QueueController.ts';

const root = '/sandbox';
const inputPath = '/sandbox/inputs/input-job-1.photo';
const plan = buildMotionSplitPathPlan(root, 'job-1', 1700000000000, 1, inputPath);
assert.equal(plan.ownedPaths.length, 5);
assert.equal(plan.outputDirectory, '/sandbox/outputs');
assert.equal(plan.stillJpgPath.endsWith('.still.jpg'), true);
assert.equal(plan.stillHeicPath.endsWith('.still.heic'), true);
assert.equal(plan.videoPath.endsWith('.video.mp4'), true);
assert.equal(plan.primaryPath.endsWith('.primary.mp4'), true);
assert.equal(new Set(plan.ownedPaths).size, 5);
assert.throws(() => buildMotionSplitPathPlan(root, 'job/1', 1700000000000, 1, inputPath), /不安全/);

const report = (overrides = {}) => JSON.stringify({
  success: true,
  isMotionPhoto: true,
  sourceKind: 'androidMotionPhotoV1',
  stillStart: 0,
  stillEnd: 100,
  videoStart: 100,
  videoEnd: 500,
  isDualStream: false,
  items: [
    { mime: 'image/jpeg', semantic: 'Primary', length: 100, padding: 0 },
    { mime: 'video/mp4', semantic: 'MotionPhoto', length: 400, padding: 0 }
  ],
  stillPath: plan.stillJpgPath,
  videoPath: plan.videoPath,
  ...overrides
});

const fileStat = (size) => ({ size, isFile: true, isDirectory: false, isSymbolicLink: false });
const stats = new Map([
  [plan.stillJpgPath, fileStat(100)],
  [plan.videoPath, fileStat(400)]
]);
const parsed = parseMotionSplitJson(report(), plan, inputPath, 500, stats);
assert.equal(parsed.assets.map((asset) => asset.kind).join(','), 'still,video');
assert.equal(parsed.assets[0].mime, 'image/jpeg');
assert.equal(parsed.assets[1].mime, 'video/mp4');
assert.throws(() => parseMotionSplitJson(report({ stillPath: plan.stillHeicPath }), plan, inputPath, 500, stats), /扩展名/);
assert.throws(() => parseMotionSplitJson(report({ videoPath: plan.primaryPath }), plan, inputPath, 500, stats), /视频路径/);
assert.throws(() => parseMotionSplitJson(report(), plan, inputPath, 500,
  new Map([[plan.stillHeicPath, fileStat(100)], [plan.videoPath, fileStat(400)]])), /实际写出/);
assert.throws(() => parseMotionSplitJson(report(), plan, inputPath, 500,
  new Map([[plan.stillJpgPath, fileStat(99)], [plan.videoPath, fileStat(400)]])), /大小/);

function makeHooks({ existingPath = '', persistError = false, splitError = false, cleanupError = false } = {}) {
  const files = new Map([[inputPath, fileStat(500)]]);
  const cleanupCalls = [];
  let registered = [];
  let copied = false;
  return {
    cleanupCalls,
    get registered() { return registered; },
    status: async (path) => {
      if (path === existingPath) return 'file';
      if (files.has(path)) return files.get(path).size === 0 ? 'empty' : 'file';
      return 'missing';
    },
    stat: async (path) => {
      if (!files.has(path)) throw new Error('missing ' + path);
      return files.get(path);
    },
    register: (paths) => { registered = paths.slice(); },
    persist: async () => { if (persistError) throw new Error('journal failed'); },
    copy: async (_source, destination) => {
      copied = true;
      files.set(destination, fileStat(500));
    },
    runSplit: async () => {
      if (!copied) throw new Error('scratch was not copied');
      if (splitError) {
        files.set(plan.stillJpgPath, fileStat(100));
        throw new Error('rust split failed');
      }
      files.set(plan.stillJpgPath, fileStat(100));
      files.set(plan.videoPath, fileStat(400));
      return report();
    },
    cleanup: async (paths) => {
      cleanupCalls.push(paths.slice());
      if (cleanupError) throw new Error('cleanup failed');
      for (const path of paths) files.delete(path);
    }
  };
}

const successHooks = makeHooks();
const success = await runMotionSplitPipeline(
  { plan, sourceInputPath: inputPath, sourceBytes: 500 },
  successHooks
);
assert.equal(success.assets.length, 2);
assert.deepEqual(successHooks.registered, plan.ownedPaths);
assert.deepEqual(successHooks.cleanupCalls, [[plan.scratchInputPath]]);

const existingHooks = makeHooks({ existingPath: plan.videoPath });
await assert.rejects(
  runMotionSplitPipeline({ plan, sourceInputPath: inputPath, sourceBytes: 500 }, existingHooks),
  /预留路径必须不存在/
);
assert.deepEqual(existingHooks.cleanupCalls, []);
assert.deepEqual(existingHooks.registered, []);

const persistHooks = makeHooks({ persistError: true });
await assert.rejects(
  runMotionSplitPipeline({ plan, sourceInputPath: inputPath, sourceBytes: 500 }, persistHooks),
  /journal failed/
);
assert.deepEqual(persistHooks.cleanupCalls, []);

const partialHooks = makeHooks({ splitError: true });
await assert.rejects(
  runMotionSplitPipeline({ plan, sourceInputPath: inputPath, sourceBytes: 500 }, partialHooks),
  /rust split failed/
);
assert.deepEqual(partialHooks.cleanupCalls, [plan.ownedPaths]);

const cleanupWarningHooks = makeHooks({ cleanupError: true });
const cleanupWarning = await runMotionSplitPipeline(
  { plan, sourceInputPath: inputPath, sourceBytes: 500 },
  cleanupWarningHooks
);
assert.equal(cleanupWarning.assets.length, 2);
assert.match(cleanupWarning.cleanupWarning, /cleanup failed/);

const ownershipController = new QueueController({
  captureMode: () => ({ modeKey: 'oppo', modeLabel: 'OPPO', config: {
    oppoCompat: 2, oppoCameraTail: 255, strictTmap: 0, applePhotographicStyles: 0, applePortrait: 0
  } }),
  execute: async () => { throw new Error('unused'); }
});
const owner = ownershipController.add({ displayName: 'owner', sourceUri: 'file://owner', inputPath });
const other = ownershipController.add({ displayName: 'other', sourceUri: 'file://other', inputPath: plan.videoPath });
ownershipController.beginExternal(owner.id);
assert.throws(() => ownershipController.registerOwnedPaths(owner.id, plan.ownedPaths), /其他项目占用/);
assert.deepEqual(ownershipController.get(owner.id).ownedPaths, [inputPath]);
assert.deepEqual(ownershipController.get(other.id).ownedPaths, [plan.videoPath]);

const policy = new SandboxPathPolicy(root);
assert.equal(policy.isArtifactCandidate(plan.stillJpgPath), true);
assert.equal(policy.isArtifactCandidate(plan.stillHeicPath), true);
assert.equal(policy.isArtifactCandidate(plan.videoPath), true);
assert.equal(policy.isArtifactCandidate(plan.primaryPath), true);
assertSafeExportDestination('content://picker/export.jpg', [inputPath, plan.videoPath]);
assert.throws(() => assertSafeExportDestination('file:///sandbox/outputs/' + encodeURIComponent(plan.videoPath.split('/').pop()), [plan.videoPath]), /不能是/);

console.log('Motion Photo split model tests passed: plan/parser/preflight/persist/partial-cleanup/sandbox/export-protection');
