import { fileIo } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import xdremuxNative from 'libentry.so';
import {
  DEFAULT_SETTINGS,
  NativeSettings,
  OPPO_CAMERA_TAIL_OPTIONS,
  OPPO_COMPAT_OPTIONS,
  SettingsOption,
  SettingsOutputMode,
  cameraTailLabel,
  cloneSettings,
  compatLabel,
  modeLabel,
  normalizeSettings,
  settingsEqual
} from '../settings/SettingsModel';
import { SettingsLoadResult, SettingsStore } from '../settings/SettingsStore';
import {
  NativeClassificationResult,
  NativeConversionResult,
  NativeConvertConfig,
  NativePhotoDetails,
  NativeProgress
} from '../queue/NativeTypes';
import {
  QueueController,
  QueueItem,
  QueueItemInput,
  QueueModeSnapshot,
  QueuePrepared,
  QueueResult
} from '../queue/QueueController';
import { copyBatchOutput } from '../queue/BatchExportCopy';
import type { BatchExportFileIo, BatchExportFileStat } from '../queue/BatchExportCopy';
import { HarmonyQueueSandbox } from '../queue/HarmonyQueueSandbox';
import { HarmonyQueueStorage } from '../queue/HarmonyQueueStorage';
import { QueuePersistenceError, QueueStateStore, emptyQueueSnapshot, restoreQueueSnapshot } from '../queue/QueuePersistence';
import {
  BatchExportEntry,
  attachBatchExportTargets,
  markBatchExportNotStarted,
  markBatchExportWaiting,
  buildBatchExportPlan,
  runBatchExport,
  summarizeBatchExport
} from '../queue/BatchExport';
import type {
  QueuePathProbe,
  QueuePathStatus,
  QueuePersistenceSnapshot,
  QueueStoreLoadResult
} from '../queue/QueuePersistence';
import {
  emptyMotionPhotoInspection,
  motionPhotoStateLabel,
  parseMotionPhotoJson
} from '../queue/MotionPhotoModel';
import type { MotionPhotoInspection } from '../queue/MotionPhotoModel';

interface NativeError {
  message?: string;
  code?: number;
}

@Entry
@Component
struct Index {
  @State private coreVersion: string = '加载中…';
  @State private operationStatus: string = '准备就绪';
  @State private settingsLoaded: boolean = false;
  @State private settingsLoading: boolean = true;
  @State private settingsSaving: boolean = false;
  @State private settingsOpen: boolean = false;
  @State private settingsWarning: string = '';
  @State private settingsError: string = '';
  @State private committedSettingsView: NativeSettings = cloneSettings(DEFAULT_SETTINGS);
  @State private draftOutputMode: SettingsOutputMode = 'oppo';
  @State private draftOppoCompat: number = DEFAULT_SETTINGS.oppoCompat;
  @State private draftOppoCameraTail: number = DEFAULT_SETTINGS.oppoCameraTail;
  @State private draftStrictTmap: boolean = DEFAULT_SETTINGS.strictTmap;
  @State private draftApplePhotographicStyles: boolean = DEFAULT_SETTINGS.applePhotographicStyles;
  @State private draftApplePortrait: boolean = DEFAULT_SETTINGS.applePortrait;
  @State private queueItems: Array<QueueItem> = [];
  @State private selectedItemId: string = '';
  @State private queueRunning: boolean = false;
  @State private stopRequested: boolean = false;
  @State private activeItemId: string = '';
  @State private pageBusy: boolean = false;
  @State private queueLoading: boolean = true;
  @State private queueLoaded: boolean = false;
  @State private queueReady: boolean = false;
  @State private queueRecoveryRequired: boolean = false;
  @State private queueWarning: string = '';
  @State private queueError: string = '';
  @State private cacheUsage: string = '缓存占用读取中…';
  @State private cleanupRunning: boolean = false;
  @State private batchExportRunning: boolean = false;
  @State private batchExportStopRequested: boolean = false;
  @State private batchExportEntries: Array<BatchExportEntry> = [];
  @State private motionInspection: MotionPhotoInspection = emptyMotionPhotoInspection();
  @State private motionInspectionItemId: string = '';
  @State private motionInspecting: boolean = false;
  @State private motionInspectingItemId: string = '';

  private queueController: QueueController | undefined = undefined;
  private queueStore: QueueStateStore | undefined = undefined;
  private queueSandbox: HarmonyQueueSandbox | undefined = undefined;
  private pageVisible: boolean = false;
  private queueRestoreStarted: boolean = false;
  private queueRestoreInFlight: boolean = false;
  private readonly settingsStore: SettingsStore = new SettingsStore();
  private committedSettings: NativeSettings = cloneSettings(DEFAULT_SETTINGS);
  private inputSerial: number = 0;
  private outputSerial: number = 0;
  private batchExportSerial: number = 0;
  private batchPickerActive: boolean = false;
  private batchPageShowWaiters: Array<(visible: boolean) => void> = [];
  private readonly motionInspectionCache: Map<string, MotionPhotoInspection> =
    new Map<string, MotionPhotoInspection>();

  aboutToAppear(): void {
    this.pageVisible = true;
    this.refreshVersion();
    this.loadSettings();
    this.restoreQueueSession();
  }

  onPageShow(): void {
    // Returning to the foreground only reattaches the view. A stopped queue
    // requires an explicit Start/Resume click so no later native work starts
    // silently after a foreground transition.
    this.pageVisible = true;
    this.attachQueueSession();
    this.resolveBatchPageShowWaiters(!this.batchExportStopRequested);
  }

  onPageHide(): void {
    this.pageVisible = false;
    // A system picker temporarily hides the page. Its onPageHide callback is
    // not a user stop. Once the picker has returned, leaving the page stops
    // only later batch exports; the current FD copy is allowed to settle.
    if (this.batchPickerActive) {
      return;
    }
    if (this.batchExportRunning) {
      this.batchExportStopRequested = true;
    }
    this.resolveBatchPageShowWaiters(false);
    this.detachQueueSession();
  }

  aboutToDisappear(): void {
    this.pageVisible = false;
    // Page teardown is a real departure, unlike the temporary hide caused by
    // the system picker. Finish the current copy and stop later batch items.
    if (this.batchExportRunning) {
      this.batchExportStopRequested = true;
    }
    this.resolveBatchPageShowWaiters(false);
    this.detachQueueSession();
  }

  private async loadSettings(): Promise<void> {
    this.settingsLoading = true;
    this.settingsLoaded = false;
    this.settingsWarning = '';
    this.settingsError = '';
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('应用上下文不可用');
      }
      const loaded: SettingsLoadResult = await this.settingsStore.load(context);
      this.committedSettings = cloneSettings(loaded.values);
      this.committedSettingsView = cloneSettings(loaded.values);
      this.applyDraft(this.committedSettings);
      this.settingsWarning = loaded.warning;
      this.settingsLoaded = true;
      this.operationStatus = loaded.warning.length > 0
        ? loaded.warning
        : '设置已加载；运行中的项目使用各自的设置快照，队列记录会持久化';
    } catch (error) {
      this.settingsError = '设置加载失败：' + this.errorMessage(error);
      this.operationStatus = this.settingsError + '；请重试';
    } finally {
      this.settingsLoading = false;
    }
  }

  private applyDraft(values: NativeSettings): void {
    const snapshot: NativeSettings = cloneSettings(values);
    this.draftOutputMode = snapshot.outputMode;
    this.draftOppoCompat = snapshot.oppoCompat;
    this.draftOppoCameraTail = snapshot.oppoCameraTail;
    this.draftStrictTmap = snapshot.strictTmap;
    this.draftApplePhotographicStyles = snapshot.applePhotographicStyles;
    this.draftApplePortrait = snapshot.applePortrait;
  }

  private draftSettings(): NativeSettings {
    return {
      outputMode: this.draftOutputMode,
      oppoCompat: this.draftOppoCompat,
      oppoCameraTail: this.draftOppoCameraTail,
      strictTmap: this.draftStrictTmap,
      applePhotographicStyles: this.draftApplePhotographicStyles,
      applePortrait: this.draftApplePortrait
    };
  }

  private settingsDirty(): boolean {
    try {
      return !settingsEqual(normalizeSettings(this.draftSettings()), this.committedSettings);
    } catch (error) {
      return true;
    }
  }

  private async saveSettings(): Promise<void> {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    let snapshot: NativeSettings;
    try {
      snapshot = normalizeSettings(this.draftSettings());
    } catch (error) {
      this.settingsError = '设置无效：' + this.errorMessage(error);
      return;
    }
    this.settingsSaving = true;
    this.settingsError = '';
    try {
      await this.settingsStore.save(snapshot);
      this.committedSettings = cloneSettings(snapshot);
      this.committedSettingsView = cloneSettings(snapshot);
      this.applyDraft(snapshot);
      this.settingsWarning = '';
      this.operationStatus = '设置已保存；后续项目将使用新设置，运行中项目不变';
      this.settingsOpen = false;
    } catch (error) {
      // Keep the draft visible and retryable. The store rolls its process
      // cache back to the previous durable record when flush fails.
      this.settingsError = '设置保存失败：' + this.errorMessage(error);
      this.operationStatus = this.settingsError + '；草稿仍保留，可重试保存';
    } finally {
      this.settingsSaving = false;
    }
  }

  private cancelSettings(): void {
    if (this.settingsSaving) {
      return;
    }
    this.applyDraft(this.committedSettings);
    this.settingsError = '';
    this.settingsOpen = false;
    this.operationStatus = '已取消未保存设置';
  }

  private restoreDefaultSettings(): void {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    this.applyDraft(DEFAULT_SETTINGS);
    this.settingsError = '';
    this.operationStatus = '已恢复默认设置草稿；点击保存后才会生效';
  }

  private openSettings(): void {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    this.settingsOpen = true;
    this.settingsError = '';
  }

  private setDraftOutputMode(mode: SettingsOutputMode): void {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    this.draftOutputMode = mode;
    if (mode === 'apple') {
      this.draftOppoCompat = 0;
      this.draftOppoCameraTail = 0;
    } else {
      this.draftApplePhotographicStyles = false;
      this.draftApplePortrait = false;
      if (this.draftOppoCompat === 0) {
        this.draftOppoCompat = DEFAULT_SETTINGS.oppoCompat;
      }
      if (this.draftOppoCameraTail === 0) {
        this.draftOppoCameraTail = DEFAULT_SETTINGS.oppoCameraTail;
      }
    }
    this.settingsError = '';
  }

  private setDraftCompat(value: number): void {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    this.draftOppoCompat = value;
    this.draftOutputMode = 'oppo';
    if (value !== 0) {
      this.draftApplePhotographicStyles = false;
      this.draftApplePortrait = false;
    } else if (this.draftApplePhotographicStyles || this.draftApplePortrait) {
      this.draftOutputMode = 'apple';
      this.draftOppoCameraTail = 0;
    }
    this.settingsError = '';
  }

  private setDraftCameraTail(value: number): void {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    this.draftOppoCameraTail = value;
    this.draftOutputMode = 'oppo';
    this.draftApplePhotographicStyles = false;
    this.draftApplePortrait = false;
    this.settingsError = '';
  }

  private setDraftAppleStyles(enabled: boolean): void {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    this.draftApplePhotographicStyles = enabled;
    if (enabled) {
      this.draftOutputMode = 'apple';
      this.draftOppoCompat = 0;
      this.draftOppoCameraTail = 0;
    }
    this.settingsError = '';
  }

  private setDraftApplePortrait(enabled: boolean): void {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    this.draftApplePortrait = enabled;
    if (enabled) {
      this.draftOutputMode = 'apple';
      this.draftOppoCompat = 0;
      this.draftOppoCameraTail = 0;
    }
    this.settingsError = '';
  }

  private setDraftStrict(enabled: boolean): void {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    this.draftStrictTmap = enabled;
    this.settingsError = '';
  }

  private async restoreQueueSession(): Promise<void> {
    if (this.queueRestoreInFlight || this.queueRestoreStarted) {
      return;
    }
    if (this.queueController !== undefined &&
      (this.queueController.isRunning || this.queueController.isPersistenceBusy)) {
      this.operationStatus = '队列或记录保存正在进行，暂不能重试读取';
      return;
    }
    this.queueRestoreInFlight = true;
    this.queueLoading = true;
    this.queueRecoveryRequired = false;
    this.queueWarning = '';
    this.queueError = '';
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('应用上下文不可用');
      }
      const root: string = context.filesDir;
      this.queueStore = new QueueStateStore(root, new HarmonyQueueStorage());
      this.queueSandbox = new HarmonyQueueSandbox(root);
      const loaded: QueueStoreLoadResult = await this.queueStore.load();
      if (loaded.corrupt || loaded.snapshot === undefined) {
        this.queueRecoveryRequired = true;
        this.queueLoaded = false;
        this.queueReady = false;
        this.queueWarning = loaded.warning.length > 0
          ? loaded.warning
          : '队列记录无法安全读取；请使用安全恢复入口备份后新建队列';
        this.operationStatus = this.queueWarning;
        return;
      }

      const pathStates: Map<string, QueuePathStatus> = new Map<string, QueuePathStatus>();
      for (const item of loaded.snapshot.items) {
        for (const path of item.ownedPaths) {
          if (!pathStates.has(path)) {
            pathStates.set(path, await this.queueSandbox.status(path));
          }
        }
      }
      const probe: QueuePathProbe = {
        status: (path: string): QueuePathStatus => {
          const state: QueuePathStatus | undefined = pathStates.get(path);
          return state === undefined ? 'unsafe' : state;
        }
      };
      const restored = restoreQueueSnapshot(loaded.snapshot, probe);
      const controller: QueueController = this.getController();
      await controller.restore(restored.snapshot);
      this.queueLoaded = true;
      // Do not expose start/import/cleanup until the normalized recovery
      // snapshot has been written successfully.
      this.queueReady = false;
      this.queueRecoveryRequired = false;
      const warnings: Array<string> = [];
      if (loaded.warning.length > 0) {
        warnings.push(loaded.warning);
      }
      for (const warning of restored.warnings) {
        warnings.push(warning);
      }
      this.queueWarning = warnings.join('；');
      this.syncQueue();
      if (this.pageVisible) {
        this.attachQueueSession();
      }
      try {
        // Persist recovery state changes such as interrupted/running and
        // missing-result transitions before allowing a new run.
        await controller.persist();
        this.queueReady = true;
      } catch (error) {
        this.queueError = '恢复后的队列记录保存失败：' + this.errorMessage(error) + '；请重试保存';
      }
      await this.refreshCacheUsage();
      if (this.queueWarning.length > 0) {
        this.operationStatus = this.queueWarning;
      } else if (this.queueError.length === 0) {
        this.operationStatus = '队列已恢复；重启会保留项目，转换仍需前台手动开始';
      }
      this.queueRestoreStarted = true;
    } catch (error) {
      this.queueLoaded = false;
      this.queueReady = false;
      this.queueRecoveryRequired = true;
      this.queueError = '队列恢复失败：' + this.errorMessage(error);
      this.queueWarning = this.queueError + '；未执行沙盒清理';
      this.operationStatus = this.queueWarning;
      this.queueRestoreStarted = false;
    } finally {
      this.queueLoading = false;
      this.queueRestoreInFlight = false;
      this.syncQueue();
    }
  }

  private async recoverQueueRecord(): Promise<void> {
    if (!this.queueRecoveryRequired || this.queueLoading || this.cleanupRunning ||
      this.queueStore === undefined || this.pageBusy) {
      return;
    }
    if (this.queueController !== undefined && this.queueController.isRunning) {
      this.operationStatus = '队列仍在运行，暂不能恢复记录';
      return;
    }
    this.pageBusy = true;
    try {
      const backups: Array<string> = await this.queueStore.quarantine();
      const empty: QueuePersistenceSnapshot = emptyQueueSnapshot();
      await this.queueStore.save(empty);
      const controller: QueueController = this.getController();
      await controller.restore(empty);
      this.queueLoaded = true;
      this.queueReady = true;
      this.queueRecoveryRequired = false;
      this.queueRestoreStarted = true;
      this.queueWarning = '原队列记录已备份：' + backups.join('、') + '；已新建空队列';
      this.queueError = '';
      this.attachQueueSession();
      this.operationStatus = '已安全备份损坏记录并新建空队列';
      await this.refreshCacheUsage();
    } catch (error) {
      this.queueError = '安全恢复失败：' + this.errorMessage(error) + '；原记录仍保留';
      this.operationStatus = this.queueError;
    } finally {
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async retryQueuePersistence(): Promise<void> {
    const controller: QueueController | undefined = this.queueController;
    if (controller === undefined || !this.queueLoaded || this.queueLoading ||
      this.queueRecoveryRequired || this.pageBusy) {
      return;
    }
    this.pageBusy = true;
    try {
      await controller.retryPersistence();
      this.queueReady = true;
      this.queueError = '';
      this.operationStatus = '队列记录已保存；可以继续前台操作';
    } catch (error) {
      this.queueError = '队列记录重试保存失败：' + this.errorMessage(error);
      this.operationStatus = this.queueError;
    } finally {
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async refreshCacheUsage(): Promise<void> {
    const sandbox: HarmonyQueueSandbox | undefined = this.queueSandbox;
    if (sandbox === undefined) {
      this.cacheUsage = '沙盒尚未加载';
      return;
    }
    try {
      const usage = await sandbox.usage();
      this.cacheUsage = '沙盒占用：' + String(usage.inputBytes + usage.outputBytes) +
        ' 字节（输入 ' + String(usage.inputFiles) + '，输出 ' + String(usage.outputFiles) + '）';
    } catch (error) {
      this.cacheUsage = '沙盒占用读取失败：' + this.errorMessage(error);
    }
  }

  private queueHasBlockingOperation(controller: QueueController): boolean {
    if (controller.isRunning || controller.activeItemId.length > 0 || controller.isPersistenceBusy) {
      return true;
    }
    return controller.items().some((item: QueueItem): boolean => item.externalBusy);
  }

  private queuePersistenceFailed(): boolean {
    return this.queueController !== undefined && this.queueController.hasPersistenceError;
  }

  private async cleanupOrphanFiles(): Promise<void> {
    const sandbox: HarmonyQueueSandbox | undefined = this.queueSandbox;
    const controller: QueueController | undefined = this.queueController;
    if (!this.queueLoaded || !this.queueReady || this.queueLoading || this.queueRecoveryRequired ||
      sandbox === undefined || controller === undefined || this.pageBusy || this.cleanupRunning) {
      return;
    }
    if (this.settingsSaving || this.queueHasBlockingOperation(controller)) {
      this.operationStatus = '有设置保存、文件操作、转换或队列保存正在进行，暂不能清理沙盒';
      return;
    }
    this.pageBusy = true;
    this.cleanupRunning = true;
    try {
      const referenced: Set<string> = new Set<string>();
      for (const item of controller.items()) {
        for (const path of item.ownedPaths) {
          referenced.add(path);
        }
      }
      const report = await sandbox.cleanupOrphans(referenced, this.queueHasBlockingOperation(controller));
      this.operationStatus = '已清理未引用沙盒文件：' + String(report.deletedPaths.length) +
        ' 个，共 ' + String(report.deletedBytes) + ' 字节';
      await this.refreshCacheUsage();
    } catch (error) {
      this.operationStatus = '清理沙盒失败：' + this.errorMessage(error) + '；可在无操作时重试';
      await this.refreshCacheUsage();
    } finally {
      this.cleanupRunning = false;
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private attachQueueSession(): void {
    if (!this.queueLoaded || this.queueController === undefined) {
      return;
    }
    const controller: QueueController = this.queueController;
    controller.attach((): void => this.syncQueue());
    this.syncQueue();
  }

  private detachQueueSession(): void {
    // The active Promise still owns its native progress handle until it
    // settles; detach only stops later queued work and UI polling.
    if (this.queueController !== undefined) {
      this.queueController.detach();
    }
  }

  private getController(): QueueController {
    if (this.queueController === undefined) {
      this.queueController = new QueueController({
        captureMode: (): QueueModeSnapshot => this.modeSnapshot(),
        prepare: (item: QueueItem): Promise<QueuePrepared> => this.prepareQueueItem(item),
        execute: (
          item: QueueItem,
          mode: QueueModeSnapshot,
          reportProgress: (progress: NativeProgress) => void
        ): Promise<QueueResult> => this.executeQueueItem(item, mode, reportProgress),
        cleanup: (item: QueueItem): Promise<void> => this.cleanupQueueItem(item),
        persistence: async (snapshot: QueuePersistenceSnapshot): Promise<void> => {
          if (this.queueStore === undefined) {
            throw new Error('队列存储尚未加载');
          }
          await this.queueStore.save(snapshot);
        },
        errorMessage: (error: Object): string => this.errorMessage(error)
      });
    }
    return this.queueController;
  }

  private syncQueue(): void {
    const controller: QueueController | undefined = this.queueController;
    if (controller === undefined) {
      return;
    }
    this.queueItems = controller.items();
    this.queueRunning = controller.isRunning;
    this.stopRequested = controller.isStopRequested;
    this.activeItemId = controller.activeItemId;
    if (controller.hasPersistenceError) {
      this.queueReady = false;
      if (this.queueError.length === 0) {
        this.queueError = '队列记录保存失败，请重试保存';
      }
    }
    if (this.selectedItemId.length === 0 ||
      this.queueItems.find((item: QueueItem): boolean => item.id === this.selectedItemId) === undefined) {
      this.selectedItemId = this.queueItems.length === 0 ? '' : this.queueItems[0].id;
    }
    const validMotionKeys: Set<string> = new Set<string>();
    for (const item of this.queueItems) {
      if (item.inputPath.length > 0) {
        validMotionKeys.add(this.motionCacheKey(item));
      }
    }
    for (const key of this.motionInspectionCache.keys()) {
      if (!validMotionKeys.has(key)) {
        this.motionInspectionCache.delete(key);
      }
    }
    this.syncMotionSelection();
  }

  private selectedItem(): QueueItem | undefined {
    return this.queueItems.find((item: QueueItem): boolean => item.id === this.selectedItemId);
  }

  private motionCacheKey(item: QueueItem): string {
    return item.id + '\u0000' + item.inputPath;
  }

  private syncMotionSelection(): void {
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined || item.inputPath.length === 0) {
      if (this.motionInspectionItemId.length !== 0 || this.motionInspection.inputPath.length !== 0) {
        this.motionInspectionItemId = item === undefined ? '' : item.id;
        this.motionInspection = emptyMotionPhotoInspection();
      }
      return;
    }
    if (this.motionInspectionItemId === item.id && this.motionInspection.inputPath === item.inputPath) {
      return;
    }
    const cached: MotionPhotoInspection | undefined = this.motionInspectionCache.get(this.motionCacheKey(item));
    this.motionInspectionItemId = item.id;
    this.motionInspection = cached === undefined
      ? { inputPath: item.inputPath, state: 'unidentified', message: '尚未识别当前输入' }
      : cached;
  }

  private selectQueueItem(id: string): void {
    this.selectedItemId = id;
    this.syncMotionSelection();
  }

  private motionInspectButtonLabel(): string {
    if (!this.motionInspecting) {
      return '识别当前沙盒输入';
    }
    return this.motionInspectingItemId === this.selectedItemId
      ? '识别中…'
      : '识别中：另一个项目';
  }

  private selectedItemRequired(): QueueItem {
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined) {
      // The details builder can be evaluated during the frame in which the
      // last item is removed. Return a safe empty value instead of throwing
      // while the parent conditional is being reconciled.
      return {
        id: '',
        revision: 0,
        displayName: '',
        sourceUri: '',
        inputPath: '',
        status: 'failed',
        attemptStatus: 'idle',
        externalBusy: false,
        progress: { stage: 0, current: 0, total: 0 },
        exportedUri: '',
        errorMessage: '',
        lastAttemptModeKey: '',
        lastAttemptModeLabel: '',
        cleanupStatus: 'none',
        cleanupErrorMessage: '',
        ownedPaths: []
      };
    }
    return item;
  }

  private async refreshVersion(): Promise<void> {
    this.pageBusy = true;
    this.operationStatus = '正在异步读取 Rust 核心版本…';
    try {
      this.coreVersion = await xdremuxNative.version();
      this.operationStatus = 'Rust 核心已加载；队列记录会在关键状态变化时保存';
    } catch (error) {
      this.coreVersion = '不可用';
      this.operationStatus = '读取核心版本失败：' + this.errorMessage(error);
    } finally {
      this.pageBusy = false;
    }
  }

  private async chooseAndImport(): Promise<void> {
    if (!this.queueLoaded || !this.queueReady || this.queueLoading || this.queueRecoveryRequired) {
      this.operationStatus = this.queueRecoveryRequired
        ? '队列记录需要安全恢复，暂不能加入照片'
        : '队列记录加载中，暂不能加入照片';
      return;
    }
    if (!this.settingsLoaded || this.pageBusy || this.queueRunning) {
      if (!this.settingsLoaded) {
        this.operationStatus = '设置尚未加载完成，暂不能加入队列';
      }
      return;
    }
    const existingController: QueueController | undefined = this.queueController;
    if (existingController !== undefined && existingController.hasPersistenceError) {
      this.operationStatus = '队列记录保存失败，请先重试保存';
      return;
    }
    this.pageBusy = true;
    this.operationStatus = '正在打开系统文件选择器…';
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('应用上下文不可用');
      }
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = ['Images|.heic,.heif,.jpg,.jpeg,.png'];
      options.maxSelectNumber = 500;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const selected: Array<string> = await documentPicker.select(options);
      if (selected.length === 0) {
        this.operationStatus = '未选择照片';
        return;
      }

      let imported: number = 0;
      let failed: number = 0;
      const controller: QueueController = this.getController();
      for (let index: number = 0; index < selected.length; index += 1) {
        const sourceUri: string = selected[index];
        const input: QueueItemInput = {
          displayName: this.displayNameFromUri(sourceUri, index),
          sourceUri: sourceUri
        };
        const added: QueueItem = controller.add(input);
        if (this.selectedItemId.length === 0) {
          this.selectQueueItem(added.id);
        }
        controller.beginExternal(added.id);
        try {
          // Lock and source ownership are journaled before opening the URI.
          await controller.persist();
          this.operationStatus = '正在准备第 ' + String(index + 1) + ' / ' +
            String(selected.length) + ' 个文件…';
          const prepared: QueuePrepared = await this.prepareQueueItem(added);
          controller.setPrepared(added.id, prepared.inputPath, prepared.details, prepared.classification);
          await controller.persist();
          imported += 1;
        } catch (error) {
          // A journal failure is a session-wide durability fault. Do not turn
          // it into an ordinary per-file preparation failure or continue
          // importing the remaining picker selection after the checkpoint is
          // known to be unavailable.
          if (controller.hasPersistenceError || error instanceof QueuePersistenceError) {
            throw new Error('队列记录保存失败：' + this.errorMessage(error));
          }
          controller.markPreparationFailed(added.id, this.errorMessage(error));
          failed += 1;
        } finally {
          controller.endExternal(added.id);
        }
      }
      this.operationStatus = '已导入 ' + String(imported) + ' 个文件；失败 ' + String(failed) +
        ' 个，失败项目可单独重试';
    } catch (error) {
      this.operationStatus = '导入失败：' + this.errorMessage(error);
    } finally {
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async prepareQueueItem(item: QueueItem): Promise<QueuePrepared> {
    let newPath: string = '';
    try {
      newPath = await this.materializeUri(item.sourceUri, item.id);
      // Register before metadata/classification so an import failure still
      // leaves an explicit task-owned path for best-effort cleanup.
      this.getController().registerOwnedPath(item.id, newPath);
      // The path must be durable before metadata/classification can publish
      // details for a task that may outlive this process.
      await this.getController().persist();
      const detailsJson: string = await xdremuxNative.inspect(newPath);
      const details: NativePhotoDetails = JSON.parse(detailsJson) as NativePhotoDetails;
      if (!details.success) {
        throw new Error(this.display(details.errorMessage));
      }
      const classification: NativeClassificationResult =
        await xdremuxNative.classify(newPath) as NativeClassificationResult;
      return { inputPath: newPath, details: details, classification: classification };
    } catch (error) {
      if (newPath.length > 0 && this.queueSandbox !== undefined) {
        try {
          await this.queueSandbox.cleanupOwned([newPath]);
        } catch (cleanupError) {
          // Preserve the metadata/classification error; explicit removal
          // retries any path that could not be deleted here.
        }
      }
      throw new Error(this.errorMessage(error));
    }
  }

  private async retrySelected(): Promise<void> {
    if (this.pageBusy || this.batchExportRunning) {
      this.operationStatus = '当前有文件操作正在进行，暂不能重试项目';
      return;
    }
    if (!this.queueLoaded || !this.queueReady || this.queueRecoveryRequired) {
      this.operationStatus = '队列记录尚未恢复';
      return;
    }
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined) {
      this.operationStatus = '请先选择队列项目';
      return;
    }
    try {
      const controller: QueueController = this.getController();
      controller.retry(item.id);
      await controller.persist();
      this.operationStatus = '已将失败项目加入待处理队列，请点击开始/继续';
      this.syncQueue();
    } catch (error) {
      this.operationStatus = '重试失败：' + this.errorMessage(error);
    }
  }

  private async reconvertSelected(): Promise<void> {
    if (this.pageBusy || this.batchExportRunning) {
      this.operationStatus = '当前有文件操作正在进行，暂不能重新转换项目';
      return;
    }
    if (!this.queueLoaded || !this.queueReady || this.queueRecoveryRequired) {
      this.operationStatus = '队列记录尚未恢复';
      return;
    }
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined) {
      this.operationStatus = '请先选择队列项目';
      return;
    }
    try {
      const controller: QueueController = this.getController();
      controller.reconvert(item.id);
      await controller.persist();
      this.operationStatus = '已将项目加入重新转换队列；上次成功结果仍保留';
      this.syncQueue();
    } catch (error) {
      this.operationStatus = '重新转换失败：' + this.errorMessage(error);
    }
  }

  private async removeSelected(): Promise<void> {
    if (this.pageBusy || this.batchExportRunning) {
      this.operationStatus = '当前有文件操作正在进行，暂不能删除项目';
      return;
    }
    if (!this.queueLoaded || !this.queueReady || this.queueRecoveryRequired) {
      this.operationStatus = '队列记录尚未恢复';
      return;
    }
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined) {
      this.operationStatus = '请先选择队列项目';
      return;
    }
    this.pageBusy = true;
    try {
      await this.getController().remove(item.id);
      this.operationStatus = '已删除项目及其沙盒文件';
    } catch (error) {
      this.operationStatus = '删除失败：' + this.errorMessage(error);
    } finally {
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async startQueue(): Promise<void> {
    if (!this.queueLoaded || !this.queueReady || this.queueLoading || this.queueRecoveryRequired) {
      this.operationStatus = this.queueRecoveryRequired
        ? '队列记录需要安全恢复，暂不能开始'
        : '队列记录加载中，暂不能开始';
      return;
    }
    if (!this.settingsLoaded || this.pageBusy) {
      if (!this.settingsLoaded) {
        this.operationStatus = '设置尚未加载完成，暂不能开始队列';
      }
      return;
    }
    const controller: QueueController = this.getController();
    if (controller.hasPersistenceError) {
      this.operationStatus = '队列记录保存失败，请先重试保存';
      return;
    }
    if (!controller.hasPendingItems) {
      this.operationStatus = '没有可运行的待处理项目';
      return;
    }
    this.operationStatus = '队列运行中：失败项目不会阻塞后续项目';
    try {
      await controller.start();
      if (controller.isStopRequested) {
        this.operationStatus = '已停止接收新项目；当前结果已完成，可点击开始/继续';
      } else {
        this.operationStatus = '队列处理完成';
      }
    } catch (error) {
      this.operationStatus = '队列运行失败：' + this.errorMessage(error);
    } finally {
      this.syncQueue();
    }
  }

  private stopQueue(): void {
    if (!this.queueRunning) {
      this.operationStatus = '队列当前未运行';
      return;
    }
    if (this.queueController === undefined) {
      this.operationStatus = '队列尚未加载';
      return;
    }
    this.queueController.stop();
    this.operationStatus = '已请求停止：当前项目完成后暂停';
    this.syncQueue();
  }

  private async exportSelected(): Promise<void> {
    if (this.pageBusy || this.batchExportRunning) {
      this.operationStatus = '当前有文件操作正在进行，暂不能导出项目';
      return;
    }
    if (!this.queueLoaded || !this.queueReady || this.queueRecoveryRequired) {
      this.operationStatus = '队列记录尚未恢复，暂不能导出';
      return;
    }
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined || item.result === undefined) {
      this.operationStatus = '请先完成一个项目的转换';
      return;
    }
    this.pageBusy = true;
    let locked: boolean = false;
    const controller: QueueController = this.getController();
    let copied: boolean = false;
    try {
      controller.beginExternal(item.id);
      locked = true;
      await controller.persist();
      this.operationStatus = '正在打开系统保存位置选择器…';
      const destination: string | undefined = await this.exportItem(item);
      if (destination === undefined) {
        this.operationStatus = '未选择导出位置；沙盒结果仍保留';
      } else {
        // exportItem returns only after the destination FD was copied, size
        // checked and closed. The queue journal may still fail afterward.
        copied = true;
        controller.markExported(item.id, destination);
        await controller.persist();
        this.operationStatus = '导出成功：已关闭目标文件并写入系统位置';
      }
    } catch (error) {
      if (copied) {
        this.operationStatus = '图片已导出，队列状态保存失败：' + this.errorMessage(error) + '；沙盒结果仍保留';
      } else {
        this.operationStatus = '导出失败：' + this.errorMessage(error) + '；沙盒结果仍保留，可重试';
      }
    } finally {
      if (locked) {
        controller.endExternal(item.id);
        try {
          await controller.persist();
        } catch (persistError) {
          this.queueError = '导出状态保存失败：' + this.errorMessage(persistError) + '；请重试保存';
        }
      }
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async exportItem(item: QueueItem): Promise<string | undefined> {
    if (item.result === undefined) {
      throw new Error('转换结果不可用');
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('应用上下文不可用');
    }
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [this.exportFileName(item)];
    options.fileSuffixChoices = ['HEIF 图像|.heic'];
    const saved: Array<string> = await documentPicker.save(options);
    if (saved.length === 0) {
      return undefined;
    }
    const destinationUri: string = saved[0];
    await copyBatchOutput(this.batchFileIo(), item.result.outputPath, destinationUri, item.sourceUri);
    return destinationUri;
  }

  private batchExportStatusLabel(entry: BatchExportEntry): string {
    if (entry.status === 'waiting') {
      return '等待写入';
    }
    if (entry.status === 'copying') {
      return '正在写入';
    }
    if (entry.status === 'succeeded') {
      return '已写入并保存状态';
    }
    if (entry.status === 'journal-failed') {
      return entry.exported ? '已写入，队列状态保存失败' : '状态保存失败';
    }
    if (entry.status === 'canceled') {
      return '已停止，未写入';
    }
    return '导出失败；后续项目继续';
  }

  private batchExportSummaryText(): string {
    const summary = summarizeBatchExport(this.batchExportEntries);
    return '批量导出：已写入 ' + String(summary.exported) + ' / ' + String(summary.total) +
      '，成功保存 ' + String(summary.succeeded) +
      '，失败 ' + String(summary.failed) +
      '，状态保存失败 ' + String(summary.journalFailed) +
      '，已停止 ' + String(summary.canceled);
  }

  private batchProtectedPaths(controller: QueueController): Array<string> {
    const paths: Array<string> = [];
    for (const item of controller.items()) {
      if (!paths.includes(item.sourceUri)) {
        paths.push(item.sourceUri);
      }
      for (const path of item.ownedPaths) {
        if (!paths.includes(path)) {
          paths.push(path);
        }
      }
    }
    return paths;
  }

  private stopBatchExport(): void {
    if (!this.batchExportRunning) {
      this.operationStatus = '批量导出当前未运行';
      return;
    }
    this.batchExportStopRequested = true;
    this.resolveBatchPageShowWaiters(false);
    this.operationStatus = '已请求停止：当前文件完成后不再写入后续项目';
  }

  private resolveBatchPageShowWaiters(visible: boolean): void {
    const waiters: Array<(visible: boolean) => void> = this.batchPageShowWaiters;
    this.batchPageShowWaiters = [];
    for (const waiter of waiters) {
      try {
        waiter(visible);
      } catch (error) {
        // A page teardown must not prevent other waiters from settling.
      }
    }
  }

  private waitForBatchPageShow(): Promise<boolean> {
    if (this.batchExportStopRequested) {
      return Promise.resolve(false);
    }
    if (this.pageVisible) {
      return Promise.resolve(true);
    }
    return new Promise<boolean>((resolve: (visible: boolean) => void): void => {
      this.batchPageShowWaiters.push(resolve);
    });
  }

  private async releaseBatchExportLocks(controller: QueueController, ids: Array<string>): Promise<void> {
    controller.endExternalBatch(ids);
    try {
      await controller.persist();
    } catch (error) {
      this.queueError = '批量导出结束后队列状态保存失败：' + this.errorMessage(error) + '；请重试保存';
    }
  }

  private async inspectSelectedMotionPhoto(): Promise<void> {
    const controller: QueueController | undefined = this.queueController;
    const item: QueueItem | undefined = this.selectedItem();
    if (this.motionInspecting || this.pageBusy || this.batchExportRunning || this.queueRunning ||
      this.cleanupRunning || this.settingsSaving || !this.settingsLoaded || !this.queueLoaded ||
      !this.queueReady || this.queueLoading || this.queueRecoveryRequired || controller === undefined) {
      this.operationStatus = '当前有操作、设置或队列恢复正在进行，暂不能识别 Motion Photo';
      return;
    }
    if (controller.hasPersistenceError || controller.isPersistenceBusy || this.queueHasBlockingOperation(controller)) {
      this.operationStatus = '队列仍有未完成文件操作或保存，请稍后重试识别';
      return;
    }
    if (item === undefined || item.inputPath.length === 0) {
      this.operationStatus = '当前项目还没有可识别的沙盒输入';
      return;
    }
    const itemId: string = item.id;
    const inputPath: string = item.inputPath;
    const cacheKey: string = this.motionCacheKey(item);
    let locked: boolean = false;
    this.pageBusy = true;
    this.motionInspecting = true;
    this.motionInspectingItemId = itemId;
    this.operationStatus = '正在识别 Motion Photo：' + item.displayName;
    try {
      controller.beginExternal(itemId);
      locked = true;
      await controller.persist();
      if (this.queueSandbox === undefined) {
        throw new Error('沙盒尚未加载');
      }
      const pathState: QueuePathStatus = await this.queueSandbox.status(inputPath);
      if (pathState !== 'file') {
        throw new Error(pathState === 'empty' ? '沙盒输入为空' : '沙盒输入不可用：' + pathState);
      }
      const stat: fileIo.Stat = await fileIo.stat(inputPath);
      if (!Number.isSafeInteger(stat.size) || stat.size <= 0) {
        throw new Error('沙盒输入大小不是安全的正整数');
      }
      const rawJson: string = await xdremuxNative.motionInspect(inputPath) as string;
      const parsed: MotionPhotoInspection = parseMotionPhotoJson(rawJson, inputPath, stat.size);
      this.motionInspectionCache.set(cacheKey, parsed);
      if (this.selectedItemId === itemId && this.selectedItem()?.inputPath === inputPath) {
        this.motionInspectionItemId = itemId;
        this.motionInspection = parsed;
      }
      this.operationStatus = 'Motion Photo（' + item.displayName + '）：' +
        motionPhotoStateLabel(parsed.state) + '：' + parsed.message;
    } catch (error) {
      const failed: MotionPhotoInspection = {
        inputPath: inputPath,
        state: 'error',
        message: this.errorMessage(error)
      };
      this.motionInspectionCache.set(cacheKey, failed);
      if (this.selectedItemId === itemId && this.selectedItem()?.inputPath === inputPath) {
        this.motionInspectionItemId = itemId;
        this.motionInspection = failed;
      }
      this.operationStatus = 'Motion Photo（' + item.displayName + '）识别失败：' +
        failed.message + '；转换结果未改变，可重试';
    } finally {
      if (locked) {
        controller.endExternal(itemId);
        try {
          await controller.persist();
        } catch (persistError) {
          this.queueError = 'Motion Photo 识别结束后队列状态保存失败：' +
            this.errorMessage(persistError) + '；请重试保存';
        }
      }
      this.motionInspecting = false;
      this.motionInspectingItemId = '';
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async startBatchExport(): Promise<void> {
    const controller: QueueController | undefined = this.queueController;
    if (this.batchExportRunning || this.pageBusy || this.queueRunning || this.cleanupRunning ||
      this.settingsSaving || !this.settingsLoaded || !this.queueLoaded || !this.queueReady ||
      this.queueLoading || this.queueRecoveryRequired || controller === undefined) {
      this.operationStatus = '当前有操作、设置或队列恢复正在进行，暂不能批量导出';
      return;
    }
    if (controller.hasPersistenceError || controller.isPersistenceBusy || this.queueHasBlockingOperation(controller)) {
      this.operationStatus = '队列仍有未完成文件操作或保存，请稍后重试';
      return;
    }

    const plan: Array<BatchExportEntry> = buildBatchExportPlan(
      controller.items(),
      String(Date.now()) + '-' + String(this.batchExportSerial + 1)
    );
    this.batchExportSerial += 1;
    if (plan.length === 0) {
      this.operationStatus = '没有可批量导出的未导出结果';
      this.batchExportEntries = [];
      return;
    }

    const ids: Array<string> = plan.map((entry: BatchExportEntry): string => entry.id);
    let locked: boolean = false;
    this.batchExportEntries = plan;
    this.batchExportRunning = true;
    this.batchExportStopRequested = false;
    this.pageBusy = true;
    try {
      controller.beginExternalBatch(ids);
      locked = true;
      await controller.persist();
      if (this.batchExportStopRequested || !this.pageVisible) {
        this.batchExportEntries = markBatchExportWaiting(plan, 'canceled', '页面已离开前台，未打开导出选择器');
        this.operationStatus = '已停止批量导出；没有写入图片';
        return;
      }
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('应用上下文不可用');
      }
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = plan.map((entry: BatchExportEntry): string => entry.fileName);
      options.fileSuffixChoices = ['HEIF 图像|.heic'];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      this.operationStatus = '正在选择 ' + String(plan.length) + ' 个导出位置…';
      this.batchPickerActive = true;
      let saved: Array<string> = [];
      try {
        saved = await documentPicker.save(options);
      } finally {
        this.batchPickerActive = false;
      }
      if (saved.length === 0) {
        this.batchExportEntries = markBatchExportNotStarted(plan, 'canceled', '用户取消批量导出');
        this.operationStatus = '已取消批量导出；没有写入图片';
        return;
      }
      // DocumentViewPicker temporarily hides this page. Do not let that
      // transient false pageVisible value cancel the actual copy loop; wait
      // for onPageShow, while a real teardown resolves false.
      const returnedToPage: boolean = await this.waitForBatchPageShow();
      if (!returnedToPage || this.batchExportStopRequested) {
        this.batchExportEntries = markBatchExportWaiting(plan, 'canceled', '页面未恢复前台，未写入后续图片');
        this.operationStatus = '已停止批量导出；没有写入图片';
        return;
      }
      let mapped: Array<BatchExportEntry>;
      try {
        mapped = attachBatchExportTargets(plan, saved, this.batchProtectedPaths(controller));
      } catch (error) {
        this.batchExportEntries = markBatchExportNotStarted(plan, 'failed', this.errorMessage(error));
        this.operationStatus = '批量导出目标无效：' + this.errorMessage(error);
        return;
      }
      this.batchExportEntries = mapped;
      const completed: Array<BatchExportEntry> = await runBatchExport(mapped, {
        copy: async (entry: BatchExportEntry): Promise<void> => {
          await copyBatchOutput(this.batchFileIo(), entry.outputPath, entry.targetUri, entry.sourceUri);
        },
        checkpoint: async (entry: BatchExportEntry): Promise<void> => {
          controller.markExported(entry.id, entry.targetUri);
          await controller.persist();
        },
        shouldStop: (): boolean => this.batchExportStopRequested,
        onStatus: (entries: Array<BatchExportEntry>): void => {
          this.batchExportEntries = entries;
          this.syncQueue();
        },
        errorMessage: (error: Object): string => this.errorMessage(error)
      });
      this.batchExportEntries = completed;
      const summary = summarizeBatchExport(completed);
      this.operationStatus = this.batchExportSummaryText();
      if (summary.journalFailed > 0) {
        this.queueError = '批量导出状态保存失败，已停止后续写入；已写入文件仍保留';
      }
    } catch (error) {
      const message: string = this.errorMessage(error);
      this.batchExportEntries = markBatchExportWaiting(this.batchExportEntries, 'failed', message);
      this.operationStatus = '批量导出失败：' + message + '；已写入文件仍保留；' + this.batchExportSummaryText();
    } finally {
      this.batchPickerActive = false;
      if (locked) {
        await this.releaseBatchExportLocks(controller, ids);
      }
      this.batchExportRunning = false;
      this.batchExportStopRequested = false;
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private batchFileIo(): BatchExportFileIo {
    return {
      openUri: async (uri: string): Promise<number> => {
        return (await fileIo.open(uri, fileIo.OpenMode.WRITE_ONLY)).fd;
      },
      statPath: async (path: string): Promise<BatchExportFileStat> => {
        return { size: (await fileIo.stat(path)).size };
      },
      statFd: async (fd: number): Promise<BatchExportFileStat> => {
        return { size: (await fileIo.stat(fd)).size };
      },
      copyPathToFd: async (path: string, fd: number): Promise<void> => {
        await fileIo.copyFile(path, fd);
      },
      close: async (fd: number): Promise<void> => {
        await fileIo.close(fd);
      }
    };
  }

  private async executeQueueItem(
    item: QueueItem,
    mode: QueueModeSnapshot,
    reportProgress: (progress: NativeProgress) => void
  ): Promise<QueueResult> {
    let temporaryPath: string = '';
    let finalPath: string = '';
    let handle: number = 0;
    let timer: number = -1;
    try {
      const paths: Array<string> = this.nextOutputPaths(item.id);
      temporaryPath = paths[0];
      finalPath = paths[1];
      const controller: QueueController = this.getController();
      controller.registerOwnedPath(item.id, temporaryPath);
      controller.registerOwnedPath(item.id, finalPath);
      // Journal both output names before invoking Rust; a crash can then only
      // leave paths attributed to this task for explicit cleanup.
      await controller.persist();
      if (temporaryPath === item.inputPath || finalPath === item.inputPath) {
        throw new Error('输出路径不能覆盖输入文件');
      }
      await this.ensureDirectory(this.parentDirectory(finalPath));
      handle = xdremuxNative.progressBegin();
      if (handle === 0) {
        throw new Error('无法创建转换进度句柄');
      }
      timer = setInterval(() => {
        try {
          const progress: NativeProgress = xdremuxNative.progressRead(handle) as NativeProgress;
          reportProgress(progress);
        } catch (error) {
          // The Rust registry is cleared immediately before the final result;
          // a late empty poll is expected and does not decide success.
        }
      }, 250);
      const conversion: NativeConversionResult = await xdremuxNative.convert(
        item.inputPath,
        temporaryPath,
        mode.config,
        handle
      ) as NativeConversionResult;
      if (!conversion.success) {
        const message: string = this.display(conversion.errorMessage);
        throw new Error(message === '—' ? 'Rust 转换失败' : message);
      }
      const temporaryStat = await fileIo.stat(temporaryPath);
      if (temporaryStat.size <= 0) {
        throw new Error('转换输出为空');
      }
      await fileIo.rename(temporaryPath, finalPath);
      const finalStat = await fileIo.stat(finalPath);
      if (finalStat.size <= 0) {
        throw new Error('转换输出校验失败');
      }
      return {
        outputPath: finalPath,
        modeKey: mode.modeKey,
        modeLabel: mode.modeLabel,
        conversion: conversion
      };
    } catch (error) {
      // Both names are owned by this item. A rename can fail after creating
      // either side, so best-effort cleanup attempts both; the controller's
      // explicit remove retries any path that remains.
      const cleanupPaths: Array<string> = [temporaryPath, finalPath].filter(
        (path: string): boolean => path.length > 0
      );
      if (this.queueSandbox !== undefined && cleanupPaths.length > 0) {
        try {
          await this.queueSandbox.cleanupOwned(cleanupPaths);
        } catch (cleanupError) {
          // The conversion error remains the item error; removal is explicit.
        }
      }
      throw new Error(this.errorMessage(error));
    } finally {
      if (timer >= 0) {
        clearInterval(timer);
      }
      if (handle !== 0) {
        try {
          // This runs only after xdremuxNative.convert has settled.
          xdremuxNative.progressEnd(handle);
        } catch (endError) {
          // Preserve the settled conversion result/error.
        }
      }
    }
  }

  private modeSnapshot(): QueueModeSnapshot {
    const settings: NativeSettings = normalizeSettings(cloneSettings(this.committedSettings));
    return {
      modeKey: settings.outputMode,
      modeLabel: modeLabel(settings),
      config: {
        oppoCompat: settings.oppoCompat,
        oppoCameraTail: settings.oppoCameraTail,
        strictTmap: settings.strictTmap ? 1 : 0,
        applePhotographicStyles: settings.applePhotographicStyles ? 1 : 0,
        applePortrait: settings.applePortrait ? 1 : 0
      }
    };
  }

  private savedSettingsSummary(): string {
    try {
      return modeLabel(this.committedSettingsView);
    } catch (error) {
      return '设置无效';
    }
  }

  private compatIndex(value: number): number {
    const index: number = OPPO_COMPAT_OPTIONS.findIndex(
      (option: SettingsOption): boolean => option.value === value
    );
    return index < 0 ? 0 : index;
  }

  private cameraTailIndex(value: number): number {
    const index: number = OPPO_CAMERA_TAIL_OPTIONS.findIndex(
      (option: SettingsOption): boolean => option.value === value
    );
    return index < 0 ? 0 : index;
  }

  private draftSettingsLabel(): string {
    try {
      return modeLabel(normalizeSettings(this.draftSettings()));
    } catch (error) {
      return '设置无效';
    }
  }

  private async cleanupQueueItem(item: QueueItem): Promise<void> {
    const sandbox: HarmonyQueueSandbox | undefined = this.queueSandbox;
    if (sandbox === undefined) {
      throw new Error('沙盒尚未加载');
    }
    // QueueSandbox validates every path and uses lstat on both directory and
    // leaf, so source URIs and files belonging to another task are untouched.
    await sandbox.cleanupOwned(item.ownedPaths.slice());
  }

  private async materializeUri(sourceUri: string, itemId: string): Promise<string> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('应用上下文不可用');
    }
    this.inputSerial += 1;
    const inputDirectory: string = context.filesDir + '/inputs';
    const destination: string = inputDirectory + '/input-' + itemId + '-' + String(Date.now()) + '-' +
      String(this.inputSerial) + '.photo';
    let sourceFd: number = -1;
    try {
      // Reserve the generated path before any copy operation so a partial
      // destination remains owned by this queue item if a later step fails.
      const controller: QueueController = this.getController();
      controller.registerOwnedPath(itemId, destination);
      // Persist ownership before a URI copy can create a partial file.
      await controller.persist();
      await this.ensureDirectory(inputDirectory);
      sourceFd = (await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY)).fd;
      await fileIo.copyFile(sourceFd, destination);
      const stat = await fileIo.stat(destination);
      if (stat.size <= 0) {
        throw new Error('沙盒照片为空');
      }
      return destination;
    } catch (error) {
      if (this.queueSandbox !== undefined) {
        try {
          await this.queueSandbox.cleanupOwned([destination]);
        } catch (cleanupError) {
          // Preserve the source/copy error; explicit item removal retries it.
        }
      }
      throw new Error(this.errorMessage(error));
    } finally {
      if (sourceFd >= 0) {
        try {
          await fileIo.close(sourceFd);
        } catch (closeError) {
          // Preserve the copy error if one already occurred.
        }
      }
    }
  }

  private async ensureDirectory(path: string): Promise<void> {
    try {
      await fileIo.mkdir(path, true);
      return;
    } catch (mkdirError) {
      try {
        const exists: boolean = await fileIo.access(path);
        if (exists) {
          return;
        }
      } catch (accessError) {
        // Fall through with the original mkdir error.
      }
      throw new Error(this.errorMessage(mkdirError));
    }
  }

  private nextOutputPaths(itemId: string): Array<string> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('应用上下文不可用');
    }
    this.outputSerial += 1;
    const stem: string = 'xdremux-' + itemId + '-' + String(Date.now()) + '-' + String(this.outputSerial);
    const outputDirectory: string = context.filesDir + '/outputs';
    const temporaryPath: string = outputDirectory + '/' + stem + '.heic.tmp';
    const finalPath: string = outputDirectory + '/' + stem + '.heic';
    if (this.queueSandbox === undefined) {
      throw new Error('沙盒尚未加载');
    }
    this.queueSandbox.pathPolicy.validate(temporaryPath);
    this.queueSandbox.pathPolicy.validate(finalPath);
    return [temporaryPath, finalPath];
  }

  private parentDirectory(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(0, slash);
  }

  private exportFileName(item: QueueItem): string {
    if (item.result === undefined) {
      return 'xdremux-export.heic';
    }
    const path: string = item.result.outputPath;
    const slash: number = path.lastIndexOf('/');
    const baseName: string = slash < 0 ? path : path.substring(slash + 1);
    const dot: number = baseName.lastIndexOf('.');
    const stem: string = dot > 0 ? baseName.substring(0, dot) : baseName;
    return stem + '-' + item.result.modeKey + '.heic';
  }

  private displayNameFromUri(uri: string, index: number): string {
    const slash: number = uri.lastIndexOf('/');
    const name: string = slash < 0 ? uri : uri.substring(slash + 1);
    return name.length === 0 ? '照片 ' + String(index + 1) : name;
  }

  private statusLabel(item: QueueItem): string {
    if (item.status === 'pending') {
      return item.result === undefined ? '待处理' : '待重新转换';
    }
    if (item.status === 'running') {
      return '处理中';
    }
    if (item.status === 'succeeded') {
      return '已完成';
    }
    return '失败';
  }

  private progressStageLabel(stage: number): string {
    if (stage === 1) {
      return '解析元数据';
    }
    if (stage === 2) {
      return '解码 JPEG';
    }
    if (stage === 3) {
      return '编码 HEVC';
    }
    if (stage === 4) {
      return '组装输出';
    }
    return '准备中';
  }

  private errorMessage(error: Object): string {
    try {
      if (error instanceof Error && error.message.length > 0) {
        return error.message;
      }
      const nativeError = error as NativeError;
      if (nativeError.message !== undefined && nativeError.message.length > 0) {
        return nativeError.message;
      }
      if (nativeError.code !== undefined) {
        return '错误码 ' + String(nativeError.code);
      }
      const serialized: string | undefined = JSON.stringify(error);
      if (serialized !== undefined && serialized !== '{}') {
        return serialized;
      }
      return String(error);
    } catch (formatError) {
      return '未知错误';
    }
  }

  private display(value: string | null | undefined): string {
    return value === null || value === undefined || value.length === 0 ? '—' : value;
  }

  private displayNumber(value: number | undefined): string {
    return value === undefined ? '—' : String(value);
  }

  private displayBigInt(value: bigint | undefined): string {
    return value === undefined ? '—' : String(value);
  }

  private motionAudioLabel(value: boolean | undefined): string {
    if (value === undefined) {
      return '未知/未提供';
    }
    return value ? '有音频' : '无音频';
  }

  private motionStateColor(): string {
    if (this.motionInspection.state === 'error') {
      return '#B3261E';
    }
    if (this.motionInspection.state === 'motion') {
      return '#16845B';
    }
    return '#52606D';
  }

  private canInspectMotionPhoto(): boolean {
    const item: QueueItem | undefined = this.selectedItem();
    return item !== undefined && item.inputPath.length > 0;
  }

  @Builder
  private motionPhotoPanel(): void {
    Column() {
      Text('Motion Photo（按需识别）')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#18202A')
        .width('100%')
        .margin({ top: 14, bottom: 6 });
      Text('识别只读取当前已物化的沙盒输入；结果按任务和 inputPath 缓存于本次运行，重启后需重新识别。')
        .fontSize(12)
        .fontColor('#52606D')
        .width('100%');
      Text('当前输入：' + this.display(this.motionInspection.inputPath))
        .fontSize(12)
        .fontColor('#52606D')
        .width('100%')
        .margin({ top: 4 });
      Text(motionPhotoStateLabel(this.motionInspection.state) + '：' + this.motionInspection.message)
        .fontSize(14)
        .fontColor(this.motionStateColor())
        .width('100%')
        .margin({ top: 6 });
      if (this.motionInspection.state === 'motion' && this.motionInspection.report !== undefined) {
        Text('来源：' + this.motionInspection.report.sourceKind + ' · 双流：' +
          (this.motionInspection.report.isDualStream ? '是' : '否') + ' · 条目：' +
          String(this.motionInspection.report.items.length))
          .fontSize(13)
          .fontColor('#18202A')
          .width('100%')
          .margin({ top: 6 });
        Text('静态范围：' + String(this.motionInspection.report.stillStart) + '–' +
          String(this.motionInspection.report.stillEnd) + ' · 视频范围：' +
          String(this.motionInspection.report.videoStart) + '–' +
          String(this.motionInspection.report.videoEnd))
          .fontSize(13)
          .fontColor('#18202A')
          .width('100%');
        if (this.motionInspection.report.primaryBytes !== undefined ||
          this.motionInspection.report.secondaryBytes !== undefined) {
          Text('视频字节：主 ' + this.displayNumber(this.motionInspection.report.primaryBytes) +
            ' · 副 ' + this.displayNumber(this.motionInspection.report.secondaryBytes))
            .fontSize(13)
            .fontColor('#18202A')
            .width('100%');
        }
        Text('视频：' + this.displayNumber(this.motionInspection.report.videoWidth) + ' × ' +
          this.displayNumber(this.motionInspection.report.videoHeight) + ' · 时长(ms)：' +
          this.displayNumber(this.motionInspection.report.durationMs) + ' · FPS：' +
          this.displayNumber(this.motionInspection.report.fps))
          .fontSize(13)
          .fontColor('#18202A')
          .width('100%');
        Text('编码：' + this.display(this.motionInspection.report.videoCodec) + ' · ' +
          '音频：' + this.motionAudioLabel(this.motionInspection.report.hasAudio) +
          (this.motionInspection.report.audioCodec !== undefined
            ? ' · ' + this.motionInspection.report.audioCodec : ''))
          .fontSize(13)
          .fontColor('#18202A')
          .width('100%');
        if (this.motionInspection.report.secondaryWidth !== undefined ||
          this.motionInspection.report.secondaryHeight !== undefined ||
          this.motionInspection.report.secondaryFps !== undefined) {
          Text('副视频：' + this.displayNumber(this.motionInspection.report.secondaryWidth) + ' × ' +
            this.displayNumber(this.motionInspection.report.secondaryHeight) + ' · FPS：' +
            this.displayNumber(this.motionInspection.report.secondaryFps))
            .fontSize(13)
            .fontColor('#18202A')
            .width('100%');
        }
      }
      Button(this.motionInspectButtonLabel())
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor('#6B4BB8')
        .width('100%')
        .height(44)
        .margin({ top: 8 })
        .enabled(this.canInspectMotionPhoto() && !this.motionInspecting && !this.pageBusy &&
          !this.queueRunning && !this.batchExportRunning && !this.cleanupRunning &&
          !this.settingsSaving && this.queueLoaded && this.queueReady &&
          !this.queueLoading && !this.queueRecoveryRequired && !this.queuePersistenceFailed())
        .onClick(() => {
          this.inspectSelectedMotionPhoto();
        });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(12)
    .backgroundColor('#F1EDFF')
    .borderRadius(10)
    .margin({ top: 10 });
  }

  @Builder
  private settingsPanel(): void {
    Column() {
      Row() {
        Text('转换设置草稿')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#18202A')
          .layoutWeight(1);
        Button('取消')
          .fontSize(13)
          .fontColor('#18202A')
          .backgroundColor('#DDE5EE')
          .enabled(!this.settingsSaving)
          .onClick(() => {
            this.cancelSettings();
          });
      }
      .width('100%');
      Text('先编辑草稿，再点击保存；保存失败时草稿会保留。运行中的项目继续使用开始时的完整快照。')
        .fontSize(13)
        .fontColor('#52606D')
        .width('100%')
        .margin({ top: 6, bottom: 12 });

      Text('输出模式')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#18202A')
        .width('100%');
      Row() {
        Button('OPPO 兼容')
          .fontSize(15)
          .fontColor(this.draftOutputMode === 'oppo' ? '#FFFFFF' : '#18202A')
          .backgroundColor(this.draftOutputMode === 'oppo' ? '#2E6BD6' : '#DDE5EE')
          .layoutWeight(1)
          .height(44)
          .enabled(!this.settingsSaving)
          .onClick(() => {
            this.setDraftOutputMode('oppo');
          });
        Button('Apple 标准')
          .fontSize(15)
          .fontColor(this.draftOutputMode === 'apple' ? '#FFFFFF' : '#18202A')
          .backgroundColor(this.draftOutputMode === 'apple' ? '#2E6BD6' : '#DDE5EE')
          .layoutWeight(1)
          .height(44)
          .margin({ left: 8 })
          .enabled(!this.settingsSaving)
          .onClick(() => {
            this.setDraftOutputMode('apple');
          });
      }
      .width('100%')
      .margin({ top: 8, bottom: 12 });

      if (this.draftOutputMode === 'oppo') {
        Text('OPPO 兼容模式')
          .fontSize(15)
          .fontColor('#18202A')
          .width('100%')
          .margin({ top: 4 });
        Select(OPPO_COMPAT_OPTIONS.map((option: SettingsOption): SelectOption => {
          return { value: option.label };
        }))
          .selected(this.compatIndex(this.draftOppoCompat))
          .value(compatLabel(this.draftOppoCompat))
          .fontColor('#18202A')
          .optionFont({ size: 14, weight: FontWeight.Regular })
          .selectedOptionFont({ size: 14, weight: FontWeight.Medium })
          .width('100%')
          .margin({ top: 6 })
          .enabled(!this.settingsSaving)
          .onSelect((index: number, text?: string): void => {
            if (index >= 0 && index < OPPO_COMPAT_OPTIONS.length) {
              this.setDraftCompat(OPPO_COMPAT_OPTIONS[index].value);
            }
          });
        Text('说明：' + (OPPO_COMPAT_OPTIONS[this.compatIndex(this.draftOppoCompat)]?.help ?? ''))
          .fontSize(12)
          .fontColor('#52606D')
          .width('100%')
          .margin({ top: 4 });

        Text('保留 OPPO 相机附加信息')
          .fontSize(15)
          .fontColor('#18202A')
          .width('100%')
          .margin({ top: 12 });
        Select(OPPO_CAMERA_TAIL_OPTIONS.map((option: SettingsOption): SelectOption => {
          return { value: option.label };
        }))
          .selected(this.cameraTailIndex(this.draftOppoCameraTail))
          .value(cameraTailLabel(this.draftOppoCameraTail))
          .fontColor('#18202A')
          .optionFont({ size: 14, weight: FontWeight.Regular })
          .selectedOptionFont({ size: 14, weight: FontWeight.Medium })
          .width('100%')
          .margin({ top: 6 })
          .enabled(!this.settingsSaving)
          .onSelect((index: number, text?: string): void => {
            if (index >= 0 && index < OPPO_CAMERA_TAIL_OPTIONS.length) {
              this.setDraftCameraTail(OPPO_CAMERA_TAIL_OPTIONS[index].value);
            }
          });
        Text('说明：' + (OPPO_CAMERA_TAIL_OPTIONS[this.cameraTailIndex(this.draftOppoCameraTail)]?.help ?? ''))
          .fontSize(12)
          .fontColor('#52606D')
          .width('100%')
          .margin({ top: 4 });
      } else {
        Text('Apple 标准会关闭 OPPO 路由和相机附加信息；下面的 Apple 选项写入可继续编辑的数据。')
          .fontSize(13)
          .fontColor('#52606D')
          .width('100%')
          .margin({ top: 4, bottom: 4 });
      }

      Text('Apple 照片功能（实验性）')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#18202A')
        .width('100%')
        .margin({ top: 14 });
      Text('开启后自动使用 Apple 标准输出；这里写入可继续调节的数据，不会把风格直接烘焙进照片。人像选项写入可编辑人像数据，需要源照片具备可用景深信息。')
        .fontSize(12)
        .fontColor('#52606D')
        .width('100%')
        .margin({ top: 4, bottom: 4 });
      Row() {
        Text('摄影风格数据')
          .fontSize(14)
          .fontColor('#18202A')
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.draftApplePhotographicStyles })
          .selectedColor('#2E6BD6')
          .switchPointColor('#FFFFFF')
          .enabled(!this.settingsSaving)
          .onChange((isOn: boolean): void => {
            this.setDraftAppleStyles(isOn);
          });
      }
      .width('100%')
      .margin({ top: 4 });
      Row() {
        Text('人像数据')
          .fontSize(14)
          .fontColor('#18202A')
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.draftApplePortrait })
          .selectedColor('#2E6BD6')
          .switchPointColor('#FFFFFF')
          .enabled(!this.settingsSaving)
          .onChange((isOn: boolean): void => {
            this.setDraftApplePortrait(isOn);
          });
      }
      .width('100%')
      .margin({ top: 4 });
      Row() {
        Text('严格 ISO 兼容（高级）')
          .fontSize(14)
          .fontColor('#18202A')
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.draftStrictTmap })
          .selectedColor('#2E6BD6')
          .switchPointColor('#FFFFFF')
          .enabled(!this.settingsSaving)
          .onChange((isOn: boolean): void => {
            this.setDraftStrict(isOn);
          });
      }
      .width('100%')
      .margin({ top: 4 });
      Text('仅用于严格 ISO 21496-1 测试；普通用户建议关闭，可能降低部分相册兼容性。')
        .fontSize(12)
        .fontColor('#52606D')
        .width('100%')
        .margin({ top: 3 });

      Text('草稿摘要：' + this.draftSettingsLabel())
        .fontSize(13)
        .fontColor('#18202A')
        .width('100%')
        .margin({ top: 12 });
      if (this.settingsError.length > 0) {
        Text(this.settingsError)
          .fontSize(13)
          .fontColor('#B3261E')
          .width('100%')
          .margin({ top: 6 });
      }
      Row() {
        Button('恢复默认（需保存）')
          .fontSize(13)
          .fontColor('#18202A')
          .backgroundColor('#DDE5EE')
          .layoutWeight(1)
          .height(44)
          .enabled(!this.settingsSaving)
          .onClick(() => {
            this.restoreDefaultSettings();
          });
        Button(this.settingsSaving ? '保存中…' : '保存并返回')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#16845B')
          .layoutWeight(1)
          .height(44)
          .margin({ left: 8 })
          .enabled(!this.settingsSaving && (this.settingsDirty() || this.settingsWarning.length > 0))
          .onClick(() => {
            this.saveSettings();
          });
      }
      .width('100%')
      .margin({ top: 14 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .margin({ top: 8, bottom: 14 });
  }

  @Builder
  private selectedDetails(): void {

            Column() {
              Text('当前项目详情')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor('#18202A')
                .width('100%')
                .margin({ bottom: 8 });
              Text('项目 ID：' + this.selectedItemRequired().id + ' · 文件：' + this.selectedItemRequired().displayName)
                .fontSize(14)
                .fontColor('#18202A')
                .width('100%');
              Text('源 URI：' + this.display(this.selectedItemRequired().sourceUri))
                .fontSize(12)
                .fontColor('#52606D')
                .width('100%')
                .margin({ top: 4 });
              Text('沙盒输入：' + this.display(this.selectedItemRequired().inputPath))
                .fontSize(12)
                .fontColor('#18202A')
                .width('100%')
                .margin({ top: 4, bottom: 10 });

              if (this.selectedItemRequired().details !== undefined) {
                Text('照片详情')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#18202A')
                  .width('100%')
                  .margin({ bottom: 6 });
                Text('厂商：' + this.display(this.selectedItemRequired().details?.make) + ' · 型号：' +
                  this.display(this.selectedItemRequired().details?.model))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('时间：' + this.display(this.selectedItemRequired().details?.dateTime))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('曝光：' + this.display(this.selectedItemRequired().details?.exposureTime) + ' · 光圈：' +
                  this.display(this.selectedItemRequired().details?.fNumber) + ' · ISO：' + this.display(this.selectedItemRequired().details?.iso))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('焦距：' + this.display(this.selectedItemRequired().details?.focalLength) + ' · 35mm：' +
                  this.display(this.selectedItemRequired().details?.focalLength35mm) + ' · 曝光补偿：' +
                  this.display(this.selectedItemRequired().details?.exposureBias))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('尺寸：' + this.displayNumber(this.selectedItemRequired().details?.width) + ' × ' +
                  this.displayNumber(this.selectedItemRequired().details?.height) + ' · HDR：' +
                  this.display(this.selectedItemRequired().details?.hdrKind))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%')
                  .margin({ bottom: 10 });
              }

              if (this.selectedItemRequired().classification !== undefined) {
                Text('分类结果')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#18202A')
                  .width('100%')
                  .margin({ bottom: 6 });
                Text('状态：' + this.display(this.selectedItemRequired().classification?.status))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('模式：' + this.display(this.selectedItemRequired().classification?.modeKey) +
                  ' · 目录：' + this.display(this.selectedItemRequired().classification?.folderName))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('HDR：' + this.display(this.selectedItemRequired().classification?.hdrKind) + ' · 家族：' +
                  this.display(this.selectedItemRequired().classification?.family))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('标签：' + String(this.selectedItemRequired().classification?.hasTagFlags) + ' · 标志：' +
                  this.displayBigInt(this.selectedItemRequired().classification?.tagFlags) + ' · 未知：' +
                  this.displayBigInt(this.selectedItemRequired().classification?.unknownFlags))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%')
                  .margin({ bottom: 10 });
              }

              if (this.selectedItemRequired().result !== undefined) {
                Text('上次成功结果：' + this.selectedItemRequired().result?.modeLabel)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#18202A')
                  .width('100%')
                  .margin({ bottom: 6 });
                Text('结果路径：' + this.selectedItemRequired().result?.outputPath)
                  .fontSize(12)
                  .fontColor('#18202A')
                  .width('100%');
                Text('核心模式：' + this.display(this.selectedItemRequired().result?.conversion.mode) +
                  ' · 家族：' + this.display(this.selectedItemRequired().result?.conversion.family))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                if (this.selectedItemRequired().attemptStatus === 'failed' && this.selectedItemRequired().errorMessage.length > 0) {
                  Text('最新重转换失败；上次成功结果仍保留：' + this.selectedItemRequired().errorMessage)
                    .fontSize(13)
                    .fontColor('#B3261E')
                    .width('100%')
                    .margin({ top: 4 });
                }
                if (this.selectedItemRequired().exportedUri.length > 0) {
                  Text('已导出：' + this.selectedItemRequired().exportedUri)
                    .fontSize(12)
                    .fontColor('#16845B')
                    .width('100%')
                    .margin({ top: 4 });
                }
              }

              this.motionPhotoPanel();

              Row() {
                Button('重试失败项目')
                  .fontSize(14)
                  .fontColor('#18202A')
                  .backgroundColor('#DDE5EE')
                  .layoutWeight(1)
                  .height(44)
                  .enabled(!this.pageBusy && !this.selectedItemRequired().externalBusy && this.selectedItemRequired().status === 'failed')
                  .onClick(() => {
                    this.retrySelected();
                  });
                Button('重新转换')
                  .fontSize(14)
                  .fontColor('#18202A')
                  .backgroundColor('#DDE5EE')
                  .layoutWeight(1)
                  .height(44)
                  .margin({ left: 8 })
                  .enabled(!this.pageBusy && !this.selectedItemRequired().externalBusy && this.selectedItemRequired().status === 'succeeded')
                  .onClick(() => {
                    this.reconvertSelected();
                  });
                Button('删除项目')
                  .fontSize(14)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#B3261E')
                  .layoutWeight(1)
                  .height(44)
                  .margin({ left: 8 })
                  .enabled(!this.pageBusy && !this.selectedItemRequired().externalBusy && this.selectedItemRequired().status !== 'running')
                  .onClick(() => {
                    this.removeSelected();
                  });
              }
              .width('100%')
              .margin({ top: 12 });
              Button('导出上次成功结果')
                .fontSize(15)
                .fontColor('#FFFFFF')
                .backgroundColor('#1F5FBF')
                .width('100%')
                .height(48)
                .margin({ top: 10 })
                .enabled(!this.pageBusy && !this.selectedItemRequired().externalBusy && this.selectedItemRequired().status !== 'running' &&
                  this.selectedItemRequired().cleanupStatus !== 'failed' && this.selectedItemRequired().result !== undefined)
                .onClick(() => {
                  this.exportSelected();
                });
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(14)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .margin({ top: 8, bottom: 18 });
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          Text('XDRemux 原生版')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor('#18202A')
            .margin({ bottom: 6 });
          Text('P3 · 多文件队列与批量导出（当前会话，前台运行）')
            .fontSize(15)
            .fontColor('#52606D')
            .margin({ bottom: 18 });

          Column() {
            Text('Rust 核心')
              .fontSize(14)
              .fontColor('#52606D');
            Text('xdremux ' + this.coreVersion)
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .fontColor('#18202A')
              .margin({ top: 4 });
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(14)
          .margin({ bottom: 14 });

          Text('输出设置（每个项目在实际开始时获取已保存设置快照）')
            .fontSize(14)
            .fontColor('#52606D')
            .width('100%');
          Row() {
            Text(this.settingsLoaded ? this.savedSettingsSummary() :
              (this.settingsLoading ? '设置加载中…' : '设置不可用'))
              .fontSize(15)
              .fontColor('#18202A')
              .layoutWeight(1);
            Button('打开设置')
              .fontSize(14)
              .fontColor('#FFFFFF')
              .backgroundColor('#2E6BD6')
              .enabled(this.settingsLoaded && !this.settingsSaving)
              .onClick(() => {
                this.openSettings();
              });
          }
          .width('100%')
          .margin({ top: 8, bottom: 8 });
          if (this.settingsWarning.length > 0) {
            Text(this.settingsWarning)
              .fontSize(12)
              .fontColor('#A15C00')
              .width('100%')
              .margin({ bottom: 6 });
          }
          if (this.settingsError.length > 0 && !this.settingsOpen) {
            Text(this.settingsError)
              .fontSize(13)
              .fontColor('#B3261E')
              .width('100%')
              .margin({ bottom: 6 });
          }
          if (!this.settingsLoaded && !this.settingsLoading) {
            Button('重试加载设置')
              .fontSize(14)
              .fontColor('#18202A')
              .backgroundColor('#DDE5EE')
              .width('100%')
              .height(42)
              .onClick(() => {
                this.loadSettings();
              });
          }
          if (this.settingsOpen) {
            this.settingsPanel();
          }

          if (this.queueLoading) {
            Text('正在校验并恢复队列记录…')
              .fontSize(13)
              .fontColor('#52606D')
              .width('100%')
              .margin({ top: 8, bottom: 8 });
          }
          if (this.queueRecoveryRequired) {
            Text(this.queueWarning.length > 0 ? this.queueWarning :
              '队列记录无法安全读取；不会自动删除或覆盖原记录。')
              .fontSize(13)
              .fontColor('#A15C00')
              .width('100%')
              .margin({ top: 8, bottom: 6 });
            Row() {
              Button('备份并新建空队列')
                .fontSize(14)
                .fontColor('#FFFFFF')
                .backgroundColor('#A15C00')
                .layoutWeight(1)
                .height(44)
                .enabled(!this.pageBusy && !this.queueLoading && !this.cleanupRunning)
                .onClick(() => {
                  this.recoverQueueRecord();
                });
              Button('重试读取')
                .fontSize(14)
                .fontColor('#18202A')
                .backgroundColor('#DDE5EE')
                .layoutWeight(1)
                .height(44)
                .margin({ left: 8 })
                .enabled(!this.pageBusy && !this.queueLoading && !this.cleanupRunning)
                .onClick(() => {
                  this.queueRestoreStarted = false;
                  this.restoreQueueSession();
                });
            }
            .width('100%')
            .margin({ bottom: 10 });
          }
          if (this.queueError.length > 0 && !this.queueRecoveryRequired) {
            Text(this.queueError)
              .fontSize(13)
              .fontColor('#B3261E')
              .width('100%')
              .margin({ top: 6, bottom: 6 });
            Button('重试保存队列记录')
              .fontSize(14)
              .fontColor('#18202A')
              .backgroundColor('#DDE5EE')
              .width('100%')
              .height(42)
              .enabled(this.queueLoaded && !this.queueLoading && !this.queueRunning &&
                !this.pageBusy && !this.cleanupRunning)
              .onClick(() => {
                this.retryQueuePersistence();
              });
          }

          Text(this.cacheUsage)
            .fontSize(12)
            .fontColor('#52606D')
            .width('100%')
            .margin({ top: 8 });
          Button(this.cleanupRunning ? '清理沙盒中…' : '清理未引用沙盒文件')
            .fontSize(13)
            .fontColor('#18202A')
            .backgroundColor('#DDE5EE')
            .width('100%')
            .height(42)
            .enabled(this.queueLoaded && this.queueReady && !this.queueRecoveryRequired &&
              !this.pageBusy && !this.queueRunning && !this.settingsSaving && !this.cleanupRunning &&
              !this.queuePersistenceFailed())
            .onClick(() => {
              this.cleanupOrphanFiles();
            });
          Text('清理只处理本应用 inputs/outputs 中未被队列引用的产物；导出的系统文件和原始 URI 不会删除。')
            .fontSize(12)
            .fontColor('#52606D')
            .width('100%')
            .margin({ bottom: 8 });

          Button('选择多个照片并加入队列')
            .fontSize(17)
            .fontColor('#FFFFFF')
            .backgroundColor('#1F5FBF')
            .width('100%')
            .height(52)
            .enabled(this.queueLoaded && this.queueReady && !this.queueLoading &&
              !this.queueRecoveryRequired && !this.queuePersistenceFailed() &&
              !this.pageBusy && !this.queueRunning)
            .onClick(() => {
              this.chooseAndImport();
            });

          Row() {
            Button(this.queueRunning ? '处理中…' : '开始 / 继续队列')
              .fontSize(16)
              .fontColor('#FFFFFF')
              .backgroundColor('#16845B')
              .layoutWeight(1)
              .height(48)
              .enabled(this.queueLoaded && this.queueReady && !this.queueLoading &&
                !this.queueRecoveryRequired && !this.queuePersistenceFailed() &&
                !this.pageBusy && !this.queueRunning && this.queueItems.length > 0)
              .onClick(() => {
                this.startQueue();
              });
            Button('停止（当前完成后）')
              .fontSize(15)
              .fontColor('#18202A')
              .backgroundColor('#DDE5EE')
              .layoutWeight(1)
              .height(48)
              .margin({ left: 10 })
              .enabled(this.queueRunning && !this.cleanupRunning)
              .onClick(() => {
                this.stopQueue();
              });
          }
          .width('100%')
          .margin({ top: 10 });

          Row() {
            Button(this.batchExportRunning ? '批量导出中…' : '批量导出未导出结果')
              .fontSize(15)
              .fontColor('#FFFFFF')
              .backgroundColor('#2E6BD6')
              .layoutWeight(1)
              .height(46)
              .enabled(this.queueLoaded && this.queueReady && !this.queueLoading &&
                !this.queueRecoveryRequired && !this.queuePersistenceFailed() &&
                !this.pageBusy && !this.queueRunning && !this.cleanupRunning &&
                !this.settingsSaving && !this.batchExportRunning)
              .onClick(() => {
                this.startBatchExport();
              });
            Button('停止后续批量导出')
              .fontSize(14)
              .fontColor('#18202A')
              .backgroundColor('#DDE5EE')
              .layoutWeight(1)
              .height(46)
              .margin({ left: 10 })
              .enabled(this.batchExportRunning)
              .onClick(() => {
                this.stopBatchExport();
              });
          }
          .width('100%')
          .margin({ top: 10 });

          if (this.batchExportEntries.length > 0) {
            Text(this.batchExportSummaryText())
              .fontSize(13)
              .fontColor('#18202A')
              .width('100%')
              .margin({ top: 8, bottom: 6 });
            Text('系统可能会先创建空目标文件；写入失败时不会自动删除用户选择的位置，沙盒结果仍可重试导出。')
              .fontSize(11)
              .fontColor('#52606D')
              .width('100%')
              .margin({ bottom: 6 });
            ForEach(this.batchExportEntries, (entry: BatchExportEntry) => {
              Column() {
                Row() {
                  Text(entry.displayName)
                    .fontSize(14)
                    .fontColor('#18202A')
                    .layoutWeight(1);
                  Text(this.batchExportStatusLabel(entry))
                    .fontSize(12)
                    .fontColor(entry.status === 'failed' || entry.status === 'journal-failed' ?
                      '#B3261E' : (entry.exported ? '#16845B' : '#52606D'));
                }
                Text(entry.fileName)
                  .fontSize(11)
                  .fontColor('#52606D')
                  .width('100%')
                  .margin({ top: 3 });
                if (entry.errorMessage.length > 0) {
                  Text(entry.errorMessage)
                    .fontSize(11)
                    .fontColor('#B3261E')
                    .width('100%')
                    .margin({ top: 3 });
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding(10)
              .backgroundColor('#FFFFFF')
              .borderRadius(8)
              .margin({ bottom: 6 });
            }, (entry: BatchExportEntry) => entry.id + '-' + entry.fileName + '-' + entry.status + '-' +
              String(entry.copySucceeded) + '-' + String(entry.exported));
          }

          Text(this.operationStatus)
            .fontSize(15)
            .fontColor('#18202A')
            .width('100%')
            .margin({ top: 14, bottom: 8 });
          Text('队列项目：' + String(this.queueItems.length) +
            ' · 关键状态会保存；重启后需手动继续，转换仅在前台运行')
            .fontSize(13)
            .fontColor('#52606D')
            .width('100%')
            .margin({ bottom: 10 });

          if (this.queueItems.length === 0) {
            Text('尚未加入照片')
              .fontSize(16)
              .fontColor('#52606D')
              .width('100%');
          } else {
            Text('项目列表（点击项目查看详情）')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#18202A')
              .width('100%')
              .margin({ bottom: 8 });
            ForEach(this.queueItems, (item: QueueItem) => {
              Row() {
                Column() {
                  Text(item.displayName)
                    .fontSize(15)
                    .fontColor('#18202A')
                    .width('100%');
                  Text(this.statusLabel(item) +
                    (item.lastAttemptModeLabel.length > 0 ? ' · ' + item.lastAttemptModeLabel : ''))
                    .fontSize(13)
                    .fontColor(item.status === 'failed' ? '#B3261E' : '#52606D')
                    .width('100%')
                    .margin({ top: 4 });
                  if (item.status === 'running' || item.progress.current > 0 || item.progress.total > 0) {
                    Text(this.progressStageLabel(item.progress.stage) + '：' +
                      String(item.progress.current) + ' / ' + String(item.progress.total))
                      .fontSize(12)
                      .fontColor('#52606D')
                      .width('100%')
                      .margin({ top: 3 });
                  }
                  if (item.errorMessage.length > 0) {
                    Text(item.errorMessage)
                      .fontSize(12)
                      .fontColor('#B3261E')
                      .width('100%')
                      .margin({ top: 3 });
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);
                Text(item.id === this.activeItemId ? '当前' : (item.id === this.selectedItemId ? '已选' : ''))
                  .fontSize(13)
                  .fontColor('#2E6BD6');
              }
              .width('100%')
              .padding(12)
              .backgroundColor(item.id === this.selectedItemId ? '#E7F0FF' : '#FFFFFF')
              .borderRadius(10)
              .margin({ bottom: 8 })
              .onClick(() => {
                this.selectQueueItem(item.id);
              });
            }, (item: QueueItem) => item.id + '-' + String(item.revision));
          }

          if (this.selectedItem() !== undefined) {
            this.selectedDetails();
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 24, right: 24, top: 28, bottom: 24 });
      }
      .layoutWeight(1)
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F7FA');
  }
}
