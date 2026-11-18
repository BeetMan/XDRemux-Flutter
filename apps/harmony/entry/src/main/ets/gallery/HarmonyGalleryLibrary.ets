import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  decodeGalleryLibrary,
  encodeGalleryLibrary,
  galleryExtensionFromName,
  galleryItemPath,
  galleryMimeTypeForExtension,
  recoverGalleryItems,
  removeGalleryLibraryItem
} from './GalleryLibraryModel';
import type { GalleryLibraryItem, GalleryLibraryRecord, GalleryStoredFile } from './GalleryLibraryModel';

interface GalleryFileError {
  code?: number;
  message?: string;
}

/**
 * Stores picker-selected originals in app-private persistent storage. A picker
 * URI is only opened for a physical copy; downstream inspection and Rust use
 * the resulting app-owned file path.
 */
export class HarmonyGalleryLibrary {
  private readonly root: string;
  private readonly itemsDirectory: string;
  private readonly manifestPath: string;
  private readonly backupPath: string;
  private items: Array<GalleryLibraryItem> = [];
  private loaded: boolean = false;
  /** Index changes run one at a time; see exclusive(). */
  private mutationChain: Promise<void> = Promise.resolve();
  /** The last load had to rebuild a damaged index. */
  public recoveredOnLoad: boolean = false;

  constructor(filesDir: string) {
    this.root = filesDir + '/xdremux-gallery';
    this.itemsDirectory = this.root + '/items';
    this.manifestPath = this.root + '/library.json';
    this.backupPath = this.root + '/library.json.bak';
  }

  /**
   * Load the index. A damaged or unreadable index no longer locks the user out
   * of the gallery: it is rebuilt from the last good copy (saved on each
   * successful load) plus the photo files actually present in items/.
   */
  public async load(): Promise<Array<GalleryLibraryItem>> {
    await this.ensureDirectories();
    await this.removeTemporaryManifests();
    let items: Array<GalleryLibraryItem> = [];
    let damaged: boolean = false;
    try {
      items = await this.readIndex(this.manifestPath);
    } catch (error) {
      damaged = true;
      try {
        items = await this.readIndex(this.backupPath);
      } catch (backupError) {
        items = [];
      }
    }
    if (damaged) {
      items = recoverGalleryItems(items, await this.listStoredFiles());
      await this.writeAtomic(encodeGalleryLibrary(items));
    } else {
      await this.saveBackup();
    }
    this.items = items.sort((left: GalleryLibraryItem, right: GalleryLibraryItem) =>
      right.importedAt - left.importedAt);
    this.recoveredOnLoad = damaged;
    this.loaded = true;
    return this.snapshot();
  }

  /** Items of one index file; a missing file is an empty library. */
  private async readIndex(path: string): Promise<Array<GalleryLibraryItem>> {
    try {
      const stat: fileIo.Stat = await fileIo.lstat(path);
      this.requireRegularFile(path, stat);
    } catch (error) {
      const fileError: GalleryFileError = error as GalleryFileError;
      if (fileError.code === 13900002) return [];
      throw this.asError(error);
    }
    const record: GalleryLibraryRecord = decodeGalleryLibrary(await fileIo.readText(path));
    return record.items;
  }

  private async saveBackup(): Promise<void> {
    try {
      if (await fileIo.access(this.manifestPath)) await fileIo.copyFile(this.manifestPath, this.backupPath);
    } catch (error) {
      // Best effort: the backup only helps a later recovery.
    }
  }

  private async listStoredFiles(): Promise<Array<GalleryStoredFile>> {
    const files: Array<GalleryStoredFile> = [];
    for (const name of await fileIo.listFile(this.itemsDirectory)) {
      try {
        const stat: fileIo.Stat = await fileIo.lstat(this.itemsDirectory + '/' + name);
        if (stat.isSymbolicLink() || !stat.isFile()) continue;
        files.push({ name: name, size: stat.size, modifiedAt: Math.floor(stat.mtime * 1000) });
      } catch (error) {
        // Skip entries that vanish or cannot be read.
      }
    }
    return files;
  }

  private async removeTemporaryManifests(): Promise<void> {
    try {
      for (const name of await fileIo.listFile(this.root)) {
        if (name.startsWith('library.json.tmp')) await fileIo.unlink(this.root + '/' + name);
      }
    } catch (error) {
      // Leftover temp files are harmless.
    }
  }

  /**
   * Run index changes one at a time, each building its list from the latest
   * committed items. Overlapping changes (a picker import while a received
   * LocalSend photo is saved, a delete during a convert) used to save lists
   * that each missed the other's entry.
   */
  private exclusive<T>(task: () => Promise<T>): Promise<T> {
    const run: Promise<T> = this.mutationChain.then((): Promise<T> => task());
    this.mutationChain = run.then((): void => {}, (): void => {});
    return run;
  }

  public snapshot(): Array<GalleryLibraryItem> {
    return this.items.map((item: GalleryLibraryItem): GalleryLibraryItem => this.cloneItem(item));
  }

  public pathFor(item: GalleryLibraryItem): string {
    return galleryItemPath(this.root, item);
  }

  public async importPhoto(sourceUri: string, displayName: string): Promise<GalleryLibraryItem> {
    if (!this.loaded) throw new Error('本地图库尚未加载');
    if (sourceUri.length === 0) throw new Error('所选照片地址为空');
    await this.ensureDirectories();

    const extension: string = galleryExtensionFromName(displayName.length > 0 ? displayName : sourceUri);
    const id: string = util.generateRandomUUID();
    const item: GalleryLibraryItem = {
      id: id,
      displayName: displayName.length > 0 ? displayName : '导入照片' + extension,
      extension: extension,
      mimeType: galleryMimeTypeForExtension(extension),
      size: 0,
      importedAt: Date.now()
    };
    const destination: string = this.pathFor(item);
    let sourceFd: number = -1;
    let copied: boolean = false;
    try {
      await this.requireMissingPath(destination);
      sourceFd = (await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY)).fd;
      await fileIo.copyFile(sourceFd, destination);
      await fileIo.close(sourceFd);
      sourceFd = -1;
      copied = true;

      const stat: fileIo.Stat = await fileIo.lstat(destination);
      this.requireRegularFile(destination, stat);
      if (stat.size <= 0) throw new Error('复制到本地图库的照片为空');
      item.size = stat.size;

      // The copy above may overlap other imports; the index update may not.
      await this.exclusive(async (): Promise<void> => {
        const nextItems: Array<GalleryLibraryItem> = this.items.slice();
        nextItems.unshift(item);
        await this.writeAtomic(encodeGalleryLibrary(nextItems));
        this.items = nextItems;
      });
      return this.cloneItem(item);
    } catch (error) {
      if (sourceFd >= 0) {
        try {
          await fileIo.close(sourceFd);
        } catch (closeError) {
          // Preserve the original copy or persistence error.
        }
      }
      if (copied) {
        try {
          await fileIo.unlink(destination);
        } catch (cleanupError) {
          // Keep the original error visible. The unindexed copy is harmless
          // and remains inside this app's private gallery directory.
        }
      }
      throw this.asError(error);
    }
  }

  public removePhoto(itemId: string): Promise<GalleryLibraryItem> {
    if (!this.loaded) return Promise.reject(new Error('本地图库尚未加载'));
    return this.exclusive((): Promise<GalleryLibraryItem> => this.removePhotoNow(itemId));
  }

  private async removePhotoNow(itemId: string): Promise<GalleryLibraryItem> {
    const itemIndex: number = this.items.findIndex((item: GalleryLibraryItem): boolean => item.id === itemId);
    if (itemIndex < 0) throw new Error('要删除的照片已不在本地图库中');

    const item: GalleryLibraryItem = this.cloneItem(this.items[itemIndex]);
    const path: string = this.pathFor(item);
    let fileExists: boolean = false;
    try {
      const stat: fileIo.Stat = await fileIo.lstat(path);
      this.requireRegularFile(path, stat);
      fileExists = true;
    } catch (error) {
      const fileError: GalleryFileError = error as GalleryFileError;
      if (fileError.code !== 13900002) throw this.asError(error);
    }

    const previousItems: Array<GalleryLibraryItem> = this.items.slice();
    const nextItems: Array<GalleryLibraryItem> = removeGalleryLibraryItem(previousItems, itemId);
    await this.writeAtomic(encodeGalleryLibrary(nextItems));
    this.items = nextItems;

    if (fileExists) {
      try {
        await fileIo.unlink(path);
      } catch (error) {
        try {
          await this.writeAtomic(encodeGalleryLibrary(previousItems));
          this.items = previousItems;
        } catch (rollbackError) {
          // Keep memory aligned with the committed index if rollback also fails.
          this.items = nextItems;
          throw new Error('照片索引已删除，但文件删除和索引回滚均失败：' + this.asError(error).message);
        }
        throw this.asError(error);
      }
    }
    return item;
  }

  private async ensureDirectories(): Promise<void> {
    await this.ensureDirectory(this.root);
    await this.ensureDirectory(this.itemsDirectory);
  }

  private async ensureDirectory(path: string): Promise<void> {
    try {
      const stat: fileIo.Stat = await fileIo.lstat(path);
      if (stat.isSymbolicLink() || !stat.isDirectory()) {
        throw new Error('本地图库目录不是安全目录：' + path);
      }
    } catch (error) {
      const fileError: GalleryFileError = error as GalleryFileError;
      if (fileError.code !== 13900002) throw this.asError(error);
      await fileIo.mkdir(path, true);
      const stat: fileIo.Stat = await fileIo.lstat(path);
      if (stat.isSymbolicLink() || !stat.isDirectory()) {
        throw new Error('无法创建安全的本地图库目录：' + path);
      }
    }
  }

  private async requireMissingPath(path: string): Promise<void> {
    try {
      const stat: fileIo.Stat = await fileIo.lstat(path);
      this.requireRegularFile(path, stat);
      throw new Error('本地图库目标文件已存在');
    } catch (error) {
      const fileError: GalleryFileError = error as GalleryFileError;
      if (fileError.code !== 13900002) throw this.asError(error);
    }
  }

  private async writeAtomic(content: string): Promise<void> {
    // A unique temp name: even if two writers ever overlapped, neither could
    // publish the other's half-written bytes.
    const temporaryPath: string = this.manifestPath + '.tmp-' + util.generateRandomUUID();
    let file: fileIo.File | undefined;
    try {
      await this.requireRegularOrMissing(this.manifestPath);
      await this.requireRegularOrMissing(temporaryPath);
      const mode: number = fileIo.OpenMode.WRITE_ONLY |
        fileIo.OpenMode.CREATE |
        fileIo.OpenMode.TRUNC |
        fileIo.OpenMode.SYNC;
      file = await fileIo.open(temporaryPath, mode);
      const expectedBytes: number = new util.TextEncoder().encode(content).byteLength;
      const writtenBytes: number = await fileIo.write(file.fd, content);
      if (writtenBytes !== expectedBytes) throw new Error('本地图库索引未完整写入');
      await fileIo.fsync(file.fd);
      await fileIo.close(file.fd);
      file = undefined;
      await this.requireRegularOrMissing(this.manifestPath);
      await fileIo.rename(temporaryPath, this.manifestPath);
    } catch (error) {
      if (file !== undefined) {
        try {
          await fileIo.close(file.fd);
        } catch (closeError) {
          // Preserve the original manifest error.
        }
      }
      try {
        await fileIo.unlink(temporaryPath);
      } catch (cleanupError) {
        // Preserve the original manifest error.
      }
      throw this.asError(error);
    }
  }

  private async requireRegularOrMissing(path: string): Promise<void> {
    try {
      const stat: fileIo.Stat = await fileIo.lstat(path);
      this.requireRegularFile(path, stat);
    } catch (error) {
      const fileError: GalleryFileError = error as GalleryFileError;
      if (fileError.code !== 13900002) throw this.asError(error);
    }
  }

  private cloneItem(item: GalleryLibraryItem): GalleryLibraryItem {
    return {
      id: item.id,
      displayName: item.displayName,
      extension: item.extension,
      mimeType: item.mimeType,
      size: item.size,
      importedAt: item.importedAt
    };
  }

  private asError(error: Object): Error {
    if (error instanceof Error) return error;
    const fileError: GalleryFileError = error as GalleryFileError;
    return new Error(fileError.message ?? String(error));
  }

  private requireRegularFile(path: string, stat: fileIo.Stat): void {
    if (stat.isSymbolicLink() || stat.isDirectory() || !stat.isFile()) {
      throw new Error('图库文件路径不是普通文件：' + path);
    }
  }
}
