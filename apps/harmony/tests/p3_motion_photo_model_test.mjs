import assert from 'node:assert/strict';
import { parseMotionPhotoJson } from '../entry/src/main/ets/queue/MotionPhotoModel.ts';

const path = '/sandbox/inputs/job-1.jpg';
const base = {
  isMotionPhoto: true,
  sourceKind: 'androidMotionPhotoV1',
  stillStart: 0,
  stillEnd: 40,
  videoStart: 40,
  videoEnd: 100,
  isDualStream: false,
  items: [{ mime: 'image/jpeg', semantic: 'Primary', length: 0, padding: 0 }],
  primaryBytes: 60,
  videoWidth: 8000,
  videoHeight: 6000,
  frameCount: 2,
  audioChannels: 2,
  audioSampleRate: 48000
};

const ordinary = parseMotionPhotoJson(JSON.stringify({ isMotionPhoto: false }), path, 100);
assert.equal(ordinary.state, 'photo');
assert.match(ordinary.message, /普通照片/);

const unidentifiedError = parseMotionPhotoJson(JSON.stringify({ isMotionPhoto: false, errorMessage: 'bad XMP' }), path, 100);
assert.equal(unidentifiedError.state, 'error');
assert.equal(unidentifiedError.message, 'bad XMP');

const valid = parseMotionPhotoJson(JSON.stringify(base), path, 100);
assert.equal(valid.state, 'motion');
assert.equal(valid.report?.videoWidth, 8000);
assert.equal(valid.report?.primaryBytes, 60);
assert.equal(valid.report?.isDualStream, false);

const malformed = parseMotionPhotoJson('{', path, 100);
assert.equal(malformed.state, 'error');

const hugeRange = parseMotionPhotoJson(JSON.stringify({ ...base, stillEnd: Number.MAX_SAFE_INTEGER + 1 }), path, 100);
assert.equal(hugeRange.state, 'error');
assert.match(hugeRange.message, /安全/);

const badBoundary = parseMotionPhotoJson(JSON.stringify({ ...base, primaryBytes: 61 }), path, 100);
assert.equal(badBoundary.state, 'error');
assert.match(badBoundary.message, /primaryBytes/);

const badSuccessError = parseMotionPhotoJson(JSON.stringify({ ...base, errorMessage: 'inconsistent' }), path, 100);
assert.equal(badSuccessError.state, 'error');

const badSecondary = parseMotionPhotoJson(JSON.stringify({ ...base, isDualStream: true, secondaryBytes: 61 }), path, 100);
assert.equal(badSecondary.state, 'error');
assert.match(badSecondary.message, /secondaryBytes/);

const invalidSize = parseMotionPhotoJson(JSON.stringify({ isMotionPhoto: false }), path, Number.MAX_SAFE_INTEGER + 1);
assert.equal(invalidSize.state, 'error');
assert.match(invalidSize.message, /大小/);

console.log('P3 Motion Photo model tests passed: ordinary/error/valid/safe-range/media-domain');
