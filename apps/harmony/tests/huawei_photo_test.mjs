import assert from 'node:assert/strict';
import { mergeHuaweiInspection, convertHuaweiPortrait, livePhotoStylesCompatible, verifyStillExtraction } from '../entry/src/main/ets/queue/HuaweiPhotoModel.ts';
import { QueueController } from '../entry/src/main/ets/queue/QueueController.ts';
import { serializeQueueSnapshot, decodeQueueSnapshot } from '../entry/src/main/ets/queue/QueuePersistence.ts';

const report = (ready) => JSON.stringify({ schema: 'xdremux-huawei-heic-v1', isHuaweiHdr: true,
  hasHuaweiPortrait: true, huaweiPortrait: { detected: true, safeToTransform: ready } });
const details = mergeHuaweiInspection({ success: true, model: 'Mate 70', applePortrait: true }, report(true));
assert.equal(details.huaweiPortraitReady, true);
assert.equal(mergeHuaweiInspection({ success: true }, report('true')).huaweiPortraitReady, false);
assert.equal(mergeHuaweiInspection({ success: true }, report(false)).huaweiPortraitReady, false);
assert.throws(() => mergeHuaweiInspection({ success: true }, 'null'));
assert.throws(() => mergeHuaweiInspection({ success: true }, '{}'));

for (const [styles, styles3, flags] of [[false, false, 0], [true, false, 1], [false, true, 7], [true, true, 7]]) {
  const calls = [];
  const bridge = {
    remux: async (input, output) => { calls.push(['remux', input, output]); return '{"success":true}'; },
    verify: async (path) => { calls.push(['verify', path]); return true; },
    attach: async (...args) => { calls.push(['attach', ...args]); return '{"status":"attached"}'; }
  };
  const output = await convertHuaweiPortrait(bridge, '/original', '/base', '/styled', 123, styles, styles3);
  assert.equal(output, flags === 0 ? '/base' : '/styled');
  assert.deepEqual(calls.slice(0, 2), [['remux', '/original', '/base'], ['verify', '/base']]);
  if (flags) assert.deepEqual(calls.slice(2), [['attach', '/base', '/styled', 123, flags], ['verify', '/styled']]);
  else assert.equal(calls.length, 2);
}
verifyStillExtraction('{"success":true,"stillBytes":1234}');
assert.throws(() => verifyStillExtraction('{"success":false,"errorMessage":"bad range"}'), /bad range/);
assert.throws(() => verifyStillExtraction('{"success":true,"stillBytes":0}'), /提取失败/);
assert.equal(livePhotoStylesCompatible({ applePhotographicStyles: false, applePhotographicStyles3: false }), true);
assert.equal(livePhotoStylesCompatible({ applePhotographicStyles: true, applePhotographicStyles3: true }), true);
assert.equal(livePhotoStylesCompatible({ applePhotographicStyles: true, applePhotographicStyles3: false }), false);
assert.equal(livePhotoStylesCompatible({}), false);
let attached = false;
const badBase = { remux: async () => '{"success":true}', verify: async () => false,
  attach: async () => { attached = true; return '{"status":"attached"}'; } };
await assert.rejects(convertHuaweiPortrait(badBase, '/input', '/base', '/styled', 0, true, true), /校验失败/);
assert.equal(attached, false);
await assert.rejects(convertHuaweiPortrait(badBase, '/input', '/input', '/styled', 0, true, true), /独立输出/);
await assert.rejects(convertHuaweiPortrait({ ...badBase, verify: async () => true,
  attach: async () => '{"status":"error","message":"injection failed"}' },
  '/input', '/base', '/styled', 0, true, true), /injection failed/);
await assert.rejects(convertHuaweiPortrait({ ...badBase, verify: async (p) => p === '/base',
  attach: async () => '{"status":"attached"}' }, '/input', '/base', '/styled', 0, true, true), /附加摄影风格/);

const controller = new QueueController({ captureMode: () => ({}), execute: async () => ({}) });
const item = controller.add({ displayName: 'portrait.heic', sourceUri: '/sandbox/original.heic',
  inputPath: '/sandbox/original.heic', details: { ...details, motionPhoto: true } });
const decoded = decodeQueueSnapshot(serializeQueueSnapshot({ nextId: 20, items: controller.items() }));
assert.equal(decoded.corrupt, false);
assert.equal(decoded.snapshot.items[0].details.huaweiPortraitReady, true);
assert.equal(decoded.snapshot.items[0].details.motionPhoto, true);
assert.equal(decoded.snapshot.items[0].details.applePortrait, true);
controller.updatePhotoDetails(item.id, '/different', { success: true });
assert.equal(controller.get(item.id).details.huaweiPortraitReady, true);
console.log('Huawei capability, portrait pipeline, failure and persistence tests passed');
