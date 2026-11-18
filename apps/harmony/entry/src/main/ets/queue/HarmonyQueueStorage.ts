import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import type { QueueStorageAdapter } from './QueuePersistence';

interface QueueFileError {
  code?: number;
  message?: string;
}
/**
 * File adapter for the queue journal. QueueStateStore gives this adapter the
 * final queue.json path; writes use the sibling .tmp path, fsync and close it,
 * then rename it over the old journal. A failed write only removes that temp.
 */
export class HarmonyQueueStorage implements QueueStorageAdapter {
  public async exists(path: string): Promise<boolean> {
    try {
      const stat: fileIo.Stat = await fileIo.lstat(path);
      this.requireRegular(path, stat);
      return true;
    } catch (error) {
      const fileError: QueueFileError = error as QueueFileError;
      if (fileError.code === 13900002) {
        return false;
      }
      throw error;
    }
  }

  public async readText(path: string): Promise<string> {
    const stat: fileIo.Stat = await fileIo.lstat(path);
    this.requireRegular(path, stat);
    return await fileIo.readText(path);
  }

  public async writeAtomic(path: string, content: string): Promise<void> {
    const temporaryPath: string = path + '.tmp';
    let file: fileIo.File | undefined;
    try {
      await this.requireExistingTargetRegular(path);
      await this.requireExistingTargetRegular(temporaryPath);
      const mode: number = fileIo.OpenMode.WRITE_ONLY |
        fileIo.OpenMode.CREATE |
        fileIo.OpenMode.TRUNC |
        fileIo.OpenMode.SYNC;
      file = await fileIo.open(temporaryPath, mode);
      const expectedBytes: number = new util.TextEncoder().encode(content).byteLength;
      const writtenBytes: number = await fileIo.write(file.fd, content);
      if (writtenBytes !== expectedBytes) {
        throw new Error('队列记录未完整写入');
      }
      await fileIo.fsync(file.fd);
      await fileIo.close(file.fd);
      file = undefined;
      await this.requireExistingTargetRegular(path);
      await fileIo.rename(temporaryPath, path);
    } catch (error) {
      if (file !== undefined) {
        try {
          await fileIo.close(file.fd);
        } catch (closeError) {
          // Preserve the original write error.
        }
      }
      try {
        if (await this.exists(temporaryPath)) {
          await fileIo.unlink(temporaryPath);
        }
      } catch (cleanupError) {
        // The original error remains visible; the temp is retained for the
        // explicit recovery path if cleanup itself fails.
      }
      throw error;
    }
  }

  public async rename(oldPath: string, newPath: string): Promise<void> {
    const sourceStat: fileIo.Stat = await fileIo.lstat(oldPath);
    this.requireRegular(oldPath, sourceStat);
    await this.requireExistingTargetRegular(newPath);
    await fileIo.rename(oldPath, newPath);
  }

  private async requireExistingTargetRegular(path: string): Promise<void> {
    try {
      const stat: fileIo.Stat = await fileIo.lstat(path);
      this.requireRegular(path, stat);
    } catch (error) {
      const fileError: QueueFileError = error as QueueFileError;
      if (fileError.code === 13900002) {
        return;
      }
      throw error;
    }
  }

  private requireRegular(path: string, stat: fileIo.Stat): void {
    if (stat.isSymbolicLink() || stat.isDirectory() || !stat.isFile()) {
      throw new Error('队列记录路径不是普通文件：' + path);
    }
  }
}
