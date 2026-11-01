import assert from 'node:assert/strict';
import {
  TransferSession,
  groupedFingerprint,
  isTransferPhotoName,
  shortFingerprint,
  transferAbiSupported,
  transferErrorLabel
} from '../entry/src/main/ets/transfer/TransferModel.ts';
import { TransferController } from '../entry/src/main/ets/transfer/TransferController.ts';

assert.equal(transferAbiSupported(0x00010003), true);
assert.equal(transferAbiSupported(0x00010004), true);
assert.equal(transferAbiSupported(0x00010002), false);
assert.equal(transferAbiSupported(0x00020003), false);
assert.equal(transferErrorLabel('port_in_use'), '端口已被占用或不可用');
assert.equal(transferErrorLabel('something_new'), 'something_new');
assert.equal(shortFingerprint('ab:cd:ef:01:23:45:67:89:aa:bb'), 'ABCD EF01 2345 6789');
assert.equal(groupedFingerprint('abcdef0123'), 'ABCD EF01 23');
assert.equal(isTransferPhotoName('IMG_1.HEIC'), true);
assert.equal(isTransferPhotoName('IMG_1.mov'), false);
assert.equal(isTransferPhotoName('.heic'), false);

const poll = (phase, records, extra = {}) => JSON.stringify({
  instance_id: 'i1', phase, ready: null, last_sequence: 0, lost: 0,
  records: records.map(([sequence, body]) => ({ sequence, body })), ...extra
});
const ev = (event) => ({ kind: 'event', event: { instance_id: 'core', sequence: 1, ...event } });

// Session: ready, offer -> accept -> progress -> commit -> end.
const s = new TransferSession();
assert.equal(s.applyPoll(poll(1, [[1, { kind: 'ready', data: { address: '0.0.0.0:53319', fingerprint: 'ff', core_instance_id: 'c' } }]])), true);
assert.equal(s.ready, true);
assert.equal(s.address, '0.0.0.0:53319');
s.applyPoll(poll(1, [[2, ev({ kind: 'offer', offer: { session_id: 's1', alias: 'Mac', peer_fingerprint: 'aa', files: [
  { id: 'f1', name: 'a.heic', size: 100, sha256: null }, { id: 'f2', name: 'a.mov', size: 300, sha256: null }] } })]]));
assert.equal(s.offers.length, 1);
assert.equal(s.activities[0].total, 400);
assert.equal(s.activities[0].status, 'pending');
// Records at or below the last sequence are ignored (re-delivery).
assert.equal(s.applyPoll(poll(1, [[2, ev({ kind: 'accepted', session_id: 's1' })]])), false);
s.applyPoll(poll(1, [[3, ev({ kind: 'accepted', session_id: 's1' })], [4, ev({ kind: 'progress', transfer_id: 's1', file_id: 'f1', bytes: 100, total: 100 })]]));
assert.equal(s.offers.length, 0);
assert.equal(s.activities[0].status, 'active');
assert.equal(s.activities[0].bytes, 100);
// Older progress never regresses.
s.applyPoll(poll(1, [[5, ev({ kind: 'progress', transfer_id: 's1', file_id: 'f1', bytes: 40, total: 100 })]]));
assert.equal(s.activities[0].bytes, 100);
s.applyPoll(poll(1, [[6, ev({ kind: 'committed', receipt: { id: 'r1', session_id: 's1', file_id: 'f1', name: 'a.heic', size: 100, sha256: 'x', peer_hash_present: false } })],
  [7, ev({ kind: 'session_ended', session_id: 's1' })]]));
assert.deepEqual(s.receipts.map((r) => r.id), ['r1']);
assert.equal(s.activities[0].status, 'done');
s.applyPoll(poll(1, [[8, ev({ kind: 'receipt_deleted', receipt_id: 'r1' })]]));
assert.equal(s.receipts.length, 0);
// An offer that ends without acceptance is shown as not received.
s.applyPoll(poll(1, [[9, ev({ kind: 'offer', offer: { session_id: 's2', alias: 'P', peer_fingerprint: 'bb', files: [] } })],
  [10, ev({ kind: 'session_ended', session_id: 's2' })]]));
assert.equal(s.activities.find((a) => a.id === 's2').status, 'failed');
// File-level failure does not fail the session; session-level does.
s.applyPoll(poll(1, [[11, ev({ kind: 'send_started', transfer_id: 't1', file_count: 2 })],
  [12, ev({ kind: 'prepared', transfer_id: 't1', files: [{ id: 'a', name: 'x', size: 10, sha256: 'h' }, { id: 'b', name: 'y', size: 20, sha256: 'h' }] })],
  [13, ev({ kind: 'failed', transfer_id: 't1', file_id: 'a', code: 'checksum_mismatch' })]]));
const t1 = s.activities.find((a) => a.id === 't1');
assert.equal(t1.total, 30);
assert.equal(t1.status, 'active');
assert.match(t1.error, /文件校验失败/);
s.applyPoll(poll(1, [[14, ev({ kind: 'sent', transfer_id: 't1', report: { files: [], error: 'declined' } })]]));
assert.equal(t1.status, 'failed');
assert.equal(t1.error, '对方已拒绝');
// Results are tagged by operation ID and taken once.
s.applyPoll(poll(1, [[15, { kind: 'result', operation_id: 7, data: { ok: 1 }, error: null }], [16, { kind: 'result', operation_id: 8, data: null, error: 'busy' }]]));
assert.deepEqual(s.takeResult(7).data, { ok: 1 });
assert.equal(s.takeResult(7), undefined);
assert.equal(s.takeResult(8).error, 'busy');
// Lost records request a resync; a new instance resets the sequence cursor.
s.applyPoll(poll(1, [], { lost: 3 }));
assert.equal(s.resyncNeeded, true);
const fresh = new TransferSession();
fresh.applyPoll(poll(0, [[1, { kind: 'start_failed', error: 'port_in_use' }]]));
assert.equal(fresh.startError, 'port_in_use');
fresh.setDiscovery({ enabled: true, error: null, peers: [{ alias: 'Mac', address: '192.168.1.5:53317', fingerprint: 'ab' }, { alias: 'bad' }] });
assert.equal(fresh.discoveryEnabled, true);
assert.deepEqual(fresh.peers, [{ alias: 'Mac', address: '192.168.1.5:53317', fingerprint: 'ab' }]);
fresh.setReceipts([{ id: 'old', session_id: 's', name: 'o.jpg', size: 1, sha256: 'x' }, { id: 'new', session_id: 's', name: 'n.jpg', size: 2, sha256: 'y' }]);
assert.deepEqual(fresh.receipts.map((r) => r.id), ['new', 'old']);

// Controller against a scripted fake bridge.
class FakeBridge {
  constructor() { this.queue = []; this.phase = 0; this.seq = 0; this.calls = []; this.op = 0; this.released = false; }
  abiVersion() { return 0x00010003; }
  push(body) { this.queue.push({ sequence: ++this.seq, body }); }
  create(json) {
    this.config = JSON.parse(json);
    this.phase = 1;
    this.push({ kind: 'ready', data: { address: '0.0.0.0:53319', fingerprint: 'FEED', core_instance_id: 'c' } });
    return 5;
  }
  submit(handle, json) {
    assert.equal(handle, 5);
    const request = JSON.parse(json);
    this.calls.push(request);
    const id = ++this.op;
    const reply = {
      discovery_start: { enabled: true, error: null, peers: [{ alias: 'Mac', address: '192.168.31.10:53317', fingerprint: 'AB' }] },
      send: { transfer_id: 'tx' },
      decide: null,
      acquire_receipt: { lease_id: id, path: '/root/r/data', receipt: {} },
      release_receipt: null,
      receipts: []
    }[request.command];
    if (request.command === 'decide' && request.transfer_id === 'gone') {
      this.push({ kind: 'result', operation_id: id, data: null, error: 'invalid_input' });
    } else {
      this.push({ kind: 'result', operation_id: id, data: reply ?? null, error: null });
    }
    return id;
  }
  poll() {
    const records = this.queue.splice(0);
    return JSON.stringify({ instance_id: 'b', phase: this.phase, ready: null, last_sequence: this.seq, lost: 0, records });
  }
  stop() { this.phase = 3; this.push({ kind: 'stopped' }); return 0; }
  release() { this.released = true; return 0; }
}

let changes = 0;
const bridge = new FakeBridge();
const controller = new TransferController(bridge, () => { changes += 1; });
await controller.start({ root: '/files/transfer', alias: 'XDRemux 鸿蒙', bind: '0.0.0.0:53319' });
assert.deepEqual(bridge.config, { root: '/files/transfer', bind: '0.0.0.0:53319', alias: 'XDRemux 鸿蒙', pin: null });
assert.equal(controller.running, true);
assert.equal(controller.session.fingerprint, 'FEED');
await controller.refreshDiscovery();
assert.equal(controller.session.peers[0].alias, 'Mac');
const id = await controller.send(controller.session.peers[0], ['/out/a.heic', '/out/a.mov'], 'IMG_1');
assert.equal(id, 'tx');
assert.deepEqual(bridge.calls.at(-1), { command: 'send', peer: { address: '192.168.31.10:53317', fingerprint: 'AB' }, paths: ['/out/a.heic', '/out/a.mov'], pin: null });
assert.equal(controller.session.activities[0].label, 'IMG_1');
const lease = await controller.acquireReceipt('r9');
assert.equal(lease.path, '/root/r/data');
await controller.releaseReceipt(lease);
assert.deepEqual(bridge.calls.at(-1), { command: 'release_receipt', lease_id: lease.leaseId });
await assert.rejects(controller.decide('gone', true), /请求无效/);
assert.ok(changes > 0);
await Promise.all([controller.stop(), controller.stop()]);
assert.equal(bridge.released, true);
assert.equal(controller.running, false);
await assert.rejects(controller.command({ command: 'snapshot' }), /未运行/);

// Startup failure stops and releases instead of leaving a runtime behind.
class FailingBridge extends FakeBridge {
  create() { this.phase = 0; this.push({ kind: 'start_failed', error: 'port_in_use' }); return 6; }
}
const failing = new FailingBridge();
await assert.rejects(new TransferController(failing, () => {}).start({ root: '/r', alias: 'a', bind: '0.0.0.0:53319' }), /端口已被占用/);
assert.equal(failing.released, true);

console.log('transfer_model_test passed');
