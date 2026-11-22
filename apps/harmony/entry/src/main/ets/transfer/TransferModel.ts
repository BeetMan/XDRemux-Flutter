// State for the LocalSend transfer runtime (crates/xdremux-transfer-ffi, C ABI
// 1.3). The native side is poll-only: every call returns at once and results,
// core events and lifecycle changes arrive as bridge records from poll. This
// model applies those records; it never touches files or the network.

export const TRANSFER_ABI_MAJOR: number = 1;
export const TRANSFER_ABI_MIN_MINOR: number = 3;

/** Bridge phases reported by poll. */
export const TRANSFER_PHASE_STARTING: number = 0;
export const TRANSFER_PHASE_RUNNING: number = 1;
export const TRANSFER_PHASE_STOPPING: number = 2;
export const TRANSFER_PHASE_STOPPED: number = 3;

export interface TransferPeer {
  alias: string;
  address: string;
  fingerprint: string;
}

export interface TransferOfferFile {
  id: string;
  name: string;
  size: number;
}

export interface TransferOffer {
  sessionId: string;
  alias: string;
  fingerprint: string;
  files: Array<TransferOfferFile>;
}

export interface TransferReceipt {
  id: string;
  sessionId: string;
  name: string;
  size: number;
  sha256: string;
}

export type TransferActivityStatus = 'pending' | 'active' | 'done' | 'failed';

export interface TransferActivity {
  id: string;
  direction: 'send' | 'receive';
  label: string;
  fileCount: number;
  bytes: number;
  total: number;
  status: TransferActivityStatus;
  error: string;
}

export interface TransferResult {
  operationId: number;
  data: Object | null;
  error: string | null;
}

export function transferAbiSupported(version: number): boolean {
  const major: number = Math.floor(version / 65536);
  const minor: number = version % 65536;
  return major === TRANSFER_ABI_MAJOR && minor >= TRANSFER_ABI_MIN_MINOR;
}

// Core ErrorCode (snake_case) values; never paths or remote messages.
const ERROR_LABELS: Map<string, string> = new Map<string, string>([
  ['invalid_input', '请求无效'],
  ['unsafe_storage', '传输存储目录不安全'],
  ['busy', '正忙，请稍后再试'],
  ['declined', '对方已拒绝'],
  ['no_space', '存储空间不足'],
  ['io', '读写文件失败'],
  ['already_exists', '文件已存在'],
  ['port_in_use', '端口已被占用或不可用'],
  ['discovery_unavailable', '设备发现不可用（局域网组播被阻止）'],
  ['network', '网络连接失败'],
  ['cancelled', '已取消'],
  ['timed_out', '连接超时'],
  ['checksum_mismatch', '文件校验失败'],
  ['truncated', '文件不完整'],
  ['identity_mismatch', '对方证书与确认的指纹不一致'],
  ['remote_failure', '对方出错'],
  ['closed', '传输服务已停止'],
  ['source_changed', '源文件已变化'],
  ['authentication', 'PIN 错误或对方要求 PIN'],
  ['internal', '内部错误']
]);

export function transferErrorLabel(code: string): string {
  return ERROR_LABELS.get(code) ?? code;
}

/** "AB:CD:…" style grouping of the first bytes, for list rows; confirm with the full value. */
export function shortFingerprint(fingerprint: string): string {
  const hex: string = fingerprint.replace(/[^0-9A-Fa-f]/g, '').toUpperCase();
  const groups: Array<string> = [];
  for (let i = 0; i < Math.min(hex.length, 16); i += 4) groups.push(hex.substring(i, i + 4));
  return groups.join(' ');
}

/** Full fingerprint in groups of four for the confirmation dialog. */
export function groupedFingerprint(fingerprint: string): string {
  const hex: string = fingerprint.replace(/[^0-9A-Fa-f]/g, '').toUpperCase();
  const groups: Array<string> = [];
  for (let i = 0; i < hex.length; i += 4) groups.push(hex.substring(i, i + 4));
  return groups.join(' ');
}

export function formatTransferBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '—';
  if (bytes < 1024) return String(bytes) + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  return (bytes / 1024 / 1024 / 1024).toFixed(2) + ' GB';
}

const PHOTO_EXTENSIONS: Array<string> = ['heic', 'heif', 'jpg', 'jpeg', 'png'];

export function isTransferPhotoName(name: string): boolean {
  const dot: number = name.lastIndexOf('.');
  return dot > 0 && PHOTO_EXTENSIONS.includes(name.substring(dot + 1).toLowerCase());
}

interface RawRecord {
  sequence?: Object;
  body?: Object;
}

interface RawPoll {
  instance_id?: Object;
  phase?: Object;
  ready?: Object;
  lost?: Object;
  records?: Object;
}

function str(value: Object | undefined | null): string {
  return typeof value === 'string' ? value : '';
}

function num(value: Object | undefined | null): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

function obj(value: Object | undefined | null): Record<string, Object> | undefined {
  return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, Object> : undefined;
}

function arr(value: Object | undefined | null): Array<Object> {
  return Array.isArray(value) ? value as Array<Object> : [];
}

export function parseTransferPeers(data: Object | null): Array<TransferPeer> {
  const snapshot: Record<string, Object> | undefined = obj(data);
  if (snapshot === undefined) return [];
  return arr(snapshot['peers']).map((value: Object): TransferPeer | undefined => {
    const peer: Record<string, Object> | undefined = obj(value);
    if (peer === undefined) return undefined;
    const address: string = str(peer['address']);
    const fingerprint: string = str(peer['fingerprint']);
    if (address.length === 0 || fingerprint.length === 0) return undefined;
    return { alias: str(peer['alias']), address: address, fingerprint: fingerprint };
  }).filter((peer: TransferPeer | undefined): boolean => peer !== undefined) as Array<TransferPeer>;
}

export function parseTransferReceipt(value: Object | undefined | null): TransferReceipt | undefined {
  const receipt: Record<string, Object> | undefined = obj(value);
  if (receipt === undefined || str(receipt['id']).length === 0) return undefined;
  return {
    id: str(receipt['id']),
    sessionId: str(receipt['session_id']),
    name: str(receipt['name']),
    size: num(receipt['size']),
    sha256: str(receipt['sha256'])
  };
}

export class TransferSession {
  public instanceId: string = '';
  public phase: number = TRANSFER_PHASE_STARTING;
  public address: string = '';
  public fingerprint: string = '';
  public startError: string = '';
  public fatal: boolean = false;
  public lost: number = 0;
  public resyncNeeded: boolean = false;
  public discoveryEnabled: boolean = false;
  public discoveryError: string = '';
  public peers: Array<TransferPeer> = [];
  /** Peers found by the subnet scan; kept across multicast updates. */
  private readonly scanned: Map<string, TransferPeer> = new Map<string, TransferPeer>();
  public offers: Array<TransferOffer> = [];
  public receipts: Array<TransferReceipt> = [];
  public activities: Array<TransferActivity> = [];
  private lastSequence: number = 0;
  private readonly results: Map<number, TransferResult> = new Map<number, TransferResult>();
  private readonly fileBytes: Map<string, number> = new Map<string, number>();

  public get ready(): boolean {
    return this.phase === TRANSFER_PHASE_RUNNING && this.address.length > 0;
  }

  /** Apply one poll payload; returns true when anything visible changed. */
  public applyPoll(raw: string): boolean {
    if (raw.length === 0) return false;
    const poll: RawPoll = JSON.parse(raw) as RawPoll;
    let changed: boolean = false;
    const instance: string = str(poll.instance_id);
    if (instance.length > 0 && instance !== this.instanceId) {
      this.instanceId = instance;
      this.lastSequence = 0;
      changed = true;
    }
    const phase: number = num(poll.phase);
    if (phase !== this.phase) {
      this.phase = phase;
      changed = true;
    }
    changed = this.applyReady(obj(poll.ready)) || changed;
    const lost: number = num(poll.lost);
    if (lost > this.lost) {
      this.lost = lost;
      this.resyncNeeded = true;
      changed = true;
    }
    const records: Array<RawRecord> = arr(poll.records).map((value: Object): RawRecord => value as RawRecord);
    records.sort((a: RawRecord, b: RawRecord): number => num(a.sequence) - num(b.sequence));
    for (const record of records) {
      const sequence: number = num(record.sequence);
      if (sequence <= this.lastSequence) continue;
      this.lastSequence = sequence;
      const body: Record<string, Object> | undefined = obj(record.body);
      if (body !== undefined) changed = this.applyBody(body) || changed;
    }
    return changed;
  }

  public takeResult(operationId: number): TransferResult | undefined {
    const result: TransferResult | undefined = this.results.get(operationId);
    if (result !== undefined) this.results.delete(operationId);
    return result;
  }

  public setDiscovery(data: Object | null): void {
    const snapshot: Record<string, Object> | undefined = obj(data);
    this.discoveryEnabled = snapshot !== undefined && snapshot['enabled'] === true;
    this.discoveryError = snapshot === undefined ? '' : str(snapshot['error']);
    this.peers = parseTransferPeers(data);
    this.mergeScanned();
  }

  public addScannedPeer(peer: TransferPeer): void {
    if (peer.fingerprint.toUpperCase() === this.fingerprint.toUpperCase()) return;
    this.scanned.set(peer.fingerprint.toUpperCase(), peer);
    this.mergeScanned();
  }

  private mergeScanned(): void {
    for (const [fingerprint, peer] of this.scanned) {
      if (!this.peers.some((known: TransferPeer): boolean => known.fingerprint.toUpperCase() === fingerprint)) {
        this.peers = [...this.peers, peer];
      }
    }
  }

  public setReceipts(data: Object | null): void {
    const receipts: Array<TransferReceipt> = arr(data).map(parseTransferReceipt)
      .filter((receipt: TransferReceipt | undefined): boolean => receipt !== undefined) as Array<TransferReceipt>;
    // Newest first, as committed events prepend.
    this.receipts = receipts.reverse();
  }

  public removeOffer(sessionId: string): void {
    this.offers = this.offers.filter((offer: TransferOffer): boolean => offer.sessionId !== sessionId);
  }

  private applyReady(ready: Record<string, Object> | undefined): boolean {
    if (ready === undefined) return false;
    const address: string = str(ready['address']);
    const fingerprint: string = str(ready['fingerprint']);
    if (address === this.address && fingerprint === this.fingerprint) return false;
    this.address = address;
    this.fingerprint = fingerprint;
    return true;
  }

  private applyBody(body: Record<string, Object>): boolean {
    switch (str(body['kind'])) {
      case 'ready':
        return this.applyReady(obj(body['data']));
      case 'start_failed':
        this.startError = str(body['error']) || 'internal';
        return true;
      case 'fatal':
        this.fatal = true;
        this.startError = str(body['error']) || 'internal';
        return true;
      case 'stopped':
        this.phase = TRANSFER_PHASE_STOPPED;
        return true;
      case 'resync_required':
        this.resyncNeeded = true;
        return true;
      case 'result': {
        const id: number = num(body['operation_id']);
        const error: Object | undefined = body['error'];
        this.results.set(id, {
          operationId: id,
          data: body['data'] ?? null,
          error: error === null || error === undefined ? null : (typeof error === 'string' ? error : JSON.stringify(error))
        });
        return false;
      }
      case 'event': {
        const event: Record<string, Object> | undefined = obj(body['event']);
        return event === undefined ? false : this.applyEvent(event);
      }
      default:
        return false;
    }
  }

  private activity(id: string): TransferActivity | undefined {
    return this.activities.find((activity: TransferActivity): boolean => activity.id === id);
  }

  private upsertActivity(activity: TransferActivity): void {
    const existing: number = this.activities.findIndex((item: TransferActivity): boolean => item.id === activity.id);
    if (existing >= 0) {
      this.activities[existing] = activity;
    } else {
      this.activities = [activity, ...this.activities].slice(0, 32);
    }
  }

  private recomputeBytes(id: string): void {
    const activity: TransferActivity | undefined = this.activity(id);
    if (activity === undefined) return;
    let bytes: number = 0;
    for (const [key, value] of this.fileBytes) {
      if (key.startsWith(id + '/')) bytes += value;
    }
    activity.bytes = activity.total > 0 ? Math.min(bytes, activity.total) : bytes;
  }

  private applyEvent(event: Record<string, Object>): boolean {
    switch (str(event['kind'])) {
      case 'offer': {
        const offer: Record<string, Object> | undefined = obj(event['offer']);
        if (offer === undefined) return false;
        const files: Array<TransferOfferFile> = arr(offer['files']).map((value: Object): TransferOfferFile => {
          const file: Record<string, Object> = obj(value) ?? {};
          return { id: str(file['id']), name: str(file['name']), size: num(file['size']) };
        });
        const sessionId: string = str(offer['session_id']);
        this.removeOffer(sessionId);
        this.offers = [...this.offers, {
          sessionId: sessionId,
          alias: str(offer['alias']),
          fingerprint: str(offer['peer_fingerprint']),
          files: files
        }];
        this.upsertActivity({
          id: sessionId,
          direction: 'receive',
          label: str(offer['alias']),
          fileCount: files.length,
          bytes: 0,
          total: files.reduce((sum: number, file: TransferOfferFile): number => sum + file.size, 0),
          status: 'pending',
          error: ''
        });
        return true;
      }
      case 'accepted': {
        const sessionId: string = str(event['session_id']);
        this.removeOffer(sessionId);
        const activity: TransferActivity | undefined = this.activity(sessionId);
        if (activity !== undefined && activity.status === 'pending') activity.status = 'active';
        return true;
      }
      case 'send_started': {
        const id: string = str(event['transfer_id']);
        const existing: TransferActivity | undefined = this.activity(id);
        this.upsertActivity({
          id: id,
          direction: 'send',
          label: existing?.label ?? '',
          fileCount: num(event['file_count']),
          bytes: 0,
          total: existing?.total ?? 0,
          status: 'active',
          error: ''
        });
        return true;
      }
      case 'prepared': {
        const activity: TransferActivity | undefined = this.activity(str(event['transfer_id']));
        if (activity === undefined) return false;
        const files: Array<Object> = arr(event['files']);
        activity.fileCount = files.length;
        let total: number = 0;
        for (const value of files) total += num(obj(value)?.['size']);
        activity.total = total;
        return true;
      }
      case 'progress': {
        const id: string = str(event['transfer_id']);
        const fileId: string = str(event['file_id']);
        const key: string = id + '/' + fileId;
        const bytes: number = num(event['bytes']);
        // Progress for one file never regresses from an older event.
        if (bytes > (this.fileBytes.get(key) ?? 0)) this.fileBytes.set(key, bytes);
        const activity: TransferActivity | undefined = this.activity(id);
        if (activity !== undefined && activity.status === 'pending') activity.status = 'active';
        this.recomputeBytes(id);
        return true;
      }
      case 'committed': {
        const receipt: TransferReceipt | undefined = parseTransferReceipt(event['receipt']);
        if (receipt === undefined) return false;
        this.receipts = [receipt, ...this.receipts.filter((item: TransferReceipt): boolean => item.id !== receipt.id)];
        return true;
      }
      case 'receipt_deleted': {
        const id: string = str(event['receipt_id']);
        this.receipts = this.receipts.filter((item: TransferReceipt): boolean => item.id !== id);
        return true;
      }
      case 'failed': {
        const id: string = str(event['transfer_id']);
        const activity: TransferActivity | undefined = this.activity(id);
        if (activity === undefined) return false;
        // A failed file inside a live session is not a failed session.
        if (event['file_id'] === null || event['file_id'] === undefined) {
          activity.status = 'failed';
          activity.error = transferErrorLabel(str(event['code']));
        } else if (activity.error.length === 0) {
          activity.error = '部分文件失败：' + transferErrorLabel(str(event['code']));
        }
        this.removeOffer(id);
        return true;
      }
      case 'session_ended': {
        const id: string = str(event['session_id']);
        this.removeOffer(id);
        const activity: TransferActivity | undefined = this.activity(id);
        if (activity !== undefined && activity.status !== 'failed') {
          activity.status = activity.status === 'pending' ? 'failed' : 'done';
          if (activity.status === 'failed' && activity.error.length === 0) activity.error = '未接收';
        }
        return true;
      }
      case 'sent': {
        const activity: TransferActivity | undefined = this.activity(str(event['transfer_id']));
        if (activity === undefined) return false;
        const report: Record<string, Object> | undefined = obj(event['report']);
        const error: string = report === undefined ? '' : str(report['error']);
        activity.status = error.length > 0 ? 'failed' : 'done';
        activity.error = error.length > 0 ? transferErrorLabel(error) : '';
        if (activity.status === 'done' && activity.total > 0) activity.bytes = activity.total;
        return true;
      }
      default:
        return false;
    }
  }
}
