import { QueuePersistenceError } from './QueuePersistence.ts';
import type { QueuePersistenceSnapshot } from './QueuePersistence.ts';
import type {
  NativeClassificationResult,
  NativeConversionResult,
  NativeConvertConfig,
  NativePhotoDetails,
  NativeProgress
} from './NativeTypes';

export type QueueItemStatus = 'pending' | 'running' | 'succeeded' | 'failed';
export type QueueAttemptStatus = 'idle' | 'pending' | 'running' | 'succeeded' | 'failed';

export interface QueueModeSnapshot {
  modeKey: string;
  modeLabel: string;
  config: NativeConvertConfig;
}

export interface QueueResult {
  outputPath: string;
  modeKey: string;
  modeLabel: string;
  conversion: NativeConversionResult;
}

export interface QueueItemInput {
  displayName: string;
  sourceUri: string;
  inputPath?: string;
  details?: NativePhotoDetails;
  classification?: NativeClassificationResult;
}

export interface QueueItem {
  id: string;
  /** Monotonic view revision used as a ForEach key for ArkUI row refresh. */
  revision: number;
  displayName: string;
  sourceUri: string;
  inputPath: string;
  status: QueueItemStatus;
  attemptStatus: QueueAttemptStatus;
  externalBusy: boolean;
  details?: NativePhotoDetails;
  classification?: NativeClassificationResult;
  progress: NativeProgress;
  result?: QueueResult;
  exportedUri: string;
  errorMessage: string;
  lastAttemptModeKey: string;
  lastAttemptModeLabel: string;
  cleanupStatus: 'none' | 'pending' | 'failed';
  cleanupErrorMessage: string;
  /** Every sandbox path allocated for this item, including failed attempts. */
  ownedPaths: Array<string>;
}

export type QueueExecute = (
  item: QueueItem,
  mode: QueueModeSnapshot,
  reportProgress: (progress: NativeProgress) => void
) => Promise<QueueResult>;

export type QueueCleanup = (item: QueueItem) => Promise<void>;
export interface QueuePrepared {
  inputPath: string;
  details: NativePhotoDetails;
  classification: NativeClassificationResult;
}
export type QueuePrepare = (item: QueueItem) => Promise<QueuePrepared>;
export type QueueModeCapture = () => QueueModeSnapshot;
export type QueueChanged = () => void;
export type QueuePersist = (snapshot: QueuePersistenceSnapshot) => Promise<void>;

export interface QueueControllerOptions {
  captureMode: QueueModeCapture;
  execute: QueueExecute;
  prepare?: QueuePrepare;
  cleanup?: QueueCleanup;
  onChanged?: QueueChanged;
  persistence?: QueuePersist;
  errorMessage?: (error: Object) => string;
}

/**
 * Foreground process-session queue. Critical state is journaled through the
 * optional persistence callback; progress ticks stay in memory. A detached
 * page stops after the current native call and never starts later work.
 */
export class QueueController {
  private readonly itemList: Array<QueueItem> = [];
  private readonly captureMode: QueueModeCapture;
  private readonly execute: QueueExecute;
  private readonly prepare?: QueuePrepare;
  private readonly cleanup?: QueueCleanup;
  private readonly formatError: (error: Object) => string;
  private readonly persistence: QueuePersist | undefined;
  private persistChain: Promise<void> = Promise.resolve();
  private persistencePending: number = 0;
  private persistenceError: Object | undefined;
  private listener: QueueChanged | undefined;
  private attached: boolean = false;
  private nextId: number = 1;
  private activeId: string = '';
  private stopRequested: boolean = false;
  private runnerTask: Promise<void> | undefined;

  constructor(options: QueueControllerOptions) {
    this.captureMode = options.captureMode;
    this.execute = options.execute;
    this.prepare = options.prepare;
    this.cleanup = options.cleanup;
    this.listener = options.onChanged;
    this.persistence = options.persistence;
    this.formatError = options.errorMessage === undefined
      ? (error: Object): string => String(error)
      : options.errorMessage;
  }

  public attach(listener?: QueueChanged): void {
    this.attached = true;
    this.listener = listener;
    this.notify();
  }

  public detach(): void {
    this.attached = false;
    this.listener = undefined;
    // A running native operation has no cancellation ABI. Let it settle, then
    // leave later pending work for an explicit foreground resume.
    this.stop();
  }

  public get isRunning(): boolean {
    return this.runnerTask !== undefined;
  }

  public get isStopRequested(): boolean {
    return this.stopRequested;
  }

  public get activeItemId(): string {
    return this.activeId;
  }

  public get hasPendingItems(): boolean {
    return this.itemList.some((item: QueueItem): boolean => item.status === 'pending' &&
      !item.externalBusy && item.cleanupStatus !== 'failed');
  }

  public items(): Array<QueueItem> {
    return this.itemList.map((item: QueueItem): QueueItem => this.copyItem(item));
  }

  public get(id: string): QueueItem | undefined {
    return this.itemList.find((item: QueueItem): boolean => item.id === id);
  }

  public snapshot(): QueuePersistenceSnapshot {
    return { nextId: this.nextId, items: this.items() };
  }

  public get hasPersistenceError(): boolean {
    return this.persistenceError !== undefined;
  }

  public get isPersistenceBusy(): boolean {
    return this.persistencePending > 0;
  }

  /** Wait for the latest journal write and checkpoint the current immutable
   * snapshot. A previous write failure intentionally blocks this checkpoint;
   * the UI must call retryPersistence explicitly before scheduling work. */
  public async persist(): Promise<void> {
    if (this.persistence === undefined) {
      return;
    }
    await this.persistChain;
    if (this.persistenceError !== undefined) {
      throw this.persistenceFailure(this.persistenceError);
    }
    const task: Promise<void> = this.enqueuePersistence(this.snapshot());
    try {
      await task;
    } catch (error) {
      throw this.persistenceFailure(error as Object);
    }
  }

  public async retryPersistence(): Promise<void> {
    if (this.persistence === undefined) {
      return;
    }
    await this.persistChain;
    this.persistenceError = undefined;
    const task: Promise<void> = this.enqueuePersistence(this.snapshot());
    try {
      await task;
    } catch (error) {
      throw this.persistenceFailure(error as Object);
    }
  }

  /** Replace the in-memory session after startup validation. Restoring never
   * starts a runner and deliberately does not write until a later checkpoint.
   */
  public async restore(snapshot: QueuePersistenceSnapshot): Promise<void> {
    if (this.runnerTask !== undefined) {
      throw new Error('cannot restore while queue is running');
    }
    // Startup restores are called before attach, but waiting here also makes
    // the method safe if a caller reuses a controller after a journal write.
    await this.persistChain;
    if (this.persistenceError !== undefined) {
      throw this.persistenceFailure(this.persistenceError);
    }
    this.itemList.length = 0;
    for (const item of snapshot.items) {
      this.itemList.push(this.copyItem(item));
    }
    this.nextId = snapshot.nextId;
    this.activeId = '';
    this.stopRequested = false;
    this.notify();
  }

  public add(input: QueueItemInput): QueueItem {
    const item: QueueItem = {
      id: 'job-' + String(this.nextId),
      revision: 0,
      displayName: input.displayName,
      sourceUri: input.sourceUri,
      inputPath: input.inputPath === undefined ? '' : input.inputPath,
      status: 'pending',
      attemptStatus: 'idle',
      externalBusy: false,
      details: input.details,
      classification: input.classification,
      progress: { stage: 0, current: 0, total: 0 },
      errorMessage: '',
      exportedUri: '',
      lastAttemptModeKey: '',
      lastAttemptModeLabel: '',
      cleanupStatus: 'none',
      cleanupErrorMessage: '',
      ownedPaths: input.inputPath === undefined || input.inputPath.length === 0
        ? []
        : [input.inputPath]
    };
    this.nextId += 1;
    this.itemList.push(item);
    this.notify(item, true);
    return item;
  }

  public beginExternal(id: string): void {
    const item = this.require(id);
    this.assertEditable(item);
    this.assertCleanupUsable(item);
    item.externalBusy = true;
    this.notify(item, true);
  }

  public endExternal(id: string): void {
    const item = this.get(id);
    if (item !== undefined) {
      item.externalBusy = false;
      this.notify(item, true);
    }
  }
  /** Lock a batch in one journal snapshot so a large export does not enqueue
   * one full queue write per item. All IDs are validated before any mutation. */
  public beginExternalBatch(ids: Array<string>): void {
    const items: Array<QueueItem> = [];
    const seen: Set<string> = new Set<string>();
    for (const id of ids) {
      if (seen.has(id)) {
        throw new Error('批量文件项目 ID 重复');
      }
      seen.add(id);
      const item: QueueItem = this.require(id);
      this.assertEditable(item);
      this.assertCleanupUsable(item);
      items.push(item);
    }
    for (const item of items) {
      item.externalBusy = true;
    }
    if (items.length > 0) {
      this.notifyItems(items, true);
    }
  }

  /** Release a batch lock in one journal snapshot. Missing IDs are tolerated
   * so cleanup of a canceled UI batch cannot mask the original error. */
  public endExternalBatch(ids: Array<string>): void {
    const changed: Array<QueueItem> = [];
    const seen: Set<string> = new Set<string>();
    for (const id of ids) {
      if (seen.has(id)) {
        continue;
      }
      seen.add(id);
      const item: QueueItem | undefined = this.get(id);
      if (item !== undefined && item.externalBusy) {
        item.externalBusy = false;
        changed.push(item);
      }
    }
    if (changed.length > 0) {
      this.notifyItems(changed, true);
    }
  }

  public setPrepared(
    id: string,
    inputPath: string,
    details: NativePhotoDetails,
    classification: NativeClassificationResult
  ): void {
    const item = this.require(id);
    if (!item.externalBusy) {
      throw new Error('item is not locked for preparation');
    }
    this.assertCleanupUsable(item);
    item.inputPath = inputPath;
    this.addOwnedPath(item, inputPath);
    item.details = details;
    item.classification = classification;
    item.status = 'pending';
    item.attemptStatus = 'idle';
    item.errorMessage = '';
    this.notify(item, true);
  }

  public markPreparationFailed(id: string, message: string): void {
    const item = this.require(id);
    if (!item.externalBusy) {
      throw new Error('item is not locked for preparation');
    }
    this.assertCleanupUsable(item);
    item.status = 'failed';
    item.attemptStatus = 'failed';
    item.errorMessage = message;
    this.notify(item, true);
  }

  public retry(id: string): void {
    const item = this.require(id);
    this.assertEditable(item);
    this.assertCleanupUsable(item);
    if (item.status !== 'failed') {
      throw new Error('only failed items can be retried');
    }
    item.status = 'pending';
    item.attemptStatus = 'pending';
    item.errorMessage = '';
    item.progress = { stage: 0, current: 0, total: 0 };
    this.notify(item, true);
  }

  public reconvert(id: string): void {
    const item = this.require(id);
    this.assertEditable(item);
    this.assertCleanupUsable(item);
    if (item.status !== 'succeeded') {
      throw new Error('only succeeded items can be reconverted');
    }
    // Keep item.result visible while the new attempt is pending/running. A
    // failed reconversion therefore retains the prior successful output.
    item.status = 'pending';
    item.attemptStatus = 'pending';
    item.errorMessage = '';
    item.exportedUri = '';
    item.progress = { stage: 0, current: 0, total: 0 };
    this.notify(item, true);
  }

  public markExported(id: string, uri: string): void {
    const item = this.require(id);
    if (!item.externalBusy) {
      throw new Error('item is not locked for export');
    }
    this.assertCleanupUsable(item);
    item.exportedUri = uri;
    this.notify(item, true);
  }

  /**
   * Register a sandbox path before a conversion or preparation operation
   * starts using it. The item remains the sole owner until explicit removal.
   * Missing paths are harmless during later cleanup, which also covers a
   * partially failed conversion or copy.
   */
  public registerOwnedPath(id: string, path: string): void {
    const item = this.require(id);
    if (!item.externalBusy && item.status !== 'running' && this.activeId !== id) {
      throw new Error('item is not active for sandbox path registration');
    }
    this.assertCleanupUsable(item);
    this.addOwnedPath(item, path);
    this.notify(item, true);
  }

  public async remove(id: string): Promise<void> {
    const item = this.require(id);
    this.assertEditable(item);
    item.externalBusy = true;
    item.cleanupStatus = 'pending';
    item.cleanupErrorMessage = '';
    this.notify(item, true);
    try {
      // Persist the deletion intent before touching any owned file. A crash
      // after this point restores a cleanup-pending record, never a live task.
      await this.persist();
      if (this.cleanup !== undefined) {
        await this.cleanup(item);
      }
    } catch (error) {
      item.status = 'failed';
      item.attemptStatus = 'failed';
      item.externalBusy = false;
      item.cleanupStatus = 'failed';
      item.cleanupErrorMessage = this.formatError(error);
      item.errorMessage = '删除清理失败：' + item.cleanupErrorMessage;
      this.notify(item, true);
      throw error;
    }

    const index: number = this.itemList.findIndex((candidate: QueueItem): boolean => candidate.id === id);
    if (index < 0) {
      throw new Error('queue item disappeared during cleanup');
    }
    this.itemList.splice(index, 1);
    try {
      // Publish the record deletion only after all known paths were cleaned.
      this.notify(undefined, true);
      await this.persist();
    } catch (error) {
      // Keep an explicit retryable record if the final journal write failed;
      // the prior on-disk cleanup-pending record is also safe on restart.
      item.status = 'failed';
      item.attemptStatus = 'failed';
      item.externalBusy = false;
      item.cleanupStatus = 'failed';
      item.cleanupErrorMessage = this.formatError(error);
      item.errorMessage = '删除记录保存失败：' + item.cleanupErrorMessage;
      this.itemList.splice(index, 0, item);
      this.notify(item, true);
      throw error;
    }
  }

  public stop(): void {
    if (this.runnerTask !== undefined) {
      this.stopRequested = true;
      this.notify(undefined, true);
    }
  }

  public start(): Promise<void> {
    if (!this.attached) {
      return Promise.reject(new Error('queue requires a foreground attachment'));
    }
    if (this.runnerTask !== undefined) {
      // A second click cannot create a second runner. Treat it as an explicit
      // resume when a stop-after-current request was set.
      this.stopRequested = false;
      return this.runnerTask;
    }

    this.stopRequested = false;
    // Install the runner guard before scheduling the loop. This closes the
    // empty-start/add/start and same-tick double-click races.
    const task: Promise<void> = Promise.resolve().then(async (): Promise<void> => {
      await this.persist();
      await this.runLoop();
    });
    this.runnerTask = task;
    // Register cleanup before returning task so an empty start cannot leave a
    // resolved old Promise that blocks a later add->start sequence.
    task.then(
      (): void => this.finishRunner(task),
      (): void => this.finishRunner(task)
    );
    return task;
  }

  private async runLoop(): Promise<void> {
    while (!this.stopRequested && this.attached) {
      const item: QueueItem | undefined = this.itemList.find(
        (candidate: QueueItem): boolean => candidate.status === 'pending' &&
          !candidate.externalBusy && candidate.cleanupStatus !== 'failed'
      );
      if (item === undefined) {
        return;
      }

      this.activeId = item.id;
      item.status = 'running';
      item.attemptStatus = 'running';
      item.errorMessage = '';
      item.progress = { stage: 0, current: 0, total: 0 };
      this.notify(item, true);
      try {
        if (item.inputPath.length === 0) {
          if (this.prepare === undefined) {
            throw new Error('沙盒输入不可用，请重试导入');
          }
          const prepared: QueuePrepared = await this.prepare(item);
          item.inputPath = prepared.inputPath;
          this.addOwnedPath(item, prepared.inputPath);
          item.details = prepared.details;
          item.classification = prepared.classification;
          this.notify(item, true);
          await this.persist();
        }
        // Capture immediately before the actual native conversion start.
        // Preparation can be asynchronous, and the copy prevents later global
        // UI mutations from changing this run's config object.
        const mode: QueueModeSnapshot = this.copyMode(this.captureMode());
        item.lastAttemptModeKey = mode.modeKey;
        item.lastAttemptModeLabel = mode.modeLabel;
        this.notify(item, true);
        await this.persist();
        const result: QueueResult = await this.execute(
          item,
          mode,
          (progress: NativeProgress): void => this.reportProgress(item.id, progress)
        );
        this.addOwnedPath(item, result.outputPath);
        item.result = result;
        item.status = 'succeeded';
        item.attemptStatus = 'succeeded';
        item.errorMessage = '';
        this.notify(item, true);
        // If the native operation succeeded but journaling fails, this catch
        // preserves result/ownedPaths, marks the item for manual retry, and
        // stops the queue instead of launching the next item.
        await this.persist();
      } catch (error) {
        if (error instanceof QueuePersistenceError) {
          this.stopRequested = true;
        }
        // Failure is isolated to this item unless persistence failed; the
        // latter stops later scheduling while preserving any native result.
        this.markFailed(item, this.formatError(error as Object));
      } finally {
        this.activeId = '';
        this.notify(item, true);
      }
    }
  }

  private reportProgress(id: string, progress: NativeProgress): void {
    const item = this.get(id);
    if (item === undefined || item.status !== 'running' || this.activeId !== id) {
      return;
    }
    item.progress = {
      stage: progress.stage,
      current: progress.current,
      total: progress.total
    };
    this.notify(item);
  }

  private markFailed(item: QueueItem, message: string): void {
    item.status = 'failed';
    item.attemptStatus = 'failed';
    item.errorMessage = message.length === 0 ? '未知错误' : message;
    this.notify(item, true);
  }

  private finishRunner(task: Promise<void>): void {
    if (this.runnerTask !== task) {
      return;
    }
    this.runnerTask = undefined;
    this.activeId = '';
    this.notify();
  }

  private require(id: string): QueueItem {
    const item = this.get(id);
    if (item === undefined) {
      throw new Error('queue item not found: ' + id);
    }
    return item;
  }

  private assertEditable(item: QueueItem): void {
    if (item.status === 'running' || item.externalBusy || this.activeId === item.id) {
      throw new Error('active item cannot be changed');
    }
  }

  private assertCleanupUsable(item: QueueItem): void {
    if (item.cleanupStatus === 'failed') {
      throw new Error('item cleanup failed; retry remove before other actions');
    }
  }

  private copyMode(captured: QueueModeSnapshot): QueueModeSnapshot {
    return {
      modeKey: captured.modeKey,
      modeLabel: captured.modeLabel,
      config: {
        oppoCompat: captured.config.oppoCompat,
        oppoCameraTail: captured.config.oppoCameraTail,
        strictTmap: captured.config.strictTmap,
        applePhotographicStyles: captured.config.applePhotographicStyles,
        applePortrait: captured.config.applePortrait
      }
    };
  }

  private copyItem(item: QueueItem): QueueItem {
    const copy: QueueItem = {
      id: item.id,
      revision: item.revision,
      displayName: item.displayName,
      sourceUri: item.sourceUri,
      inputPath: item.inputPath,
      status: item.status,
      attemptStatus: item.attemptStatus,
      externalBusy: item.externalBusy,
      progress: {
        stage: item.progress.stage,
        current: item.progress.current,
        total: item.progress.total
      },
      result: item.result === undefined ? undefined : {
        outputPath: item.result.outputPath,
        modeKey: item.result.modeKey,
        modeLabel: item.result.modeLabel,
        conversion: {
          success: item.result.conversion.success,
          mode: item.result.conversion.mode,
          family: item.result.conversion.family,
          edrScale: item.result.conversion.edrScale,
          gainMapMax: item.result.conversion.gainMapMax,
          errorMessage: item.result.conversion.errorMessage
        }
      },
      exportedUri: item.exportedUri,
      errorMessage: item.errorMessage,
      lastAttemptModeKey: item.lastAttemptModeKey,
      lastAttemptModeLabel: item.lastAttemptModeLabel,
      cleanupStatus: item.cleanupStatus,
      cleanupErrorMessage: item.cleanupErrorMessage,
      ownedPaths: item.ownedPaths.slice()
    };
    if (item.details !== undefined) {
      copy.details = { ...item.details };
    }
    if (item.classification !== undefined) {
      copy.classification = { ...item.classification };
    }
    return copy;
  }

  private notify(item?: QueueItem, durable: boolean = false): void {
    if (item !== undefined) {
      item.revision += 1;
    }
    this.notifyChanged(durable);
  }

  private notifyItems(items: Array<QueueItem>, durable: boolean): void {
    for (const item of items) {
      item.revision += 1;
    }
    this.notifyChanged(durable);
  }

  private notifyChanged(durable: boolean): void {
    if (durable) {
      this.schedulePersistence();
    }
    if (this.listener !== undefined) {
      try {
        this.listener();
      } catch (error) {
        // UI refresh failures must not stop the native queue.
      }
    }
  }

  private schedulePersistence(): void {
    if (this.persistence === undefined || this.persistenceError !== undefined) {
      return;
    }
    let snapshot: QueuePersistenceSnapshot;
    try {
      snapshot = this.snapshot();
    } catch (error) {
      this.recordPersistenceFailure(error as Object);
      return;
    }
    // State transitions may enqueue a checkpoint without an awaiter. Attach a
    // sink so a rejected journal write is still latched by the chain without
    // becoming an unhandled Promise rejection in the UI event loop.
    const task: Promise<void> = this.enqueuePersistence(snapshot);
    task.catch((): void => {
      // persistenceFailure is recorded by the serial chain above.
    });
  }

  private enqueuePersistence(snapshot: QueuePersistenceSnapshot): Promise<void> {
    if (this.persistence === undefined) {
      return Promise.resolve();
    }
    const writer: QueuePersist = this.persistence;
    this.persistencePending += 1;
    // The chain itself always settles, but a latched failure prevents later
    // queued snapshots from invoking the writer and masking the first error.
    const task: Promise<void> = this.persistChain.then((): Promise<void> => {
      if (this.persistenceError !== undefined) {
        return Promise.reject(this.persistenceFailure(this.persistenceError));
      }
      return writer(snapshot);
    });
    this.persistChain = task.then(
      (): void => {
        // A successful write clears no error: only retryPersistence may clear
        // the failure latch after the user explicitly requests a retry.
      },
      (error: Object): void => {
        this.recordPersistenceFailure(error);
      }
    ).then((): void => {
      this.persistencePending -= 1;
      // Queue UI controls also depend on the busy count. This notification is
      // deliberately non-durable so it cannot enqueue another journal write.
      this.notify();
    });
    return task;
  }

  private recordPersistenceFailure(error: Object): void {
    if (this.persistenceError === undefined) {
      this.persistenceError = error;
    }
    this.stopRequested = true;
    // Surface the durable write failure without scheduling another write.
    this.notify();
  }

  private persistenceFailure(error: Object): QueuePersistenceError {
    if (error instanceof QueuePersistenceError) {
      return error;
    }
    return new QueuePersistenceError('队列记录保存失败；已停止后续排程，请重试保存', error);
  }

  private addOwnedPath(item: QueueItem, path: string): void {
    if (path.length === 0 || item.ownedPaths.includes(path)) {
      return;
    }
    item.ownedPaths.push(path);
  }
}
