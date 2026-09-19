import type { QueuePathStatus } from './QueuePersistence';

export type SandboxPathKind = 'input' | 'output';
type SandboxContainerState = 'ok' | 'missing' | 'unsafe';

export interface SandboxFileStat {
  size: number;
  isFile: boolean;
  isDirectory: boolean;
  isSymbolicLink: boolean;
}
export interface SandboxIoAdapter {
  stat(path: string): Promise<SandboxFileStat>;
  list(path: string): Promise<Array<string>>;
  unlink(path: string): Promise<void>;
}

export interface SandboxCleanupReport {
  deletedPaths: Array<string>;
  missingPaths: Array<string>;
  failedPaths: Array<string>;
  deletedBytes: number;
}

export interface SandboxUsageReport {
  inputFiles: number;
  outputFiles: number;
  inputBytes: number;
  outputBytes: number;
  candidateFiles: number;
}

function emptyCleanupReport(): SandboxCleanupReport {
  return {
    deletedPaths: [],
    missingPaths: [],
    failedPaths: [],
    deletedBytes: 0
  };
}

/**
 * Path policy for files allocated by the native app. It deliberately accepts
 * only one filename below inputs/outputs; URI strings, traversal, symlinks and
 * nested paths never become deletion candidates.
 */
export class SandboxPathPolicy {
  public readonly root: string;
  public readonly inputDirectory: string;
  public readonly outputDirectory: string;

  constructor(root: string) {
    const normalized: string = root.endsWith('/') && root.length > 1
      ? root.substring(0, root.length - 1)
      : root;
    if (normalized.length === 0 || normalized.includes('\u0000') || normalized.includes('\\') ||
      normalized.includes('://') || normalized.includes('..')) {
      throw new Error('沙盒根目录无效');
    }
    this.root = normalized;
    this.inputDirectory = normalized + '/inputs';
    this.outputDirectory = normalized + '/outputs';
  }

  public kindOf(path: string): SandboxPathKind {
    const inputLeaf: string | undefined = this.leafUnder(path, this.inputDirectory);
    if (inputLeaf !== undefined) {
      return 'input';
    }
    const outputLeaf: string | undefined = this.leafUnder(path, this.outputDirectory);
    if (outputLeaf !== undefined) {
      return 'output';
    }
    throw new Error('路径不在应用沙盒输入/输出目录：' + path);
  }

  public validate(path: string): void {
    this.kindOf(path);
  }

  public leaf(path: string): string {
    const inputLeaf: string | undefined = this.leafUnder(path, this.inputDirectory);
    if (inputLeaf !== undefined) {
      return inputLeaf;
    }
    const outputLeaf: string | undefined = this.leafUnder(path, this.outputDirectory);
    if (outputLeaf !== undefined) {
      return outputLeaf;
    }
    throw new Error('路径不在应用沙盒输入/输出目录：' + path);
  }

  public isArtifactCandidate(path: string): boolean {
    const kind: SandboxPathKind = this.kindOf(path);
    const name: string = this.leaf(path);
    if (kind === 'input') {
      return name.startsWith('input-') && !name.endsWith('.tmp');
    }
    return (name.startsWith('xdremux-') &&
      (name.endsWith('.heic') || name.endsWith('.heic.tmp'))) ||
      (name.includes('.apple-features-base-') && name.endsWith('.heic'));
  }

  public artifactPath(kind: SandboxPathKind, leaf: string): string {
    if (leaf.length === 0 || leaf.includes('/') || leaf.includes('\\') || leaf.includes('\u0000') ||
      leaf.includes('..') || leaf.includes('://') || leaf === '.' || leaf === '..') {
      throw new Error('沙盒文件名无效');
    }
    const directory: string = kind === 'input' ? this.inputDirectory : this.outputDirectory;
    const path: string = directory + '/' + leaf;
    if (!this.isArtifactCandidate(path)) {
      throw new Error('沙盒文件名不是受支持的应用产物：' + leaf);
    }
    return path;
  }

  private leafUnder(path: string, directory: string): string | undefined {
    if (path.length === 0 || path.includes('\u0000') || path.includes('\\') || path.includes('://') ||
      path.includes('..') || !path.startsWith(directory + '/')) {
      return undefined;
    }
    const leaf: string = path.substring(directory.length + 1);
    if (leaf.length === 0 || leaf.includes('/')) {
      return undefined;
    }
    return leaf;
  }
}

/**
 * IO-adapter based sandbox manager. The policy and operation ordering can be
 * tested on a normal host; HarmonyQueueSandbox supplies the platform adapter.
 */
export class QueueSandbox {
  private readonly policy: SandboxPathPolicy;
  private readonly io: SandboxIoAdapter;

  constructor(root: string, io: SandboxIoAdapter) {
    this.policy = new SandboxPathPolicy(root);
    this.io = io;
  }

  public get pathPolicy(): SandboxPathPolicy {
    return this.policy;
  }

  public async status(path: string): Promise<QueuePathStatus> {
    const kind: SandboxPathKind = this.policy.kindOf(path);
    const container: SandboxContainerState = await this.containerState(kind);
    if (container === 'missing') {
      return 'missing';
    }
    if (container === 'unsafe') {
      return 'unsafe';
    }
    try {
      const stat: SandboxFileStat = await this.io.stat(path);
      if (stat.isSymbolicLink || stat.isDirectory || !stat.isFile || !Number.isFinite(stat.size) || stat.size < 0) {
        return 'unsafe';
      }
      return stat.size === 0 ? 'empty' : 'file';
    } catch (error) {
      if (this.isMissingError(error as Object)) {
        return 'missing';
      }
      throw error;
    }
  }

  public async cleanupOwned(paths: Array<string>): Promise<SandboxCleanupReport> {
    const report: SandboxCleanupReport = emptyCleanupReport();
    const unique: Set<string> = new Set<string>();
    // Validate the complete list before deleting anything. A malformed path
    // must not cause a partial deletion followed by a later path rejection.
    const kinds: Set<SandboxPathKind> = new Set<SandboxPathKind>();
    for (const path of paths) {
      if (unique.has(path)) {
        throw new Error('任务归属路径重复，已停止清理');
      }
      unique.add(path);
      const kind: SandboxPathKind = this.policy.kindOf(path);
      kinds.add(kind);
    }
    for (const kind of kinds) {
      const container: SandboxContainerState = await this.containerState(kind);
      if (container === 'unsafe') {
        throw new Error('沙盒目录不安全，已停止清理');
      }
    }
    for (const path of paths) {
      await this.deleteOne(path, report);
    }
    this.throwFailures(report, '任务沙盒清理部分失败');
    return report;
  }

  public async usage(): Promise<SandboxUsageReport> {
    const report: SandboxUsageReport = {
      inputFiles: 0,
      outputFiles: 0,
      inputBytes: 0,
      outputBytes: 0,
      candidateFiles: 0
    };
    await this.inspectDirectory(this.policy.inputDirectory, 'input', report);
    await this.inspectDirectory(this.policy.outputDirectory, 'output', report);
    return report;
  }

  /**
   * Explicit maintenance only. Every reference is validated before scanning,
   * and candidates outside the queue ownership set are removed serially.
   */
  public async cleanupOrphans(referencedPaths: Set<string>, busy: boolean): Promise<SandboxCleanupReport> {
    if (busy) {
      throw new Error('有文件操作或转换正在进行，暂不能清理沙盒');
    }
    for (const path of referencedPaths) {
      this.policy.kindOf(path);
    }
    const report: SandboxCleanupReport = emptyCleanupReport();
    await this.cleanupDirectoryOrphans(this.policy.inputDirectory, 'input', referencedPaths, report);
    await this.cleanupDirectoryOrphans(this.policy.outputDirectory, 'output', referencedPaths, report);
    this.throwFailures(report, '孤儿沙盒文件清理部分失败');
    return report;
  }

  private async inspectDirectory(
    directory: string,
    kind: SandboxPathKind,
    report: SandboxUsageReport
  ): Promise<void> {
    const container: SandboxContainerState = await this.containerState(kind);
    if (container === 'unsafe') {
      throw new Error('沙盒目录不安全，无法读取占用');
    }
    if (container === 'missing') {
      return;
    }
    const names: Array<string> = await this.listSafe(directory);
    for (const nameValue of names) {
      const name: string = this.cleanListName(nameValue);
      if (name.length === 0) {
        continue;
      }
      const path: string = directory + '/' + name;
      try {
        if (!this.policy.isArtifactCandidate(path)) {
          continue;
        }
      } catch (error) {
        continue;
      }
      report.candidateFiles += 1;
      try {
        const stat: SandboxFileStat = await this.io.stat(path);
        if (stat.isFile && !stat.isDirectory && !stat.isSymbolicLink && Number.isFinite(stat.size) && stat.size >= 0) {
          if (kind === 'input') {
            report.inputFiles += 1;
            report.inputBytes += stat.size;
          } else {
            report.outputFiles += 1;
            report.outputBytes += stat.size;
          }
        }
      } catch (error) {
        // Usage is best-effort; an unreadable item remains eligible for a
        // later explicit retry and is never treated as safely deletable.
      }
    }
  }

  private async cleanupDirectoryOrphans(
    directory: string,
    kind: SandboxPathKind,
    referencedPaths: Set<string>,
    report: SandboxCleanupReport
  ): Promise<void> {
    const container: SandboxContainerState = await this.containerState(kind);
    if (container === 'unsafe') {
      throw new Error('沙盒目录不安全，无法清理');
    }
    if (container === 'missing') {
      return;
    }
    const names: Array<string> = await this.listSafe(directory);
    for (const nameValue of names) {
      const name: string = this.cleanListName(nameValue);
      if (name.length === 0) {
        continue;
      }
      let path: string;
      try {
        path = this.policy.artifactPath(kind, name);
      } catch (error) {
        continue;
      }
      if (referencedPaths.has(path)) {
        continue;
      }
      await this.deleteOne(path, report);
    }
  }

  private async deleteOne(path: string, report: SandboxCleanupReport): Promise<void> {
    const kind: SandboxPathKind = this.policy.kindOf(path);
    const container: SandboxContainerState = await this.containerState(kind);
    if (container === 'unsafe') {
      report.failedPaths.push(path);
      return;
    }
    if (container === 'missing') {
      report.missingPaths.push(path);
      return;
    }
    let stat: SandboxFileStat;
    try {
      stat = await this.io.stat(path);
    } catch (error) {
      if (this.isMissingError(error as Object)) {
        report.missingPaths.push(path);
        return;
      }
      report.failedPaths.push(path);
      return;
    }
    if (stat.isSymbolicLink || stat.isDirectory || !stat.isFile || !Number.isFinite(stat.size) || stat.size < 0) {
      report.failedPaths.push(path);
      return;
    }
    try {
      await this.io.unlink(path);
      report.deletedPaths.push(path);
      report.deletedBytes += stat.size;
    } catch (error) {
      if (this.isMissingError(error as Object)) {
        report.missingPaths.push(path);
      } else {
        report.failedPaths.push(path);
      }
    }
  }

  private async listSafe(path: string): Promise<Array<string>> {
    try {
      return await this.io.list(path);
    } catch (error) {
      if (this.isMissingError(error as Object)) {
        return [];
      }
      throw error;
    }
  }

  private cleanListName(name: string): string {
    if (name.startsWith('/')) {
      const relative: string = name.substring(1);
      return relative.includes('/') ? '' : relative;
    }
    return name.includes('/') ? '' : name;
  }

  private async containerState(kind: SandboxPathKind): Promise<SandboxContainerState> {
    const directory: string = kind === 'input' ? this.policy.inputDirectory : this.policy.outputDirectory;
    try {
      const rootStat: SandboxFileStat = await this.io.stat(this.policy.root);
      if (rootStat.isSymbolicLink || !rootStat.isDirectory) {
        return 'unsafe';
      }
      const directoryStat: SandboxFileStat = await this.io.stat(directory);
      if (directoryStat.isSymbolicLink || !directoryStat.isDirectory) {
        return 'unsafe';
      }
      return 'ok';
    } catch (error) {
      if (this.isMissingError(error as Object)) {
        return 'missing';
      }
      throw error;
    }
  }

  private throwFailures(report: SandboxCleanupReport, prefix: string): void {
    if (report.failedPaths.length > 0) {
      throw new Error(prefix + '：' + report.failedPaths.join('、'));
    }
  }

  private isMissingError(error: Object): boolean {
    const candidate: { code?: number } = error as { code?: number };
    return candidate.code === 13900002;
  }
}
