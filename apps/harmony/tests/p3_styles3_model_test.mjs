import assert from 'node:assert/strict';
import {
  DEFAULT_SETTINGS,
  modeLabel,
  normalizeSettings
} from '../entry/src/main/ets/settings/SettingsModel.ts';
import { QueueController } from '../entry/src/main/ets/queue/QueueController.ts';
import { ps3OptionsFor, stableGrainSeed } from '../entry/src/main/ets/queue/Ps3Model.ts';

const ps3Mode = (enabled) => ({
  modeKey: 'apple',
  modeLabel: enabled ? 'Apple 标准 · 摄影风格 · 摄影风格 3' : 'Apple 标准',
  applePhotographicStyles3: enabled,
  config: {
    oppoCompat: 0,
    oppoCameraTail: 0,
    strictTmap: 0,
    applePhotographicStyles: enabled ? 1 : 0,
    applePortrait: 0
  }
});

const successfulResult = (item, mode) => ({
  outputPath: `/sandbox/${item.id}-${mode.applePhotographicStyles3 ? 'ps3' : 'plain'}.heic`,
  modeKey: mode.modeKey,
  modeLabel: mode.modeLabel,
  conversion: {
    success: true,
    mode: mode.modeKey,
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
  throw new Error(`timed out waiting for ${label}`);
};

const styles3 = normalizeSettings({
  ...DEFAULT_SETTINGS,
  applePhotographicStyles: false,
  applePhotographicStyles3: true
});
assert.equal(styles3.applePhotographicStyles, true);
assert.equal(styles3.outputMode, 'apple');
assert.equal(modeLabel(styles3), 'Apple 标准 · 摄影风格 · 摄影风格 3');

const firstSeed = stableGrainSeed('/sandbox/inputs/a😀.photo');
assert.equal(firstSeed, stableGrainSeed('/sandbox/inputs/a😀.photo'));
assert.notEqual(firstSeed, stableGrainSeed('/sandbox/inputs/b😀.photo'));
assert.deepEqual(ps3OptionsFor('/sandbox/inputs/a😀.photo', true), {
  applePhotographicStyles3: true,
  grainSeed: firstSeed
});

let enabled = true;
let release;
const gate = new Promise((resolve) => { release = resolve; });
const snapshots = [];
const controller = new QueueController({
  captureMode: () => ps3Mode(enabled),
  execute: async (item, mode) => {
    snapshots.push({ id: item.id, ps3: mode.applePhotographicStyles3 === true });
    if (item.displayName === 'first') await gate;
    return successfulResult(item, mode);
  }
});
controller.attach();
const first = controller.add({
  displayName: 'first',
  sourceUri: 'uri://first',
  inputPath: '/sandbox/inputs/first.photo'
});
const second = controller.add({
  displayName: 'second',
  sourceUri: 'uri://second',
  inputPath: '/sandbox/inputs/second.photo'
});
const running = controller.start();
await waitFor(() => controller.activeItemId === first.id, 'PS3 first snapshot');
enabled = false;
release();
await running;
assert.deepEqual(snapshots, [
  { id: first.id, ps3: true },
  { id: second.id, ps3: false }
]);
assert.equal(first.result.modeLabel, 'Apple 标准 · 摄影风格 · 摄影风格 3');

let attempt = 0;
const failureController = new QueueController({
  captureMode: () => ps3Mode(true),
  execute: async (item, mode) => {
    attempt += 1;
    if (attempt === 2) {
      // This is the same error surfaced when either native PS3 post-process
      // returns 0. QueueController must keep the last published result.
      throw new Error('PS3 texture_styles 注入失败');
    }
    return successfulResult(item, mode);
  }
});
failureController.attach();
const retained = failureController.add({
  displayName: 'reconvert',
  sourceUri: 'uri://reconvert',
  inputPath: '/sandbox/inputs/reconvert.photo'
});
await failureController.start();
const oldResultPath = retained.result.outputPath;
failureController.reconvert(retained.id);
await failureController.start();
assert.equal(retained.status, 'failed');
assert.equal(retained.attemptStatus, 'failed');
assert.equal(retained.result.outputPath, oldResultPath);
assert.match(retained.errorMessage, /texture_styles/);

console.log('Harmony PS3 model tests passed: dependency/seed/snapshot/post-process-failure-retention');
