// LocalSend device transfer sheet: Send and Receive tabs over the shared
// adapter (TransferController). Mirrors the Flutter transfer page (#79):
// pick a device and send without a fingerprint screen, subnet scan when
// multicast is quiet, a renamable device name, keep-awake while a transfer
// runs, inbox previews, Live Photo pairing (.pvt.zip unpack, loose HEIC + MOV),
// and saving to the local gallery or the system Photos library.
import { common } from '@kit.AbilityKit';
import { deviceInfo, zlib } from '@kit.BasicServicesKit';
import { preferences, uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { connection, socket } from '@kit.NetworkKit';
import { systemShare } from '@kit.ShareKit';
import { LengthMetrics, window } from '@kit.ArkUI';
import xdremuxNative from 'libentry.so';
import { TransferController } from './TransferController';
import type { TransferBridge, TransferLease } from './TransferController';
import { TransferSession, formatTransferBytes } from './TransferModel';
import type {
  TransferActivity, TransferOffer, TransferOfferFile, TransferPeer, TransferReceipt
} from './TransferModel';
import {
  cleanTransferDeviceName,
  groupTransferInbox,
  parseTransferAddress,
  transferScanTargets,
  validateLivePhotoBundleEntries
} from './TransferInbox';
import type { LivePhotoBundleParts, TransferInboxEntry, TransferScanTarget } from './TransferInbox';

export interface TransferSendSource {
  source: string;
  name: string;
}

interface TransferView {
  running: boolean;
  ready: boolean;
  discoveryError: string;
  peers: Array<TransferPeer>;
  offers: Array<TransferOffer>;
  activities: Array<TransferActivity>;
  inbox: Array<TransferInboxEntry>;
}

interface NamedFile {
  path: string;
  name: string;
}

const EMPTY_VIEW: TransferView = {
  running: false, ready: false, discoveryError: '', peers: [], offers: [], activities: [], inbox: []
};
const LISTEN_PORT: number = 53319;
const PREFS_NAME: string = 'xdremux_transfer';
const ALIAS_KEY: string = 'alias.v1';
const SCAN_BATCH: number = 64;

@Component
export struct TransferPanel {
  /** Files handed in by the opener (a converted queue item); may be empty. */
  @Prop initialSources: Array<TransferSendSource> = [];
  @Prop initialLabel: string = '';
  /** Copies a received photo into the app's local gallery. */
  importToGallery: (path: string, name: string) => Promise<void> =
    async (path: string, name: string): Promise<void> => {};
  /** Adds a received photo to the conversion queue (via the local gallery). */
  addToQueue: (path: string, name: string) => Promise<void> =
    async (path: string, name: string): Promise<void> => {};

  @State private tab: number = 1;
  @State private view: TransferView = EMPTY_VIEW;
  @State private busy: boolean = false;
  @State private status: string = '';
  @State private sendFiles: Array<TransferSendSource> = [];
  @State private sendLabel: string = '';
  @State private deviceName: string = '';
  @State private nameDraft: string = '';
  @State private editingName: boolean = false;
  @State private showAddresses: boolean = false;
  @State private localAddresses: Array<string> = [];
  @State private manualAddress: string = '';
  @State private scanning: boolean = false;
  @State private previews: Record<string, string> = {};

  private controller: TransferController | undefined = undefined;
  private discoveryTimer: number = -1;
  private startedAt: number = 0;
  private autoScanned: boolean = false;
  private keepingAwake: boolean = false;
  private previewing: Set<string> = new Set<string>();
  private alive: boolean = true;

  aboutToAppear(): void {
    this.sendFiles = this.initialSources.slice();
    this.sendLabel = this.initialLabel;
    this.tab = this.sendFiles.length > 0 ? 0 : 1;
    this.controller = new TransferController(this.bridge(), (): void => {
      this.publish();
    });
    void this.loadDeviceName().then((): void => {
      // Choosing files to send is the explicit action; the Receive tab waits for the toggle.
      if (this.sendFiles.length > 0) void this.start();
    });
  }

  aboutToDisappear(): void {
    this.alive = false;
    if (this.discoveryTimer >= 0) {
      clearInterval(this.discoveryTimer);
      this.discoveryTimer = -1;
    }
    this.setKeepAwake(false);
    // Leaving the sheet stops listening; never keep the LAN port open unseen.
    void this.controller?.stop();
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private bridge(): TransferBridge {
    return {
      abiVersion: (): number => xdremuxNative.transferAbiVersion() as number,
      create: (configJson: string): number => xdremuxNative.transferCreate(configJson) as number,
      submit: (handle: number, requestJson: string): number =>
        xdremuxNative.transferSubmit(handle, requestJson) as number,
      poll: (handle: number, maxEvents: number, maxBytes: number): string =>
        xdremuxNative.transferPoll(handle, maxEvents, maxBytes) as string,
      stop: (handle: number): number => xdremuxNative.transferStop(handle) as number,
      release: (handle: number): number => xdremuxNative.transferRelease(handle) as number
    };
  }

  private errorText(error: Object): string {
    return error instanceof Error ? error.message : String(error);
  }

  private publish(): void {
    if (!this.alive) return;
    const controller: TransferController | undefined = this.controller;
    if (controller === undefined) return;
    const session: TransferSession = controller.session;
    this.view = {
      running: controller.running,
      ready: controller.running && session.ready,
      discoveryError: session.discoveryError,
      peers: session.peers.slice(),
      offers: session.offers.slice(),
      // Copy rows: the session mutates activities in place on progress.
      activities: session.activities.map((activity: TransferActivity): TransferActivity => ({
        id: activity.id, direction: activity.direction, label: activity.label, fileCount: activity.fileCount,
        bytes: activity.bytes, total: activity.total, status: activity.status, error: activity.error
      })),
      inbox: groupTransferInbox(session.receipts)
    };
    this.setKeepAwake(this.view.activities.some((activity: TransferActivity): boolean =>
      activity.status === 'active' || activity.status === 'pending'));
    void this.loadPreviews();
  }

  // ---------- lifecycle ----------

  private async loadDeviceName(): Promise<void> {
    try {
      const prefs: preferences.Preferences = await preferences.getPreferences(this.context(), PREFS_NAME);
      this.deviceName = cleanTransferDeviceName(prefs.getSync(ALIAS_KEY, '') as string);
    } catch (error) {
      this.deviceName = '';
    }
  }

  private modelName(): string {
    const model: string = (deviceInfo.marketName ?? '').trim();
    return model.length > 0 ? model : 'HarmonyOS';
  }

  private visibleName(): string {
    return this.deviceName.length > 0 ? this.deviceName : this.modelName();
  }

  private async saveDeviceName(): Promise<void> {
    const clean: string = cleanTransferDeviceName(this.nameDraft);
    try {
      const prefs: preferences.Preferences = await preferences.getPreferences(this.context(), PREFS_NAME);
      if (clean.length === 0) {
        prefs.deleteSync(ALIAS_KEY);
      } else {
        prefs.putSync(ALIAS_KEY, clean);
      }
      await prefs.flush();
      this.deviceName = clean;
      this.editingName = false;
      this.status = this.view.running ? '新名称在重新开启接收后生效' : '';
    } catch (error) {
      this.status = '保存名称失败：' + this.errorText(error);
    }
  }

  private async start(): Promise<void> {
    const controller: TransferController | undefined = this.controller;
    if (controller === undefined || controller.running || this.busy) return;
    this.busy = true;
    this.status = '';
    try {
      await controller.start({
        root: this.context().filesDir + '/transfer',
        alias: this.visibleName(),
        bind: '0.0.0.0:' + String(LISTEN_PORT)
      });
      this.startedAt = Date.now();
      this.autoScanned = false;
      this.localAddresses = this.localIPv4s();
      await controller.refreshReceipts();
      await this.refreshDiscovery();
      this.discoveryTimer = setInterval((): void => {
        void this.tick();
      }, 2000);
    } catch (error) {
      this.status = this.errorText(error);
    } finally {
      this.busy = false;
      this.publish();
    }
  }

  private async stop(): Promise<void> {
    if (this.discoveryTimer >= 0) {
      clearInterval(this.discoveryTimer);
      this.discoveryTimer = -1;
    }
    this.busy = true;
    try {
      await this.controller?.stop();
    } finally {
      this.busy = false;
      this.publish();
    }
  }

  private async tick(): Promise<void> {
    const controller: TransferController | undefined = this.controller;
    if (controller === undefined || !controller.running) return;
    try {
      await controller.discoveryStatus();
      if (controller.session.resyncNeeded) await controller.refreshReceipts();
    } catch (error) {
      // Discovery status is advisory; keep the last peer list.
    }
    // Multicast is often blocked: after a few quiet seconds scan the subnet once.
    if (!this.autoScanned && controller.session.peers.length === 0 && Date.now() - this.startedAt >= 3000) {
      this.autoScanned = true;
      void this.scanSubnet();
    }
  }

  private async refreshDiscovery(): Promise<void> {
    try {
      await this.controller?.refreshDiscovery();
    } catch (error) {
      // An unavailable multicast path is shown from the discovery snapshot.
    }
  }

  private setKeepAwake(on: boolean): void {
    if (on === this.keepingAwake) return;
    this.keepingAwake = on;
    window.getLastWindow(this.context()).then((win: window.Window): Promise<void> =>
      win.setWindowKeepScreenOn(on)).catch((): void => {});
  }

  // ---------- discovery ----------

  private localIPv4s(): Array<string> {
    try {
      const net: connection.NetHandle = connection.getDefaultNetSync();
      const props: connection.ConnectionProperties = connection.getConnectionPropertiesSync(net);
      return props.linkAddresses
        .map((link: connection.LinkAddress): string => link.address.address)
        .filter((address: string): boolean => /^\d+\.\d+\.\d+\.\d+$/.test(address));
    } catch (error) {
      return [];
    }
  }

  private async tcpOpen(target: TransferScanTarget): Promise<boolean> {
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    try {
      await tcp.connect({ address: { address: target.host, port: target.port, family: 1 }, timeout: 600 });
      return true;
    } catch (error) {
      return false;
    } finally {
      tcp.close().catch((): void => {});
    }
  }

  /** LocalSend's fallback: try every /24 neighbour on both ports, then identify answering hosts. */
  private async scanSubnet(): Promise<void> {
    const controller: TransferController | undefined = this.controller;
    if (controller === undefined || !controller.running || this.scanning) return;
    this.scanning = true;
    try {
      const targets: Array<TransferScanTarget> = transferScanTargets(this.localIPv4s());
      const open: Array<TransferScanTarget> = [];
      for (let i = 0; i < targets.length; i += SCAN_BATCH) {
        const batch: Array<TransferScanTarget> = targets.slice(i, i + SCAN_BATCH);
        const results: Array<boolean> = await Promise.all(batch.map((target: TransferScanTarget): Promise<boolean> =>
          this.tcpOpen(target)));
        results.forEach((ok: boolean, index: number): void => {
          if (ok) open.push(batch[index]);
        });
        if (!controller.running || !this.alive) return;
      }
      for (const target of open) {
        try {
          const peer: TransferPeer = await controller.probe(target.host + ':' + String(target.port), 3000);
          controller.session.addScannedPeer(peer);
          this.publish();
        } catch (error) {
          // Not a LocalSend endpoint; skip it.
        }
      }
    } finally {
      this.scanning = false;
    }
  }

  private async refreshPeers(): Promise<void> {
    await this.refreshDiscovery();
    await this.scanSubnet();
  }

  private async connectManual(): Promise<void> {
    const controller: TransferController | undefined = this.controller;
    if (controller === undefined || !controller.running || this.busy) return;
    this.busy = true;
    try {
      const address: string = parseTransferAddress(this.manualAddress, 53317);
      const peer: TransferPeer = await controller.probe(address);
      controller.session.addScannedPeer(peer);
      this.manualAddress = '';
      this.status = '';
      this.publish();
    } catch (error) {
      this.status = '连接失败：' + this.errorText(error);
    } finally {
      this.busy = false;
    }
  }

  // ---------- send ----------

  private async pickPhotos(): Promise<void> {
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
      options.maxSelectNumber = 50;
      const result: photoAccessHelper.PhotoSelectResult = await new photoAccessHelper.PhotoViewPicker().select(options);
      if (result.photoUris.length === 0) return;
      const directory: string = this.context().cacheDir + '/transfer-picked/' + String(Date.now());
      await fileIo.mkdir(directory, true);
      const added: Array<TransferSendSource> = [];
      for (const uri of result.photoUris) {
        const leaf: string = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1));
        const name: string = this.uniqueName(leaf.length > 0 ? leaf : 'photo.jpg',
          [...this.sendFiles, ...added].map((file: TransferSendSource): string => file.name));
        const target: string = directory + '/' + name;
        const source: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
        try {
          await fileIo.copyFile(source.fd, target);
        } finally {
          await fileIo.close(source.fd);
        }
        added.push({ source: target, name: name });
      }
      this.sendFiles = [...this.sendFiles, ...added];
      if (this.sendLabel.length === 0 || this.initialSources.length === 0) {
        this.sendLabel = String(this.sendFiles.length) + ' 个文件';
      }
      if (!this.view.running) void this.start();
    } catch (error) {
      this.status = '选择照片失败：' + this.errorText(error);
    }
  }

  private uniqueName(name: string, taken: Array<string>): string {
    if (!taken.includes(name)) return name;
    const dot: number = name.lastIndexOf('.');
    const stem: string = dot > 0 ? name.substring(0, dot) : name;
    const extension: string = dot > 0 ? name.substring(dot) : '';
    for (let i = 2; ; i += 1) {
      const candidate: string = stem + '-' + String(i) + extension;
      if (!taken.includes(candidate)) return candidate;
    }
  }

  /** Copy sources whose basename differs from the name the peer should see. */
  private async stageSendFiles(): Promise<Array<string>> {
    const directory: string = this.context().cacheDir + '/transfer-send/' + String(Date.now());
    await fileIo.mkdir(directory, true);
    const paths: Array<string> = [];
    for (const file of this.sendFiles) {
      const stat: fileIo.Stat = await fileIo.lstat(file.source);
      if (stat.isSymbolicLink() || !stat.isFile() || stat.size <= 0) throw new Error('文件不可读，请重新选择：' + file.name);
      if (file.source.substring(file.source.lastIndexOf('/') + 1) === file.name) {
        paths.push(file.source);
      } else {
        const target: string = directory + '/' + file.name;
        await fileIo.copyFile(file.source, target);
        paths.push(target);
      }
    }
    return paths;
  }

  private async sendTo(peer: TransferPeer): Promise<void> {
    const controller: TransferController | undefined = this.controller;
    if (controller === undefined || !controller.running || this.sendFiles.length === 0 || this.busy) return;
    this.busy = true;
    this.status = '';
    try {
      const paths: Array<string> = await this.stageSendFiles();
      const label: string = this.sendLabel.length > 0 ? this.sendLabel : String(paths.length) + ' 个文件';
      await controller.send(peer, paths, label + ' → ' + (peer.alias.length > 0 ? peer.alias : peer.address));
    } catch (error) {
      this.status = '发送失败：' + this.errorText(error);
    } finally {
      this.busy = false;
    }
  }

  // ---------- receive ----------

  private async decide(offer: TransferOffer, accept: boolean): Promise<void> {
    try {
      await this.controller?.decide(offer.sessionId, accept);
    } catch (error) {
      this.status = (accept ? '接收' : '拒绝') + '失败：' + this.errorText(error);
    }
  }

  /** Copy a receipt's immutable data file out under its own name, holding a read lease meanwhile. */
  private async copyReceipt(receipt: TransferReceipt, directory: string): Promise<string> {
    const controller: TransferController | undefined = this.controller;
    if (controller === undefined) throw new Error('传输服务未运行');
    await fileIo.mkdir(directory, true);
    const target: string = directory + '/' + receipt.name;
    const lease: TransferLease = await controller.acquireReceipt(receipt.id);
    try {
      if (await fileIo.access(target)) await fileIo.unlink(target);
      await fileIo.copyFile(lease.path, target);
    } finally {
      await controller.releaseReceipt(lease);
    }
    return target;
  }

  private workDirectory(kind: string): string {
    return this.context().cacheDir + '/transfer-' + kind + '/' + String(Date.now()) + '-' +
      String(Math.floor(Math.random() * 100000));
  }

  private async unpackLiveZip(receipt: TransferReceipt): Promise<NamedFile[]> {
    const directory: string = this.workDirectory('unpack');
    const zipPath: string = await this.copyReceipt(receipt, directory);
    const out: string = directory + '/out';
    await fileIo.mkdir(out, true);
    await zlib.decompressFile(zipPath, out, {});
    const entries: Array<string> = fileIo.listFileSync(out, { recursion: true })
      .map((entry: string): string => entry.replace(/^\/+/, ''));
    const parts: LivePhotoBundleParts = validateLivePhotoBundleEntries(receipt.name, entries);
    const bundle: string = out + '/' + receipt.name.substring(0, receipt.name.length - '.zip'.length);
    return [
      { path: bundle + '/' + parts.still, name: parts.still },
      { path: bundle + '/' + parts.movie, name: parts.movie }
    ];
  }

  /** Files that make up an inbox row, copied out of the inbox: still first. */
  private async entryFiles(entry: TransferInboxEntry): Promise<NamedFile[]> {
    if (entry.kind === 'live-zip') return await this.unpackLiveZip(entry.receipt);
    const directory: string = this.workDirectory('out');
    const files: Array<NamedFile> = [{ path: await this.copyReceipt(entry.receipt, directory), name: entry.receipt.name }];
    if (entry.movie !== undefined) {
      files.push({ path: await this.copyReceipt(entry.movie, directory), name: entry.movie.name });
    }
    return files;
  }

  /** Photos and Live Photo stills go to the queue; plain files cannot convert. */
  private async queueEntry(entry: TransferInboxEntry): Promise<void> {
    const files: Array<NamedFile> = await this.entryFiles(entry);
    await this.addToQueue(files[0].path, files[0].name);
  }

  private async queueAll(): Promise<string> {
    let added: number = 0;
    let failed: number = 0;
    for (const entry of this.view.inbox.slice()) {
      if (entry.kind === 'file') continue;
      try {
        await this.queueEntry(entry);
        added += 1;
      } catch (error) {
        failed += 1;
      }
    }
    return '已加入转换队列 ' + String(added) + ' 张' + (failed > 0 ? '，' + String(failed) + ' 张未加入' : '');
  }

  private async saveToGallery(entry: TransferInboxEntry): Promise<void> {
    const files: Array<NamedFile> = await this.entryFiles(entry);
    await this.importToGallery(files[0].path, files[0].name);
  }

  /** System Photos via the creation dialog (no gallery permission); Live Photos as photo + video. */
  private async saveToPhotos(entries: Array<TransferInboxEntry>): Promise<number> {
    const files: Array<NamedFile> = [];
    for (const entry of entries) {
      if (entry.kind === 'file') continue;
      files.push(...await this.entryFiles(entry));
    }
    if (files.length === 0) return 0;
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.context());
    const configs: Array<photoAccessHelper.PhotoCreationConfig> = files.map((file: NamedFile):
      photoAccessHelper.PhotoCreationConfig => {
      const dot: number = file.name.lastIndexOf('.');
      const extension: string = dot > 0 ? file.name.substring(dot + 1).toLowerCase() : 'jpg';
      return {
        title: dot > 0 ? file.name.substring(0, dot) : file.name,
        fileNameExtension: extension,
        photoType: extension === 'mov' || extension === 'mp4'
          ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE
      };
    });
    const targets: Array<string> = await helper.showAssetsCreationDialog(
      files.map((file: NamedFile): string => fileUri.getUriFromPath(file.path)), configs);
    if (targets.length !== files.length) throw new Error('已取消保存');
    for (let i = 0; i < files.length; i += 1) {
      const target: fileIo.File = await fileIo.open(targets[i], fileIo.OpenMode.WRITE_ONLY);
      try {
        await fileIo.copyFile(files[i].path, target.fd);
      } finally {
        await fileIo.close(target.fd);
      }
    }
    return files.length;
  }

  private async share(entry: TransferInboxEntry): Promise<void> {
    const directory: string = this.workDirectory('out');
    const files: Array<NamedFile> = [{ path: await this.copyReceipt(entry.receipt, directory), name: entry.receipt.name }];
    if (entry.movie !== undefined) {
      files.push({ path: await this.copyReceipt(entry.movie, directory), name: entry.movie.name });
    }
    const data: systemShare.SharedData = new systemShare.SharedData({
      utd: utd.UniformDataType.FILE_URI, uri: fileUri.getUriFromPath(files[0].path), title: files[0].name
    });
    for (const file of files.slice(1)) {
      data.addRecord({ utd: utd.UniformDataType.FILE_URI, uri: fileUri.getUriFromPath(file.path), title: file.name });
    }
    await new systemShare.ShareController(data).show(this.context(), {
      selectionMode: systemShare.SelectionMode.BATCH,
      previewMode: systemShare.SharePreviewMode.DEFAULT
    });
  }

  private async deleteEntry(entry: TransferInboxEntry): Promise<void> {
    const controller: TransferController | undefined = this.controller;
    if (controller === undefined) return;
    await controller.deleteReceipt(entry.receipt.id);
    if (entry.movie !== undefined) await controller.deleteReceipt(entry.movie.id);
  }

  private async runAction(action: () => Promise<string>): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      this.status = await action();
    } catch (error) {
      this.status = this.errorText(error);
    } finally {
      this.busy = false;
      this.publish();
    }
  }

  private confirmClearInbox(): void {
    const count: number = this.view.inbox.length;
    this.getUIContext().showAlertDialog({
      title: '清空收件箱？',
      message: '删除收件箱里的 ' + String(count) + ' 项。已存入图库或相册的副本不受影响。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '清空',
        fontColor: '#B3261E',
        action: (): void => {
          void this.runAction(async (): Promise<string> => {
            for (const entry of this.view.inbox.slice()) await this.deleteEntry(entry);
            return '';
          });
        }
      }
    });
  }

  /** Small preview copies for photo rows; loaded once per receipt. */
  private async loadPreviews(): Promise<void> {
    const controller: TransferController | undefined = this.controller;
    if (controller === undefined || !controller.running) return;
    for (const entry of this.view.inbox.slice(0, 30)) {
      const id: string = entry.receipt.id;
      if (entry.kind === 'file' || this.previews[id] !== undefined || this.previewing.has(id)) continue;
      this.previewing.add(id);
      try {
        const path: string = entry.kind === 'live-zip'
          ? (await this.unpackLiveZip(entry.receipt))[0].path
          : await this.copyReceipt(entry.receipt, this.context().cacheDir + '/transfer-preview/' + id);
        if (!this.alive) return;
        const next: Record<string, string> = {};
        Object.keys(this.previews).forEach((key: string): void => {
          next[key] = this.previews[key];
        });
        next[id] = path;
        this.previews = next;
      } catch (error) {
        // No preview; the row keeps its icon.
      }
    }
  }

  // ---------- UI ----------

  private activityText(activity: TransferActivity): string {
    const direction: string = activity.direction === 'send' ? '发送' : '接收';
    const state: string = activity.status === 'pending' ? '等待对方确认'
      : activity.status === 'active' ? '传输中'
      : activity.status === 'done' ? '已完成' : '失败';
    const size: string = activity.total > 0
      ? formatTransferBytes(activity.bytes) + ' / ' + formatTransferBytes(activity.total) : '';
    return direction + ' · ' + (activity.label.length > 0 ? activity.label : String(activity.fileCount) + ' 个文件') +
      ' · ' + state + (size.length > 0 ? ' · ' + size : '') + (activity.error.length > 0 ? ' · ' + activity.error : '');
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .width('100%')
      .margin({ top: 18, bottom: 6 });
  }

  @Builder
  activitySection() {
    if (this.view.activities.length > 0) {
      this.sectionTitle('传输记录');
      ForEach(this.view.activities, (activity: TransferActivity) => {
        Column() {
          Text(this.activityText(activity))
            .fontSize(12)
            .fontColor(activity.status === 'failed' ? '#B3261E' : $r('sys.color.font_primary'))
            .width('100%');
          if (activity.status === 'active' && activity.total > 0) {
            Progress({ value: activity.bytes, total: activity.total, type: ProgressType.Linear })
              .width('100%')
              .margin({ top: 4 });
          }
        }
        .width('100%')
        .margin({ bottom: 8 });
      }, (activity: TransferActivity): string => activity.id + activity.status + String(activity.bytes) + activity.error);
    }
  }

  @Builder
  sendTab() {
    Column() {
      Row() {
        Text(this.sendFiles.length > 0 ? '要发送的文件（' + String(this.sendFiles.length) + '）' : '要发送的文件')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1);
        if (this.sendFiles.length > 0) {
          Button('清空')
            .fontSize(13)
            .height(32)
            .backgroundColor($r('sys.color.background_secondary'))
            .fontColor($r('sys.color.font_primary'))
            .onClick((): void => {
              this.sendFiles = [];
              this.sendLabel = '';
            });
        }
      }
      .width('100%')
      .margin({ bottom: 6 });
      if (this.sendFiles.length === 0) {
        Text('先添加要发送的文件')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%');
      }
      ForEach(this.sendFiles, (file: TransferSendSource) => {
        Row() {
          Text(file.name)
            .fontSize(13)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
          Text('移除')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .padding(6)
            .onClick((): void => {
              this.sendFiles = this.sendFiles.filter((item: TransferSendSource): boolean => item !== file);
            });
        }
        .width('100%');
      }, (file: TransferSendSource): string => file.source + '|' + file.name);
      Button('选择照片')
        .width('100%')
        .height(40)
        .margin({ top: 8 })
        .backgroundColor($r('sys.color.background_secondary'))
        .fontColor($r('sys.color.font_primary'))
        .enabled(!this.busy)
        .onClick((): void => {
          void this.pickPhotos();
        });

      Row() {
        Text(this.scanning ? '附近设备 · 正在搜索…' : '附近设备')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1);
        Button('刷新')
          .fontSize(13)
          .height(32)
          .enabled(this.view.running && !this.scanning)
          .onClick((): void => {
            void this.refreshPeers();
          });
      }
      .width('100%')
      .margin({ top: 18, bottom: 6 });
      if (!this.view.running) {
        Text(this.busy ? '正在开启…' : '尚未搜索附近设备')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%');
        if (!this.busy) {
          Button('搜索附近设备')
            .width('100%')
            .height(40)
            .margin({ top: 8 })
            .onClick((): void => {
              void this.start();
            });
        }
      } else if (this.view.peers.length === 0) {
        Text(this.scanning ? '正在扫描局域网…' : '正在自动发现附近设备。请确认对方打开了 LocalSend，并与本机在同一 Wi-Fi。')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%');
      }
      ForEach(this.view.peers, (peer: TransferPeer) => {
        Row() {
          SymbolGlyph($r('sys.symbol.pc_and_phone_fill'))
            .fontSize(20)
            .fontColor([$r('sys.color.font_secondary')])
            .margin({ right: 10 });
          Column() {
            Text(peer.alias.length > 0 ? peer.alias : peer.address)
              .fontSize(14)
              .fontColor($r('sys.color.font_primary'))
              .width('100%');
            Text(peer.address.split(':')[0])
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%');
          }
          .layoutWeight(1);
          Button(this.sendFiles.length > 0 ? '发送' : '先添加文件')
            .fontSize(13)
            .height(34)
            .enabled(!this.busy && this.sendFiles.length > 0)
            .onClick((): void => {
              void this.sendTo(peer);
            });
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 });
      }, (peer: TransferPeer): string => peer.fingerprint + '@' + peer.address);
      if (this.view.running) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '输入 IP 地址（如 192.168.1.20）', text: this.manualAddress })
            .layoutWeight(1)
            .height(40)
            .type(InputType.Normal)
            .onChange((value: string): void => {
              this.manualAddress = value;
            });
          Button('连接')
            .height(40)
            .enabled(!this.busy && this.manualAddress.trim().length > 0)
            .onClick((): void => {
              void this.connectManual();
            });
        }
        .width('100%')
        .margin({ top: 6 });
      }
      this.activitySection();
    }
    .width('100%');
  }

  @Builder
  inboxRow(entry: TransferInboxEntry) {
    Column() {
      Row() {
        if (this.previews[entry.receipt.id] !== undefined) {
          Image('file://' + this.previews[entry.receipt.id])
            .width(52)
            .height(52)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
            .margin({ right: 10 });
        } else {
          SymbolGlyph(entry.kind === 'file' ? $r('sys.symbol.doc_plaintext') : (entry.kind === 'photo' ? $r('sys.symbol.picture') : $r('sys.symbol.livephoto')))
            .fontSize(28)
            .fontColor([$r('sys.color.font_secondary')])
            .width(52)
            .margin({ right: 10 });
        }
        Column() {
          Text(entry.receipt.name)
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          Text((entry.kind === 'live' || entry.kind === 'live-zip' ? '实况照片 · ' : '') +
            formatTransferBytes(entry.receipt.size + (entry.movie?.size ?? 0)))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%');
        }
        .layoutWeight(1);
      }
      .width('100%');
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(14), cross: LengthMetrics.vp(8) } }) {
        if (entry.kind !== 'file') {
          Text('加入转换队列')
            .fontSize(13)
            .fontColor($r('sys.color.font_emphasize'))
            .onClick((): void => {
              void this.runAction(async (): Promise<string> => {
                await this.queueEntry(entry);
                return '已加入转换队列：' + entry.receipt.name;
              });
            });
          Text('存入图库')
            .fontSize(13)
            .fontColor($r('sys.color.font_emphasize'))
            .onClick((): void => {
              void this.runAction(async (): Promise<string> => {
                await this.saveToGallery(entry);
                return '已存入图库：' + entry.receipt.name;
              });
            });
          Text('存入相册')
            .fontSize(13)
            .fontColor($r('sys.color.font_emphasize'))
            .onClick((): void => {
              void this.runAction(async (): Promise<string> => {
                await this.saveToPhotos([entry]);
                return entry.kind === 'photo' ? '已存入相册' : '已存入相册（照片 + 视频）';
              });
            });
        }
        Text('分享')
          .fontSize(13)
          .fontColor($r('sys.color.font_emphasize'))
          .onClick((): void => {
            void this.runAction(async (): Promise<string> => {
              await this.share(entry);
              return '';
            });
          });
        Text('删除')
          .fontSize(13)
          .fontColor('#B3261E')
          .onClick((): void => {
            void this.runAction(async (): Promise<string> => {
              await this.deleteEntry(entry);
              return '';
            });
          });
      }
      .width('100%')
      .padding({ left: 62 })
      .margin({ top: 8 });
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 });
  }

  @Builder
  receiveTab() {
    Column() {
      Column() {
        Row() {
          Text(this.view.running ? (this.view.ready ? '可被发现' : '正在开启…') : '接收已关闭')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.view.running })
            .enabled(!this.busy)
            .onChange((isOn: boolean): void => {
              if (isOn && !this.view.running) void this.start();
              if (!isOn && this.view.running) void this.stop();
            });
        }
        .width('100%');
        Text(this.view.running
          ? '附近设备可以找到本机；收到的文件需要你点接收后才会保存'
          : '开启后才能被发现和收文件。离开此页会停止。')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 4 });
        if (this.editingName) {
          Row({ space: 8 }) {
            TextInput({ placeholder: this.modelName(), text: this.nameDraft })
              .layoutWeight(1)
              .height(38)
              .maxLength(64)
              .onChange((value: string): void => {
                this.nameDraft = value;
              });
            Button('保存')
              .height(38)
              .onClick((): void => {
                void this.saveDeviceName();
              });
          }
          .width('100%')
          .margin({ top: 10 });
        } else {
          Row() {
            Text('其他设备看到的本机名称：' + this.visibleName())
              .fontSize(13)
              .fontColor($r('sys.color.font_primary'))
              .layoutWeight(1);
            Text('修改')
              .fontSize(13)
              .fontColor($r('sys.color.font_emphasize'))
              .onClick((): void => {
                this.nameDraft = this.deviceName;
                this.editingName = true;
              });
          }
          .width('100%')
          .margin({ top: 10 });
        }
        if (this.view.ready) {
          Text(this.showAddresses ? '对方找不到本机？在对方的「发送」页手动输入以下任一地址：' : '对方找不到本机？')
            .fontSize(13)
            .fontColor($r('sys.color.font_emphasize'))
            .width('100%')
            .margin({ top: 10 })
            .onClick((): void => {
              this.localAddresses = this.localIPv4s();
              this.showAddresses = !this.showAddresses;
            });
          if (this.showAddresses) {
            ForEach(this.localAddresses, (address: string) => {
              Text(address + ':' + String(LISTEN_PORT))
                .fontSize(14)
                .fontColor($r('sys.color.font_primary'))
                .copyOption(CopyOptions.LocalDevice)
                .width('100%')
                .margin({ top: 4 });
            }, (address: string): string => address);
          }
        }
      }
      .width('100%')
      .padding(14)
      .backgroundColor($r('sys.color.background_secondary'))
      .borderRadius(14);

      if (this.view.offers.length > 0) {
        this.sectionTitle('等待你确认');
        ForEach(this.view.offers, (offer: TransferOffer) => {
          Column() {
            Text((offer.alias.length > 0 ? offer.alias : '对方设备') + ' 想发送 ' + String(offer.files.length) + ' 个文件（' +
              formatTransferBytes(offer.files.reduce((sum: number, file: TransferOfferFile): number => sum + file.size, 0)) + '）')
              .fontSize(14)
              .fontColor($r('sys.color.font_primary'))
              .width('100%');
            Text(offer.files.slice(0, 6).map((file: TransferOfferFile): string => file.name).join('、') +
              (offer.files.length > 6 ? ' 等' : ''))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .margin({ top: 2 });
            Row({ space: 8 }) {
              Button('拒绝')
                .layoutWeight(1)
                .height(38)
                .backgroundColor($r('sys.color.background_primary'))
                .fontColor($r('sys.color.font_primary'))
                .onClick((): void => {
                  void this.decide(offer, false);
                });
              Button('接收全部')
                .layoutWeight(1)
                .height(38)
                .onClick((): void => {
                  void this.decide(offer, true);
                });
            }
            .width('100%')
            .margin({ top: 8 });
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('sys.color.background_secondary'))
          .borderRadius(12)
          .margin({ bottom: 8 });
        }, (offer: TransferOffer): string => offer.sessionId);
      }

      this.activitySection();

      if (this.view.running && this.view.inbox.length > 0) {
        Row() {
          Text('收件箱（' + String(this.view.inbox.length) + '）')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1);
          if (this.view.inbox.some((entry: TransferInboxEntry): boolean => entry.kind !== 'file')) {
            Text('全部加入队列')
              .fontSize(13)
              .fontColor($r('sys.color.font_emphasize'))
              .margin({ right: 14 })
              .onClick((): void => {
                void this.runAction(async (): Promise<string> => await this.queueAll());
              });
            Text('全部存入相册')
              .fontSize(13)
              .fontColor($r('sys.color.font_emphasize'))
              .margin({ right: 14 })
              .onClick((): void => {
                void this.runAction(async (): Promise<string> =>
                  '已存入相册 ' + String(await this.saveToPhotos(this.view.inbox)) + ' 个文件');
              });
          }
          Text('清空')
            .fontSize(13)
            .fontColor('#B3261E')
            .onClick((): void => {
              this.confirmClearInbox();
            });
        }
        .width('100%')
        .margin({ top: 18, bottom: 2 });
        ForEach(this.view.inbox, (entry: TransferInboxEntry) => {
          this.inboxRow(entry);
        }, (entry: TransferInboxEntry): string =>
          entry.receipt.id + entry.kind + (entry.movie?.id ?? '') + (this.previews[entry.receipt.id] ?? ''));
      }
    }
    .width('100%');
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button('发送')
          .layoutWeight(1)
          .height(36)
          .backgroundColor(this.tab === 0 ? $r('sys.color.comp_background_emphasize') : $r('sys.color.background_secondary'))
          .fontColor(this.tab === 0 ? $r('sys.color.font_on_primary') : $r('sys.color.font_primary'))
          .onClick((): void => {
            this.tab = 0;
            if (!this.view.running) void this.start();
          });
        Button('接收' + (this.view.offers.length > 0 ? '（' + String(this.view.offers.length) + '）' : ''))
          .layoutWeight(1)
          .height(36)
          .backgroundColor(this.tab === 1 ? $r('sys.color.comp_background_emphasize') : $r('sys.color.background_secondary'))
          .fontColor(this.tab === 1 ? $r('sys.color.font_on_primary') : $r('sys.color.font_primary'))
          .onClick((): void => {
            this.tab = 1;
          });
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 8 });
      if (this.status.length > 0) {
        Text(this.status)
          .fontSize(13)
          .fontColor(this.status.includes('失败') ? '#B3261E' : $r('sys.color.font_secondary'))
          .width('100%')
          .padding({ left: 18, right: 18, bottom: 6 });
      }
      Scroll() {
        Column() {
          if (this.tab === 0) {
            this.sendTab();
          } else {
            this.receiveTab();
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18, bottom: 32 });
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off);
    }
    .width('100%')
    .height('100%');
  }
}
