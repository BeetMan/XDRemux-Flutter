import assert from 'node:assert/strict';
import {
  emptyMotionPhotoInspection,
  motionPhotoStateLabel,
  parseMotionPhotoJson
} from '../entry/src/main/ets/queue/MotionPhotoModel.ts';

const INPUT_PATH = '/sandbox/inputs/motion-photo.jpg';
const FILE_SIZE = 1024;
const MAX_SAFE = Number.MAX_SAFE_INTEGER;
const MAX_U32 = 0xFFFFFFFF;
const MAX_U16 = 0xFFFF;

const hasOwn = (value, key) => Object.prototype.hasOwnProperty.call(value, key);

const baseReport = (overrides = {}) => ({
  isMotionPhoto: true,
  sourceKind: 'androidMotionPhotoV1',
  stillStart: 0,
  stillEnd: 400,
  videoStart: 400,
  videoEnd: 1000,
  isDualStream: false,
  items: [
    { mime: 'image/jpeg', semantic: 'Primary', length: 0, padding: 0 },
    { mime: 'video/mp4', semantic: 'MotionPhoto', length: 600, padding: 0 }
  ],
  ...overrides
});

const parse = (value, inputPath = INPUT_PATH, fileSize = FILE_SIZE) => (
  parseMotionPhotoJson(JSON.stringify(value), inputPath, fileSize)
);

const expectError = (value, pattern, inputPath = INPUT_PATH, fileSize = FILE_SIZE) => {
  const inspection = typeof value === 'string'
    ? parseMotionPhotoJson(value, inputPath, fileSize)
    : parse(value, inputPath, fileSize);
  assert.equal(inspection.state, 'error');
  if (pattern !== undefined) {
    assert.match(inspection.message, pattern);
  }
  assert.equal(inspection.report, undefined);
  return inspection;
};

const expectMotion = (value, inputPath = INPUT_PATH, fileSize = FILE_SIZE) => {
  const inspection = parse(value, inputPath, fileSize);
  assert.equal(inspection.state, 'motion');
  assert.equal(inspection.inputPath, inputPath);
  assert.equal(inspection.message, '已识别 Motion Photo');
  assert.ok(inspection.report);
  return inspection.report;
};

const testRealSchemaAndUnknownValues = () => {
  const report = expectMotion(baseReport({
    sourceKind: 'futureVendorMotionV9',
    isDualStream: true,
    presentationTimestampUs: -123,
    presentationSource: 'futurePresentationSource',
    videoWidth: MAX_U32,
    videoHeight: MAX_U32,
    durationMs: MAX_SAFE,
    fps: 240.5,
    frameCount: MAX_U32,
    videoCodec: 'future-video-codec',
    hasAudio: true,
    audioCodec: 'future-audio-codec',
    audioChannels: MAX_U16,
    audioSampleRate: MAX_U32,
    audioDurationMs: MAX_SAFE,
    primaryBytes: 400,
    secondaryBytes: 200,
    secondaryWidth: MAX_U32,
    secondaryHeight: MAX_U32,
    secondaryFps: 120.25,
    // These keys are outside the Rust to_json_with_media schema. They must
    // not become a second, invented report contract.
    secondaryAudioCodec: 'must-be-ignored',
    secondaryAudioChannels: 2,
    futureField: { value: 1 }
  }));

  assert.equal(report.isMotionPhoto, true);
  assert.equal(report.sourceKind, 'futureVendorMotionV9');
  assert.equal(report.isDualStream, true);
  assert.deepEqual(report.items, baseReport().items);
  assert.equal(report.videoWidth, MAX_U32);
  assert.equal(report.videoHeight, MAX_U32);
  assert.equal(report.frameCount, MAX_U32);
  assert.equal(report.audioChannels, MAX_U16);
  assert.equal(report.audioSampleRate, MAX_U32);
  assert.equal(report.primaryBytes, 400);
  assert.equal(report.secondaryBytes, 200);
  assert.equal(report.secondaryFps, 120.25);
  assert.equal(hasOwn(report, 'secondaryAudioCodec'), false);
  assert.equal(hasOwn(report, 'futureField'), false);
};

const testMinimalMediaAndUnknownAudio = () => {
  const report = expectMotion(baseReport({
    hasAudio: true,
    audioCodec: 'vendor-audio-unknown'
  }));

  assert.equal(report.hasAudio, true);
  assert.equal(report.audioCodec, 'vendor-audio-unknown');
  assert.equal(report.videoWidth, undefined);
  assert.equal(report.durationMs, undefined);
  assert.equal(report.primaryBytes, undefined);
  assert.equal(report.secondaryBytes, undefined);
};

const testOrdinaryErrorAndFlagSemantics = () => {
  const ordinary = parse({ isMotionPhoto: false }, INPUT_PATH, 0);
  assert.equal(ordinary.state, 'photo');
  assert.equal(ordinary.report, undefined);
  assert.match(ordinary.message, /普通照片/);
  assert.equal(motionPhotoStateLabel(ordinary.state), '普通照片 / 未识别结构');

  const nativeError = parse({ isMotionPhoto: false, errorMessage: 'XMP 解析失败' });
  assert.equal(nativeError.state, 'error');
  assert.equal(nativeError.message, 'XMP 解析失败');
  assert.equal(motionPhotoStateLabel(nativeError.state), '识别错误');

  const emptyError = parse({ isMotionPhoto: false, errorMessage: '' });
  assert.equal(emptyError.state, 'photo');

  const successWithError = expectError(
    baseReport({ errorMessage: 'native error must not be swallowed' }),
    /同时包含成功标志和错误信息/
  );
  assert.equal(successWithError.message.includes('native error must not be swallowed'), false);

  expectError({ isMotionPhoto: false, errorMessage: null }, /errorMessage/);
  expectError({ isMotionPhoto: false, errorMessage: 7 }, /errorMessage/);

  // The Rust report always emits isDualStream for a recognized asset.
  expectError({ ...baseReport(), isDualStream: undefined }, /isDualStream/);
  expectError({ ...baseReport(), isDualStream: 'false' }, /isDualStream/);
};

const testInvalidEnvelopesAndEmptyInspection = () => {
  for (const raw of [
    'not-json',
    'null',
    '[]',
    'true',
    '{}',
    JSON.stringify({ isMotionPhoto: null }),
    JSON.stringify({ isMotionPhoto: 'false' })
  ]) {
    expectError(raw);
  }

  const empty = emptyMotionPhotoInspection();
  assert.deepEqual(empty, {
    inputPath: '',
    state: 'unidentified',
    message: '尚未识别当前输入'
  });
  assert.equal(motionPhotoStateLabel('unidentified'), '尚未识别');
  assert.equal(parse(JSON.stringify({ isMotionPhoto: false }), '').state, 'error');
  assert.match(parse(JSON.stringify({ isMotionPhoto: false }), '').message, /输入路径为空/);
};

const testRequiredFieldsAndItems = () => {
  for (const field of [
    'sourceKind',
    'stillStart',
    'stillEnd',
    'videoStart',
    'videoEnd',
    'items'
  ]) {
    const value = baseReport();
    delete value[field];
    expectError(value, new RegExp(field));
  }

  expectError({ ...baseReport(), sourceKind: '' }, /sourceKind/);
  expectError({ ...baseReport(), sourceKind: 123 }, /sourceKind/);
  expectError({ ...baseReport(), items: [] }, /items/);
  expectError({ ...baseReport(), items: [null] }, /items\[0\]/);
  expectError({ ...baseReport(), items: ['not-an-object'] }, /items\[0\]/);

  for (const itemField of ['mime', 'semantic', 'length', 'padding']) {
    const item = { mime: 'image/jpeg', semantic: 'Primary', length: 0, padding: 0 };
    delete item[itemField];
    expectError({ ...baseReport(), items: [item] }, new RegExp(itemField));
  }
  expectError({
    ...baseReport(),
    items: [{ mime: '', semantic: 'Primary', length: 0, padding: 0 }]
  }, /mime/);
  expectError({
    ...baseReport(),
    items: [{ mime: 'image/jpeg', semantic: 'Primary', length: FILE_SIZE + 1, padding: 0 }]
  }, /length/);
  expectError({
    ...baseReport(),
    items: [{ mime: 'image/jpeg', semantic: 'Primary', length: 0, padding: FILE_SIZE + 1 }]
  }, /padding/);
};

const testRangesFileSizeAndRustAdjacentBoundary = () => {
  // Rust emits the still and video resources back-to-back. The shared
  // boundary is valid because both individual ranges remain non-empty.
  const adjacent = expectMotion(baseReport({
    stillStart: 0,
    stillEnd: 1,
    videoStart: 1,
    videoEnd: 2,
    items: [{ mime: 'video/mp4', semantic: 'MotionPhoto', length: 1, padding: 0 }],
    primaryBytes: 0,
    secondaryBytes: 0
  }), INPUT_PATH, 2);
  assert.equal(adjacent.stillEnd, adjacent.videoStart);

  for (const invalid of [
    { stillStart: 0, stillEnd: 0 },
    { stillStart: 2, stillEnd: 1 },
    { videoStart: 1, videoEnd: 1 },
    { videoStart: 2, videoEnd: 1 },
    { stillEnd: FILE_SIZE + 1 },
    { videoEnd: FILE_SIZE + 1 }
  ]) {
    expectError({ ...baseReport(), ...invalid }, /字节范围|安全的非负字节整数/);
  }

  expectError({ ...baseReport(), stillStart: -1 }, /stillStart/);
  expectError({ ...baseReport(), videoEnd: 1.5 }, /videoEnd/);
  expectError({ ...baseReport(), videoStart: '400' }, /videoStart/);
  expectError({ ...baseReport(), videoEnd: null }, /videoEnd/);

  for (const invalidSize of [-1, Number.NaN, Number.POSITIVE_INFINITY, MAX_SAFE + 1]) {
    expectError({ isMotionPhoto: false }, /文件大小/, INPUT_PATH, invalidSize);
  }

  const nearSafeLimit = expectMotion(baseReport({
    stillStart: MAX_SAFE - 3,
    stillEnd: MAX_SAFE - 2,
    videoStart: MAX_SAFE - 2,
    videoEnd: MAX_SAFE,
    primaryBytes: 2,
    secondaryBytes: 2,
    items: [{ mime: 'video/mp4', semantic: 'MotionPhoto', length: 2, padding: 0 }]
  }), INPUT_PATH, MAX_SAFE);
  assert.equal(nearSafeLimit.videoEnd, MAX_SAFE);
  assert.equal(nearSafeLimit.primaryBytes, 2);
};

const testNumericTypeAndRangeBoundaries = () => {
  const maxTyped = expectMotion(baseReport({
    videoWidth: MAX_U32,
    videoHeight: MAX_U32,
    frameCount: MAX_U32,
    audioSampleRate: MAX_U32,
    audioChannels: MAX_U16,
    durationMs: MAX_SAFE,
    audioDurationMs: MAX_SAFE,
    presentationTimestampUs: -MAX_SAFE,
    fps: 0,
    secondaryWidth: MAX_U32,
    secondaryHeight: MAX_U32,
    secondaryFps: 0
  }));
  assert.equal(maxTyped.videoWidth, MAX_U32);
  assert.equal(maxTyped.audioChannels, MAX_U16);
  assert.equal(maxTyped.presentationTimestampUs, -MAX_SAFE);

  for (const field of ['videoWidth', 'videoHeight', 'frameCount', 'audioSampleRate',
    'secondaryWidth', 'secondaryHeight']) {
    expectError({ ...baseReport(), [field]: MAX_U32 + 1 }, new RegExp(field));
  }
  expectError({ ...baseReport(), audioChannels: MAX_U16 + 1 }, /audioChannels/);
  expectError({ ...baseReport(), presentationTimestampUs: MAX_SAFE + 1 }, /presentationTimestampUs/);
  expectError({ ...baseReport(), presentationTimestampUs: -MAX_SAFE - 1 }, /presentationTimestampUs/);
  expectError({ ...baseReport(), durationMs: MAX_SAFE + 1 }, /durationMs/);

  for (const field of [
    'videoWidth', 'videoHeight', 'durationMs', 'fps', 'frameCount',
    'videoCodec', 'hasAudio', 'audioCodec', 'audioChannels', 'audioSampleRate',
    'audioDurationMs', 'primaryBytes', 'secondaryBytes', 'secondaryWidth',
    'secondaryHeight', 'secondaryFps'
  ]) {
    expectError({ ...baseReport(), [field]: null }, new RegExp(field));
  }

  expectError({ ...baseReport(), fps: -0.001 }, /fps/);
  expectError({ ...baseReport(), fps: '24' }, /fps/);
  expectError({ ...baseReport(), audioChannels: 1.5 }, /audioChannels/);
  expectError({ ...baseReport(), videoWidth: Number.MAX_SAFE_INTEGER }, /videoWidth/);

  // Pixel dimensions are u32 values, independent of compressed file bytes.
  const dimensionsLargerThanFile = expectMotion(baseReport({
    stillEnd: 4,
    videoStart: 4,
    videoEnd: 10,
    items: [{ mime: 'video/mp4', semantic: 'MotionPhoto', length: 6, padding: 0 }],
    videoWidth: 3840,
    videoHeight: 2160,
    secondaryWidth: 1920,
    secondaryHeight: 1080
  }), INPUT_PATH, 10);
  assert.equal(dimensionsLargerThanFile.videoWidth, 3840);
  assert.equal(dimensionsLargerThanFile.secondaryHeight, 1080);
};

const testByteCountBoundsAndOptionalZero = () => {
  const zero = expectMotion(baseReport({
    presentationTimestampUs: 0,
    videoWidth: 0,
    videoHeight: 0,
    durationMs: 0,
    fps: 0,
    frameCount: 0,
    hasAudio: false,
    audioChannels: 0,
    audioSampleRate: 0,
    audioDurationMs: 0,
    primaryBytes: 0,
    secondaryBytes: 0,
    secondaryWidth: 0,
    secondaryHeight: 0,
    secondaryFps: 0
  }));
  assert.equal(zero.presentationTimestampUs, 0);
  assert.equal(zero.primaryBytes, 0);
  assert.equal(zero.secondaryBytes, 0);

  for (const field of ['primaryBytes', 'secondaryBytes']) {
    expectError({ ...baseReport(), [field]: 601 }, new RegExp(field));
  }
  const maxBytes = expectMotion(baseReport({ primaryBytes: 600, secondaryBytes: 600 }));
  assert.equal(maxBytes.primaryBytes, 600);
  assert.equal(maxBytes.secondaryBytes, 600);
};

const run = () => {
  testRealSchemaAndUnknownValues();
  testMinimalMediaAndUnknownAudio();
  testOrdinaryErrorAndFlagSemantics();
  testInvalidEnvelopesAndEmptyInspection();
  testRequiredFieldsAndItems();
  testRangesFileSizeAndRustAdjacentBoundary();
  testNumericTypeAndRangeBoundaries();
  testByteCountBoundsAndOptionalZero();
  console.log('Harmony Motion Photo inspect edge tests passed: schema/ordinary/error/envelope/items/ranges/safe-int/u32-u16/optional-zero/byte-bounds');
};

run();
