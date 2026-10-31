import assert from 'node:assert/strict';
import {
  buildStoredZip,
  crc32,
  dosDateTime,
  livePhotoBundleName,
  livePhotoBundleZipEntries,
  parseLivePhotoBundleReport
} from '../entry/src/main/ets/queue/LivePhotoBundleZip.ts';

const bytes = (text) => new TextEncoder().encode(text);

// CRC-32/ISO-HDLC check value.
assert.equal(crc32(bytes('123456789')), 0xCBF43926);
assert.equal(crc32(new Uint8Array(0)), 0);

assert.deepEqual(dosDateTime(new Date(2026, 9, 31, 6, 30, 59)), [((2026 - 1980) << 9) | (10 << 5) | 31, (6 << 11) | (30 << 5) | 29]);
assert.equal(dosDateTime(new Date(1970, 0, 1))[0] >> 9, 0);

assert.equal(livePhotoBundleName('/s/outputs/input-job-1-live-1-1.heic'), 'input-job-1-live-1-1.pvt');
assert.throws(() => livePhotoBundleName('/s/outputs/bad name.heic'), /不能用于/);
assert.throws(() => livePhotoBundleName('/s/outputs/.heic'), /不能用于/);

const still = { leaf: 'a.heic', data: bytes('still') };
const mov = { leaf: 'a.mov', data: bytes('movie!') };
const plist = { leaf: 'metadata.plist', data: bytes('<plist/>\n') };
const entries = livePhotoBundleZipEntries('a.pvt', [plist, mov, { leaf: '.DS_Store', data: bytes('x') }, still]);
assert.deepEqual(entries.map((e) => e.name), ['a.pvt/a.heic', 'a.pvt/a.mov', 'a.pvt/metadata.plist']);
assert.throws(() => livePhotoBundleZipEntries('a.pvt', [still, mov]), /只包含/);
assert.throws(() => livePhotoBundleZipEntries('a.pvt', [still, { leaf: 'b.mov', data: bytes('m') }, plist]), /不一致/);
assert.throws(() => livePhotoBundleZipEntries('a.pvt', [still, mov, plist, { leaf: 'extra.txt', data: bytes('e') }]), /只包含/);
assert.throws(() => livePhotoBundleZipEntries('a.pvt', [{ leaf: 'a.heic', data: new Uint8Array(0) }, mov, plist]), /无效/);
assert.throws(() => livePhotoBundleZipEntries('../a.pvt', [still, mov, plist]), /包名无效/);

// Parse the stored zip back with a minimal reader and check every field.
const modified = new Date(2026, 9, 31, 12, 0, 0);
const zip = buildStoredZip(entries, modified);
const view = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);
const eocd = zip.length - 22;
assert.equal(view.getUint32(eocd, true), 0x06054B50);
assert.equal(view.getUint16(eocd + 10, true), 3);
const cdSize = view.getUint32(eocd + 12, true);
const cdStart = view.getUint32(eocd + 16, true);
assert.equal(cdStart + cdSize, eocd);
const decoder = new TextDecoder();
let p = cdStart;
const found = [];
for (let i = 0; i < 3; i += 1) {
  assert.equal(view.getUint32(p, true), 0x02014B50);
  assert.equal(view.getUint16(p + 10, true), 0, 'stored method');
  const crc = view.getUint32(p + 16, true);
  const size = view.getUint32(p + 20, true);
  assert.equal(view.getUint32(p + 24, true), size);
  const nameLength = view.getUint16(p + 28, true);
  const offset = view.getUint32(p + 42, true);
  const name = decoder.decode(zip.subarray(p + 46, p + 46 + nameLength));
  assert.equal(view.getUint32(offset, true), 0x04034B50);
  assert.equal(view.getUint32(offset + 14, true), crc);
  const localName = decoder.decode(zip.subarray(offset + 30, offset + 30 + view.getUint16(offset + 26, true)));
  assert.equal(localName, name);
  const data = zip.subarray(offset + 30 + nameLength, offset + 30 + nameLength + size);
  assert.equal(crc32(data), crc);
  found.push([name, decoder.decode(data)]);
  p += 46 + nameLength;
}
assert.deepEqual(found, [['a.pvt/a.heic', 'still'], ['a.pvt/a.mov', 'movie!'], ['a.pvt/metadata.plist', '<plist/>\n']]);
assert.throws(() => buildStoredZip([], modified), /数量/);
assert.throws(() => buildStoredZip([{ name: 'x', data: bytes('1') }, { name: 'x', data: bytes('2') }], modified), /重复/);
assert.throws(() => buildStoredZip([{ name: '../x', data: bytes('1') }], modified), /无效/);
assert.throws(() => buildStoredZip([{ name: '图.heic', data: bytes('1') }], modified), /ASCII/);

const bundle = '/cache/pvt-export/a.pvt';
assert.deepEqual(
  parseLivePhotoBundleReport(JSON.stringify({ success: true, bundlePath: bundle, stillPath: bundle + '/a.heic', videoPath: bundle + '/a.mov' }), bundle),
  { bundlePath: bundle, stillPath: bundle + '/a.heic', videoPath: bundle + '/a.mov' });
assert.throws(() => parseLivePhotoBundleReport(JSON.stringify({ success: false, errorMessage: 'still and MOV content identifiers do not match' }), bundle), /content identifiers/);
assert.throws(() => parseLivePhotoBundleReport('{', bundle), /无法解析/);
assert.throws(() => parseLivePhotoBundleReport(JSON.stringify({ success: true, bundlePath: '/other.pvt', stillPath: bundle + '/a.heic', videoPath: bundle + '/a.mov' }), bundle), /不一致/);
assert.throws(() => parseLivePhotoBundleReport(JSON.stringify({ success: true, bundlePath: bundle, stillPath: '/elsewhere/a.heic', videoPath: bundle + '/a.mov' }), bundle), /不在包目录内/);

console.log('live_photo_bundle_zip_test passed');
