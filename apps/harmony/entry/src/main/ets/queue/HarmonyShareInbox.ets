import { fileIo } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import type { Want } from '@kit.AbilityKit';
import { HarmonyQueueStorage } from './HarmonyQueueStorage';
import {
  SHARE_IMPORT_ACTION,
  addShareInboxItem,
  emptyShareInboxSnapshot,
  filterSharedImages,
  removeShareInboxItem,
  serializeShareInboxSnapshot,
  updateShareInboxItem,
  validateShareInboxSnapshot,
  WantReferenceGuard
} from './ShareImportModel';
import type { ShareInboxItem, ShareInboxSnapshot } from './ShareImportModel';

interface ShareFileError {
  code?: number;
  message?: string;
}

type InboxListener = () => void;

interface ShareCopyState {
  started: boolean;
}

/** Copies Share Kit URIs immediately while the temporary read grant is live.
 * The inbox journal is written before each destination is created, then the
 * page later transfers that file into the durable task queue. */
export class HarmonyShareInbox {
  private readonly root: string;
  private readonly inputsDirectory: string;
  private readonly journalPath: string;
  private readonly storage: HarmonyQueueStorage;
  private readonly wantGuard: WantReferenceGuard<Want> = new WantReferenceGuard<Want>();
  private readonly listeners: Array<InboxListener> = [];
  private serial: Promise<void> = Promise.resolve();
  private transientNotice: string = '';

  constructor(root: string) {
    if (root.length === 0 || root.includes('\u0000') || root.includes('://') || root.includes('..') ||
      root.includes('\\')) {
      throw new Error('分享收件箱沙盒根目录无效');
    }
    this.root = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    this.inputsDirectory = this.root + '/inputs';
    this.journalPath = this.root + '/shared-import-inbox.json';
    this.storage = new HarmonyQueueStorage();
  }

  public subscribe(listener: InboxListener): () => void {
    this.listeners.push(listener);
    return (): void => {
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) this.listeners.splice(index, 1);
    };
  }

  public get sandboxRoot(): string {
    return this.root;
  }

  public async receiveWant(want: Want): Promise<void> {
    if (want.action !== SHARE_IMPORT_ACTION || !this.wantGuard.claim(want)) return;
    await this.exclusive(async (): Promise<void> => {
      try {
        const shared: systemShare.SharedData = await systemShare.getSharedData(want);
        const filtered = filterSharedImages(shared.getRecords());
        if (filtered.images.length === 0) {
          const snapshot: ShareInboxSnapshot = await this.readUnlocked();
          const ignoredText: string = filtered.ignored > 0
            ? '（已忽略 ' + String(filtered.ignored) + ' 条非 HEIC/JPEG 或非文件记录）'
            : '';
          await this.writeUnlocked({
            nextId: snapshot.nextId,
            items: snapshot.items,
            notice: '分享内容里没有可导入的 HEIC/JPEG 图片。请重新分享图片，或在应用内选择照片' + ignoredText + '。'
          });
          return;
        }

        const limitText: string = filtered.truncated > 0
          ? '；仅接收前 ' + String(filtered.images.length) + ' 张图片，另有 ' + String(filtered.truncated) + ' 张未导入'
          : '';
        const ignoredText: string = filtered.ignored > 0
          ? '；已忽略 ' + String(filtered.ignored) + ' 条非支持图片记录'
          : '';
        let snapshot: ShareInboxSnapshot = await this.readUnlocked();
        snapshot = { nextId: snapshot.nextId, items: snapshot.items, notice: '' };
        await this.writeUnlocked(snapshot);
        for (let index: number = 0; index < filtered.images.length; index += 1) {
          const image = filtered.images[index];
          const appended = addShareInboxItem(snapshot, image, this.root);
          snapshot = appended.snapshot;
          // This durable record owns the intended destination before the first
          // byte is copied. A restart can safely recover a partial copy.
          await this.writeUnlocked(snapshot);
          const copyState: ShareCopyState = { started: false };
          try {
            await this.ensureInputDirectory();
            await this.copyGrantedUri(image.uri, appended.item.inputPath, copyState);
            snapshot = updateShareInboxItem(snapshot, appended.item.id, 'ready', appended.item.inputPath, '');
          } catch (error) {
            const detail: string = this.errorText(error);
            const message: string = '分享图片复制失败，分享访问权限可能已过期。请回到分享来源重新分享，或在应用内重新选择照片。' +
              (detail.length > 0 ? '（' + detail + '）' : '');
            snapshot = updateShareInboxItem(
              snapshot,
              appended.item.id,
              'failed',
              copyState.started ? appended.item.inputPath : '',
              message
            );
          }
          await this.writeUnlocked(snapshot);
        }
        snapshot = {
          nextId: snapshot.nextId,
          items: snapshot.items,
          notice: '已接收 ' + String(filtered.images.length) + ' 张分享图片，正在加入处理队列' +
            limitText + ignoredText + '。'
        };
        await this.writeUnlocked(snapshot);
      } catch (error) {
        const notice: string = '无法读取系统分享内容。分享授权可能已过期，请重新分享图片，或在应用内重新选择照片。' +
          '（' + this.errorText(error) + '）';
        this.transientNotice = notice;
        try {
          const snapshot: ShareInboxSnapshot = await this.readUnlocked();
          await this.writeUnlocked({ nextId: snapshot.nextId, items: snapshot.items, notice: notice });
        } catch (journalError) {
          // Preserve the original message in-process. A corrupt journal is
          // never overwritten; the previous queue and inbox files stay intact.
        }
      } finally {
        this.publish();
      }
    });
  }

  public async pending(): Promise<Array<ShareInboxItem>> {
    return await this.exclusive(async (): Promise<Array<ShareInboxItem>> => {
      let snapshot: ShareInboxSnapshot = await this.readUnlocked();
      let changed: boolean = false;
      const items: Array<ShareInboxItem> = [];
      for (const item of snapshot.items) {
        let recovered: ShareInboxItem = this.copyItem(item);
        if (item.status === 'copying') {
          recovered = {
            id: item.id,
            status: 'failed',
            sourceUri: item.sourceUri,
            displayName: item.displayName,
            inputPath: item.inputPath,
            errorMessage: '分享导入在应用退出时中断。请回到分享来源重新分享，或在应用内重新选择照片。'
          };
          changed = true;
        }
        if (recovered.inputPath.length > 0) {
          try {
            const stat: fileIo.Stat = await fileIo.lstat(recovered.inputPath);
            if (!stat.isFile() || stat.isDirectory() || stat.isSymbolicLink() || stat.size <= 0) {
              recovered = { id: recovered.id, status: 'failed', sourceUri: recovered.sourceUri,
                displayName: recovered.displayName, inputPath: '',
                errorMessage: '分享图片沙盒副本缺失或无效，请回到分享来源重新分享，或在应用内重新选择照片。' };
              changed = true;
            }
          } catch (error) {
            if (!this.isMissing(error)) throw new Error(this.errorText(error as Object));
            recovered = { id: recovered.id, status: 'failed', sourceUri: recovered.sourceUri,
              displayName: recovered.displayName, inputPath: '',
              errorMessage: '分享图片沙盒副本已丢失，请回到分享来源重新分享，或在应用内重新选择照片。' };
            changed = true;
          }
        }
        items.push(recovered);
      }
      if (changed) {
        snapshot = { nextId: snapshot.nextId, notice: snapshot.notice, items: items };
        await this.writeUnlocked(snapshot);
      }
      return items;
    });
  }

  public async remove(id: string): Promise<void> {
    await this.exclusive(async (): Promise<void> => {
      const snapshot: ShareInboxSnapshot = await this.readUnlocked();
      await this.writeUnlocked(removeShareInboxItem(snapshot, id));
    });
  }

  public async takeNotice(): Promise<string> {
    return await this.exclusive(async (): Promise<string> => {
      const snapshot: ShareInboxSnapshot = await this.readUnlocked();
      const notice: string = snapshot.notice.length > 0 ? snapshot.notice : this.transientNotice;
      this.transientNotice = '';
      if (snapshot.notice.length > 0) {
        await this.writeUnlocked({ nextId: snapshot.nextId, items: snapshot.items, notice: '' });
      }
      return notice;
    });
  }

  private async copyGrantedUri(uri: string, destination: string, copyState: ShareCopyState): Promise<void> {
    let sourceFd: number = -1;
    try {
      try {
        const existing: fileIo.Stat = await fileIo.lstat(destination);
        if (existing.isSymbolicLink() || existing.isDirectory() || existing.isFile()) {
          throw new Error('分享导入目标文件已存在，未覆盖任何文件');
        }
      } catch (error) {
        if (!this.isMissing(error)) throw new Error(this.errorText(error as Object));
      }
      sourceFd = (await fileIo.open(uri, fileIo.OpenMode.READ_ONLY)).fd;
      // The inbox has already journaled this unique leaf. Once the copy call
      // starts, keep any partial destination attributed to that inbox record;
      // only the queue may later delete it after ownership transfer.
      copyState.started = true;
      await fileIo.copyFile(sourceFd, destination);
      const copied: fileIo.Stat = await fileIo.lstat(destination);
      if (!copied.isFile() || copied.isDirectory() || copied.isSymbolicLink() || copied.size <= 0) {
        throw new Error('分享图片复制结果为空或不是普通文件');
      }
    } finally {
      if (sourceFd >= 0) {
        try {
          await fileIo.close(sourceFd);
        } catch (error) {
          // Preserve the first open/copy/stat error.
        }
      }
    }
  }

  private async ensureInputDirectory(): Promise<void> {
    try {
      await fileIo.mkdir(this.inputsDirectory, true);
    } catch (error) {
      if (!await fileIo.access(this.inputsDirectory)) throw new Error(this.errorText(error as Object));
    }
  }

  private copyItem(item: ShareInboxItem): ShareInboxItem {
    return {
      id: item.id,
      status: item.status,
      sourceUri: item.sourceUri,
      displayName: item.displayName,
      inputPath: item.inputPath,
      errorMessage: item.errorMessage
    };
  }

  private async readUnlocked(): Promise<ShareInboxSnapshot> {
    const exists: boolean = await this.storage.exists(this.journalPath);
    const tempExists: boolean = await this.storage.exists(this.journalPath + '.tmp');
    if (!exists) {
      if (tempExists) throw new Error('发现未提交的分享收件箱临时记录；已保留原文件并停止接收');
      return emptyShareInboxSnapshot();
    }
    const raw: string = await this.storage.readText(this.journalPath);
    return validateShareInboxSnapshot(JSON.parse(raw) as Object, this.root);
  }

  private async writeUnlocked(snapshot: ShareInboxSnapshot): Promise<void> {
    const raw: string = serializeShareInboxSnapshot(snapshot, this.root);
    await this.storage.writeAtomic(this.journalPath, raw);
    this.publish();
  }

  private async exclusive<T>(work: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.serial.then(work, work);
    this.serial = result.then((): void => undefined, (): void => undefined);
    return await result;
  }

  private publish(): void {
    for (const listener of this.listeners.slice()) {
      try {
        listener();
      } catch (error) {
        // Inbox persistence and delivery cannot depend on a UI listener.
      }
    }
  }

  private isMissing(error: Object): boolean {
    const candidate: ShareFileError = error as ShareFileError;
    return candidate.code === 13900002;
  }

  private errorText(error: Object): string {
    const candidate: ShareFileError = error as ShareFileError;
    if (candidate.message !== undefined && candidate.message.length > 0) return candidate.message;
    if (candidate.code !== undefined) return '错误码 ' + String(candidate.code);
    return error instanceof Error ? error.message : String(error);
  }
}

let sharedInbox: HarmonyShareInbox | undefined = undefined;

export function getHarmonyShareInbox(root: string): HarmonyShareInbox {
  const normalizedRoot: string = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  if (sharedInbox === undefined) sharedInbox = new HarmonyShareInbox(normalizedRoot);
  if (sharedInbox !== undefined && sharedInbox.sandboxRoot !== normalizedRoot) {
    throw new Error('应用分享收件箱目录已锁定');
  }
  return sharedInbox;
}
