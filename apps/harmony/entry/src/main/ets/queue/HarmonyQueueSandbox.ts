import { fileIo } from '@kit.CoreFileKit';
import { QueueSandbox } from './QueueSandbox';
import type { SandboxFileStat, SandboxIoAdapter } from './QueueSandbox';

interface QueueFileError {
  code?: number;
  message?: string;
}
class HarmonySandboxIoAdapter implements SandboxIoAdapter {
  public async stat(path: string): Promise<SandboxFileStat> {
    const stat: fileIo.Stat = await fileIo.lstat(path);
    return {
      size: stat.size,
      isFile: stat.isFile(),
      isDirectory: stat.isDirectory(),
      isSymbolicLink: stat.isSymbolicLink()
    };
  }

  public async list(path: string): Promise<Array<string>> {
    return await fileIo.listFile(path);
  }

  public async unlink(path: string): Promise<void> {
    await fileIo.unlink(path);
  }
}

/** Harmony file-IO adapter for QueueSandbox. lstat is used so cleanup never
 * follows a symbolic link supplied by a malformed record or directory entry. */
export class HarmonyQueueSandbox extends QueueSandbox {
  constructor(root: string) {
    super(root, new HarmonySandboxIoAdapter());
  }

  public static isMissingError(error: Object): boolean {
    const candidate: QueueFileError = error as QueueFileError;
    return candidate.code === 13900002;
  }
}
