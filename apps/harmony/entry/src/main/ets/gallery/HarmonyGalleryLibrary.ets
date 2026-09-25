import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  decodeGalleryLibrary,
  encodeGalleryLibrary,
  galleryExtensionFromName,
  galleryItemPath,
  galleryMimeTypeForExtension
} from './GalleryLibraryModel';
import type { GalleryLibraryItem, GalleryLibraryRecord } from './GalleryLibraryModel';

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
  private items: Array<GalleryLibraryItem> = [];
  private loaded: boolean = false;

  constructor(filesDir: string) {
    this.root = filesDir + '/xdremux-gallery';
    this.itemsDirectory = this.root + '/items';
    this.manifestPath = this.root + '/library.json';
  }

  public async load(): Promise<Array<GalleryLibraryItem>> {
    await this.ensureDirectories();
    try {
      const stat: fileIo.Stat = await fileIo.lstat(this.manifestPath);
      this.requireRegularFile(this.manifestPath, stat);
      const raw: string = await fileIo.readText(this.manifestPath);
      const record: GalleryLibraryRecord = decodeGalleryLibrary(raw);
      this.items = record.items.sort((left: GalleryLibraryItem, right: GalleryLibraryItem) =>
        right.importedAt - left.importedAt);
    } catch (error) {
      const fileError: GalleryFileError = error as GalleryFileError;
      if (fileError.code !== 13900002) throw this.asError(error);
      this.items = [];
    }
    this.loaded = true;
    return this.snapshot();
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

      const nextItems: Array<GalleryLibraryItem> = this.items.slice();
      nextItems.unshift(item);
      await this.writeAtomic(encodeGalleryLibrary(nextItems));
      this.items = nextItems;
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
    const temporaryPath: string = this.manifestPath + '.tmp';
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
