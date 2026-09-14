import assert from 'node:assert/strict';
import { SettingsPersistence } from '../entry/src/main/ets/settings/SettingsPersistence.ts';
import {
  DEFAULT_SETTINGS,
  OPPO_CAMERA_TAIL_OPTIONS,
  OPPO_COMPAT_OPTIONS,
  SettingsSaveQueue,
  decodeSettingsJson,
  modeLabel,
  normalizeSettings,
  serializeSettings,
  settingsEqual
} from '../entry/src/main/ets/settings/SettingsModel.ts';

const assertDefaults = () => {
  assert.deepEqual(DEFAULT_SETTINGS, {
    outputMode: 'oppo',
    oppoCompat: 2,
    oppoCameraTail: 255,
    strictTmap: false,
    applePhotographicStyles: false,
    applePortrait: false
  });
  assert.deepEqual(OPPO_COMPAT_OPTIONS.map((option) => option.value), [1, 2, 3, 4, 5, 6, 0]);
  assert.deepEqual(OPPO_CAMERA_TAIL_OPTIONS.map((option) => option.value), [255, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
};

const assertModeTransitions = () => {
  const apple = normalizeSettings({ ...DEFAULT_SETTINGS, outputMode: 'oppo', applePortrait: true });
  assert.equal(apple.outputMode, 'apple');
  assert.equal(apple.oppoCompat, 0);
  assert.equal(apple.oppoCameraTail, 0);

  const appleFeatures = normalizeSettings({
    ...DEFAULT_SETTINGS,
    outputMode: 'oppo',
    applePhotographicStyles: true,
    applePortrait: true,
    strictTmap: true
  });
  assert.equal(appleFeatures.outputMode, 'apple');
  assert.equal(appleFeatures.strictTmap, true);
  assert.equal(modeLabel(appleFeatures), 'Apple 标准 · 摄影风格 · 人像数据 · 严格 ISO');

  const explicitOff = normalizeSettings({ ...DEFAULT_SETTINGS, oppoCompat: 0, oppoCameraTail: 9 });
  assert.equal(explicitOff.outputMode, 'oppo');
  assert.equal(explicitOff.oppoCompat, 0);
  assert.equal(explicitOff.oppoCameraTail, 9);
};

const assertStorageValidation = () => {
  const encoded = serializeSettings(DEFAULT_SETTINGS);
  assert.deepEqual(decodeSettingsJson(encoded), { values: DEFAULT_SETTINGS, warning: '' });
  for (const raw of ['', 'null', '[]', '3', '"settings"', '{bad json']) {
    const result = decodeSettingsJson(raw);
    if (raw === '') {
      assert.equal(result.warning, '');
    } else {
      assert.match(result.warning, /设置文件无效/);
      assert.deepEqual(result.values, DEFAULT_SETTINGS);
    }
  }
  const wrongEnum = decodeSettingsJson(JSON.stringify({
    schema: 1,
    outputMode: 'oppo',
    oppoCompat: 8,
    oppoCameraTail: 255,
    strictTmap: false,
    applePhotographicStyles: false,
    applePortrait: false
  }));
  assert.match(wrongEnum.warning, /OPPO 兼容值错误/);

  const wrongType = decodeSettingsJson(JSON.stringify({
    schema: 1,
    outputMode: 'oppo',
    oppoCompat: 2,
    oppoCameraTail: 255,
    strictTmap: 1,
    applePhotographicStyles: false,
    applePortrait: false
  }));
  assert.match(wrongType.warning, /布尔值错误/);
  const wrongSchema = decodeSettingsJson(JSON.stringify({
    schema: 2,
    outputMode: 'oppo',
    oppoCompat: 2,
    oppoCameraTail: 255,
    strictTmap: false,
    applePhotographicStyles: false,
    applePortrait: false
  }));
  assert.match(wrongSchema.warning, /版本不受支持/);
};

const assertSerialWritesAndFailureRecovery = async () => {
  const calls = [];
  let rejectFirst = true;
  const queue = new SettingsSaveQueue(async (values) => {
    calls.push(values.oppoCompat);
    await Promise.resolve();
    if (rejectFirst) {
      rejectFirst = false;
      throw new Error('synthetic flush failure');
    }
  });
  const firstValues = { ...DEFAULT_SETTINGS, oppoCompat: 1 };
  const secondValues = { ...DEFAULT_SETTINGS, oppoCompat: 6 };
  const first = queue.enqueue(firstValues).catch(() => undefined);
  // The queue must snapshot caller-owned objects before an async write starts.
  firstValues.oppoCompat = 4;
  const second = queue.enqueue(secondValues);
  await Promise.all([first, second]);
  assert.deepEqual(calls, [1, 6]);
  assert.equal(settingsEqual(secondValues, { ...DEFAULT_SETTINGS, oppoCompat: 6 }), true);
};

const fakePreferences = (initialRaw) => {
  let raw = initialRaw;
  let pending = initialRaw;
  let failNextFlush = false;
  return {
    get raw() {
      return raw;
    },
    failNext() {
      failNextFlush = true;
    },
    has: async () => raw !== undefined,
    getString: async () => raw ?? '',
    putString: (value) => {
      pending = value;
    },
    delete: () => {
      pending = undefined;
    },
    flush: async () => {
      if (failNextFlush) {
        failNextFlush = false;
        throw new Error('synthetic flush failure');
      }
      raw = pending;
    }
  };
};

const assertPersistenceRollback = async () => {
  const corrupt = fakePreferences('{broken persisted settings');
  const corruptPersistence = new SettingsPersistence(corrupt);
  const corruptLoad = await corruptPersistence.load();
  assert.match(corruptLoad.warning, /原数据未覆盖/);
  corrupt.failNext();
  await assert.rejects(
    corruptPersistence.save({ ...DEFAULT_SETTINGS, strictTmap: true }),
    /已保留未保存草稿/
  );
  assert.equal(corrupt.raw, '{broken persisted settings');
  await corruptPersistence.save({ ...DEFAULT_SETTINGS, strictTmap: true });
  assert.match(corrupt.raw, /"strictTmap":true/);

  const normalizedStore = fakePreferences(undefined);
  const normalizedPersistence = new SettingsPersistence(normalizedStore);
  await normalizedPersistence.load();
  await normalizedPersistence.save({ ...DEFAULT_SETTINGS, outputMode: 'oppo', applePortrait: true });
  const afterSave = await normalizedPersistence.load();
  assert.equal(afterSave.values.outputMode, 'apple');
  assert.equal(afterSave.values.oppoCompat, 0);
  assert.equal(afterSave.values.oppoCameraTail, 0);
  assert.equal(afterSave.values.applePortrait, true);
  assert.match(normalizedStore.raw, /"outputMode":"apple"/);

  const missing = fakePreferences(undefined);
  const missingPersistence = new SettingsPersistence(missing);
  const missingLoad = await missingPersistence.load();
  assert.equal(missingLoad.warning, '');
  missing.failNext();
  await assert.rejects(missingPersistence.save({ ...DEFAULT_SETTINGS, oppoCompat: 6 }));
  assert.equal(missing.raw, undefined);
};

assertDefaults();
assertModeTransitions();
assertStorageValidation();
await assertSerialWritesAndFailureRecovery();
await assertPersistenceRollback();
console.log('Harmony settings model tests passed: defaults/mapping/transitions/schema/serial writer/core persistence rollback');
