import assert from 'node:assert/strict';
import {
  QUEUE_SCHEMA_VERSION,
  QueuePersistenceError,
  QueueStateStore,
  decodeQueueSnapshot,
  emptyQueueSnapshot,
  restoreQueueSnapshot,
  serializeQueueSnapshot
} from '../entry/src/main/ets/queue/QueuePersistence.ts';

const MAX_U64 = 18446744073709551615n;

const hasOwn = (value, key) => Object.prototype.hasOwnProperty.call(value, key);

const classification = (tagFlags = 0n, unknownFlags = 0n) => ({
  modeKey: 'oppo',
  folderName: 'OPPO',
  status: 'ok',
  rawUserComment: null,
  hasTagFlags: true,
  tagFlags,
  unknownFlags,
  hdrKind: 'gain-map',
  family: 'test'
});

const conversion = (overrides = {}) => ({
  success: true,
  mode: 'oppo',
  family: 'test',
  edrScale: 1,
  gainMapMax: 2,
  errorMessage: null,
  ...overrides
});

const resultFor = (id, overrides = {}) => ({
  outputPath: `/sandbox/${id}.output.heic`,
  modeKey: 'oppo',
  modeLabel: 'OPPO 兼容',
  conversion: conversion(),
  ...overrides
});

const queueItem = (overrides = {}) => {
  const id = overrides.id ?? 'job-1';
  const inputPath = hasOwn(overrides, 'inputPath') ? overrides.inputPath : `/sandbox/${id}.input.jpg`;
  const result = hasOwn(overrides, 'result') ? overrides.result : undefined;
  const ownedPaths = hasOwn(overrides, 'ownedPaths')
    ? overrides.ownedPaths
    : [inputPath, result?.outputPath].filter((path) => path !== undefined && path.length > 0);
  const item = {
    id,
    revision: 42,
    displayName: `display-${id}`,
    sourceUri: `content://${id}`,
    inputPath,
    status: 'pending',
    attemptStatus: 'idle',
    externalBusy: false,
    classification: classification(),
    progress: { stage: 1, current: 2, total: 3 },
    exportedUri: '',
    errorMessage: '',
    lastAttemptModeKey: '',
    lastAttemptModeLabel: '',
    cleanupStatus: 'none',
    cleanupErrorMessage: '',
    ownedPaths
  };
  if (hasOwn(overrides, 'details')) item.details = overrides.details;
  if (result !== undefined) item.result = result;
  for (const [key, value] of Object.entries(overrides)) {
    if (key !== 'result' && key !== 'details' && key !== 'ownedPaths') item[key] = value;
  }
  return item;
};

const snapshotWith = (items, nextId = 10) => ({ nextId, items });

const validSerializedRecord = (item = queueItem(), nextId = 10) => (
  JSON.parse(serializeQueueSnapshot(snapshotWith([item], nextId)))
);

const assertCorrupt = (raw, pattern) => {
  const decoded = decodeQueueSnapshot(raw);
  assert.equal(decoded.corrupt, true, `expected corrupt record for ${raw}`);
  assert.equal(decoded.snapshot, undefined);
  assert.match(decoded.warning, /队列记录无效/);
  if (pattern !== undefined) assert.match(decoded.warning, pattern);
  return decoded;
};

const assertRejected = (operation, pattern) => {
  assert.throws(operation, (error) => {
    assert.ok(error instanceof Error);
    if (pattern !== undefined) assert.match(error.message, pattern);
    return true;
  });
};

const probeFor = (states = {}) => ({
  status(path) {
    return states[path] ?? 'missing';
  }
});

class MemoryAdapter {
  constructor() {
    this.files = new Map();
    this.writeCalls = [];
    this.renameCalls = [];
    this.failWrites = 0;
    this.failRenameAt = undefined;
  }

  async exists(path) {
    return this.files.has(path);
  }

  async readText(path) {
    if (!this.files.has(path)) throw new Error(`missing ${path}`);
    return this.files.get(path);
  }

  async writeAtomic(path, content) {
    this.writeCalls.push({ path, content });
    const temporaryPath = `${path}.tmp`;
    this.files.set(temporaryPath, content);
    if (this.failWrites > 0) {
      this.failWrites -= 1;
      throw new Error('synthetic atomic write failure');
    }
    this.files.set(path, content);
    this.files.delete(temporaryPath);
  }

  async rename(oldPath, newPath) {
    this.renameCalls.push({ oldPath, newPath });
    if (this.failRenameAt === this.renameCalls.length) {
      throw new Error(`synthetic rename failure ${this.renameCalls.length}`);
    }
    if (!this.files.has(oldPath)) throw new Error(`missing ${oldPath}`);
    this.files.set(newPath, this.files.get(oldPath));
    this.files.delete(oldPath);
  }
}

const testU64RoundTrip = () => {
  const item = queueItem({
    classification: classification(MAX_U64, 0n),
    result: resultFor('job-1')
  });
  const encoded = serializeQueueSnapshot(snapshotWith([item], 2));
  const rawRecord = JSON.parse(encoded);
  assert.equal(rawRecord.schema, QUEUE_SCHEMA_VERSION);
  assert.equal(rawRecord.items[0].classification.tagFlags, MAX_U64.toString());
  assert.equal(rawRecord.items[0].classification.unknownFlags, '0');

  const decoded = decodeQueueSnapshot(encoded);
  assert.equal(decoded.corrupt, false);
  assert.equal(decoded.snapshot.nextId, 2);
  assert.equal(decoded.snapshot.items[0].revision, 0);
  assert.equal(decoded.snapshot.items[0].classification.tagFlags, MAX_U64);
  assert.equal(decoded.snapshot.items[0].classification.unknownFlags, 0n);
  assert.equal(decoded.snapshot.items[0].result.conversion.success, true);

  for (const value of ['00', '-1', '18446744073709551616', '1.0']) {
    const invalid = JSON.parse(encoded);
    invalid.items[0].classification.tagFlags = value;
    assertCorrupt(JSON.stringify(invalid), /tagFlags/);
  }
};

const testEmptyAndMalformedRecords = async () => {
  assertCorrupt('', /记录为空/);
  assertCorrupt('   ');
  for (const raw of ['null', '[]', '3', '"queue"', '{bad json']) assertCorrupt(raw);

  const validEmpty = JSON.stringify({ schema: QUEUE_SCHEMA_VERSION, nextId: 1, items: [] });
  assert.equal(decodeQueueSnapshot(validEmpty).corrupt, false);
  assert.deepEqual(decodeQueueSnapshot(validEmpty).snapshot, emptyQueueSnapshot());

  const invalidRoots = [
    { schema: QUEUE_SCHEMA_VERSION + 1, nextId: 1, items: [] },
    { schema: null, nextId: 1, items: [] },
    { schema: QUEUE_SCHEMA_VERSION, nextId: 0, items: [] },
    { schema: QUEUE_SCHEMA_VERSION, nextId: 1.5, items: [] },
    { schema: QUEUE_SCHEMA_VERSION, nextId: 1, items: {} },
    { schema: QUEUE_SCHEMA_VERSION, nextId: 1, items: [null] }
  ];
  for (const root of invalidRoots) assertCorrupt(JSON.stringify(root));

  for (const [field, value] of [
    ['displayName', null],
    ['sourceUri', null],
    ['inputPath', null],
    ['externalBusy', null],
    ['status', 'unknown'],
    ['attemptStatus', 'unknown'],
    ['cleanupStatus', null],
    ['details', null],
    ['classification', null],
    ['result', null],
    ['ownedPaths', null]
  ]) {
    const record = validSerializedRecord();
    record.items[0][field] = value;
    assertCorrupt(JSON.stringify(record), new RegExp(field));
  }
  const badProgress = validSerializedRecord();
  badProgress.items[0].progress.current = null;
  assertCorrupt(JSON.stringify(badProgress), /progress\.current/);

  const adapter = new MemoryAdapter();
  const store = new QueueStateStore('/empty-main', adapter);
  adapter.files.set(store.path, '');
  const loaded = await store.load();
  assert.equal(loaded.corrupt, true);
  assert.equal(loaded.snapshot, undefined);
  assert.equal(loaded.tempPresent, false);
  assert.match(loaded.warning, /记录为空/);
};

const testIdentifierAndOwnershipInvariants = () => {
  assertRejected(
    () => serializeQueueSnapshot(snapshotWith([queueItem({ id: 'job-1' }), queueItem({ id: 'job-1' })])),
    /重复任务 ID/
  );
  const duplicateId = validSerializedRecord();
  duplicateId.items.push({ ...duplicateId.items[0] });
  assertCorrupt(JSON.stringify(duplicateId), /任务 ID 重复/);

  assertRejected(
    () => serializeQueueSnapshot(snapshotWith([queueItem({ id: 'job-1' })], 1)),
    /nextId.*冲突/
  );
  const nextIdConflict = validSerializedRecord(queueItem({ id: 'job-1' }), 2);
  nextIdConflict.nextId = 1;
  assertCorrupt(JSON.stringify(nextIdConflict), /nextId.*冲突/);

  const sharedPath = '/sandbox/shared-input.jpg';
  const crossTask = [
    queueItem({ id: 'job-1', inputPath: sharedPath, ownedPaths: [sharedPath] }),
    queueItem({ id: 'job-2', inputPath: sharedPath, ownedPaths: [sharedPath] })
  ];
  assertRejected(
    () => serializeQueueSnapshot(snapshotWith(crossTask, 3)),
    /跨任务重复/
  );
  const crossTaskRecord = validSerializedRecord(queueItem({ id: 'job-1' }));
  const second = validSerializedRecord(queueItem({ id: 'job-2', inputPath: '/sandbox/other.jpg' }), 3).items[0];
  second.ownedPaths = [crossTaskRecord.items[0].ownedPaths[0]];
  second.inputPath = second.ownedPaths[0];
  crossTaskRecord.items.push(second);
  assertCorrupt(JSON.stringify(crossTaskRecord), /跨任务重复/);

  const unownedInput = queueItem({ ownedPaths: ['/sandbox/other.jpg'] });
  assertRejected(() => serializeQueueSnapshot(snapshotWith([unownedInput])), /输入路径/);
  const unownedInputRecord = validSerializedRecord();
  unownedInputRecord.items[0].ownedPaths = ['/sandbox/other.jpg'];
  assertCorrupt(JSON.stringify(unownedInputRecord), /输入路径/);

  const unownedResult = queueItem({
    result: resultFor('job-1'),
    ownedPaths: ['/sandbox/job-1.input.jpg']
  });
  assertRejected(() => serializeQueueSnapshot(snapshotWith([unownedResult])), /结果路径/);
  const unownedResultRecord = validSerializedRecord(queueItem({ result: resultFor('job-1') }));
  unownedResultRecord.items[0].ownedPaths = [unownedResultRecord.items[0].inputPath];
  assertCorrupt(JSON.stringify(unownedResultRecord), /结果路径/);

  const repeatedOwned = queueItem({ ownedPaths: ['/sandbox/job-1.input.jpg', '/sandbox/job-1.input.jpg'] });
  assertRejected(() => serializeQueueSnapshot(snapshotWith([repeatedOwned])), /归属路径重复/);
  const repeatedOwnedRecord = validSerializedRecord();
  repeatedOwnedRecord.items[0].ownedPaths.push(repeatedOwnedRecord.items[0].ownedPaths[0]);
  assertCorrupt(JSON.stringify(repeatedOwnedRecord), /ownedPaths/);
};

const testResultSafety = () => {
  const valid = validSerializedRecord(queueItem({ result: resultFor('job-1') }));
  const invalidResults = [
    [{ ...valid.items[0].result, conversion: { ...valid.items[0].result.conversion, success: false } }, /success/],
    [{ ...valid.items[0].result, modeKey: 'other' }, /modeKey/],
    [{ ...valid.items[0].result, outputPath: '/sandbox/job-1.tmp' }, /临时/],
    [{ ...valid.items[0].result, outputPath: '/sandbox/.apple-features-base-job-1.heic' }, /临时/]
  ];
  for (const [badResult, warning] of invalidResults) {
    const record = JSON.parse(JSON.stringify(valid));
    record.items[0].result = badResult;
    if (!record.items[0].ownedPaths.includes(badResult.outputPath)) {
      record.items[0].ownedPaths.push(badResult.outputPath);
    }
    assertCorrupt(JSON.stringify(record), warning);
  }

  const samePath = '/sandbox/job-1.input.jpg';
  const sameResult = queueItem({
    result: resultFor('job-1', { outputPath: samePath }),
    ownedPaths: [samePath]
  });
  assertRejected(() => serializeQueueSnapshot(snapshotWith([sameResult])), /输入路径/);
  const sameRecord = validSerializedRecord(queueItem({ result: resultFor('job-1') }));
  sameRecord.items[0].result.outputPath = sameRecord.items[0].inputPath;
  assertCorrupt(JSON.stringify(sameRecord), /结果路径不能与输入路径相同/);

  const invalidConversion = queueItem({
    result: resultFor('job-1', { conversion: conversion({ success: false }) })
  });
  assertRejected(() => serializeQueueSnapshot(snapshotWith([invalidConversion])), /success/);
  assertRejected(
    () => serializeQueueSnapshot(snapshotWith([queueItem({ result: resultFor('job-1', { modeKey: 'other' }) })])),
    /modeKey/
  );
};

const testRestoreRecovery = () => {
  const running = queueItem({
    status: 'running',
    attemptStatus: 'running',
    externalBusy: true,
    result: resultFor('job-1')
  });
  const runningResult = restoreQueueSnapshot(
    snapshotWith([running], 2),
    probeFor({ [running.inputPath]: 'file', [running.result.outputPath]: 'file' })
  );
  const restoredRunning = runningResult.snapshot.items[0];
  assert.equal(restoredRunning.status, 'failed');
  assert.equal(restoredRunning.attemptStatus, 'failed');
  assert.equal(restoredRunning.externalBusy, false);
  assert.match(restoredRunning.errorMessage, /中断/);

  const cleanupPending = queueItem({ cleanupStatus: 'pending', status: 'pending', attemptStatus: 'pending' });
  const cleanupResult = restoreQueueSnapshot(
    snapshotWith([cleanupPending]),
    probeFor({ [cleanupPending.inputPath]: 'file' })
  );
  const restoredCleanup = cleanupResult.snapshot.items[0];
  assert.equal(restoredCleanup.status, 'failed');
  assert.equal(restoredCleanup.attemptStatus, 'failed');
  assert.equal(restoredCleanup.cleanupStatus, 'failed');
  assert.match(restoredCleanup.cleanupErrorMessage, /中断/);
  assert.match(restoredCleanup.errorMessage, /删除清理/);

  const pendingMissingInput = queueItem({ attemptStatus: 'pending' });
  const missingInputResult = restoreQueueSnapshot(snapshotWith([pendingMissingInput]), probeFor());
  const restoredMissingInput = missingInputResult.snapshot.items[0];
  assert.equal(restoredMissingInput.inputPath, '');
  assert.equal(restoredMissingInput.status, 'failed');
  assert.equal(restoredMissingInput.attemptStatus, 'failed');
  assert.match(restoredMissingInput.errorMessage, /输入缺失/);
  assert.deepEqual(missingInputResult.warnings, []);
  assert.ok(restoredMissingInput.ownedPaths.includes(pendingMissingInput.inputPath));

  const succeededMissingInput = queueItem({
    status: 'succeeded',
    attemptStatus: 'succeeded',
    result: resultFor('job-1')
  });
  const succeededMissingInputResult = restoreQueueSnapshot(
    snapshotWith([succeededMissingInput]),
    probeFor({ [succeededMissingInput.result.outputPath]: 'file' })
  );
  const restoredSucceededMissingInput = succeededMissingInputResult.snapshot.items[0];
  assert.equal(restoredSucceededMissingInput.inputPath, '');
  assert.equal(restoredSucceededMissingInput.status, 'succeeded');
  assert.ok(restoredSucceededMissingInput.result);
  assert.deepEqual(succeededMissingInputResult.warnings, []);

  for (const resultState of ['missing', 'empty']) {
    const missingResultItem = queueItem({
      status: 'succeeded',
      attemptStatus: 'succeeded',
      result: resultFor('job-1')
    });
    const restored = restoreQueueSnapshot(
      snapshotWith([missingResultItem]),
      probeFor({ [missingResultItem.inputPath]: 'file', [missingResultItem.result.outputPath]: resultState })
    ).snapshot.items[0];
    assert.equal(restored.result, undefined, `result must be cleared for ${resultState}`);
    assert.equal(restored.status, 'failed');
    assert.equal(restored.attemptStatus, 'failed');
    assert.match(restored.errorMessage, /转换结果缺失/);
  }

  const succeededWithoutResult = queueItem({ status: 'succeeded', attemptStatus: 'succeeded' });
  const noResultRestored = restoreQueueSnapshot(
    snapshotWith([succeededWithoutResult]),
    probeFor({ [succeededWithoutResult.inputPath]: 'file' })
  ).snapshot.items[0];
  assert.equal(noResultRestored.status, 'failed');
  assert.equal(noResultRestored.attemptStatus, 'failed');
  assert.match(noResultRestored.errorMessage, /缺少可用转换结果/);

  const unsafePath = queueItem({ ownedPaths: ['/sandbox/safe.jpg', '/sandbox/unsafe.jpg'] });
  assert.throws(
    () => restoreQueueSnapshot(snapshotWith([unsafePath]), probeFor({ '/sandbox/unsafe.jpg': 'unsafe' })),
    QueuePersistenceError
  );
};

const testStateStoreTransactions = async () => {
  const adapter = new MemoryAdapter();
  const store = new QueueStateStore('/store/', adapter);
  assert.equal(store.path, '/store/queue.json');
  assert.equal(store.tempPath, '/store/queue.json.tmp');

  adapter.files.set(store.tempPath, '{"schema":1,"nextId":2,"items":[]}');
  let loaded = await store.load();
  assert.equal(loaded.snapshot, undefined);
  assert.equal(loaded.corrupt, true);
  assert.equal(loaded.tempPresent, true);
  assert.match(loaded.warning, /没有主记录/);

  const committed = serializeQueueSnapshot(snapshotWith([queueItem()], 2));
  adapter.files.set(store.path, committed);
  adapter.files.set(store.tempPath, '{uncommitted newer snapshot');
  loaded = await store.load();
  assert.equal(loaded.corrupt, false);
  assert.equal(loaded.snapshot.items[0].id, 'job-1');
  assert.equal(loaded.tempPresent, true);
  assert.match(loaded.warning, /忽略临时内容/);

  adapter.files.set(store.path, '');
  adapter.files.delete(store.tempPath);
  loaded = await store.load();
  assert.equal(loaded.corrupt, true);
  assert.equal(loaded.snapshot, undefined);

  const oldSnapshot = snapshotWith([queueItem({ displayName: 'old' })], 2);
  const oldRaw = serializeQueueSnapshot(oldSnapshot);
  adapter.files.set(store.path, oldRaw);
  adapter.failWrites = 1;
  await assert.rejects(
    store.save(snapshotWith([queueItem({ displayName: 'new' })], 2)),
    (error) => error instanceof QueuePersistenceError && /保存失败/.test(error.message)
  );
  assert.equal(adapter.files.get(store.path), oldRaw);
  assert.equal(JSON.parse(adapter.files.get(store.path)).items[0].displayName, 'old');

  await assert.rejects(
    store.save(snapshotWith([queueItem({ id: 'job-1', displayName: 'invalid' })], 1)),
    /nextId.*冲突/
  );
  assert.equal(adapter.files.get(store.path), oldRaw);

  await store.save(snapshotWith([queueItem({ displayName: 'new' })], 2));
  assert.equal(JSON.parse(adapter.files.get(store.path)).items[0].displayName, 'new');
};

const testQuarantineKeepsEvidenceOnPartialFailure = async () => {
  const adapter = new MemoryAdapter();
  const store = new QueueStateStore('/quarantine', adapter);
  adapter.files.set(store.path, '{corrupt-main');
  adapter.files.set(store.tempPath, '{uncommitted-temp');
  adapter.failRenameAt = 2;

  await assert.rejects(store.quarantine(), /synthetic rename failure 2/);
  assert.equal(adapter.files.has(store.path), false);
  assert.equal(adapter.files.get(store.tempPath), '{uncommitted-temp');
  const mainBackups = [...adapter.files.keys()].filter((path) => /queue\.json\.corrupt-[0-9]+$/.test(path));
  assert.equal(mainBackups.length, 1);
  assert.equal(adapter.files.get(mainBackups[0]), '{corrupt-main');
  assert.equal(adapter.renameCalls.length, 2);
};

await testEmptyAndMalformedRecords();
testU64RoundTrip();
testIdentifierAndOwnershipInvariants();
testResultSafety();
testRestoreRecovery();
await testStateStoreTransactions();
await testQuarantineKeepsEvidenceOnPartialFailure();

console.log('Harmony queue persistence tests passed: u64/empty-malformed/schema/identity/ownership/result-safety/restore/store/quarantine');
