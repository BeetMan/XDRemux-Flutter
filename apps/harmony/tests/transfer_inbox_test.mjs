import assert from 'node:assert/strict';
import {
  cleanTransferDeviceName,
  groupTransferInbox,
  isLivePhotoZipName,
  parseTransferAddress,
  transferScanTargets,
  validateLivePhotoBundleEntries
} from '../entry/src/main/ets/transfer/TransferInbox.ts';

const r = (id, name, sessionId = 's1') => ({ id, sessionId, name, size: 1, sha256: 'x' });

// Loose iPhone-style Live Photo pairs collapse into one row; the MOV row disappears.
const grouped = groupTransferInbox([
  r('m1', 'IMG_0001.MOV'), r('p1', 'IMG_0001.HEIC'), r('p2', 'IMG_0002.jpg'),
  r('z1', 'IMG_9.pvt.zip'), r('d1', 'notes.pdf'), r('m2', 'IMG_0003.mov'),
  r('p4', 'IMG_0004.heic', 's2'), r('m4', 'IMG_0004.mov', 's3')
]);
assert.deepEqual(grouped.map((e) => [e.kind, e.receipt.id, e.movie?.id]), [
  ['live', 'p1', 'm1'], ['photo', 'p2', undefined], ['live-zip', 'z1', undefined],
  ['file', 'd1', undefined], ['file', 'm2', undefined],
  // Different sessions never pair.
  ['photo', 'p4', undefined], ['file', 'm4', undefined]
]);
// Only one still claims a MOV.
assert.deepEqual(groupTransferInbox([r('a', 'X.heic'), r('b', 'X.jpg'), r('m', 'X.mov')]).map((e) => e.kind), ['live', 'photo']);

assert.equal(isLivePhotoZipName('IMG.pvt.zip'), true);
assert.equal(isLivePhotoZipName('.pvt.zip'), false);
assert.equal(isLivePhotoZipName('IMG.zip'), false);

assert.deepEqual(validateLivePhotoBundleEntries('IMG.pvt.zip', ['IMG.pvt/', 'IMG.pvt/IMG.heic', 'IMG.pvt/IMG.mov', 'IMG.pvt/metadata.plist']),
  { still: 'IMG.heic', movie: 'IMG.mov' });
assert.throws(() => validateLivePhotoBundleEntries('IMG.pvt.zip', ['other/IMG.heic', 'IMG.pvt/IMG.mov']), /结构无效/);
assert.throws(() => validateLivePhotoBundleEntries('IMG.pvt.zip', ['IMG.pvt/sub/IMG.heic', 'IMG.pvt/IMG.mov']), /结构无效/);
assert.throws(() => validateLivePhotoBundleEntries('IMG.pvt.zip', ['IMG.pvt/.hidden', 'IMG.pvt/IMG.mov']), /结构无效/);
assert.throws(() => validateLivePhotoBundleEntries('IMG.pvt.zip', ['IMG.pvt/IMG.heic']), /一张照片和一个 MOV/);
assert.throws(() => validateLivePhotoBundleEntries('IMG.pvt.zip', ['IMG.pvt/a.heic', 'IMG.pvt/b.jpg', 'IMG.pvt/a.mov']), /一张照片和一个 MOV/);
assert.throws(() => validateLivePhotoBundleEntries('IMG.zip', []), /不是/);

assert.equal(cleanTransferDeviceName('  我的\u0007手机  '), '我的手机');
assert.equal(cleanTransferDeviceName('x'.repeat(80)).length, 64);
assert.equal(cleanTransferDeviceName(' \n '), '');

const targets = transferScanTargets(['192.168.31.242', '10.0.0.5', '100.64.1.2', 'fe80::1']);
assert.equal(targets.length, 2 * 253 * 2);
assert.equal(targets.some((t) => t.host === '192.168.31.242'), false);
assert.deepEqual(targets.slice(0, 2), [{ host: '192.168.31.1', port: 53319 }, { host: '192.168.31.1', port: 53317 }]);
assert.equal(targets.some((t) => t.host.startsWith('100.64.')), false);
assert.deepEqual(transferScanTargets([]), []);

assert.equal(parseTransferAddress(' 192.168.31.175 ', 53317), '192.168.31.175:53317');
assert.equal(parseTransferAddress('192.168.31.175:53319', 53317), '192.168.31.175:53319');
assert.throws(() => parseTransferAddress('mac.local', 53317), /IPv4/);
assert.throws(() => parseTransferAddress('192.168.1.300', 53317), /IP 地址无效/);
assert.throws(() => parseTransferAddress('192.168.1.3:70000', 53317), /端口无效/);

console.log('transfer_inbox_test passed');

// Scanned peers survive later multicast snapshots and never include this device.
const { TransferSession } = await import('../entry/src/main/ets/transfer/TransferModel.ts');
const session = new TransferSession();
session.fingerprint = 'self';
session.addScannedPeer({ alias: '192.168.31.9', address: '192.168.31.9:53317', fingerprint: 'ab' });
session.addScannedPeer({ alias: 'me', address: '192.168.31.2:53319', fingerprint: 'SELF' });
session.setDiscovery({ enabled: true, error: null, peers: [{ alias: 'Mac', address: '192.168.31.175:53317', fingerprint: 'cd' }] });
assert.deepEqual(session.peers.map((p) => p.fingerprint), ['cd', 'ab']);
session.setDiscovery({ enabled: true, error: null, peers: [{ alias: 'Nine', address: '192.168.31.9:53317', fingerprint: 'AB' }] });
assert.deepEqual(session.peers.map((p) => p.alias), ['Nine']);
console.log('transfer scan merge passed');
