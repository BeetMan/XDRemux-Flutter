import {
  TRANSFER_PHASE_STOPPED,
  TransferSession,
  transferAbiSupported,
  transferErrorLabel
} from './TransferModel.ts';
import type { TransferActivity, TransferPeer, TransferReceipt, TransferResult } from './TransferModel.ts';

/** The N-API surface from libentry.so (transfer_bridge.cpp). */
export interface TransferBridge {
  abiVersion(): number;
  create(configJson: string): number;
  submit(handle: number, requestJson: string): number;
  poll(handle: number, maxEvents: number, maxBytes: number): string;
  stop(handle: number): number;
  release(handle: number): number;
}

export interface TransferStartOptions {
  root: string;
  alias: string;
  bind: string;
}

export interface TransferLease {
  leaseId: number;
  path: string;
}

const POLL_INTERVAL_MS: number = 150;
const POLL_MAX_EVENTS: number = 64;
const POLL_MAX_BYTES: number = 1024 * 1024;
const COMMAND_TIMEOUT_MS: number = 30000;
const START_TIMEOUT_MS: number = 20000;
const STOP_TIMEOUT_MS: number = 30000;
const STATUS_BUSY: string = 'TRANSFER_3';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

function errorCode(error: Object): string {
  const code: Object | undefined = (error as Record<string, Object>)['code'];
  return typeof code === 'string' ? code : '';
}

/**
 * One transfer runtime. Explicit start binds the LAN listener; stop revokes
 * leases, joins the native runtime and releases the handle. Never auto-starts
 * and never auto-accepts: offers wait for decide().
 */
export class TransferController {
  public session: TransferSession = new TransferSession();
  private handle: number = 0;
  private timer: number = -1;
  private stopping: Promise<void> | undefined = undefined;
  private readonly bridge: TransferBridge;
  private readonly onChange: () => void;

  constructor(bridge: TransferBridge, onChange: () => void) {
    this.bridge = bridge;
    this.onChange = onChange;
  }

  public get running(): boolean {
    return this.handle !== 0 && this.stopping === undefined;
  }

  public async start(options: TransferStartOptions): Promise<void> {
    if (this.handle !== 0) throw new Error('传输服务已在运行');
    const version: number = this.bridge.abiVersion();
    if (!transferAbiSupported(version)) {
      throw new Error('传输库版本不兼容：0x' + version.toString(16));
    }
    this.session = new TransferSession();
    this.handle = this.bridge.create(JSON.stringify({
      root: options.root,
      bind: options.bind,
      alias: options.alias,
      pin: null
    }));
    this.timer = setInterval((): void => {
      this.pump();
    }, POLL_INTERVAL_MS);
    const deadline: number = Date.now() + START_TIMEOUT_MS;
    while (!this.session.ready) {
      this.pump();
      if (this.session.startError.length > 0 || this.session.phase === TRANSFER_PHASE_STOPPED) {
        const reason: string = transferErrorLabel(this.session.startError || 'closed');
        await this.stop();
        throw new Error('传输服务启动失败：' + reason);
      }
      if (Date.now() > deadline) {
        await this.stop();
        throw new Error('传输服务启动超时');
      }
      await sleep(50);
    }
    this.onChange();
  }

  /** Drain bridge records; never blocks on network or disk. */
  public pump(): void {
    if (this.handle === 0) return;
    let raw: string = '';
    try {
      raw = this.bridge.poll(this.handle, POLL_MAX_EVENTS, POLL_MAX_BYTES);
    } catch (error) {
      // Busy means another drain is in progress; anything else surfaces via stop.
      if (errorCode(error as Object) !== STATUS_BUSY) this.session.fatal = true;
      return;
    }
    if (this.session.applyPoll(raw)) this.onChange();
  }

  /** Submit one JSON command and wait for its tagged result. */
  public async command(request: Record<string, Object | null>, timeoutMs: number = COMMAND_TIMEOUT_MS): Promise<Object | null> {
    if (!this.running) throw new Error('传输服务未运行');
    const operation: number = this.bridge.submit(this.handle, JSON.stringify(request));
    const deadline: number = Date.now() + timeoutMs;
    for (;;) {
      this.pump();
      const result: TransferResult | undefined = this.session.takeResult(operation);
      if (result !== undefined) {
        if (result.error !== null) throw new Error(transferErrorLabel(result.error));
        return result.data;
      }
      if (Date.now() > deadline) {
        // Never replay a command whose outcome is unknown.
        throw new Error('传输操作超时，结果未知（操作 ' + String(operation) + '）');
      }
      if (this.handle === 0) throw new Error(transferErrorLabel('closed'));
      await sleep(40);
    }
  }

  public async refreshDiscovery(): Promise<void> {
    const data: Object | null = await this.command({ command: 'discovery_start', interface: null });
    this.session.setDiscovery(data);
    this.onChange();
  }

  public async discoveryStatus(): Promise<void> {
    this.session.setDiscovery(await this.command({ command: 'discovery_status' }));
    this.onChange();
  }

  /** Identify a LocalSend endpoint by address ("IP:port"); discovery only, no trust. */
  public async probe(address: string, timeoutMs: number = 5000): Promise<TransferPeer> {
    const data: Record<string, Object> | null =
      await this.command({ command: 'probe', address: address }, timeoutMs) as Record<string, Object> | null;
    const fingerprint: Object | undefined = data?.['fingerprint'];
    const reported: Object | undefined = data?.['address'];
    if (typeof fingerprint !== 'string' || fingerprint.length === 0) throw new Error('对方不是 LocalSend 设备');
    return {
      alias: typeof data?.['alias'] === 'string' ? data['alias'] as string : address.split(':')[0],
      address: typeof reported === 'string' && reported.length > 0 ? reported : address,
      fingerprint: fingerprint
    };
  }

  public async refreshReceipts(): Promise<void> {
    this.session.setReceipts(await this.command({ command: 'receipts', after: null, limit: 64 }));
    this.session.resyncNeeded = false;
    this.onChange();
  }

  public async decide(sessionId: string, accept: boolean): Promise<void> {
    await this.command({ command: 'decide', transfer_id: sessionId, accept: accept });
    this.session.removeOffer(sessionId);
    this.onChange();
  }

  /** The caller must have shown and confirmed the full peer fingerprint. */
  public async send(peer: TransferPeer, paths: Array<string>, label: string): Promise<string> {
    const data: Object | null = await this.command({
      command: 'send',
      peer: { address: peer.address, fingerprint: peer.fingerprint },
      paths: paths,
      pin: null
    });
    const id: string = typeof (data as Record<string, Object>)?.['transfer_id'] === 'string'
      ? (data as Record<string, Object>)['transfer_id'] as string : '';
    const activity: TransferActivity | undefined = this.session.activities.find((item: TransferActivity): boolean => item.id === id);
    if (activity !== undefined) activity.label = label;
    else if (id.length > 0) {
      this.session.activities = [{
        id: id, direction: 'send', label: label, fileCount: paths.length,
        bytes: 0, total: 0, status: 'active', error: ''
      }, ...this.session.activities];
    }
    this.onChange();
    return id;
  }

  public async acquireReceipt(receiptId: string): Promise<TransferLease> {
    const data: Record<string, Object> | null =
      await this.command({ command: 'acquire_receipt', receipt_id: receiptId }) as Record<string, Object> | null;
    const leaseId: Object | undefined = data?.['lease_id'];
    const path: Object | undefined = data?.['path'];
    if (typeof leaseId !== 'number' || typeof path !== 'string' || path.length === 0) {
      throw new Error('收件文件租约无效');
    }
    return { leaseId: leaseId, path: path };
  }

  public async releaseReceipt(lease: TransferLease): Promise<void> {
    await this.command({ command: 'release_receipt', lease_id: lease.leaseId });
  }

  public async deleteReceipt(receiptId: string): Promise<void> {
    await this.command({ command: 'delete_receipt', receipt_id: receiptId });
    this.session.receipts = this.session.receipts.filter((receipt: TransferReceipt): boolean => receipt.id !== receiptId);
    this.onChange();
  }

  /** Idempotent: stop revokes leases and joins the runtime, then releases the handle. */
  public stop(): Promise<void> {
    if (this.stopping !== undefined) return this.stopping;
    if (this.handle === 0) return Promise.resolve();
    this.stopping = this.stopAndRelease().finally((): void => {
      this.stopping = undefined;
    });
    return this.stopping;
  }

  private async stopAndRelease(): Promise<void> {
    const handle: number = this.handle;
    this.bridge.stop(handle);
    const deadline: number = Date.now() + STOP_TIMEOUT_MS;
    while (this.session.phase !== TRANSFER_PHASE_STOPPED && Date.now() < deadline) {
      this.pump();
      await sleep(50);
    }
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    // Release only after Stopped; Busy means native shutdown is still running.
    for (let attempt = 0; attempt < 100; attempt += 1) {
      if (this.bridge.release(handle) !== 3) break;
      await sleep(100);
    }
    this.handle = 0;
    this.session.peers = [];
    this.session.offers = [];
    this.onChange();
  }
}
