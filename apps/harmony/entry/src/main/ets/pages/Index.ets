import { Available, deviceInfo } from '@kit.BasicServicesKit';
import { ColorMetrics, LengthMetrics, SymbolGlyphModifier, uiMaterial, window } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import {
  BlurStrategy,
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsAnimationMode,
  HdsBarStyle,
  HdsTabs,
  HdsTabsController,
  bleedIconStyle,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import { fileIo } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
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
import { HarmonyShareInbox, getHarmonyShareInbox } from '../queue/HarmonyShareInbox';
import { persistQueueBeforeInboxRemoval } from '../queue/ShareImportModel';
import type { ShareInboxItem } from '../queue/ShareImportModel';
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
import {
  buildMotionSplitPathPlan,
  runMotionSplitPipeline
} from '../queue/MotionPhotoSplitModel';
import type {
  MotionPhotoSplitAsset,
  MotionPhotoSplitResult,
  MotionSplitFileStat,
  MotionSplitPathPlan
} from '../queue/MotionPhotoSplitModel';
import {
  buildLivePhotoPairPathPlan,
  runLivePhotoPairPipeline
} from '../queue/LivePhotoPairModel';
import type {
  LivePhotoFileStat,
  LivePhotoPairPathPlan,
  LivePhotoPairResult
} from '../queue/LivePhotoPairModel';
import {
  attachLivePhotoExportTargets,
  buildLivePhotoExportPlan,
  runLivePhotoPairExport,
  summarizeLivePhotoExport
} from '../queue/LivePhotoPairExport';
import type { LivePhotoExportEntry } from '../queue/LivePhotoPairExport';
import { ps3OptionsFor } from '../queue/Ps3Model';
import { HarmonyGalleryLibrary } from '../gallery/HarmonyGalleryLibrary';
import {
  galleryMimeTypeForExtension,
  galleryItemPath
} from '../gallery/GalleryLibraryModel';
import type { GalleryLibraryItem } from '../gallery/GalleryLibraryModel';

interface NativeError {
  message?: string;
  code?: number;
}

interface GalleryPhotoTile {
  item: GalleryLibraryItem;
  path: string;
}

class GalleryPhotoDataSource implements IDataSource {
  private items: Array<GalleryPhotoTile> = [];
  private listeners: Array<DataChangeListener> = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): GalleryPhotoTile {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }

  replaceAll(items: Array<GalleryPhotoTile>): void {
    this.items = items.slice();
    this.listeners.forEach((listener: DataChangeListener): void => {
      listener.onDataReloaded();
    });
  }
}

interface GalleryPhotoInspection {
  details: NativePhotoDetails;
  classification: NativeClassificationResult;
  displayImageWidth: number;
  displayImageHeight: number;
}

const TRANSPARENT_SYSTEM_BAR_COLOR: string = '#00000000';
const GALLERY_DETAIL_BAR_HEIGHT: number = 56;
const GALLERY_DETAIL_BAR_BOTTOM_MARGIN: number = 28;
const GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT: number = 92;
const GALLERY_DETAIL_PANEL_HANDLE_HEIGHT: number = 36;
const GALLERY_DETAIL_PANEL_BOTTOM_INSET: number = GALLERY_DETAIL_BAR_BOTTOM_MARGIN;
const GALLERY_DETAIL_PANEL_TOP_CLEARANCE: number = 120;
const GALLERY_DETAIL_PANEL_CONTENT_CLEARANCE: number = 48;
const GALLERY_DETAIL_PANEL_SNAP_DRAG_THRESHOLD: number = 32;
const GALLERY_DETAIL_PANEL_FLICK_OFFSET_THRESHOLD: number = 12;
const GALLERY_DETAIL_PANEL_FLICK_VELOCITY_THRESHOLD: number = 450;
const GALLERY_DETAIL_THUMBNAIL_STRIP_HEIGHT: number = 74;
const GALLERY_DETAIL_THUMBNAIL_GAP: number = 10;
const GALLERY_THUMBNAIL_CACHE_LIMIT: number = 96;
const GALLERY_THUMBNAIL_DECODE_WIDTH: number = 200;
const GALLERY_THUMBNAIL_DECODE_HEIGHT: number = 240;

class QueueHeicCompatibleCapability implements photoAccessHelper.AssetCompatibleCapability {
  supportedHighResolution: boolean = true;
  supportedMimeType: Array<string> = ['image/heic'];
}

class OriginalPhotoSelectOptions extends photoAccessHelper.PhotoSelectOptions {
  // CURRENT is 1 in API 26. Keep the value numeric so older API runtimes can
  // ignore this extension field without resolving the API-26 enum at startup.
  preferredCompatibleMode: number = 1;
  assetCompatibleCapability: QueueHeicCompatibleCapability = new QueueHeicCompatibleCapability();
}

@Entry
@Component
struct Index {
  @State private coreVersion: string = '加载中…';
  @State private operationStatus: string = '准备就绪';
  @State private settingsLoaded: boolean = false;
  @State private settingsLoading: boolean = true;
  @State private settingsSaving: boolean = false;
  @State private settingsWarning: string = '';
  @State private settingsError: string = '';
  @State private committedSettingsView: NativeSettings = cloneSettings(DEFAULT_SETTINGS);
  @State private draftOutputMode: SettingsOutputMode = 'oppo';
  @State private draftOppoCompat: number = DEFAULT_SETTINGS.oppoCompat;
  @State private draftOppoCameraTail: number = DEFAULT_SETTINGS.oppoCameraTail;
  @State private draftStrictTmap: boolean = DEFAULT_SETTINGS.strictTmap;
  @State private draftApplePhotographicStyles: boolean = DEFAULT_SETTINGS.applePhotographicStyles;
  @State private draftApplePhotographicStyles3: boolean = DEFAULT_SETTINGS.applePhotographicStyles3;
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
  @State private motionSplitResult: MotionPhotoSplitResult | undefined = undefined;
  @State private motionSplitting: boolean = false;
  @State private motionSplittingItemId: string = '';
  @State private livePhotoPairing: boolean = false;
  @State private livePhotoPairExporting: boolean = false;
  @State private livePhotoPairResult: LivePhotoPairResult | undefined = undefined;
  @State private livePhotoPairExportEntries: Array<LivePhotoExportEntry> = [];
  @State private mainTabIndex: number = 1;
  @State private galleryDetailVisible: boolean = false;
  @State private galleryDetailMounted: boolean = false;
  @State private galleryHeroPreloadPending: boolean = false;
  @State private galleryHeroPreloadItemId: string = '';
  @State private galleryHeroPlaceholderReady: boolean = false;
  @State private galleryHeroMetadataReady: boolean = false;
  @State private galleryHeroTransitionActive: boolean = false;
  @State private galleryHeroOpening: boolean = false;
  @State private galleryPhotoTitleTopPosition: number = 47;
  @State private galleryDisplayImageWidth: number = 0;
  @State private galleryDisplayImageHeight: number = 0;
  @State private galleryZoomScale: number = 1;
  @State private galleryPanOffsetX: number = 0;
  @State private galleryPanOffsetY: number = 0;
  @State private galleryDismissOffsetY: number = 0;
  @State private galleryViewportWidth: number = 0;
  @State private galleryViewportHeight: number = 0;
  @State private galleryInfoPanelVisible: boolean = false;
  @State private galleryChromeVisible: boolean = true;
  @State private galleryPanelHeight: number = GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT;
  @State private galleryPanelMode: 'info' | 'settings' = 'info';
  @State private galleryPhotoSettingsId: string = '';
  @State private galleryPhotoSettingsView: NativeSettings = cloneSettings(DEFAULT_SETTINGS);
  @State private galleryPhotos: Array<GalleryPhotoTile> = [];
  @State private galleryLoadedPreviewIds: Array<string> = [];
  @State private galleryDetailLoadedImageId: string = '';
  @State private galleryCachedThumbnailIds: Array<string> = [];
  @State private galleryThumbnailDecodeFailedIds: Array<string> = [];
  @State private gallerySdrCompareHolding: boolean = false;
  @State private gallerySdrCompareLoading: boolean = false;
  @State private gallerySdrCompareActive: boolean = false;
  @State private gallerySdrPreviewPixelMap: image.PixelMap | undefined = undefined;
  @State private galleryMediaCount: number = 0;
  @State private galleryLoading: boolean = true;
  @State private galleryLibraryReady: boolean = false;
  @State private galleryLoadError: string = '';
  @State private galleryImporting: boolean = false;
  @State private importMiniBarExpanded: boolean = false;
  @State private supportsHdsImmersiveMaterial: boolean = false;
  @State private galleryQueuePreparing: boolean = false;
  @State private galleryQueueItemId: string = '';
  @State private galleryStatus: string = '选择一张照片查看信息并开始转换';
  @State private galleryMimeType: string = '';
  @State private gallerySandboxPath: string = '';
  @State private galleryCopiedBytes: number = 0;
  @State private galleryCurrentItem: GalleryLibraryItem | undefined = undefined;
  @State private galleryDetails: NativePhotoDetails | undefined = undefined;
  @State private galleryClassification: NativeClassificationResult | undefined = undefined;

  private queueController: QueueController | undefined = undefined;
  private queueStore: QueueStateStore | undefined = undefined;
  private queueSandbox: HarmonyQueueSandbox | undefined = undefined;
  private shareInbox: HarmonyShareInbox | undefined = undefined;
  private shareInboxUnsubscribe: (() => void) | undefined = undefined;
  private shareDrainInFlight: boolean = false;
  private shareDrainWakePending: boolean = false;
  private pageVisible: boolean = false;
  private queueRestoreStarted: boolean = false;
  private queueRestoreInFlight: boolean = false;
  private readonly settingsStore: SettingsStore = new SettingsStore();
  private readonly galleryScrollController: Scroller = new Scroller();
  private readonly queueScrollController: Scroller = new Scroller();
  private readonly settingsScrollController: Scroller = new Scroller();
  private galleryLibrary: HarmonyGalleryLibrary | undefined = undefined;
  private tabsController: HdsTabsController | undefined = undefined;
  private committedSettings: NativeSettings = cloneSettings(DEFAULT_SETTINGS);
  private readonly galleryPhotoSettings: Map<string, NativeSettings> = new Map<string, NativeSettings>();
  private readonly galleryInspectionCache: Map<string, GalleryPhotoInspection> =
    new Map<string, GalleryPhotoInspection>();
  private readonly galleryDecodedDimensionsCache: Map<string, Array<number>> = new Map<string, Array<number>>();
  private readonly galleryThumbnailPixelMapCache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private readonly galleryDetailDecodedImageIds: Set<string> = new Set<string>();
  private readonly galleryThumbnailDecodeInFlight: Set<string> = new Set<string>();
  private readonly gallerySwiperDataSource: GalleryPhotoDataSource = new GalleryPhotoDataSource();
  private readonly galleryDetailSwiperController: SwiperController = new SwiperController();
  private readonly galleryThumbnailScroller: Scroller = new Scroller();
  private inputSerial: number = 0;
  private outputSerial: number = 0;
  private motionSplitSerial: number = 0;
  private livePhotoPairSerial: number = 0;
  private batchExportSerial: number = 0;
  private galleryPinchStartScale: number = 1;
  private galleryPinchStartPanX: number = 0;
  private galleryPinchStartPanY: number = 0;
  private galleryPinchCenterX: number = 0.5;
  private galleryPinchCenterY: number = 0.5;
  private galleryPanStartX: number = 0;
  private galleryPanStartY: number = 0;
  @State private galleryInfoPanelContentHeight: number = 0;
  @State private galleryInfoPanelScrollViewportHeight: number = 0;
  private galleryPanelDragStartHeight: number = GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT;
  private galleryPanelBodyDragStartHeight: number = GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT;
  private galleryPanelBodyDragActive: boolean = false;
  private galleryPanelBodyDragVertical: boolean = false;
  private galleryPageGestureAxis: 'none' | 'horizontal' | 'vertical' = 'none';
  private galleryPagePanBlockedByPanel: boolean = false;
  private galleryPanBlockedByInfoPanel: boolean = false;
  private galleryPinchBlockedByInfoPanel: boolean = false;
  private galleryGestureAxis: 'none' | 'horizontal' | 'vertical' = 'none';
  private gallerySelectionSerial: number = 0;
  private galleryDetailSelectionUsesDelayedReveal: boolean = false;
  private gallerySdrDecodeSerial: number = 0;
  private gallerySdrPreviewItemId: string = '';
  private galleryChromeToggleBlockedUntil: number = 0;
  private galleryStatusBarResetTimer: number = -1;
  private galleryStatusBarUpdate: Promise<void> = Promise.resolve();
  private galleryHeroBackdropResetTimer: number = -1;
  private galleryDetailImageRevealTimer: number = -1;
  private readonly queuePhotoPickerOptions: OriginalPhotoSelectOptions = new OriginalPhotoSelectOptions();
  private readonly galleryPhotoPickerOptions: OriginalPhotoSelectOptions = new OriginalPhotoSelectOptions();
  private batchPickerActive: boolean = false;
  private batchPageShowWaiters: Array<(visible: boolean) => void> = [];
  private readonly motionInspectionCache: Map<string, MotionPhotoInspection> =
    new Map<string, MotionPhotoInspection>();
  private readonly motionSplitCache: Map<string, MotionPhotoSplitResult> =
    new Map<string, MotionPhotoSplitResult>();
  private readonly livePhotoPairCache: Map<string, LivePhotoPairResult> = new Map<string, LivePhotoPairResult>();
  private livePhotoPairExportKey: string = '';
  private livePhotoPairItemId: string = '';

  aboutToAppear(): void {
    this.pageVisible = true;
    void this.updateGalleryPhotoTitlePosition();
    if (this.shouldUseImmersiveMainChrome()) {
      this.updateHdsImmersiveMaterialSupport();
    }
    this.queuePhotoPickerOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    this.queuePhotoPickerOptions.maxSelectNumber = 500;
    this.galleryPhotoPickerOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    this.galleryPhotoPickerOptions.maxSelectNumber = 200;
    this.refreshVersion();
    this.loadSettings();
    void this.loadGalleryLibrary();
    this.restoreQueueSession();
  }

  onBackPress(): boolean {
    if (this.galleryHeroPreloadPending) {
      this.galleryHeroPreloadPending = false;
      this.galleryHeroPreloadItemId = '';
      this.galleryHeroPlaceholderReady = false;
      this.galleryHeroMetadataReady = false;
      this.galleryHeroOpening = false;
      this.gallerySelectionSerial += 1;
      return true;
    }
    if (!this.galleryDetailVisible) {
      return this.galleryDetailMounted;
    }
    if (this.galleryPanelMode === 'settings') {
      this.galleryPanelMode = 'info';
      return true;
    }
    this.closeGalleryDetail();
    return true;
  }

  onPageShow(): void {
    // Returning to the foreground only reattaches the view. A stopped queue
    // requires an explicit Start/Resume click so no later native work starts
    // silently after a foreground transition.
    this.pageVisible = true;
    this.ensureGalleryStatusBarVisible();
    this.attachShareInbox();
    this.attachQueueSession();
    this.requestShareInboxDrain();
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
    this.ensureGalleryStatusBarVisible();
    this.endGallerySdrCompare();
    // Page teardown is a real departure, unlike the temporary hide caused by
    // the system picker. Finish the current copy and stop later batch items.
    if (this.batchExportRunning) {
      this.batchExportStopRequested = true;
    }
    this.resolveBatchPageShowWaiters(false);
    this.detachShareInbox();
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
    this.draftApplePhotographicStyles3 = snapshot.applePhotographicStyles3;
    this.draftApplePortrait = snapshot.applePortrait;
  }

  private draftSettings(): NativeSettings {
    return {
      outputMode: this.draftOutputMode,
      oppoCompat: this.draftOppoCompat,
      oppoCameraTail: this.draftOppoCameraTail,
      strictTmap: this.draftStrictTmap,
      applePhotographicStyles: this.draftApplePhotographicStyles,
      applePhotographicStyles3: this.draftApplePhotographicStyles3,
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

  private onMainTabChange(index: number): void {
    if (index !== this.mainTabIndex && this.importMiniBarExpanded &&
      deviceInfo.sdkApiVersion >= 26 && deviceInfo.apiAvailable('26.0.0')) {
      this.setImportMiniBarExpanded(false);
    }
    this.mainTabIndex = index;
    if (index === 2 && this.settingsLoaded && !this.settingsSaving) {
      this.settingsError = '';
    }
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
      this.draftApplePhotographicStyles3 = false;
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
      this.draftApplePhotographicStyles3 = false;
      this.draftApplePortrait = false;
    } else if (this.draftApplePhotographicStyles || this.draftApplePhotographicStyles3 ||
      this.draftApplePortrait) {
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
    this.draftApplePhotographicStyles3 = false;
    this.draftApplePortrait = false;
    this.settingsError = '';
  }

  private setDraftAppleStyles(enabled: boolean): void {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    this.draftApplePhotographicStyles = enabled;
    // PS3 depends on the 2023 styles graph. Keeping the base toggle on avoids
    // a draft that visually disagrees with the normalized native snapshot.
    if (!enabled && this.draftApplePhotographicStyles3) {
      this.draftApplePhotographicStyles = true;
    }
    if (enabled) {
      this.draftOutputMode = 'apple';
      this.draftOppoCompat = 0;
      this.draftOppoCameraTail = 0;
    }
    this.settingsError = '';
  }

  private setDraftAppleStyles3(enabled: boolean): void {
    if (!this.settingsLoaded || this.settingsSaving) {
      return;
    }
    this.draftApplePhotographicStyles3 = enabled;
    if (enabled) {
      this.draftOutputMode = 'apple';
      this.draftOppoCompat = 0;
      this.draftOppoCameraTail = 0;
      this.draftApplePhotographicStyles = true;
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
      this.shareInbox = getHarmonyShareInbox(root);
      this.attachShareInbox();
      this.shareDrainWakePending = true;
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
      if (this.queueReady) this.shareDrainWakePending = true;
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
      this.shareDrainWakePending = true;
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
      if (this.shareInbox !== undefined) {
        for (const incoming of await this.shareInbox.pending()) {
          if (incoming.inputPath.length > 0) referenced.add(incoming.inputPath);
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

  private attachShareInbox(): void {
    if (this.shareInbox === undefined || this.shareInboxUnsubscribe !== undefined) return;
    this.shareInboxUnsubscribe = this.shareInbox.subscribe((): void => this.requestShareInboxDrain());
  }

  private detachShareInbox(): void {
    if (this.shareInboxUnsubscribe !== undefined) {
      this.shareInboxUnsubscribe();
      this.shareInboxUnsubscribe = undefined;
    }
  }

  private requestShareInboxDrain(): void {
    this.shareDrainWakePending = true;
    this.scheduleShareInboxDrain();
  }

  private scheduleShareInboxDrain(): void {
    const controller: QueueController | undefined = this.queueController;
    if (!this.shareDrainWakePending || this.shareInbox === undefined || !this.pageVisible ||
      !this.queueLoaded || !this.queueReady || this.queueRecoveryRequired || this.queueLoading ||
      this.pageBusy || this.queueRunning || this.cleanupRunning || this.batchExportRunning ||
      this.settingsSaving || (controller !== undefined && controller.hasPersistenceError) ||
      this.shareDrainInFlight) {
      return;
    }
    this.shareDrainWakePending = false;
    void this.drainShareInbox();
  }

  private async drainShareInbox(): Promise<void> {
    const inbox: HarmonyShareInbox | undefined = this.shareInbox;
    if (inbox === undefined || this.shareDrainInFlight || !this.queueReady || this.queueRecoveryRequired) {
      this.shareDrainWakePending = true;
      return;
    }
    this.shareDrainInFlight = true;
    this.pageBusy = true;
    try {
      const controller: QueueController = this.getController();
      const incomingItems: Array<ShareInboxItem> = await inbox.pending();
      let imported: number = 0;
      let failed: number = 0;
      for (const incoming of incomingItems) {
        const alreadyQueued: QueueItem | undefined = controller.items().find((item: QueueItem): boolean =>
          item.sourceToken === incoming.id ||
          (incoming.inputPath.length > 0 && item.inputPath === incoming.inputPath));
        if (alreadyQueued !== undefined) {
          // The queue journal wins after a crash between its commit and inbox
          // removal. The file is already queue-owned, so forget metadata only.
          // Re-check durable queue ownership before dropping the inbox row;
          // an in-memory item after a failed journal write is not a handoff.
          await persistQueueBeforeInboxRemoval(
            async (): Promise<void> => controller.persist(),
            async (): Promise<void> => inbox.remove(incoming.id)
          );
          continue;
        }
        const ready: boolean = incoming.status === 'ready' && incoming.inputPath.length > 0;
        const queued: QueueItem = controller.add({
          displayName: incoming.displayName,
          // Once copied, the owned sandbox path is the durable source identity;
          // only failed copies retain the temporary external share URI for retry.
          sourceUri: ready ? incoming.inputPath : incoming.sourceUri,
          sourceKind: 'share',
          sourceToken: incoming.id,
          inputPath: ready ? incoming.inputPath : undefined
        });
        if (this.selectedItemId.length === 0) this.selectQueueItem(queued.id);
        controller.beginExternal(queued.id);
        try {
          if (!ready && incoming.inputPath.length > 0) {
            controller.registerOwnedPath(queued.id, incoming.inputPath);
          }
          // Persist queue ownership before Rust inspection or removing the
          // inbox row. Failed queue saves leave the staged copy retryable.
          try {
            await persistQueueBeforeInboxRemoval(
              async (): Promise<void> => controller.persist(),
              async (): Promise<void> => inbox.remove(incoming.id)
            );
          } catch (error) {
            if (controller.hasPersistenceError || error instanceof QueuePersistenceError) {
              throw new Error(this.errorMessage(error));
            }
            // A later startup reconciles by sourceToken/path without unlinking.
          }
          if (!ready) {
            controller.markPreparationFailed(queued.id, incoming.errorMessage.length > 0
              ? incoming.errorMessage
              : '分享导入未完成，请重新分享图片或在应用内重新选择照片。');
            failed += 1;
          } else {
            const detailsJson: string = await xdremuxNative.inspect(incoming.inputPath);
            const details: NativePhotoDetails = JSON.parse(detailsJson) as NativePhotoDetails;
            if (!details.success) throw new Error(this.display(details.errorMessage));
            const classification: NativeClassificationResult =
              await xdremuxNative.classify(incoming.inputPath) as NativeClassificationResult;
            controller.setPrepared(queued.id, incoming.inputPath, details, classification);
            imported += 1;
          }
          await controller.persist();
        } catch (error) {
          if (controller.hasPersistenceError || error instanceof QueuePersistenceError) {
            throw new Error(this.errorMessage(error));
          }
          controller.markPreparationFailed(queued.id, this.errorMessage(error));
          failed += 1;
          await controller.persist();
        } finally {
          controller.endExternal(queued.id);
        }
      }
      const notice: string = await inbox.takeNotice();
      if (incomingItems.length > 0) {
        this.operationStatus = '系统分享已加入队列：成功 ' + String(imported) + '，失败 ' + String(failed) +
          '；失败项目可重试或删除';
      } else if (notice.length > 0) {
        this.operationStatus = notice;
      }
      this.syncQueue();
      await this.refreshCacheUsage();
    } catch (error) {
      this.operationStatus = '系统分享暂未加入队列：' + this.errorMessage(error) +
        '；可以重新分享，或在应用内重新选择照片';
      if (this.queueController?.hasPersistenceError !== true) this.shareDrainWakePending = false;
    } finally {
      this.pageBusy = false;
      this.shareDrainInFlight = false;
      this.syncQueue();
      this.scheduleShareInboxDrain();
    }
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
    for (const key of this.motionSplitCache.keys()) {
      if (!validMotionKeys.has(key)) {
        this.motionSplitCache.delete(key);
      }
    }
    const validPairKeys: Set<string> = new Set<string>();
    for (const item of this.queueItems) {
      const pairKey: string = this.livePhotoPairCacheKey(item);
      if (pairKey.length > 0) validPairKeys.add(pairKey);
    }
    for (const key of this.livePhotoPairCache.keys()) {
      if (!validPairKeys.has(key)) this.livePhotoPairCache.delete(key);
    }
    this.syncMotionSelection();
    this.scheduleShareInboxDrain();
  }

  private selectedItem(): QueueItem | undefined {
    return this.queueItems.find((item: QueueItem): boolean => item.id === this.selectedItemId);
  }

  private motionCacheKey(item: QueueItem): string {
    return item.id + '\u0000' + item.inputPath;
  }

  private livePhotoPairCacheKey(item: QueueItem): string {
    const result: QueueResult | undefined = item.result;
    if (item.inputPath.length === 0 || result === undefined || result.modeKey !== 'apple' ||
      result.sourceInputPath !== item.inputPath || !result.outputPath.endsWith('.heic')) {
      return '';
    }
    return item.id + '\u0000' + item.inputPath + '\u0000' + result.outputPath;
  }

  private syncMotionSelection(): void {
    const item: QueueItem | undefined = this.selectedItem();
    const pairKey: string = item === undefined ? '' : this.livePhotoPairCacheKey(item);
    if (this.livePhotoPairExportKey !== pairKey) {
      this.livePhotoPairExportKey = pairKey;
      this.livePhotoPairExportEntries = [];
    }
    this.livePhotoPairResult = pairKey.length === 0 ? undefined : this.livePhotoPairCache.get(pairKey);
    if (item === undefined || item.inputPath.length === 0) {
      if (this.motionInspectionItemId.length !== 0 || this.motionInspection.inputPath.length !== 0) {
        this.motionInspectionItemId = item === undefined ? '' : item.id;
        this.motionInspection = emptyMotionPhotoInspection();
      }
      this.motionSplitResult = undefined;
      return;
    }
    if (this.motionInspectionItemId === item.id && this.motionInspection.inputPath === item.inputPath) {
      return;
    }
    const cached: MotionPhotoInspection | undefined = this.motionInspectionCache.get(this.motionCacheKey(item));
    const splitCached: MotionPhotoSplitResult | undefined = this.motionSplitCache.get(this.motionCacheKey(item));
    this.motionInspectionItemId = item.id;
    this.motionInspection = cached === undefined
      ? { inputPath: item.inputPath, state: 'unidentified', message: '尚未识别当前输入' }
      : cached;
    this.motionSplitResult = splitCached;
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

  private motionSplitButtonLabel(): string {
    if (!this.motionSplitting) {
      return this.motionSplitResult === undefined ? '拆分 Motion Photo 资源' : '重新拆分 Motion Photo 资源';
    }
    return this.motionSplittingItemId === this.selectedItemId ? '拆分中…' : '拆分中：另一个项目';
  }

  private canMakeLivePhotoPair(): boolean {
    const item: QueueItem | undefined = this.selectedItem();
    return item !== undefined && this.livePhotoPairCacheKey(item).length > 0 &&
      this.motionInspection.state === 'motion' && this.motionInspection.inputPath === item.inputPath &&
      this.motionInspection.report !== undefined;
  }

  private livePhotoPairButtonLabel(): string {
    if (this.livePhotoPairing) {
      return this.livePhotoPairItemId === this.selectedItemId ? 'Live Photo 配对中…' : 'Live Photo 配对中：另一个项目';
    }
    return this.livePhotoPairResult === undefined ? '生成 Live Photo 配对文件' : '重新生成 Live Photo 配对文件';
  }

  private livePhotoExportStatusLabel(entry: LivePhotoExportEntry): string {
    if (entry.status === 'succeeded') return entry.label + '：已写入 ' + entry.targetUri;
    if (entry.status === 'failed') return entry.label + '：写入失败：' + entry.errorMessage;
    return entry.label + '：尚未写入';
  }

  private livePhotoExportSummaryText(): string {
    const summary = summarizeLivePhotoExport(this.livePhotoPairExportEntries);
    return '成对文件写入：' + String(summary.succeeded) + ' / ' + String(summary.total) +
      '；失败 ' + String(summary.failed) + '；待处理 ' + String(summary.waiting);
  }

  private motionSplitAsset(kind: 'still' | 'video' | 'primary'): MotionPhotoSplitAsset | undefined {
    if (this.motionSplitResult === undefined) {
      return undefined;
    }
    return this.motionSplitResult.assets.find((asset: MotionPhotoSplitAsset): boolean => asset.kind === kind);
  }

  private motionSplitAssetDescription(kind: 'still' | 'video' | 'primary'): string {
    const asset: MotionPhotoSplitAsset | undefined = this.motionSplitAsset(kind);
    return asset === undefined ? '' : asset.label + ' · ' + asset.fileName + ' · ' + String(asset.size) + ' 字节';
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

  private async chooseAndImport(
    usePhotoLibraryPicker: boolean = true,
    allowReselectSelectedShare: boolean = true
  ): Promise<void> {
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
    const selectedBeforePicker: QueueItem | undefined = this.selectedItem();
    const reselectingShare: boolean = allowReselectSelectedShare && selectedBeforePicker !== undefined &&
      selectedBeforePicker.sourceKind === 'share' && selectedBeforePicker.status === 'failed' &&
      selectedBeforePicker.inputPath.length === 0;
    const reselectTargetId: string = reselectingShare && selectedBeforePicker !== undefined
      ? selectedBeforePicker.id
      : '';
    this.pageBusy = true;
    this.operationStatus = reselectingShare || !usePhotoLibraryPicker
      ? '正在打开系统文件选择器…'
      : '正在打开图库选择器…';
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('应用上下文不可用');
      }
      let selected: Array<string> = [];
      if (reselectingShare || !usePhotoLibraryPicker) {
        const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
        options.fileSuffixFilters = ['Images|.heic,.heif,.jpg,.jpeg,.png'];
        options.maxSelectNumber = reselectingShare ? 1 : 500;
        const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
        selected = await documentPicker.select(options);
      } else {
        // API 26's original-format preference belongs to queue imports only.
        // Every selected URI is copied into the queue sandbox before Rust sees it.
        const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
        const selection: photoAccessHelper.PhotoSelectResult =
          await photoPicker.select(this.queuePhotoPickerOptions);
        selected = selection.photoUris;
      }
      if (selected.length === 0) {
        this.operationStatus = '未选择照片';
        return;
      }

      if (reselectingShare && reselectTargetId.length > 0) {
        await this.reselectFailedShare(reselectTargetId, selected[0]);
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

  private async reselectFailedShare(itemId: string, sourceUri: string): Promise<void> {
    const controller: QueueController = this.getController();
    const item: QueueItem | undefined = controller.get(itemId);
    if (item === undefined) {
      throw new Error('原分享项目已不存在，请重新选择图片并加入新队列项目');
    }
    controller.beginExternal(itemId);
    try {
      controller.replaceFailedShareSource(itemId, sourceUri);
      await controller.persist();
      const updated: QueueItem | undefined = controller.get(itemId);
      if (updated === undefined) throw new Error('重新选择的队列项目已不存在');
      const prepared: QueuePrepared = await this.prepareQueueItem(updated, true);
      controller.setPrepared(itemId, prepared.inputPath, prepared.details, prepared.classification);
      await controller.persist();
      this.operationStatus = '已重新选择并准备图片；原队列项目已恢复，可开始处理';
    } catch (error) {
      if (controller.hasPersistenceError || error instanceof QueuePersistenceError) {
        throw new Error('队列记录保存失败：' + this.errorMessage(error));
      }
      controller.markPreparationFailed(itemId, this.errorMessage(error));
      await controller.persist();
      throw new Error(this.errorMessage(error));
    } finally {
      controller.endExternal(itemId);
    }
  }

  private async prepareQueueItem(item: QueueItem, allowFreshShareUri: boolean = false): Promise<QueuePrepared> {
    let newPath: string = '';
    try {
      if (item.sourceKind === 'share' && item.inputPath.length === 0 && !allowFreshShareUri) {
        throw new Error('分享授权可能已过期；请使用应用内选择器重新选择图片，不会重试旧 URI');
      }
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
      const detail: string = this.errorMessage(error);
      const message: string = item.sourceKind === 'share' && item.inputPath.length === 0
        ? '无法重新读取分享图片；分享授权可能已过期，请重新分享或在应用内重新选择照片。' +
          (detail.length > 0 ? '（' + detail + '）' : '')
        : detail;
      throw new Error(message);
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
    if (item.sourceKind === 'share' && item.inputPath.length === 0) {
      this.operationStatus = '分享授权可能已过期，不能重试旧 URI。请点“重新选择失效分享图片”恢复当前队列项目';
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
       const destination: string | undefined = await this.exportItem(item, controller);
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

  private async exportItem(item: QueueItem, controller: QueueController): Promise<string | undefined> {
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
    if (saved.length !== 1) {
      throw new Error('单项导出选择器返回多个位置；未写入图片');
    }
    const destinationUri: string = saved[0];
    await copyBatchOutput(
      this.batchFileIo(),
      item.result.outputPath,
      destinationUri,
      item.sourceUri,
      this.batchProtectedPaths(controller)
    );
    return destinationUri;
  }

  private async exportMotionSplitAsset(kind: 'still' | 'video' | 'primary'): Promise<void> {
    if (this.pageBusy || this.batchExportRunning || this.motionSplitting || this.motionInspecting ||
      this.queueRunning || this.cleanupRunning || this.settingsSaving) {
      this.operationStatus = '当前有文件操作正在进行，暂不能导出 Motion Photo 资源';
      return;
    }
    if (!this.queueLoaded || !this.queueReady || this.queueRecoveryRequired) {
      this.operationStatus = '队列记录尚未恢复，暂不能导出 Motion Photo 资源';
      return;
    }
    const item: QueueItem | undefined = this.selectedItem();
    const controller: QueueController | undefined = this.queueController;
    if (item === undefined || controller === undefined) {
      this.operationStatus = '请先选择队列项目';
      return;
    }
    if (controller.hasPersistenceError || controller.isPersistenceBusy || this.queueHasBlockingOperation(controller)) {
      this.operationStatus = '队列仍有未完成文件操作或保存，请稍后重试导出';
      return;
    }
    const cached: MotionPhotoSplitResult | undefined = this.motionSplitCache.get(this.motionCacheKey(item));
    const asset: MotionPhotoSplitAsset | undefined = cached === undefined
      ? undefined
      : cached.assets.find((candidate: MotionPhotoSplitAsset): boolean => candidate.kind === kind);
    if (cached === undefined || cached.inputPath !== item.inputPath || asset === undefined) {
      this.operationStatus = '当前 Motion Photo 资源不可用，请重新拆分';
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.operationStatus = '应用上下文不可用';
      return;
    }
    let locked: boolean = false;
    this.pageBusy = true;
    try {
      controller.beginExternal(item.id);
      locked = true;
      await controller.persist();
      if (this.queueSandbox === undefined) {
        throw new Error('沙盒尚未加载');
      }
      const assetState: QueuePathStatus = await this.queueSandbox.status(asset.path);
      if (assetState !== 'file') {
        throw new Error('拆分资源不可用：' + assetState);
      }
      const assetStat: MotionSplitFileStat = await this.motionSplitStat(asset.path);
      if (assetStat.isSymbolicLink || assetStat.isDirectory || !assetStat.isFile ||
        assetStat.size !== asset.size || assetStat.size <= 0) {
        throw new Error('拆分资源大小或文件类型已变化');
      }
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [asset.fileName];
      options.fileSuffixChoices = [asset.mime + '|' + asset.suffix];
      const saved: Array<string> = await documentPicker.save(options);
      if (saved.length === 0) {
        this.operationStatus = item.displayName + '：未选择导出位置；拆分资源仍保留';
        return;
      }
      if (saved.length !== 1) {
        throw new Error('资源导出选择器返回多个位置；未写入资源');
      }
      await copyBatchOutput(
        this.batchFileIo(),
        asset.path,
        saved[0],
        item.sourceUri,
        this.batchProtectedPaths(controller)
      );
      this.operationStatus = item.displayName + '：' + asset.label + '导出成功；原转换结果状态未改变';
    } catch (error) {
      this.operationStatus = item.displayName + '：' + asset.label + '导出失败：' +
        this.errorMessage(error) + '；拆分资源仍保留，可重试';
    } finally {
      if (locked) {
        controller.endExternal(item.id);
        try {
          await controller.persist();
        } catch (persistError) {
          this.queueError = 'Motion Photo 资源导出结束后队列状态保存失败：' +
            this.errorMessage(persistError) + '；请重试保存';
        }
      }
      this.pageBusy = false;
      this.syncQueue();
    }
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

  private async splitSelectedMotionPhoto(): Promise<void> {
    const controller: QueueController | undefined = this.queueController;
    const item: QueueItem | undefined = this.selectedItem();
    if (this.motionSplitting || this.motionInspecting || this.pageBusy || this.batchExportRunning ||
      this.queueRunning || this.cleanupRunning || this.settingsSaving || !this.settingsLoaded ||
      !this.queueLoaded || !this.queueReady || this.queueLoading || this.queueRecoveryRequired ||
      controller === undefined) {
      this.operationStatus = '当前有操作、设置或队列恢复正在进行，暂不能拆分 Motion Photo';
      return;
    }
    if (controller.hasPersistenceError || controller.isPersistenceBusy || this.queueHasBlockingOperation(controller)) {
      this.operationStatus = '队列仍有未完成文件操作或保存，请稍后重试拆分';
      return;
    }
    if (item === undefined || item.inputPath.length === 0) {
      this.operationStatus = '当前项目还没有可拆分的沙盒输入';
      return;
    }
    if (this.motionInspection.state !== 'motion' || this.motionInspection.report === undefined ||
      this.motionInspection.inputPath !== item.inputPath) {
      this.operationStatus = '请先识别当前输入的 Motion Photo 结构';
      return;
    }
    const context = this.getUIContext().getHostContext();
    const sandbox: HarmonyQueueSandbox | undefined = this.queueSandbox;
    if (context === undefined || sandbox === undefined) {
      this.operationStatus = '应用沙盒尚未加载';
      return;
    }
    const itemId: string = item.id;
    const inputPath: string = item.inputPath;
    const cacheKey: string = this.motionCacheKey(item);
    let locked: boolean = false;
    this.pageBusy = true;
    this.motionSplitting = true;
    this.motionSplittingItemId = itemId;
    this.operationStatus = '正在拆分 Motion Photo：' + item.displayName;
    try {
      controller.beginExternal(itemId);
      locked = true;
      await controller.persist();
      const inputState: QueuePathStatus = await sandbox.status(inputPath);
      if (inputState !== 'file') {
        throw new Error(inputState === 'empty' ? '沙盒输入为空' : '沙盒输入不可用：' + inputState);
      }
      const sourceStat: MotionSplitFileStat = await this.motionSplitStat(inputPath);
      if (!Number.isSafeInteger(sourceStat.size) || sourceStat.size <= 0) {
        throw new Error('沙盒输入大小不是安全的正整数');
      }
      this.motionSplitSerial += 1;
      const plan: MotionSplitPathPlan = buildMotionSplitPathPlan(
        context.filesDir,
        itemId,
        Date.now(),
        this.motionSplitSerial,
        inputPath
      );
      // Protect every path already referenced by every queue item before the
      // attempt allocation is journaled. The production controller repeats
      // the check atomically when registering the five paths.
      controller.assertPathsAvailable(plan.ownedPaths);
      const result: MotionPhotoSplitResult = await runMotionSplitPipeline(
        { plan: plan, sourceInputPath: inputPath, sourceBytes: sourceStat.size },
        {
          status: async (path: string): Promise<'file' | 'empty' | 'missing' | 'unsafe'> => {
            return await sandbox.status(path);
          },
          stat: async (path: string): Promise<MotionSplitFileStat> => {
            return await this.motionSplitStat(path);
          },
          register: (paths: Array<string>): void => {
            controller.registerOwnedPaths(itemId, paths);
          },
          persist: async (): Promise<void> => {
            await controller.persist();
          },
          copy: async (source: string, destination: string): Promise<void> => {
            await this.copySandboxPath(source, destination);
          },
          runSplit: async (input: string, outputDirectory: string): Promise<string> => {
            return await xdremuxNative.motionSplit(input, outputDirectory) as string;
          },
          cleanup: async (paths: Array<string>): Promise<void> => {
            await sandbox.cleanupOwned(paths);
          }
        }
      );
      this.motionSplitCache.set(cacheKey, result);
      if (this.selectedItemId === itemId && this.selectedItem()?.inputPath === inputPath) {
        this.motionSplitResult = result;
      }
      this.operationStatus = result.cleanupWarning.length > 0
        ? 'Motion Photo 已拆分；临时输入清理失败：' + result.cleanupWarning + '，仍保留归属可重试删除'
        : 'Motion Photo 已拆分，可分别导出静态图和视频资源';
    } catch (error) {
      this.operationStatus = item.displayName + '：Motion Photo 拆分失败：' +
        this.errorMessage(error) + '；转换结果未改变，可重试';
    } finally {
      if (locked) {
        controller.endExternal(itemId);
        try {
          await controller.persist();
        } catch (persistError) {
          this.queueError = 'Motion Photo 拆分结束后队列状态保存失败：' +
            this.errorMessage(persistError) + '；请重试保存';
        }
      }
      this.motionSplitting = false;
      this.motionSplittingItemId = '';
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async makeSelectedLivePhotoPair(): Promise<void> {
    const controller: QueueController | undefined = this.queueController;
    const item: QueueItem | undefined = this.selectedItem();
    if (this.livePhotoPairing || this.livePhotoPairExporting || this.motionSplitting || this.motionInspecting ||
      this.pageBusy || this.batchExportRunning || this.queueRunning || this.cleanupRunning || this.settingsSaving ||
      !this.settingsLoaded || !this.queueLoaded || !this.queueReady || this.queueLoading ||
      this.queueRecoveryRequired || controller === undefined) {
      this.operationStatus = '当前有操作、设置或队列恢复正在进行，暂不能生成 Live Photo 配对';
      return;
    }
    if (controller.hasPersistenceError || controller.isPersistenceBusy || this.queueHasBlockingOperation(controller)) {
      this.operationStatus = '队列仍有未完成文件操作或保存，请稍后重试 Live Photo 配对';
      return;
    }
    if (item === undefined || !this.canMakeLivePhotoPair() || this.motionInspection.report === undefined) {
      this.operationStatus = '请先识别当前 Motion Photo，并转换出与该原图绑定的 Apple HEIC 结果';
      return;
    }
    const result: QueueResult | undefined = item.result;
    if (result === undefined || result.modeKey !== 'apple' || result.sourceInputPath !== item.inputPath) {
      this.operationStatus = 'Apple 转换结果不属于当前输入；请重新执行 Apple 转换';
      return;
    }
    const context = this.getUIContext().getHostContext();
    const sandbox: HarmonyQueueSandbox | undefined = this.queueSandbox;
    if (context === undefined || sandbox === undefined) {
      this.operationStatus = '应用沙盒尚未加载';
      return;
    }

    const itemId: string = item.id;
    const sourceInputPath: string = item.inputPath;
    const convertedStillPath: string = result.outputPath;
    const cacheKey: string = this.livePhotoPairCacheKey(item);
    let locked: boolean = false;
    this.pageBusy = true;
    this.livePhotoPairing = true;
    this.livePhotoPairItemId = itemId;
    this.operationStatus = '正在生成 Live Photo HEIC/MOV 配对：' + item.displayName;
    try {
      controller.beginExternal(itemId);
      locked = true;
      await controller.persist();
      if (await sandbox.status(sourceInputPath) !== 'file') throw new Error('Motion Photo 沙盒原图不可用');
      if (await sandbox.status(convertedStillPath) !== 'file') throw new Error('Apple 转换静态图不可用');
      this.livePhotoPairSerial += 1;
      const plan: LivePhotoPairPathPlan = buildLivePhotoPairPathPlan(
        context.filesDir, itemId, Date.now(), this.livePhotoPairSerial, sourceInputPath, convertedStillPath);
      controller.assertPathsAvailable(plan.ownedPaths);
      const paired: LivePhotoPairResult = await runLivePhotoPairPipeline(
        { plan: plan, sourceInputPath: sourceInputPath, convertedStillPath: convertedStillPath },
        {
          status: async (path: string): Promise<'file' | 'empty' | 'missing' | 'unsafe'> => await sandbox.status(path),
          stat: async (path: string): Promise<LivePhotoFileStat> => await this.motionSplitStat(path),
          register: (paths: Array<string>): void => controller.registerOwnedPaths(itemId, paths),
          persist: async (): Promise<void> => await controller.persist(),
          copy: async (source: string, destination: string): Promise<void> =>
            await this.copySandboxPath(source, destination),
          makeLivePhoto: async (source: string, still: string, outputDirectory: string): Promise<string> =>
            await xdremuxNative.livePhotoMake(source, still, outputDirectory) as string,
          pairValid: async (still: string, mov: string): Promise<boolean> =>
            await xdremuxNative.livePhotoPairValid(still, mov) as boolean,
          cleanup: async (paths: Array<string>): Promise<void> => {
            await sandbox.cleanupOwned(paths);
          }
        });
      this.livePhotoPairCache.set(cacheKey, paired);
      if (this.selectedItemId === itemId) {
        const current: QueueItem | undefined = this.selectedItem();
        if (current !== undefined && this.livePhotoPairCacheKey(current) === cacheKey) {
          this.livePhotoPairResult = paired;
        }
      }
      this.operationStatus = paired.cleanupWarning.length > 0
        ? 'Live Photo 配对已生成；临时输入清理失败：' + paired.cleanupWarning + '，仍由队列管理'
        : 'Live Photo HEIC/MOV 配对已生成，Rust 已确认标识匹配；图库导入与 Apple Photos 播放尚未验证';
    } catch (error) {
      this.operationStatus = item.displayName + '：Live Photo 配对失败：' + this.errorMessage(error) +
        '；本次候选单独清理，旧配对和转换结果保留';
    } finally {
      if (locked) {
        controller.endExternal(itemId);
        try {
          await controller.persist();
        } catch (persistError) {
          this.queueError = 'Live Photo 配对结束后队列状态保存失败：' + this.errorMessage(persistError) + '；请重试保存';
        }
      }
      this.livePhotoPairing = false;
      this.livePhotoPairItemId = '';
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async exportSelectedLivePhotoPair(): Promise<void> {
    const controller: QueueController | undefined = this.queueController;
    const item: QueueItem | undefined = this.selectedItem();
    if (this.livePhotoPairExporting || this.livePhotoPairing || this.motionSplitting || this.motionInspecting ||
      this.pageBusy || this.batchExportRunning || this.queueRunning || this.cleanupRunning || this.settingsSaving ||
      controller === undefined || item === undefined) {
      this.operationStatus = '当前有文件操作正在进行，暂不能导出 Live Photo 配对';
      return;
    }
    if (!this.queueLoaded || !this.queueReady || this.queueRecoveryRequired || controller.hasPersistenceError ||
      controller.isPersistenceBusy || this.queueHasBlockingOperation(controller)) {
      this.operationStatus = '队列仍在恢复、保存或执行文件操作，暂不能导出 Live Photo 配对';
      return;
    }
    const cacheKey: string = this.livePhotoPairCacheKey(item);
    const pair: LivePhotoPairResult | undefined = cacheKey.length === 0 ? undefined : this.livePhotoPairCache.get(cacheKey);
    if (pair === undefined || pair.inputPath !== item.inputPath || pair.convertedStillPath !== item.result?.outputPath) {
      this.operationStatus = '当前项目没有与原图及 Apple 转换结果匹配的 Live Photo 配对；请重新生成';
      return;
    }
    const context = this.getUIContext().getHostContext();
    const sandbox: HarmonyQueueSandbox | undefined = this.queueSandbox;
    if (context === undefined || sandbox === undefined) {
      this.operationStatus = '应用沙盒尚未加载';
      return;
    }
    const entries: Array<LivePhotoExportEntry> = buildLivePhotoExportPlan(pair);
    const itemId: string = item.id;
    let locked: boolean = false;
    this.pageBusy = true;
    this.livePhotoPairExporting = true;
    this.livePhotoPairExportEntries = entries;
    this.operationStatus = '正在准备 Live Photo 成对文件导出…';
    try {
      controller.beginExternal(itemId);
      locked = true;
      await controller.persist();
      for (const entry of entries) {
        const state: QueuePathStatus = await sandbox.status(entry.sourcePath);
        if (state !== 'file') throw new Error(entry.label + ' 不可用：' + state);
        const stat: LivePhotoFileStat = await this.motionSplitStat(entry.sourcePath);
        if (stat.isSymbolicLink || stat.isDirectory || !stat.isFile ||
          !Number.isSafeInteger(stat.size) || stat.size <= 0) throw new Error(entry.label + ' 不是非空普通文件');
      }
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = entries.map((entry: LivePhotoExportEntry): string => entry.fileName);
      this.operationStatus = '请选择两个同名 Live Photo 文件的保存位置…';
      this.batchPickerActive = true;
      let saved: Array<string> = [];
      try {
        saved = await documentPicker.save(options);
      } finally {
        this.batchPickerActive = false;
      }
      if (saved.length === 0) {
        this.operationStatus = '已取消 Live Photo 导出；两个文件都未写入';
        return;
      }
      if (!await this.waitForBatchPageShow()) {
        this.livePhotoPairExportEntries = entries.map((entry: LivePhotoExportEntry): LivePhotoExportEntry => ({
          kind: entry.kind,
          label: entry.label,
          sourcePath: entry.sourcePath,
          fileName: entry.fileName,
          targetUri: entry.targetUri,
          status: 'failed',
          errorMessage: '页面未恢复前台，未写入'
        }));
        this.operationStatus = '页面未恢复前台；Live Photo 两个文件都未写入';
        return;
      }
      const protectedPaths: Array<string> = this.batchProtectedPaths(controller);
      const mapped: Array<LivePhotoExportEntry> = attachLivePhotoExportTargets(entries, saved, protectedPaths);
      this.livePhotoPairExportEntries = mapped;
      const completed: Array<LivePhotoExportEntry> = await runLivePhotoPairExport(mapped,
        async (entry: LivePhotoExportEntry): Promise<void> => await copyBatchOutput(
          this.batchFileIo(), entry.sourcePath, entry.targetUri, item.sourceUri, protectedPaths));
      this.livePhotoPairExportEntries = completed;
      const summary = summarizeLivePhotoExport(completed);
      this.operationStatus = 'Live Photo 成对文件写入 ' + String(summary.succeeded) + ' / ' +
        String(summary.total) + '；失败 ' + String(summary.failed) +
        '。两个文件按顺序写入，不具备原子性；转换结果导出状态未改变';
    } catch (error) {
      const message: string = this.errorMessage(error);
      this.livePhotoPairExportEntries = entries.map((entry: LivePhotoExportEntry): LivePhotoExportEntry => ({
        kind: entry.kind,
        label: entry.label,
        sourcePath: entry.sourcePath,
        fileName: entry.fileName,
        targetUri: entry.targetUri,
        status: 'failed',
        errorMessage: message
      }));
      this.operationStatus = 'Live Photo 成对导出未完成：' + message + '；未修改转换结果导出状态';
    } finally {
      this.batchPickerActive = false;
      if (locked) {
        controller.endExternal(itemId);
        try {
          await controller.persist();
        } catch (persistError) {
          this.queueError = 'Live Photo 导出结束后队列状态保存失败：' + this.errorMessage(persistError) + '；请重试保存';
        }
      }
      this.livePhotoPairExporting = false;
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

  private async motionSplitStat(path: string): Promise<MotionSplitFileStat> {
    const stat: fileIo.Stat = await fileIo.lstat(path);
    return {
      size: stat.size,
      isFile: stat.isFile(),
      isDirectory: stat.isDirectory(),
      isSymbolicLink: stat.isSymbolicLink()
    };
  }

  private async copySandboxPath(sourcePath: string, destinationPath: string): Promise<void> {
    let sourceFd: number = -1;
    try {
      sourceFd = (await fileIo.open(sourcePath, fileIo.OpenMode.READ_ONLY)).fd;
      await fileIo.copyFile(sourceFd, destinationPath);
    } finally {
      if (sourceFd >= 0) {
        try {
          await fileIo.close(sourceFd);
        } catch (closeError) {
          // Preserve a copy failure; the pipeline owns cleanup of the scratch.
        }
      }
    }
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
        handle,
        ps3OptionsFor(item.inputPath, mode.applePhotographicStyles3 === true)
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
    return this.modeSnapshotForSettings(this.committedSettings);
  }

  private modeSnapshotForSettings(values: NativeSettings): QueueModeSnapshot {
    const settings: NativeSettings = normalizeSettings(cloneSettings(values));
    return {
      modeKey: settings.outputMode,
      modeLabel: modeLabel(settings),
      applePhotographicStyles3: settings.applePhotographicStyles3,
      config: {
        oppoCompat: settings.oppoCompat,
        oppoCameraTail: settings.oppoCameraTail,
        strictTmap: settings.strictTmap ? 1 : 0,
        applePhotographicStyles: settings.applePhotographicStyles ? 1 : 0,
        applePortrait: settings.applePortrait ? 1 : 0
      }
    };
  }

  private settingsFromModeSnapshot(snapshot: QueueModeSnapshot): NativeSettings {
    return normalizeSettings({
      outputMode: snapshot.modeKey as SettingsOutputMode,
      oppoCompat: snapshot.config.oppoCompat,
      oppoCameraTail: snapshot.config.oppoCameraTail,
      strictTmap: snapshot.config.strictTmap === 1,
      applePhotographicStyles: snapshot.config.applePhotographicStyles === 1,
      applePhotographicStyles3: snapshot.applePhotographicStyles3 === true,
      applePortrait: snapshot.config.applePortrait === 1
    });
  }

  private galleryPhotoIsHeif(): boolean {
    const mimeType: string = this.galleryMimeType.toLowerCase();
    const extension: string = (this.galleryCurrentItem?.extension ?? '').toLowerCase();
    return mimeType === 'image/heic' || mimeType === 'image/heif' ||
      extension === 'heic' || extension === 'heif' || extension === '.heic' || extension === '.heif';
  }

  private gallerySupportsNativeConversion(): boolean {
    const classification: NativeClassificationResult | undefined = this.galleryClassification;
    const details: NativePhotoDetails | undefined = this.galleryDetails;
    const hdrKind: string = (classification?.hdrKind ?? details?.hdrKind ?? '').toLowerCase();
    return hdrKind === 'lhdr' || hdrKind === 'uhdr';
  }

  private canCompareGallerySdr(): boolean {
    return this.galleryDetailVisible && this.galleryChromeVisible && this.galleryCurrentItem !== undefined &&
      this.gallerySandboxPath.length > 0 && this.gallerySupportsNativeConversion();
  }

  private async beginGallerySdrCompare(): Promise<void> {
    if (!this.canCompareGallerySdr() || this.gallerySdrCompareLoading || this.gallerySdrCompareActive) return;
    this.gallerySdrCompareHolding = true;
    this.gallerySdrCompareLoading = true;
    const serial: number = this.gallerySdrDecodeSerial + 1;
    this.gallerySdrDecodeSerial = serial;
    const itemId: string = this.galleryCurrentItem?.id ?? '';
    let imageSource: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      imageSource = image.createImageSource('file://' + this.gallerySandboxPath);
      pixelMap = await imageSource.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredDynamicRange: image.DecodingDynamicRange.SDR
      });
      if (!this.gallerySdrCompareHolding || serial !== this.gallerySdrDecodeSerial ||
        itemId !== this.galleryCurrentItem?.id) return;
      const previousPixelMap: image.PixelMap | undefined = this.gallerySdrPreviewPixelMap;
      this.gallerySdrPreviewPixelMap = pixelMap;
      pixelMap = undefined;
      this.gallerySdrPreviewItemId = itemId;
      this.gallerySdrCompareActive = true;
      if (previousPixelMap !== undefined) {
        setTimeout((): void => {
          void previousPixelMap.release();
        }, 180);
      }
    } catch (error) {
      if (serial === this.gallerySdrDecodeSerial && this.gallerySdrCompareHolding) {
        this.galleryStatus = 'SDR 对比加载失败：' + this.errorMessage(error);
      }
    } finally {
      if (imageSource !== undefined) {
        try {
          await imageSource.release();
        } catch (releaseError) {
          // The PixelMap is independent after decoding; source release is best effort.
        }
      }
      if (pixelMap !== undefined) {
        try {
          await pixelMap.release();
        } catch (releaseError) {
          // A stale decode can finish after the user has released the button.
        }
      }
      if (serial === this.gallerySdrDecodeSerial) this.gallerySdrCompareLoading = false;
    }
  }

  private endGallerySdrCompare(): void {
    if (!this.gallerySdrCompareHolding && !this.gallerySdrCompareActive && !this.gallerySdrCompareLoading) return;
    this.gallerySdrCompareHolding = false;
    this.gallerySdrDecodeSerial += 1;
    this.gallerySdrCompareLoading = false;
    this.gallerySdrCompareActive = false;
    const pixelMap: image.PixelMap | undefined = this.gallerySdrPreviewPixelMap;
    this.gallerySdrPreviewPixelMap = undefined;
    this.gallerySdrPreviewItemId = '';
    if (pixelMap !== undefined) {
      setTimeout((): void => {
        void pixelMap.release();
      }, 180);
    }
  }

  private canConvertGalleryPhotoDirectly(): boolean {
    return this.galleryLibraryReady && this.galleryLibrary !== undefined && this.galleryCurrentItem !== undefined &&
      this.gallerySandboxPath.length > 0 && this.galleryDetails !== undefined &&
      this.galleryClassification !== undefined && this.gallerySupportsNativeConversion() && this.settingsLoaded &&
      !this.galleryImporting && !this.galleryQueuePreparing && !this.pageBusy && !this.queueRunning &&
      !this.cleanupRunning && !this.batchExportRunning && !this.settingsSaving && !this.livePhotoPairing &&
      !this.livePhotoPairExporting && !this.motionSplitting && !this.motionInspecting;
  }

  private gallerySupportedOutputModes(): Array<SettingsOutputMode> {
    return this.gallerySupportsNativeConversion() ? ['oppo', 'apple'] : [];
  }

  private gallerySupportsApplePhotoData(): boolean {
    return this.gallerySupportsNativeConversion() && this.galleryPhotoIsHeif();
  }

  private gallerySupportsPortraitData(): boolean {
    return this.gallerySupportsApplePhotoData() && this.galleryClassification?.modeKey === 'portrait';
  }

  private galleryEffectiveSettings(): NativeSettings {
    const settings: NativeSettings = cloneSettings(this.galleryPhotoSettingsView);
    if (!this.gallerySupportsApplePhotoData()) {
      settings.applePhotographicStyles = false;
      settings.applePhotographicStyles3 = false;
      settings.applePortrait = false;
    } else if (!this.gallerySupportsPortraitData()) {
      settings.applePortrait = false;
    }
    return normalizeSettings(settings);
  }

  private galleryPhotoModeSnapshot(): QueueModeSnapshot {
    if (!this.gallerySupportsNativeConversion()) {
      throw new Error('这张照片不含可转换的 ProXDR 数据');
    }
    return this.modeSnapshotForSettings(this.galleryEffectiveSettings());
  }

  private galleryPhotoSettingsSummary(): string {
    try {
      return modeLabel(this.galleryEffectiveSettings());
    } catch (error) {
      return '设置无效';
    }
  }

  private updateGalleryPhotoSettings(values: NativeSettings): void {
    if (this.galleryPhotoSettingsId.length === 0) return;
    try {
      const normalized: NativeSettings = normalizeSettings(values);
      const snapshot: NativeSettings = cloneSettings(normalized);
      this.galleryPhotoSettings.set(this.galleryPhotoSettingsId, snapshot);
      this.galleryPhotoSettingsView = cloneSettings(snapshot);
      this.galleryStatus = '转换设置仅保存到当前照片';
    } catch (error) {
      this.galleryStatus = '照片设置无效：' + this.errorMessage(error);
    }
  }

  private setGalleryPhotoOutputMode(mode: SettingsOutputMode): void {
    if (!this.gallerySupportedOutputModes().includes(mode)) return;
    const settings: NativeSettings = cloneSettings(this.galleryPhotoSettingsView);
    settings.outputMode = mode;
    if (mode === 'apple') {
      settings.oppoCompat = 0;
      settings.oppoCameraTail = 0;
    } else {
      settings.applePhotographicStyles = false;
      settings.applePhotographicStyles3 = false;
      settings.applePortrait = false;
      if (settings.oppoCompat === 0) settings.oppoCompat = DEFAULT_SETTINGS.oppoCompat;
      if (settings.oppoCameraTail === 0) settings.oppoCameraTail = DEFAULT_SETTINGS.oppoCameraTail;
    }
    this.updateGalleryPhotoSettings(settings);
  }

  private setGalleryPhotoCompat(value: number): void {
    const settings: NativeSettings = cloneSettings(this.galleryPhotoSettingsView);
    settings.outputMode = 'oppo';
    settings.oppoCompat = value;
    settings.applePhotographicStyles = false;
    settings.applePhotographicStyles3 = false;
    settings.applePortrait = false;
    this.updateGalleryPhotoSettings(settings);
  }

  private setGalleryPhotoCameraTail(value: number): void {
    const settings: NativeSettings = cloneSettings(this.galleryPhotoSettingsView);
    settings.outputMode = 'oppo';
    settings.oppoCameraTail = value;
    settings.applePhotographicStyles = false;
    settings.applePhotographicStyles3 = false;
    settings.applePortrait = false;
    this.updateGalleryPhotoSettings(settings);
  }

  private setGalleryPhotoStrictTmap(enabled: boolean): void {
    const settings: NativeSettings = cloneSettings(this.galleryPhotoSettingsView);
    settings.strictTmap = enabled;
    this.updateGalleryPhotoSettings(settings);
  }

  private setGalleryPhotoStyles(enabled: boolean): void {
    if (!this.gallerySupportsApplePhotoData()) return;
    const settings: NativeSettings = cloneSettings(this.galleryPhotoSettingsView);
    settings.applePhotographicStyles = enabled || settings.applePhotographicStyles3;
    if (enabled) {
      settings.outputMode = 'apple';
      settings.oppoCompat = 0;
      settings.oppoCameraTail = 0;
    }
    this.updateGalleryPhotoSettings(settings);
  }

  private setGalleryPhotoStyles3(enabled: boolean): void {
    if (!this.gallerySupportsApplePhotoData()) return;
    const settings: NativeSettings = cloneSettings(this.galleryPhotoSettingsView);
    settings.applePhotographicStyles3 = enabled;
    if (enabled) {
      settings.applePhotographicStyles = true;
      settings.outputMode = 'apple';
      settings.oppoCompat = 0;
      settings.oppoCameraTail = 0;
    }
    this.updateGalleryPhotoSettings(settings);
  }

  private setGalleryPhotoPortrait(enabled: boolean): void {
    if (!this.gallerySupportsPortraitData()) return;
    const settings: NativeSettings = cloneSettings(this.galleryPhotoSettingsView);
    settings.applePortrait = enabled;
    if (enabled) {
      settings.outputMode = 'apple';
      settings.oppoCompat = 0;
      settings.oppoCameraTail = 0;
    }
    this.updateGalleryPhotoSettings(settings);
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

  private async loadGalleryLibrary(): Promise<void> {
    if (this.galleryLoading && this.galleryLibraryReady) return;
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.galleryLoadError = '应用上下文不可用，无法打开本地图库';
      this.galleryLoading = false;
      return;
    }
    this.galleryLoading = true;
    this.galleryLoadError = '';
    try {
      if (this.galleryLibrary === undefined) {
        this.galleryLibrary = new HarmonyGalleryLibrary(context.filesDir);
      }
      const items: Array<GalleryLibraryItem> = await this.galleryLibrary.load();
      this.galleryPhotos = items.map((item: GalleryLibraryItem): GalleryPhotoTile => ({
        item: item,
        path: this.galleryLibrary?.pathFor(item) ?? galleryItemPath(context.filesDir + '/xdremux-gallery', item)
      }));
      this.galleryLoadedPreviewIds = [];
      this.gallerySwiperDataSource.replaceAll(this.galleryPhotos);
      this.galleryMediaCount = items.length;
      this.galleryLibraryReady = true;
      this.galleryStatus = items.length > 0
        ? '本地图库已加载 ' + String(items.length) + ' 张照片'
        : '导入照片后会保存在 XDRemux 本地图库中';
    } catch (error) {
      this.galleryLibraryReady = false;
      this.galleryLoadError = '读取本地图库失败：' + this.errorMessage(error);
    } finally {
      this.galleryLoading = false;
    }
  }

  private async importGalleryPhotos(): Promise<void> {
    if (this.galleryImporting || this.galleryLoading || this.pageBusy || this.queueRunning) return;
    if (!this.galleryLibraryReady || this.galleryLibrary === undefined) {
      this.galleryLoadError = '本地图库尚未就绪，请先重新加载';
      return;
    }
    this.galleryImporting = true;
    this.pageBusy = true;
    this.galleryLoadError = '';
    this.galleryStatus = '正在打开照片选择器…';
    let imported: number = 0;
    let failed: number = 0;
    try {
      const pickerView: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      // The system picker grants access only to the chosen assets. Request
      // API 26 originals, then persist a physical copy before any Rust call.
      const selection: photoAccessHelper.PhotoSelectResult =
        await pickerView.select(this.galleryPhotoPickerOptions);
      const selected: Array<string> = selection.photoUris;
      if (selected.length === 0) {
        this.galleryStatus = '未选择照片';
        return;
      }
      for (let index: number = 0; index < selected.length; index += 1) {
        try {
          const displayName: string = this.displayNameFromUri(selected[index], index);
          const item: GalleryLibraryItem = await this.galleryLibrary.importPhoto(selected[index], displayName);
          const tile: GalleryPhotoTile = { item: item, path: this.galleryLibrary.pathFor(item) };
          this.galleryPhotos = [tile, ...this.galleryPhotos];
          this.gallerySwiperDataSource.replaceAll(this.galleryPhotos);
          this.galleryMediaCount += 1;
          imported += 1;
        } catch (error) {
          failed += 1;
        }
      }
      this.galleryStatus = '已导入 ' + String(imported) + ' 张照片' +
        (failed > 0 ? '，失败 ' + String(failed) + ' 张' : '') +
        '；原图保存在应用本地';
    } catch (error) {
      this.galleryStatus = '导入失败：' + this.errorMessage(error);
    } finally {
      this.pageBusy = false;
      this.galleryImporting = false;
    }
  }

  @Available({ minApiVersion: '26.0.0' })
  private async enqueueAllGalleryPhotos(): Promise<void> {
    if (!this.canImportQueueMiniBarAction() || !this.galleryLibraryReady || this.galleryPhotos.length === 0) {
      this.galleryStatus = this.galleryPhotos.length === 0
        ? '本地图库没有可加入队列的照片'
        : '队列或本地图库尚未就绪，请稍后重试';
      this.mainTabIndex = 1;
      this.setImportMiniBarExpanded(false);
      return;
    }

    const queue: QueueController = this.getController();
    const tiles: Array<GalleryPhotoTile> = this.galleryPhotos.slice();
    let added: number = 0;
    let skipped: number = 0;
    let failed: number = 0;
    this.setImportMiniBarExpanded(false);
    this.galleryQueuePreparing = true;
    this.pageBusy = true;
    this.galleryStatus = '正在检查本地图库并加入可转换照片…';
    try {
      for (const tile of tiles) {
        if (queue.hasPersistenceError || this.queueRecoveryRequired) {
          failed += tiles.length - added - skipped - failed;
          break;
        }
        if (queue.items().some((item: QueueItem): boolean => item.sourceUri === tile.path)) {
          skipped += 1;
          continue;
        }

        let item: QueueItem | undefined = undefined;
        let locked: boolean = false;
        try {
          let inspection: GalleryPhotoInspection | undefined = this.galleryInspectionCache.get(tile.item.id);
          if (inspection === undefined) {
            const detailsJson: string = await xdremuxNative.inspect(tile.path);
            const details: NativePhotoDetails = JSON.parse(detailsJson) as NativePhotoDetails;
            if (!details.success) throw new Error(this.display(details.errorMessage));
            const classification: NativeClassificationResult =
              await xdremuxNative.classify(tile.path) as NativeClassificationResult;
            inspection = {
              details: details,
              classification: classification,
              displayImageWidth: this.galleryDecodedDimensionsCache.get(tile.item.id)?.[0] ?? 0,
              displayImageHeight: this.galleryDecodedDimensionsCache.get(tile.item.id)?.[1] ?? 0
            };
            this.galleryInspectionCache.set(tile.item.id, inspection);
          }

          const hdrKind: string = (inspection.classification.hdrKind ?? inspection.details.hdrKind ?? '').toLowerCase();
          if (hdrKind !== 'lhdr' && hdrKind !== 'uhdr') {
            skipped += 1;
            continue;
          }

          const savedSettings: NativeSettings | undefined = this.galleryPhotoSettings.get(tile.item.id);
          const settings: NativeSettings = normalizeSettings(cloneSettings(
            savedSettings ?? this.committedSettings
          ));
          const extension: string = tile.item.extension.toLowerCase();
          const isHeif: boolean = extension === '.heic' || extension === '.heif';
          if (!isHeif) {
            settings.applePhotographicStyles = false;
            settings.applePhotographicStyles3 = false;
            settings.applePortrait = false;
          } else if (inspection.classification.modeKey !== 'portrait') {
            settings.applePortrait = false;
          }

          item = queue.add({
            displayName: tile.item.displayName,
            sourceUri: tile.path,
            modeOverride: this.modeSnapshotForSettings(settings)
          });
          queue.beginExternal(item.id);
          locked = true;
          await queue.persist();
          const prepared: QueuePrepared = await this.prepareQueueItem(item);
          queue.setPrepared(item.id, prepared.inputPath, prepared.details, prepared.classification);
          await queue.persist();
          added += 1;
        } catch (error) {
          failed += 1;
          const message: string = this.errorMessage(error);
          if (item !== undefined && locked && !queue.hasPersistenceError &&
            !(error instanceof QueuePersistenceError)) {
            try {
              queue.markPreparationFailed(item.id, message);
              await queue.persist();
            } catch (persistError) {
              this.queueError = '批量加入队列时保存失败：' + this.errorMessage(persistError);
            }
          } else if (queue.hasPersistenceError || error instanceof QueuePersistenceError) {
            this.queueError = '批量加入队列时保存失败：' + message + '；请先重试保存队列';
            break;
          }
        } finally {
          if (item !== undefined && locked) queue.endExternal(item.id);
          this.syncQueue();
        }
      }
    } finally {
      this.galleryQueuePreparing = false;
      this.pageBusy = false;
      this.mainTabIndex = 1;
      this.syncQueue();
    }

    this.operationStatus = '本地图库加入队列：新增 ' + String(added) + ' 张，已存在或不含可转换 HDR 数据 ' +
      String(skipped) + ' 张' + (failed > 0 ? '，失败 ' + String(failed) + ' 张' : '');
    this.galleryStatus = this.operationStatus;
  }

  private async inspectGallerySelection(
    tile: GalleryPhotoTile,
    openDetail: boolean = false,
    delayHdrReveal: boolean = false
  ): Promise<void> {
    if (tile.path.length === 0) return;
    this.endGallerySdrCompare();
    const selectionSerial: number = this.gallerySelectionSerial + 1;
    this.gallerySelectionSerial = selectionSerial;
    this.clearGalleryDetailImageRevealTimer();
    this.galleryDetailSelectionUsesDelayedReveal = delayHdrReveal;
    const shouldOpenDetail: boolean = openDetail && !this.galleryDetailVisible;
    const cachedInspection: GalleryPhotoInspection | undefined = this.galleryInspectionCache.get(tile.item.id);
    if (shouldOpenDetail || delayHdrReveal) {
      // A decoded image from a previous visit does not guarantee the newly
      // mounted HDR Image already has a frame to draw. Keep the SDR preview
      // through the detail entrance until this particular render completes.
      this.galleryDetailLoadedImageId = '';
    } else if (tile.item.id !== this.galleryCurrentItem?.id) {
      // Horizontal photo swipes keep the original quick path: reuse an already
      // decoded frame immediately and otherwise reveal on the decode callback.
      this.galleryDetailLoadedImageId = this.galleryDetailDecodedImageIds.has(tile.item.id) ? tile.item.id : '';
    }
    this.galleryZoomScale = 1;
    this.galleryPanOffsetX = 0;
    this.galleryPanOffsetY = 0;
    this.galleryDismissOffsetY = 0;
    this.galleryGestureAxis = 'none';
    this.galleryCurrentItem = tile.item;
    const cachedDimensions: Array<number> | undefined = this.galleryDecodedDimensionsCache.get(tile.item.id);
    this.galleryDisplayImageWidth = cachedDimensions?.[0] ?? 0;
    this.galleryDisplayImageHeight = cachedDimensions?.[1] ?? 0;
    this.galleryPanelMode = 'info';
    const existingQueueItem: QueueItem | undefined = this.queueItems.find(
      (item: QueueItem): boolean => item.sourceUri === tile.path
    );
    this.galleryQueueItemId = existingQueueItem?.id ?? '';
    this.galleryPhotoSettingsId = tile.item.id;
    const savedPhotoSettings: NativeSettings | undefined = this.galleryPhotoSettings.get(tile.item.id);
    const initialPhotoSettings: NativeSettings = savedPhotoSettings !== undefined
      ? cloneSettings(savedPhotoSettings)
      : existingQueueItem?.modeOverride !== undefined
        ? this.settingsFromModeSnapshot(existingQueueItem.modeOverride)
        : cloneSettings(this.settingsLoaded ? this.committedSettings : DEFAULT_SETTINGS);
    this.galleryPhotoSettings.set(tile.item.id, cloneSettings(initialPhotoSettings));
    this.galleryPhotoSettingsView = cloneSettings(initialPhotoSettings);
    this.galleryImporting = cachedInspection === undefined;
    this.galleryDetails = cachedInspection?.details;
    this.galleryClassification = cachedInspection?.classification;
    this.gallerySandboxPath = tile.path;
    this.galleryCopiedBytes = 0;
    this.galleryMimeType = tile.item.mimeType.length > 0
      ? tile.item.mimeType
      : galleryMimeTypeForExtension(tile.item.extension);
    this.galleryStatus = cachedInspection === undefined
      ? '正在读取本地原图信息…'
      : '已读取本地原图 ' + this.galleryFormatLabel() + ' · ' +
        String(cachedInspection.details.width ?? 0) + ' × ' + String(cachedInspection.details.height ?? 0);
    if (shouldOpenDetail) {
      if (this.galleryStatusBarResetTimer >= 0) {
        clearTimeout(this.galleryStatusBarResetTimer);
        this.galleryStatusBarResetTimer = -1;
      }
      this.galleryPanelHeight = GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT;
      this.galleryChromeVisible = true;
      this.galleryHeroPreloadItemId = tile.item.id;
      this.galleryHeroPlaceholderReady = false;
      this.galleryHeroMetadataReady = false;
      this.galleryHeroPreloadPending = true;
      this.touchGalleryThumbnail(tile);
      this.galleryHeroPlaceholderReady = this.galleryThumbnailPixelMapCache.has(tile.item.id) ||
        this.galleryThumbnailDecodeFailedIds.includes(tile.item.id);
    }
    if (cachedInspection !== undefined) {
      this.galleryCopiedBytes = tile.item.size;
      if (shouldOpenDetail) {
        this.galleryHeroMetadataReady = true;
        this.tryStartGalleryHeroTransition(tile.item.id);
      }
      return;
    }
    try {
      const stat: fileIo.Stat = await fileIo.lstat(tile.path);
      if (stat.isSymbolicLink() || !stat.isFile() || stat.size !== tile.item.size || stat.size <= 0) {
        throw new Error('本地图库原图缺失或大小不匹配');
      }
      if (selectionSerial !== this.gallerySelectionSerial) return;
      this.galleryCopiedBytes = stat.size;
      const detailsJson: string = await xdremuxNative.inspect(tile.path);
      const details: NativePhotoDetails = JSON.parse(detailsJson) as NativePhotoDetails;
      if (!details.success) throw new Error(this.display(details.errorMessage));
      if (selectionSerial !== this.gallerySelectionSerial) return;
      this.galleryDetails = details;
      if (shouldOpenDetail) {
        this.galleryHeroMetadataReady = true;
        this.tryStartGalleryHeroTransition(tile.item.id);
      }
      const classification: NativeClassificationResult =
        await xdremuxNative.classify(tile.path) as NativeClassificationResult;
      if (selectionSerial !== this.gallerySelectionSerial) return;
      this.galleryInspectionCache.set(tile.item.id, {
        details: details,
        classification: classification,
        displayImageWidth: this.galleryDecodedDimensionsCache.get(tile.item.id)?.[0] ?? 0,
        displayImageHeight: this.galleryDecodedDimensionsCache.get(tile.item.id)?.[1] ?? 0
      });
      this.galleryClassification = classification;
      this.galleryStatus = '已读取本地原图 ' + this.galleryFormatLabel() + ' · ' +
        String(details.width ?? 0) + ' × ' + String(details.height ?? 0);
    } catch (error) {
      if (selectionSerial === this.gallerySelectionSerial) {
        this.galleryStatus = '读取本地照片失败：' + this.errorMessage(error);
        if (shouldOpenDetail) {
          this.galleryHeroMetadataReady = true;
          this.tryStartGalleryHeroTransition(tile.item.id);
        }
      }
    } finally {
      if (selectionSerial === this.gallerySelectionSerial) this.galleryImporting = false;
    }
  }

  private galleryFileSuffixFromUri(uri: string): string {
    const path: string = uri.split('?')[0].split('#')[0].toLowerCase();
    const dot: number = path.lastIndexOf('.');
    if (dot < 0) return '.img';
    const extension: string = path.substring(dot);
    return extension.length > 1 && extension.length <= 13 ? extension : '.img';
  }

  private openGalleryTile(tile: GalleryPhotoTile): void {
    if (this.galleryImporting) return;
    this.galleryStatus = '正在读取 ' + tile.item.displayName + '…';
    void this.inspectGallerySelection(tile, true, true);
  }

  private tryStartGalleryHeroTransition(itemId: string): void {
    if (!this.galleryHeroPreloadPending || itemId !== this.galleryHeroPreloadItemId ||
      itemId !== this.galleryCurrentItem?.id || !this.galleryHeroPlaceholderReady ||
      !this.galleryHeroMetadataReady || this.galleryViewportWidth <= 0 || this.galleryViewportHeight <= 0) return;
    if (!this.galleryThumbnailPixelMapCache.has(itemId) &&
      !this.galleryThumbnailDecodeFailedIds.includes(itemId)) return;
    this.galleryHeroPreloadPending = false;
    this.galleryHeroPreloadItemId = '';
    this.galleryHeroPlaceholderReady = false;
    this.galleryHeroMetadataReady = false;
    this.galleryChromeToggleBlockedUntil = Date.now() + 650;
    if (this.galleryHeroBackdropResetTimer >= 0) {
      clearTimeout(this.galleryHeroBackdropResetTimer);
      this.galleryHeroBackdropResetTimer = -1;
    }
    this.galleryHeroTransitionActive = true;
    this.galleryHeroOpening = true;
    this.ensureGalleryStatusBarVisible();
    this.getUIContext().animateTo({ duration: 420, curve: Curve.Friction }, () => {
      this.galleryDetailMounted = true;
      this.galleryDetailVisible = true;
      this.galleryInfoPanelVisible = true;
    });
    this.galleryHeroBackdropResetTimer = setTimeout((): void => {
      this.galleryHeroBackdropResetTimer = -1;
      if (this.galleryDetailVisible) {
        this.galleryHeroTransitionActive = false;
        this.galleryHeroOpening = false;
        this.ensureGalleryStatusBarVisible();
      }
    }, 460);
  }

  private closeGalleryDetail(): void {
    this.clearGalleryDetailImageRevealTimer();
    if (!this.galleryDetailVisible) return;
    this.endGallerySdrCompare();
    this.gallerySelectionSerial += 1;
    if (this.galleryStatusBarResetTimer >= 0) clearTimeout(this.galleryStatusBarResetTimer);
    if (this.galleryHeroBackdropResetTimer >= 0) {
      clearTimeout(this.galleryHeroBackdropResetTimer);
      this.galleryHeroBackdropResetTimer = -1;
    }
    this.galleryHeroTransitionActive = true;
    this.galleryHeroOpening = false;
    this.getUIContext().animateTo({ duration: 360, curve: Curve.Friction }, () => {
      this.galleryZoomScale = 1;
      this.galleryPanOffsetX = 0;
      this.galleryPanOffsetY = 0;
      this.galleryDismissOffsetY = 0;
      this.galleryPanelHeight = GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT;
      this.galleryInfoPanelVisible = false;
      this.galleryChromeVisible = false;
      this.galleryDetailVisible = false;
      // Removing the destination frame starts the reverse shared-element
      // transition; the framework keeps its transition snapshot alive while
      // the source tile follows it back into the grid.
      this.galleryDetailMounted = false;
    });
    this.galleryStatusBarResetTimer = setTimeout((): void => {
      this.galleryStatusBarResetTimer = -1;
      if (!this.galleryDetailVisible) {
        this.galleryHeroTransitionActive = false;
        this.ensureGalleryStatusBarVisible();
      }
    }, 420);
  }

  private galleryTransitionId(itemId: string): string {
    return 'xdremux-gallery-photo-' + itemId;
  }

  private cacheGalleryDecodedDimensions(itemId: string, width: number, height: number): void {
    if (width <= 0 || height <= 0) return;
    this.galleryDecodedDimensionsCache.set(itemId, [width, height]);
    const inspection: GalleryPhotoInspection | undefined = this.galleryInspectionCache.get(itemId);
    if (inspection !== undefined) {
      inspection.displayImageWidth = width;
      inspection.displayImageHeight = height;
    }
    if (itemId === this.galleryCurrentItem?.id) {
      this.galleryDisplayImageWidth = width;
      this.galleryDisplayImageHeight = height;
    }
  }

  private galleryPreviewIsLoaded(itemId: string): boolean {
    return this.galleryLoadedPreviewIds.includes(itemId);
  }

  private cacheGalleryThumbnail(itemId: string, pixelMap: image.PixelMap): void {
    this.galleryThumbnailPixelMapCache.delete(itemId);
    this.galleryThumbnailPixelMapCache.set(itemId, pixelMap);
    this.galleryCachedThumbnailIds = [...this.galleryCachedThumbnailIds.filter(
      (cachedId: string): boolean => cachedId !== itemId
    ), itemId];

    while (this.galleryThumbnailPixelMapCache.size > GALLERY_THUMBNAIL_CACHE_LIMIT) {
      const cacheIds: Array<string> = Array.from(this.galleryThumbnailPixelMapCache.keys());
      if (cacheIds.length === 0) break;
      let oldestId: string = cacheIds[0];
      if (oldestId === itemId && cacheIds.length > 1) oldestId = cacheIds[1];
      const evictedPixelMap: image.PixelMap | undefined = this.galleryThumbnailPixelMapCache.get(oldestId);
      this.galleryThumbnailPixelMapCache.delete(oldestId);
      this.galleryCachedThumbnailIds = this.galleryCachedThumbnailIds.filter(
        (cachedId: string): boolean => cachedId !== oldestId
      );
      if (evictedPixelMap !== undefined) {
        setTimeout((): void => {
          void evictedPixelMap.release();
        }, 240);
      }
    }
  }

  private touchGalleryThumbnail(tile: GalleryPhotoTile): void {
    const cachedPixelMap: image.PixelMap | undefined = this.galleryThumbnailPixelMapCache.get(tile.item.id);
    if (cachedPixelMap !== undefined) {
      this.galleryThumbnailPixelMapCache.delete(tile.item.id);
      this.galleryThumbnailPixelMapCache.set(tile.item.id, cachedPixelMap);
      return;
    }
    if (this.galleryThumbnailDecodeFailedIds.includes(tile.item.id) ||
      this.galleryThumbnailDecodeInFlight.has(tile.item.id)) return;
    void this.decodeGalleryThumbnail(tile);
  }

  private async decodeGalleryThumbnail(tile: GalleryPhotoTile): Promise<void> {
    if (this.galleryThumbnailPixelMapCache.has(tile.item.id) ||
      this.galleryThumbnailDecodeInFlight.has(tile.item.id)) return;
    this.galleryThumbnailDecodeInFlight.add(tile.item.id);
    let imageSource: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      imageSource = image.createImageSource('file://' + tile.path);
      let sourceWidth: number = this.galleryDecodedDimensionsCache.get(tile.item.id)?.[0] ?? 0;
      let sourceHeight: number = this.galleryDecodedDimensionsCache.get(tile.item.id)?.[1] ?? 0;
      if (sourceWidth <= 0 || sourceHeight <= 0) {
        const imageInfo: image.ImageInfo = await imageSource.getImageInfo();
        sourceWidth = imageInfo.size.width;
        sourceHeight = imageInfo.size.height;
      }
      if (sourceWidth <= 0 || sourceHeight <= 0) throw new Error('无法读取照片尺寸');
      const previewScale: number = Math.min(1,
        Math.max(GALLERY_THUMBNAIL_DECODE_WIDTH, GALLERY_THUMBNAIL_DECODE_HEIGHT) /
        Math.max(sourceWidth, sourceHeight));
      pixelMap = await imageSource.createPixelMap({
        desiredSize: {
          width: Math.max(1, Math.round(sourceWidth * previewScale)),
          height: Math.max(1, Math.round(sourceHeight * previewScale))
        },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredDynamicRange: image.DecodingDynamicRange.SDR
      });
      if (pixelMap === undefined) throw new Error('无法生成缩略图');
      if (!this.galleryPhotos.some((currentTile: GalleryPhotoTile): boolean =>
        currentTile.item.id === tile.item.id)) return;
      this.cacheGalleryThumbnail(tile.item.id, pixelMap);
      pixelMap = undefined;
      if (this.galleryHeroPreloadPending && this.galleryHeroPreloadItemId === tile.item.id &&
        this.galleryCurrentItem?.id === tile.item.id) {
        this.galleryHeroPlaceholderReady = true;
      }
      this.tryStartGalleryHeroTransition(tile.item.id);
    } catch (error) {
      if (!this.galleryThumbnailDecodeFailedIds.includes(tile.item.id)) {
        this.galleryThumbnailDecodeFailedIds = [...this.galleryThumbnailDecodeFailedIds, tile.item.id];
      }
      if (this.galleryHeroPreloadPending && this.galleryHeroPreloadItemId === tile.item.id &&
        this.galleryCurrentItem?.id === tile.item.id) {
        this.galleryHeroPlaceholderReady = true;
      }
      this.tryStartGalleryHeroTransition(tile.item.id);
    } finally {
      if (imageSource !== undefined) {
        try {
          await imageSource.release();
        } catch (releaseError) {
          // Decoded thumbnails are independent of their source.
        }
      }
      if (pixelMap !== undefined) {
        try {
          await pixelMap.release();
        } catch (releaseError) {
          // Release a thumbnail that was discarded before reaching the cache.
        }
      }
      this.galleryThumbnailDecodeInFlight.delete(tile.item.id);
    }
  }

  private centerGalleryThumbnail(index: number, animated: boolean = true): void {
    if (index < 0 || index >= this.galleryPhotos.length) return;
    const itemStride: number = 58 + 8;
    const contentWidth: number = 36 + this.galleryPhotos.length * itemStride - 8;
    const maximumOffset: number = Math.max(0, contentWidth - this.galleryViewportWidth);
    const selectedCenter: number = 18 + index * itemStride + 29;
    const offset: number = Math.max(0, Math.min(maximumOffset, selectedCenter - this.galleryViewportWidth / 2));
    try {
      this.galleryThumbnailScroller.scrollTo({
        xOffset: offset,
        yOffset: 0,
        animation: animated ? { duration: 240, curve: Curve.EaseOut } : false
      });
    } catch (error) {
      // The strip may not be attached yet during the opening transition.
    }
  }

  private onGalleryPreviewDecoded(itemId: string, width: number, height: number): void {
    if (width <= 0 || height <= 0) return;
    this.cacheGalleryDecodedDimensions(itemId, width, height);
    if (this.galleryPreviewIsLoaded(itemId)) return;
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
      this.galleryLoadedPreviewIds = [...this.galleryLoadedPreviewIds, itemId];
    });
  }

  private onGalleryDetailImageDecoded(
    itemId: string,
    width: number,
    height: number,
    isHighDynamicRangeImage: boolean = true
  ): void {
    this.onGalleryPreviewDecoded(itemId, width, height);
    if (!isHighDynamicRangeImage) return;
    this.galleryDetailDecodedImageIds.add(itemId);
    if (itemId !== this.galleryCurrentItem?.id || this.galleryDetailLoadedImageId === itemId ||
      this.galleryDetailImageRevealTimer >= 0) return;
    if (!this.galleryDetailSelectionUsesDelayedReveal) {
      this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
        this.galleryDetailLoadedImageId = itemId;
      });
      return;
    }
    const selectionSerial: number = this.gallerySelectionSerial;
    this.galleryDetailImageRevealTimer = setTimeout((): void => {
      this.galleryDetailImageRevealTimer = -1;
      if (selectionSerial !== this.gallerySelectionSerial || itemId !== this.galleryCurrentItem?.id ||
        !this.galleryDetailVisible || this.galleryHeroOpening) return;
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
        this.galleryDetailLoadedImageId = itemId;
      });
    }, 100);
  }

  private clearGalleryDetailImageRevealTimer(): void {
    if (this.galleryDetailImageRevealTimer < 0) return;
    clearTimeout(this.galleryDetailImageRevealTimer);
    this.galleryDetailImageRevealTimer = -1;
  }

  private galleryImageDimensions(itemId: string): Array<number> {
    const decoded: Array<number> | undefined = this.galleryDecodedDimensionsCache.get(itemId);
    if (decoded !== undefined && decoded[0] > 0 && decoded[1] > 0) return decoded;
    const inspection: GalleryPhotoInspection | undefined = this.galleryInspectionCache.get(itemId);
    if (inspection !== undefined && inspection.displayImageWidth > 0 && inspection.displayImageHeight > 0) {
      return [inspection.displayImageWidth, inspection.displayImageHeight];
    }
    if (itemId === this.galleryCurrentItem?.id && this.galleryDisplayImageWidth > 0 &&
      this.galleryDisplayImageHeight > 0) {
      return [this.galleryDisplayImageWidth, this.galleryDisplayImageHeight];
    }
    return [0, 0];
  }

  private galleryImageFrameWidth(itemId: string): number {
    if (this.galleryViewportWidth <= 0) return 0;
    return this.galleryImageDimensions(itemId)[0] > 0
      ? this.galleryViewportWidth
      : Math.min(this.galleryViewportWidth, this.galleryViewportHeight);
  }

  private galleryImageFrameHeight(itemId: string): number {
    const dimensions: Array<number> = this.galleryImageDimensions(itemId);
    if (dimensions[0] <= 0 || dimensions[1] <= 0 || this.galleryViewportWidth <= 0) {
      return Math.min(this.galleryViewportWidth, this.galleryViewportHeight);
    }
    return this.galleryViewportWidth * dimensions[1] / dimensions[0];
  }

  private galleryBaseImageWidth(): number {
    const dimensions: Array<number> = this.galleryImageDimensions(this.galleryCurrentItem?.id ?? '');
    const imageWidth: number = dimensions[0];
    const imageHeight: number = dimensions[1];
    if (imageWidth <= 0 || imageHeight <= 0 || this.galleryViewportWidth <= 0 || this.galleryViewportHeight <= 0) {
      return Math.min(this.galleryViewportWidth, this.galleryViewportHeight);
    }
    return this.galleryViewportWidth;
  }

  private galleryBaseImageHeight(): number {
    const dimensions: Array<number> = this.galleryImageDimensions(this.galleryCurrentItem?.id ?? '');
    const imageWidth: number = dimensions[0];
    const imageHeight: number = dimensions[1];
    if (imageWidth <= 0 || imageHeight <= 0 || this.galleryViewportWidth <= 0 || this.galleryViewportHeight <= 0) {
      return Math.min(this.galleryViewportWidth, this.galleryViewportHeight);
    }
    return this.galleryViewportWidth * imageHeight / imageWidth;
  }

  private galleryPhotoVerticalOffset(): number {
    return 0;
  }

  private galleryMaxPanX(scale: number): number {
    if (this.galleryViewportWidth <= 0) return 0;
    return Math.max(0, (this.galleryBaseImageWidth() * scale - this.galleryViewportWidth) / 2);
  }

  private galleryMaxPanY(scale: number): number {
    if (this.galleryViewportHeight <= 0) return 0;
    return Math.max(0, (this.galleryBaseImageHeight() * scale - this.galleryViewportHeight) / 2);
  }

  private clampGalleryPanX(value: number, scale: number = this.galleryZoomScale): number {
    const limit: number = this.galleryMaxPanX(scale);
    return Math.max(-limit, Math.min(limit, value));
  }

  private clampGalleryPanY(value: number, scale: number = this.galleryZoomScale): number {
    const limit: number = this.galleryMaxPanY(scale);
    const baseOffset: number = this.galleryDetailVisible ? this.galleryPhotoVerticalOffset() : 0;
    return Math.max(-limit - baseOffset, Math.min(limit - baseOffset, value));
  }

  private galleryTouchStartedInInfoPanel(event: GestureEvent, usePanOrigin: boolean = false): boolean {
    if (!this.galleryChromeVisible || !this.galleryInfoPanelVisible || this.galleryViewportHeight <= 0 ||
      this.galleryInfoPanelContentHeight <= 0) return false;
    const panelTop: number = this.galleryPanelTop();
    if (event.fingerList.length === 0) return false;
    for (const finger of event.fingerList) {
      const touchY: number = usePanOrigin ? finger.localY - event.offsetY : finger.localY;
      if (touchY >= panelTop && touchY <= this.galleryViewportHeight) return true;
    }
    return false;
  }

  private galleryTouchStartedOnPanelHandle(event: GestureEvent, usePanOrigin: boolean = false): boolean {
    if (!this.galleryChromeVisible || !this.galleryInfoPanelVisible || this.galleryViewportHeight <= 0 ||
      event.fingerList.length === 0) return false;
    const panelTop: number = this.galleryPanelTop();
    for (const finger of event.fingerList) {
      const touchY: number = usePanOrigin ? finger.localY - event.offsetY : finger.localY;
      if (touchY >= panelTop && touchY <= panelTop + GALLERY_DETAIL_PANEL_HANDLE_HEIGHT) return true;
    }
    return false;
  }

  private galleryPanelMaximumHeight(): number {
    if (this.galleryViewportHeight <= 0) return 560;
    const safeAvailableHeight: number = Math.max(GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT,
      this.galleryViewportHeight - GALLERY_DETAIL_PANEL_BOTTOM_INSET - GALLERY_DETAIL_PANEL_TOP_CLEARANCE);
    const contentFitHeight: number = this.galleryInfoPanelContentHeight > 0
      ? GALLERY_DETAIL_PANEL_HANDLE_HEIGHT + this.galleryInfoPanelContentHeight +
        GALLERY_DETAIL_PANEL_CONTENT_CLEARANCE + GALLERY_DETAIL_BAR_HEIGHT
      : Math.max(220, this.galleryViewportHeight * 0.68);
    return Math.max(GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT, Math.min(safeAvailableHeight, contentFitHeight));
  }

  private clampGalleryPanelHeight(height: number): number {
    return Math.max(GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT,
      Math.min(this.galleryPanelMaximumHeight(), height));
  }

  private galleryPanelSnapHeights(): Array<number> {
    const maximumHeight: number = this.galleryPanelMaximumHeight();
    const snapHeights: Array<number> = [GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT];
    if (maximumHeight > snapHeights[snapHeights.length - 1] + 1) {
      snapHeights.push(maximumHeight);
    }
    return snapHeights;
  }

  private galleryPanelSnapTarget(height: number): number {
    const snapHeights: Array<number> = this.galleryPanelSnapHeights();
    let targetHeight: number = snapHeights[0];
    let nearestDistance: number = Math.abs(height - targetHeight);
    for (let index: number = 1; index < snapHeights.length; index += 1) {
      const distance: number = Math.abs(height - snapHeights[index]);
      if (distance < nearestDistance) {
        targetHeight = snapHeights[index];
        nearestDistance = distance;
      }
    }
    return targetHeight;
  }

  private galleryPanelTop(): number {
    return Math.max(0, this.galleryViewportHeight - this.galleryPanelHeight - GALLERY_DETAIL_PANEL_BOTTOM_INSET);
  }

  private galleryPanelDragStart(): void {
    this.galleryPanelDragStartHeight = this.galleryPanelHeight;
  }

  private galleryPanelDragUpdate(event: GestureEvent): void {
    // Gesture offsets are in vp, matching the panel's ArkUI height.
    this.galleryPanelHeight = this.clampGalleryPanelHeight(this.galleryPanelDragStartHeight - event.offsetY);
  }

  private galleryPanelDragEnd(event: GestureEvent): void {
    const height: number = this.clampGalleryPanelHeight(this.galleryPanelDragStartHeight - event.offsetY);
    const dragOffsetY: number = event.offsetY;
    const upwardIntent: boolean = dragOffsetY <= -GALLERY_DETAIL_PANEL_SNAP_DRAG_THRESHOLD ||
      (dragOffsetY <= -GALLERY_DETAIL_PANEL_FLICK_OFFSET_THRESHOLD &&
        event.velocityY <= -GALLERY_DETAIL_PANEL_FLICK_VELOCITY_THRESHOLD);
    const downwardIntent: boolean = dragOffsetY >= GALLERY_DETAIL_PANEL_SNAP_DRAG_THRESHOLD ||
      (dragOffsetY >= GALLERY_DETAIL_PANEL_FLICK_OFFSET_THRESHOLD &&
        event.velocityY >= GALLERY_DETAIL_PANEL_FLICK_VELOCITY_THRESHOLD);
    const targetHeight: number = upwardIntent ? this.galleryPanelMaximumHeight()
      : downwardIntent ? GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT
        : this.galleryPanelSnapTarget(height);
    this.getUIContext().animateTo({ duration: 240, curve: Curve.Friction }, () => {
      this.galleryPanelHeight = targetHeight;
    });
  }

  private galleryPanelBodyCanCollapse(): boolean {
    return this.galleryPanelHeight > GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT + 1 &&
      this.galleryInfoPanelScrollViewportHeight > 0 &&
      this.galleryInfoPanelContentHeight <= this.galleryInfoPanelScrollViewportHeight + 1;
  }

  private galleryPanelBodyDragStart(): void {
    this.galleryPanelBodyDragActive = this.galleryPanelBodyCanCollapse();
    this.galleryPanelBodyDragVertical = false;
    this.galleryPanelBodyDragStartHeight = this.galleryPanelHeight;
  }

  private galleryPanelBodyDragUpdate(event: GestureEvent): void {
    if (!this.galleryPanelBodyDragActive) return;
    const horizontalTravel: number = Math.abs(event.offsetX);
    const verticalTravel: number = Math.abs(event.offsetY);
    if (Math.max(horizontalTravel, verticalTravel) < 10) return;
    if (verticalTravel <= horizontalTravel * 1.15) return;
    this.galleryPanelBodyDragVertical = true;
    if (event.offsetY > 0) {
      this.galleryPanelHeight = Math.max(GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT,
        this.galleryPanelBodyDragStartHeight - event.offsetY);
    }
  }

  private galleryPanelBodyDragEnd(event: GestureEvent): void {
    if (!this.galleryPanelBodyDragActive) return;
    this.galleryPanelBodyDragActive = false;
    if (!this.galleryPanelBodyDragVertical) return;
    const downwardIntent: boolean = event.offsetY >= GALLERY_DETAIL_PANEL_SNAP_DRAG_THRESHOLD ||
      (event.offsetY >= GALLERY_DETAIL_PANEL_FLICK_OFFSET_THRESHOLD &&
        event.velocityY >= GALLERY_DETAIL_PANEL_FLICK_VELOCITY_THRESHOLD);
    const targetHeight: number = downwardIntent
      ? GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT
      : this.galleryPanelBodyDragStartHeight;
    this.getUIContext().animateTo({ duration: 190, curve: Curve.Friction }, () => {
      this.galleryPanelHeight = targetHeight;
    });
  }

  private galleryPagePanStart(event: GestureEvent): void {
    const startedInPanel: boolean = this.galleryTouchStartedInInfoPanel(event, true);
    const startedOnHandle: boolean = this.galleryTouchStartedOnPanelHandle(event, true);
    this.galleryPagePanBlockedByPanel = startedOnHandle ||
      (startedInPanel && this.galleryPanelHeight > GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT + 1);
    this.galleryPageGestureAxis = 'none';
  }

  private galleryPagePanUpdate(event: GestureEvent): void {
    if (this.galleryPagePanBlockedByPanel || this.galleryZoomScale > 1.02) return;
    if (this.galleryPageGestureAxis === 'none') {
      const horizontalTravel: number = Math.abs(event.offsetX);
      const verticalTravel: number = Math.abs(event.offsetY);
      if (Math.max(horizontalTravel, verticalTravel) < 10) return;
      if (horizontalTravel > verticalTravel * 1.15) {
        this.galleryPageGestureAxis = 'horizontal';
      } else if (verticalTravel > horizontalTravel * 1.15) {
        this.galleryPageGestureAxis = 'vertical';
      } else {
        return;
      }
    }
    if (this.galleryPageGestureAxis === 'vertical') {
      this.galleryDismissOffsetY = Math.max(0, event.offsetY);
    }
  }

  private galleryPagePanEnd(event: GestureEvent): void {
    if (this.galleryPagePanBlockedByPanel) {
      this.galleryPagePanBlockedByPanel = false;
      this.galleryPageGestureAxis = 'none';
      return;
    }
    if (this.galleryZoomScale > 1.02) {
      this.galleryPageGestureAxis = 'none';
      return;
    }
    if (this.galleryPageGestureAxis !== 'vertical') {
      this.galleryPageGestureAxis = 'none';
      return;
    }
    const dragOffsetY: number = event.offsetY;
    const dismissThreshold: number = Math.max(72, this.galleryViewportHeight * 0.10);
    const downwardIntent: boolean = dragOffsetY >= dismissThreshold ||
      (dragOffsetY >= GALLERY_DETAIL_PANEL_FLICK_OFFSET_THRESHOLD &&
        event.velocityY >= GALLERY_DETAIL_PANEL_FLICK_VELOCITY_THRESHOLD);
    const upwardIntent: boolean = dragOffsetY <= -GALLERY_DETAIL_PANEL_SNAP_DRAG_THRESHOLD ||
      (dragOffsetY <= -GALLERY_DETAIL_PANEL_FLICK_OFFSET_THRESHOLD &&
        event.velocityY <= -GALLERY_DETAIL_PANEL_FLICK_VELOCITY_THRESHOLD);
    this.galleryPageGestureAxis = 'none';
    if (downwardIntent) {
      this.dismissGalleryDetailBySwipe();
    } else if (upwardIntent) {
      this.expandGalleryInfoPanelFromSwipe();
    } else {
      this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
        this.galleryDismissOffsetY = 0;
      });
    }
  }

  private galleryPanStart(event: GestureEvent): void {
    this.galleryPanBlockedByInfoPanel = this.galleryTouchStartedInInfoPanel(event, true);
    this.galleryGestureAxis = 'none';
    this.galleryPanStartX = this.galleryPanOffsetX;
    this.galleryPanStartY = this.galleryPanOffsetY;
  }

  private galleryPanUpdate(event: GestureEvent): void {
    if (this.galleryPanBlockedByInfoPanel) return;
    if (this.galleryZoomScale > 1.02) {
      this.galleryPanOffsetX = this.clampGalleryPanX(this.galleryPanStartX + event.offsetX);
      this.galleryPanOffsetY = this.clampGalleryPanY(this.galleryPanStartY + event.offsetY);
      return;
    }
    if (this.galleryGestureAxis === 'none') {
      const horizontalTravel: number = Math.abs(event.offsetX);
      const verticalTravel: number = Math.abs(event.offsetY);
      if (Math.max(horizontalTravel, verticalTravel) < 10) return;
      if (horizontalTravel > verticalTravel * 1.15) {
        this.galleryGestureAxis = 'horizontal';
      } else if (verticalTravel > horizontalTravel * 1.15) {
        this.galleryGestureAxis = 'vertical';
      } else {
        return;
      }
    }
    if (this.galleryGestureAxis === 'vertical') {
      // The page-level gesture owns expand/dismiss actions; this photo gesture
      // only tracks the downward offset so the page follows the finger.
      this.galleryDismissOffsetY = Math.max(0, event.offsetY);
    }
  }

  private galleryPanEnd(event: GestureEvent): void {
    if (this.galleryPanBlockedByInfoPanel) {
      this.galleryPanBlockedByInfoPanel = false;
      this.galleryGestureAxis = 'none';
      return;
    }
    if (this.galleryZoomScale > 1.02) {
      this.galleryPanOffsetX = this.clampGalleryPanX(this.galleryPanOffsetX);
      this.galleryPanOffsetY = this.clampGalleryPanY(this.galleryPanOffsetY);
      return;
    }
    if (this.galleryGestureAxis === 'horizontal') {
      this.galleryGestureAxis = 'none';
      return;
    }
    if (this.galleryGestureAxis === 'vertical') {
      this.galleryGestureAxis = 'none';
      return;
    }
    this.galleryGestureAxis = 'none';
  }

  private expandGalleryInfoPanelFromSwipe(): void {
    if (!this.galleryDetailVisible) return;
    // The photo layer also owns a single-tap chrome toggle. A swipe can finish
    // close enough to a tap for both recognizers to fire in parallel; suppress
    // that trailing tap so the panel stays open after an upward swipe.
    this.galleryChromeToggleBlockedUntil = Date.now() + 700;
    if (!this.galleryChromeVisible) {
      this.galleryChromeVisible = true;
    }
    this.galleryInfoPanelVisible = true;
    const targetHeight: number = this.galleryPanelMaximumHeight();
    this.getUIContext().animateTo({ duration: 240, curve: Curve.Friction }, () => {
      this.galleryDismissOffsetY = 0;
      this.galleryPanelHeight = targetHeight;
    });
  }

  private galleryPinchStart(event: GestureEvent): void {
    this.galleryPinchBlockedByInfoPanel = this.galleryTouchStartedInInfoPanel(event);
    if (this.galleryPinchBlockedByInfoPanel) return;
    this.galleryPinchStartScale = this.galleryZoomScale;
    this.galleryPinchStartPanX = this.galleryPanOffsetX;
    this.galleryPinchStartPanY = this.galleryPanOffsetY;
    const imageWidth: number = this.galleryBaseImageWidth() * this.galleryZoomScale;
    const imageHeight: number = this.galleryBaseImageHeight() * this.galleryZoomScale;
    if (imageWidth > 0 && imageHeight > 0 && this.galleryViewportWidth > 0 && this.galleryViewportHeight > 0) {
      const imageLeft: number = (this.galleryViewportWidth - imageWidth) / 2 + this.galleryPanOffsetX;
      const imageTop: number = (this.galleryViewportHeight - imageHeight) / 2 +
        this.galleryPhotoVerticalOffset() + this.galleryPanOffsetY;
      this.galleryPinchCenterX = Math.max(0, Math.min(1, (event.pinchCenterX - imageLeft) / imageWidth));
      this.galleryPinchCenterY = Math.max(0, Math.min(1, (event.pinchCenterY - imageTop) / imageHeight));
    } else {
      this.galleryPinchCenterX = 0.5;
      this.galleryPinchCenterY = 0.5;
    }
  }

  private galleryPinchUpdate(event: GestureEvent): void {
    if (this.galleryPinchBlockedByInfoPanel) return;
    const nextScale: number = Math.max(1, Math.min(5, this.galleryPinchStartScale * event.scale));
    if (nextScale <= 1.02) {
      this.galleryZoomScale = 1;
      this.galleryPanOffsetX = 0;
      this.galleryPanOffsetY = 0;
      return;
    }
    const scaleRatio: number = nextScale / this.galleryPinchStartScale;
    this.galleryZoomScale = nextScale;
    this.galleryPanOffsetX = this.clampGalleryPanX(this.galleryPinchStartPanX +
      (this.galleryPinchCenterX - 0.5) * this.galleryBaseImageWidth() * this.galleryPinchStartScale *
      (scaleRatio - 1), nextScale);
    this.galleryPanOffsetY = this.clampGalleryPanY(this.galleryPinchStartPanY +
      (this.galleryPinchCenterY - 0.5) * this.galleryBaseImageHeight() * this.galleryPinchStartScale *
      (scaleRatio - 1), nextScale);
  }

  private galleryPinchEnd(): void {
    if (this.galleryPinchBlockedByInfoPanel) {
      this.galleryPinchBlockedByInfoPanel = false;
      return;
    }
    if (this.galleryZoomScale <= 1.02) {
      this.galleryZoomScale = 1;
      this.galleryPanOffsetX = 0;
      this.galleryPanOffsetY = 0;
    }
    this.galleryPinchStartScale = this.galleryZoomScale;
  }

  private toggleGalleryZoom(event: GestureEvent): void {
    if (this.galleryTouchStartedInInfoPanel(event)) return;
    const nextScale: number = this.galleryZoomScale > 1.05 ? 1 : 2;
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
      this.galleryZoomScale = nextScale;
      if (nextScale === 1) {
        this.galleryPanOffsetX = 0;
        this.galleryPanOffsetY = 0;
      }
    });
  }

  private toggleGalleryChrome(): void {
    if (!this.galleryDetailVisible || Date.now() < this.galleryChromeToggleBlockedUntil) return;
    const nextChromeVisible: boolean = !this.galleryChromeVisible;
    if (!nextChromeVisible) this.endGallerySdrCompare();
    this.ensureGalleryStatusBarVisible();
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseInOut }, () => {
      this.galleryChromeVisible = nextChromeVisible;
    });
  }

  private ensureGalleryStatusBarVisible(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) return;
    this.galleryStatusBarUpdate = this.galleryStatusBarUpdate
      .then(async (): Promise<void> => {
        const mainWindow: window.Window = await window.getLastWindow(context);
        await mainWindow.setWindowSystemBarEnable(['status', 'navigation']);
        await mainWindow.setWindowSystemBarProperties({
          // Keep the system bar clear so the page's single top material can
          // extend continuously behind it.
          statusBarColor: TRANSPARENT_SYSTEM_BAR_COLOR,
          statusBarContentColor: this.galleryDetailForegroundColor()
        });
      })
      .catch((error: Object): void => {
        console.error('Failed to restore gallery status bar: ' + JSON.stringify(error));
      });
  }

  private isSystemDarkMode(): boolean {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    return context !== undefined &&
      context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private galleryDetailScrimColor(): string {
    return this.isSystemDarkMode() ? '#B3000000' : '#B3FFFFFF';
  }

  private galleryDetailForegroundColor(): string {
    // The chrome-free photo view has a black backing strip under the status
    // indicators; keep those indicators readable until the title chrome returns.
    if (this.galleryDetailVisible && !this.galleryChromeVisible) return '#FFFFFFFF';
    return this.isSystemDarkMode() ? '#FFFFFFFF' : '#FF000000';
  }

  private galleryInfoPanelPrimaryTextColor(): string {
    return this.isSystemDarkMode() ? '#FFF9FAFC' : '#FF17191C';
  }

  private galleryInfoPanelSecondaryTextColor(): string {
    return this.isSystemDarkMode() ? '#D9F9FAFC' : '#CC30343A';
  }

  private async updateGalleryPhotoTitlePosition(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) return;
    try {
      const mainWindow: window.Window = await window.getLastWindow(context);
      const avoidArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.galleryPhotoTitleTopPosition = this.getUIContext().px2vp(avoidArea.topRect.height) + 5;
    } catch (error) {
      // Keep the phone-sized fallback if the system inset is unavailable.
    }
  }

  private galleryCurrentPhotoIndex(): number {
    const selectedId: string | undefined = this.galleryCurrentItem?.id;
    if (selectedId === undefined) return -1;
    for (let index: number = 0; index < this.galleryPhotos.length; index += 1) {
      if (this.galleryPhotos[index].item.id === selectedId) return index;
    }
    return -1;
  }

  private onGallerySwiperChange(index: number): void {
    if (index < 0 || index >= this.galleryPhotos.length) return;
    this.centerGalleryThumbnail(index);
    const nextTile: GalleryPhotoTile = this.galleryPhotos[index];
    if (nextTile.item.id === this.galleryCurrentItem?.id) return;
    this.galleryStatus = '正在读取 ' + nextTile.item.displayName + '…';
    void this.inspectGallerySelection(nextTile, false);
  }

  private dismissGalleryDetailBySwipe(): void {
    if (!this.galleryDetailVisible) return;
    this.closeGalleryDetail();
  }

  private async convertGallerySelection(runImmediately: boolean): Promise<void> {
    const controller: QueueController | undefined = this.queueController;
    if (this.galleryQueuePreparing || this.galleryImporting) {
      return;
    }
    if (!this.queueLoaded || !this.queueReady || this.queueLoading || this.queueRecoveryRequired ||
      !this.settingsLoaded) {
      this.galleryStatus = this.queueRecoveryRequired
        ? '队列需要先恢复，暂不能转换这张照片'
        : '设置或队列仍在加载，暂不能转换这张照片';
      return;
    }
    if (this.pageBusy || this.queueRunning || this.cleanupRunning || this.batchExportRunning ||
      this.settingsSaving || this.livePhotoPairing || this.livePhotoPairExporting ||
      this.motionSplitting || this.motionInspecting) {
      this.galleryStatus = '当前有其他文件操作，暂不能转换这张照片';
      return;
    }
    if (this.gallerySandboxPath.length === 0 || this.galleryDetails === undefined ||
      this.galleryClassification === undefined) {
      this.galleryStatus = '请先从图库选择一张已成功读取的照片';
      return;
    }
    if (!this.gallerySupportsNativeConversion()) {
      this.galleryStatus = '这张照片不含可转换的 ProXDR 数据';
      return;
    }

    const queue: QueueController = controller === undefined ? this.getController() : controller;
    if (queue.hasPersistenceError || queue.isPersistenceBusy || this.queueHasBlockingOperation(queue)) {
      this.galleryStatus = '队列仍有未完成的保存或文件操作，请完成后再转换';
      return;
    }
    const mode: QueueModeSnapshot = this.galleryPhotoModeSnapshot();
    const existing: QueueItem | undefined = this.galleryQueueItemId.length > 0
      ? queue.get(this.galleryQueueItemId)
      : undefined;
    if (existing !== undefined) {
      if (existing.status === 'running' || existing.externalBusy) {
        this.galleryStatus = '这张照片正在处理中，请等待当前操作完成';
        return;
      }
      try {
        queue.setModeOverride(existing.id, mode);
        if (existing.status === 'succeeded') {
          queue.reconvert(existing.id);
        } else if (existing.status === 'failed') {
          queue.retry(existing.id);
        }
        await queue.persist();
        this.galleryStatus = runImmediately
          ? '已更新这张照片的设置，准备单张转换…'
          : '已更新队列中这张照片的设置';
        if (runImmediately) {
          await this.startGalleryQueueItemSingle(existing.id, queue);
        } else {
          this.showGalleryQueueAddedToast();
        }
      } catch (error) {
        this.galleryStatus = '更新队列项目失败：' + this.errorMessage(error);
      }
      return;
    }

    const sourcePath: string = this.gallerySandboxPath;
    const expectedBytes: number = this.galleryCopiedBytes;
    let item: QueueItem | undefined = undefined;
    let locked: boolean = false;
    let prepared: boolean = false;
    this.galleryQueuePreparing = true;
    this.pageBusy = true;
    this.galleryStatus = '正在把照片登记到持久化队列…';
    try {
      const sourceStat: fileIo.Stat = await fileIo.lstat(sourcePath);
      if (!sourceStat.isFile() || sourceStat.size <= 0 || sourceStat.size !== expectedBytes) {
        throw new Error('图库沙箱副本已失效或大小发生变化，请重新选择照片');
      }
      const suffix: string = this.galleryFileSuffixFromUri(sourcePath);
      item = queue.add({
        displayName: this.galleryCurrentItem?.displayName ?? ('本地照片' + suffix),
        sourceUri: sourcePath,
        modeOverride: mode
      });
      this.galleryQueueItemId = item.id;
      queue.beginExternal(item.id);
      locked = true;
      this.selectQueueItem(item.id);
      // The queue record and its source identity are durable before the
      // selected cache copy is opened or the durable input copy is created.
      await queue.persist();
      const preparedInput: QueuePrepared = await this.prepareQueueItem(item);
      const durableStat: fileIo.Stat = await fileIo.lstat(preparedInput.inputPath);
      if (!durableStat.isFile() || durableStat.size !== expectedBytes) {
        throw new Error('持久化队列副本与已检查的图库照片大小不一致');
      }
      queue.setPrepared(item.id, preparedInput.inputPath, preparedInput.details, preparedInput.classification);
      await queue.persist();
      prepared = true;
      this.galleryStatus = '照片已复制到持久化队列；原图保持不变';
    } catch (error) {
      const message: string = this.errorMessage(error);
      if (item !== undefined && locked && !queue.hasPersistenceError && !(error instanceof QueuePersistenceError)) {
        try {
          queue.markPreparationFailed(item.id, message);
          await queue.persist();
        } catch (persistError) {
          this.queueError = '图库照片已登记，但队列状态保存失败：' + this.errorMessage(persistError);
        }
      } else if (queue.hasPersistenceError || error instanceof QueuePersistenceError) {
        this.queueError = '队列记录保存失败：' + message + '；请先重试保存队列';
      }
      this.galleryStatus = '加入转换队列失败：' + message;
    } finally {
      if (item !== undefined && locked) {
        queue.endExternal(item.id);
      }
      this.galleryQueuePreparing = false;
      this.pageBusy = false;
      this.syncQueue();
    }

    if (!prepared || item === undefined) {
      return;
    }
    if (runImmediately) {
      this.galleryStatus = '正在单独转换这张照片…';
      await this.startGalleryQueueItemSingle(item.id, queue);
      return;
    }
    this.galleryStatus = '照片已加入转换队列；此设置只应用于这张照片';
    this.operationStatus = '照片已加入队列；可继续浏览，或在队列页开始处理';
    this.showGalleryQueueAddedToast();
  }

  private showGalleryQueueAddedToast(): void {
    this.showGallerySuccessToast('已加入队列');
  }

  private showGallerySuccessToast(message: string): void {
    try {
      if (this.shouldUseImmersiveMainChrome()) {
        this.showImmersiveGallerySuccessToast(message);
      } else {
        this.getUIContext().getPromptAction().showToast({
          message: message,
          duration: 2000
        });
      }
    } catch (error) {
      // Queue persistence already succeeded; a toast failure must not change that result.
    }
  }

  @Available({ minApiVersion: '26.0.0' })
  private showImmersiveGallerySuccessToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({
      message: message,
      duration: 2000,
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN
      })
    });
  }

  private galleryConvertedPhotoName(item: GalleryLibraryItem, modeKey: string): string {
    const dot: number = item.displayName.lastIndexOf('.');
    const stem: string = dot > 0 ? item.displayName.substring(0, dot) : item.displayName;
    return stem + '-' + modeKey + '.heic';
  }

  private async convertGalleryPhotoDirectly(): Promise<void> {
    if (!this.canConvertGalleryPhotoDirectly()) {
      this.galleryStatus = '照片尚未准备好，或当前有其他文件操作';
      return;
    }
    const sourceItem: GalleryLibraryItem | undefined = this.galleryCurrentItem;
    const library: HarmonyGalleryLibrary | undefined = this.galleryLibrary;
    if (sourceItem === undefined || library === undefined) return;

    const sourcePath: string = this.gallerySandboxPath;
    const expectedBytes: number = this.galleryCopiedBytes;
    const selectionSerial: number = this.gallerySelectionSerial;
    let mode: QueueModeSnapshot | undefined = undefined;
    let temporaryPath: string = '';
    let finalPath: string = '';
    let handle: number = 0;
    let timer: number = -1;
    try {
      mode = this.galleryPhotoModeSnapshot();
      const paths: Array<string> = this.nextGalleryOutputPaths();
      temporaryPath = paths[0];
      finalPath = paths[1];
    } catch (error) {
      this.galleryStatus = '无法准备图库输出路径：' + this.errorMessage(error);
      return;
    }
    if (mode === undefined) return;

    this.pageBusy = true;
    this.galleryStatus = '正在直接转换并保存新图…';
    try {
      const sourceStat: fileIo.Stat = await fileIo.lstat(sourcePath);
      if (sourceStat.isSymbolicLink() || !sourceStat.isFile() || sourceStat.size <= 0 ||
        sourceStat.size !== expectedBytes) {
        throw new Error('图库沙箱原图已失效或大小发生变化');
      }
      await this.ensureDirectory(this.parentDirectory(finalPath));
      if (temporaryPath === sourcePath || finalPath === sourcePath) {
        throw new Error('输出路径不能覆盖当前原图');
      }

      handle = xdremuxNative.progressBegin();
      if (handle === 0) throw new Error('无法创建转换进度句柄');
      timer = setInterval(() => {
        try {
          const progress: NativeProgress = xdremuxNative.progressRead(handle) as NativeProgress;
          const progressText: string = progress.total > 0
            ? String(progress.current) + ' / ' + String(progress.total)
            : '处理中';
          if (selectionSerial === this.gallerySelectionSerial) {
            this.galleryStatus = this.progressStageLabel(progress.stage) + '：' + progressText;
          }
        } catch (error) {
          // The Rust progress handle can close immediately after conversion.
        }
      }, 250);

      const conversion: NativeConversionResult = await xdremuxNative.convert(
        sourcePath,
        temporaryPath,
        mode.config,
        handle,
        ps3OptionsFor(sourcePath, mode.applePhotographicStyles3 === true)
      ) as NativeConversionResult;
      if (!conversion.success) {
        const message: string = this.display(conversion.errorMessage);
        throw new Error(message === '—' ? 'Rust 转换失败' : message);
      }

      const temporaryStat: fileIo.Stat = await fileIo.lstat(temporaryPath);
      if (temporaryStat.isSymbolicLink() || !temporaryStat.isFile() || temporaryStat.size <= 0) {
        throw new Error('转换输出为空或格式无效');
      }
      await fileIo.rename(temporaryPath, finalPath);
      const finalStat: fileIo.Stat = await fileIo.lstat(finalPath);
      if (finalStat.isSymbolicLink() || !finalStat.isFile() || finalStat.size <= 0) {
        throw new Error('转换结果校验失败');
      }

      const savedItem: GalleryLibraryItem = await library.importPhoto(
        finalPath,
        this.galleryConvertedPhotoName(sourceItem, mode.modeKey)
      );
      const savedTile: GalleryPhotoTile = { item: savedItem, path: library.pathFor(savedItem) };
      this.galleryPhotos = [savedTile, ...this.galleryPhotos.filter(
        (tile: GalleryPhotoTile): boolean => tile.item.id !== savedItem.id
      )];
      this.gallerySwiperDataSource.replaceAll(this.galleryPhotos);
      this.galleryMediaCount = this.galleryPhotos.length;
      if (selectionSerial === this.gallerySelectionSerial) {
        this.galleryStatus = '转换完成，新图已保存到 XDRemux 本地图库';
      }
      this.operationStatus = '照片已直接转换并保存为本地图库新图';
      this.showGallerySuccessToast('已转换并保存为新照片');
    } catch (error) {
      const message: string = '直接转换失败：' + this.errorMessage(error);
      if (selectionSerial === this.gallerySelectionSerial) this.galleryStatus = message;
      this.getUIContext().getPromptAction().showToast({ message: message });
    } finally {
      if (timer >= 0) clearInterval(timer);
      if (handle !== 0) {
        try {
          xdremuxNative.progressEnd(handle);
        } catch (error) {
          // Preserve the settled conversion result.
        }
      }
      for (const outputPath of [temporaryPath, finalPath]) {
        if (outputPath.length === 0) continue;
        try {
          await fileIo.unlink(outputPath);
        } catch (error) {
          // A missing scratch/output file is already cleaned up.
        }
      }
      this.pageBusy = false;
    }
  }

  private async startGalleryQueueItemSingle(itemId: string, queue: QueueController): Promise<void> {
    if (queue.isRunning || this.queueRunning) {
      this.galleryStatus = '队列正在运行，请等待当前项目完成后再单独转换';
      return;
    }
    this.selectQueueItem(itemId);
    this.closeGalleryDetail();
    this.mainTabIndex = 1;
    this.operationStatus = '正在转换所选照片；队列中的其他项目保持待处理';
    try {
      await queue.startSingle(itemId);
      const finished: QueueItem | undefined = queue.get(itemId);
      this.operationStatus = finished?.status === 'succeeded'
        ? '单张转换完成；其他队列项目仍保持待处理'
        : '单张转换结束；请检查所选项目状态';
    } catch (error) {
      this.operationStatus = '单张转换失败：' + this.errorMessage(error);
    } finally {
      this.syncQueue();
    }
  }

  private galleryPhotoTitleLabel(): string {
    return this.galleryCurrentItem?.displayName ?? '本地照片';
  }

  private galleryCameraModelLabel(): string {
    const make: string = (this.galleryDetails?.make ?? '').trim();
    const model: string = (this.galleryDetails?.model ?? '').trim();
    if (model.length > 0) {
      return make.length > 0 && model.toLowerCase().indexOf(make.toLowerCase()) < 0
        ? make + ' ' + model
        : model;
    }
    return make.length > 0 ? make : '未知机型';
  }

  private galleryPhotoModeLabel(): string {
    const displayName: string = (this.galleryCurrentItem?.displayName ?? '').toLowerCase();
    if (displayName.endsWith('-oppo.heic')) return '已转换为 OPPO';
    if (displayName.endsWith('-apple.heic')) return '已转换为 Apple';

    const classification: NativeClassificationResult | undefined = this.galleryClassification;
    const folderName: string = (classification?.folderName ?? '').trim();
    if (folderName.length > 0) return folderName;
    if (this.galleryImporting) return '正在识别模式…';
    return '未识别模式';
  }

  private galleryDetailSubtitle(): string {
    return this.galleryCameraModelLabel() + ' · ' + this.galleryPhotoModeLabel();
  }

  @Builder
  private galleryPhotoTitleOverlay() {
    if (this.galleryDetailMounted && this.galleryChromeVisible) {
      Row() {
        Marquee({
          start: true,
          step: 0.8,
          loop: -1,
          fromStart: true,
          src: this.galleryPhotoTitleLabel(),
          delay: 1400
        })
          .width('100%')
          .height(28)
          .fontColor(this.galleryDetailForegroundColor())
          .fontSize(22)
          .fontWeight(FontWeight.Bold);
      }
      .width('100%')
      .height(28)
      // Keep the scrolling filename clear of the right-side HDR/delete/share
      // controls. The HDR action is wider than the title bar's normal menu.
      .padding({ left: 68, right: this.canCompareGallerySdr() ? 152 : 120 })
      .alignItems(VerticalAlign.Center)
      .position({ x: 0, y: this.galleryPhotoTitleTopPosition })
      .hitTestBehavior(HitTestMode.None)
      .zIndex(25);
    }
  }

  private galleryFormatLabel(): string {
    if (this.galleryMimeType.length > 0) {
      const mimeType: string = this.galleryMimeType.toLowerCase();
      if (mimeType === 'image/heic' || mimeType === 'image/heif') {
        return 'HEIC';
      }
      if (mimeType === 'image/jpeg' || mimeType === 'image/jpg') {
        return 'JPEG';
      }
      const slash: number = mimeType.lastIndexOf('/');
      return (slash >= 0 ? mimeType.substring(slash + 1) : mimeType).toUpperCase();
    }
    const path: string = this.gallerySandboxPath;
    const dot: number = path.lastIndexOf('.');
    return dot >= 0 ? path.substring(dot + 1).toUpperCase() : '未知';
  }

  private async shareCurrentGalleryPhoto(): Promise<void> {
    const item: GalleryLibraryItem | undefined = this.galleryCurrentItem;
    const path: string = this.gallerySandboxPath;
    if (item === undefined || path.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '当前没有可分享的照片' });
      return;
    }

    try {
      const stat: fileIo.Stat = await fileIo.stat(path);
      if (!Number.isSafeInteger(stat.size) || stat.size <= 0) {
        throw new Error('本地照片为空或不可读');
      }
      const uiContext: UIContext = this.getUIContext();
      const context: common.UIAbilityContext = uiContext.getHostContext() as common.UIAbilityContext;
      const imageType: string = utd.getUniformDataTypeByFilenameExtension(
        item.extension,
        utd.UniformDataType.IMAGE
      );
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: imageType,
        uri: fileUri.getUriFromPath(path),
        title: item.displayName
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      });
    } catch (error) {
      const message: string = '分享照片失败：' + this.errorMessage(error);
      this.galleryStatus = message;
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private galleryPhotoHasQueueReference(path: string): boolean {
    return this.queueItems.some((item: QueueItem): boolean =>
      item.sourceUri === path || item.inputPath === path
    );
  }

  private confirmDeleteCurrentGalleryPhoto(): void {
    const item: GalleryLibraryItem | undefined = this.galleryCurrentItem;
    const tile: GalleryPhotoTile | undefined = item === undefined
      ? undefined
      : this.galleryPhotos.find((photo: GalleryPhotoTile): boolean => photo.item.id === item.id);
    if (item === undefined || tile === undefined || this.galleryLibrary === undefined) return;
    if (this.galleryImporting || this.pageBusy || this.queueRunning || this.galleryQueuePreparing) {
      this.showGallerySuccessToast('当前有文件操作，暂不能删除照片');
      return;
    }
    if (this.galleryPhotoHasQueueReference(tile.path)) {
      this.showGallerySuccessToast('该照片仍被队列记录引用，请先移除队列项目再删除');
      return;
    }

    try {
      this.getUIContext().showAlertDialog({
        title: '删除本地照片？',
        message: '将从 XDRemux 本地图库和应用沙箱中删除“' + item.displayName + '”。手机系统图库中的原图不会受影响。',
        autoCancel: true,
        buttons: [
          {
            value: '取消',
            action: (): void => {}
          },
          {
            value: '删除',
            style: DialogButtonStyle.HIGHLIGHT,
            action: (): void => {
              void this.deleteGalleryPhoto(item.id);
            }
          }
        ]
      });
    } catch (error) {
      this.showGallerySuccessToast('无法打开删除确认窗口');
    }
  }

  private async deleteGalleryPhoto(itemId: string): Promise<void> {
    const index: number = this.galleryPhotos.findIndex((photo: GalleryPhotoTile): boolean =>
      photo.item.id === itemId
    );
    const tile: GalleryPhotoTile | undefined = index >= 0 ? this.galleryPhotos[index] : undefined;
    const library: HarmonyGalleryLibrary | undefined = this.galleryLibrary;
    if (tile === undefined || library === undefined) return;
    if (this.galleryPhotoHasQueueReference(tile.path)) {
      this.showGallerySuccessToast('该照片仍被队列记录引用，请先移除队列项目再删除');
      return;
    }

    try {
      await library.removePhoto(itemId);
      const remainingPhotos: Array<GalleryPhotoTile> = this.galleryPhotos.filter(
        (photo: GalleryPhotoTile): boolean => photo.item.id !== itemId
      );
      const oldThumbnail: image.PixelMap | undefined = this.galleryThumbnailPixelMapCache.get(itemId);
      this.galleryThumbnailPixelMapCache.delete(itemId);
      this.galleryCachedThumbnailIds = this.galleryCachedThumbnailIds.filter(
        (cachedId: string): boolean => cachedId !== itemId
      );
      this.galleryThumbnailDecodeFailedIds = this.galleryThumbnailDecodeFailedIds.filter(
        (failedId: string): boolean => failedId !== itemId
      );
      this.galleryLoadedPreviewIds = this.galleryLoadedPreviewIds.filter(
        (loadedId: string): boolean => loadedId !== itemId
      );
      if (this.galleryDetailLoadedImageId === itemId) this.galleryDetailLoadedImageId = '';
      this.galleryDetailDecodedImageIds.delete(itemId);
      this.galleryInspectionCache.delete(itemId);
      this.galleryDecodedDimensionsCache.delete(itemId);
      this.galleryPhotoSettings.delete(itemId);
      if (oldThumbnail !== undefined) {
        setTimeout((): void => {
          void oldThumbnail.release();
        }, 240);
      }

      this.galleryPhotos = remainingPhotos;
      this.galleryMediaCount = remainingPhotos.length;
      this.gallerySwiperDataSource.replaceAll(remainingPhotos);
      if (remainingPhotos.length > 0) {
        const nextIndex: number = Math.min(index, remainingPhotos.length - 1);
        const nextTile: GalleryPhotoTile = remainingPhotos[nextIndex];
        this.galleryCurrentItem = nextTile.item;
        void this.inspectGallerySelection(nextTile, false);
      } else {
        this.gallerySelectionSerial += 1;
        this.galleryCurrentItem = undefined;
        this.galleryDetails = undefined;
        this.galleryClassification = undefined;
        this.gallerySandboxPath = '';
        this.galleryMimeType = '';
        this.galleryDetailVisible = false;
        this.galleryDetailMounted = false;
        this.galleryHeroTransitionActive = false;
        this.galleryStatus = '导入照片后会保存在 XDRemux 本地图库中';
      }
      this.operationStatus = '已从 XDRemux 本地图库删除照片';
      this.showGallerySuccessToast('已删除本地照片副本');
    } catch (error) {
      const message: string = '删除照片失败：' + this.errorMessage(error);
      this.galleryStatus = message;
      this.showGallerySuccessToast(message);
    }
  }

  private shouldUseImmersiveMainChrome(): boolean {
    return deviceInfo.sdkApiVersion >= 26 && deviceInfo.apiAvailable('26.0.0');
  }

  @Available({ minApiVersion: '26.0.0' })
  private updateHdsImmersiveMaterialSupport(): void {
    const supportedTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    this.supportsHdsImmersiveMaterial =
      supportedTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
  }

  @Available({ minApiVersion: '26.0.0' })
  private hdsSystemMaterialType(): hdsMaterial.MaterialType {
    return hdsMaterial.MaterialType.ADAPTIVE;
  }

  @Available({ minApiVersion: '26.0.0' })
  private hdsSystemMaterialLevel(): hdsMaterial.MaterialLevel {
    return this.supportsHdsImmersiveMaterial
      ? hdsMaterial.MaterialLevel.EXQUISITE
      : hdsMaterial.MaterialLevel.SMOOTH;
  }

  @Available({ minApiVersion: '26.0.0' })
  private hdsTabBarMaterialType(): hdsMaterial.MaterialType {
    return hdsMaterial.MaterialType.IMMERSIVE;
  }

  @Available({ minApiVersion: '26.0.0' })
  private hdsTabBarMaterialLevel(): hdsMaterial.MaterialLevel {
    return hdsMaterial.MaterialLevel.EXQUISITE;
  }

  private systemAccentColorWithAlpha(alpha: number): string {
    try {
      const accent: ColorMetrics = ColorMetrics.resourceColor($r('sys.color.ohos_id_color_activated'));
      return ColorMetrics.rgba(accent.red, accent.green, accent.blue, Math.max(0, Math.min(1, alpha))).color;
    } catch (_error) {
      return '#00000000';
    }
  }

  @Builder
  private ownGalleryPage() {
    Column() {
      if (!this.shouldUseImmersiveMainChrome()) {
        Row() {
          Column() {
            Text('图库')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'));
            Text(String(this.galleryMediaCount) + ' 张 · 仅保存在本机')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .margin({ top: 3 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 14, bottom: 12 });
      }

      if (this.galleryPhotos.length === 0 && this.shouldUseImmersiveMainChrome()) {
        Text(String(this.galleryMediaCount) + ' 张 · 仅保存在本机')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding({ left: 20, right: 20, top: 98, bottom: 12 });
      }

      if (this.galleryLoading && this.galleryPhotos.length === 0) {
        Column() {
          LoadingProgress().width(38).height(38);
          Text('正在打开本地图库…')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .margin({ top: 12 });
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);
      } else if (this.galleryPhotos.length === 0) {
        Column() {
          Text(this.galleryLoadError.length > 0 ? '本地图库暂时无法打开' : '还没有导入照片')
            .fontSize(19)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .textAlign(TextAlign.Center);
          Text(this.galleryLoadError.length > 0
            ? this.galleryLoadError
            : '点底部“＋”从系统图库添加照片。导入后原图保存在应用沙箱，可随时查看信息和转换。')
            .fontSize(14)
            .fontColor(this.galleryLoadError.length > 0
              ? $r('sys.color.ohos_id_color_alert')
              : $r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
            .lineHeight(22)
            .margin({ top: 9 });
          if (this.galleryLoadError.length > 0) {
            Button('重试')
              .height(42)
              .margin({ top: 14 })
              .enabled(!this.galleryLoading)
              .onClick((): void => {
                void this.loadGalleryLibrary();
              });
          }
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 32, right: 32, bottom: 40 });
      } else {
        Scroll(this.galleryScrollController) {
          Column() {
            if (this.shouldUseImmersiveMainChrome()) {
              Text(String(this.galleryMediaCount) + ' 张 · 仅保存在本机')
                .fontSize(13)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .padding({ left: 20, right: 20, top: 98, bottom: 12 });
            }

            Grid() {
              LazyForEach(this.gallerySwiperDataSource, (tile: GalleryPhotoTile) => {
                GridItem() {
                  Stack() {
                    if (!this.galleryPreviewIsLoaded(tile.item.id)) {
                      Stack({ alignContent: Alignment.Center }) {
                        SymbolGlyph($r('sys.symbol.picture'))
                          .fontSize(20)
                          .fontColor(['#55FFFFFF']);
                      }
                      .width('100%')
                      .height('100%')
                      .backgroundColor('#181B20');
                    }
                    Image('file://' + tile.path)
                      .width('100%')
                      .height('100%')
                      .orientation(ImageRotateOrientation.AUTO)
                      .objectFit(ImageFit.Cover)
                      .autoResize(true)
                      // Keep grid cells SDR so their shared-element source
                      // matches the SDR frame used while opening the detail.
                      .dynamicRangeMode(DynamicRangeMode.STANDARD)
                      .opacity(this.galleryPreviewIsLoaded(tile.item.id) ? 1 : 0)
                      .onComplete((event): void => {
                        this.onGalleryPreviewDecoded(tile.item.id, Number(event?.width ?? 0),
                          Number(event?.height ?? 0));
                      });
                  }
                  .width('100%')
                  .aspectRatio(1)
                  .clip(true)
                  .borderRadius(10)
                  .backgroundColor($r('sys.color.background_tertiary'))
                  .geometryTransition(tile.item.id === this.galleryCurrentItem?.id
                    ? this.galleryTransitionId(tile.item.id) : '', { follow: true })
                  .zIndex(tile.item.id === this.galleryCurrentItem?.id && this.galleryHeroTransitionActive ? 30 : 0)
                  .transition(TransitionEffect.IDENTITY)
                  .onClick((): void => {
                    this.openGalleryTile(tile);
                  });
                }
                .zIndex(tile.item.id === this.galleryCurrentItem?.id && this.galleryHeroTransitionActive ? 30 : 0)
              }, (tile: GalleryPhotoTile) => tile.item.id);
            }
            .columnsTemplate('1fr 1fr 1fr')
            .columnsGap(4)
            .rowsGap(4)
            .width('100%')
            .padding({ left: 4, right: 4, bottom: 96 });
          }
          .width('100%');
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .clipContent(ContentClipMode.BOUNDARY)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .onScrollStart((): void => {
          this.expandGalleryImportMiniBarOnScroll();
        });

        if (this.galleryLoadError.length > 0) {
          Text(this.galleryLoadError)
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_alert'))
            .width('100%')
            .padding({ left: 18, right: 18, top: 5, bottom: 5 });
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      this.galleryViewportWidth = Number(newArea.width);
      this.galleryViewportHeight = Number(newArea.height);
      if (this.galleryHeroPreloadPending) {
        this.tryStartGalleryHeroTransition(this.galleryHeroPreloadItemId);
      }
    });
  }

  @Builder
  private galleryActionTabContent() {
    Row() {}
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None);
  }

  @Builder
  private galleryConvertActionTab() {
    Column({ space: 3 }) {
      SymbolGlyph($r('sys.symbol.play_arrow_triangle_2_circlepath'))
        .fontSize(20)
        .fontColor([this.canConvertGalleryPhotoDirectly()
          ? $r('sys.color.font_primary')
          : $r('sys.color.font_secondary')]);
      Text('转换单张')
        .fontSize(10)
        .fontColor(this.canConvertGalleryPhotoDirectly()
          ? $r('sys.color.font_primary')
          : $r('sys.color.font_secondary'));
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.Default)
    .accessibilityText('转换并保存为本地图库新图')
    .onClick((): void => {
      if (!this.canConvertGalleryPhotoDirectly()) {
        this.showGallerySuccessToast('暂不支持转换该图片');
        return;
      }
      void this.convertGalleryPhotoDirectly();
    });
  }

  @Builder
  private galleryQueueActionTab() {
    Stack({ alignContent: Alignment.Center }) {
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(25)
          .fontColor([$r('sys.color.ohos_id_color_primary_contrary')])
          .hitTestBehavior(HitTestMode.None);
      }
      .width(52)
      .height(52)
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        materialColor: this.systemAccentColorWithAlpha(0.72),
        interactive: true,
        lightEffect: { color: this.systemAccentColorWithAlpha(0.58) }
      }))
      .hitTestBehavior(HitTestMode.Default)
      .accessibilityText('加入转换队列')
      .onClick((): void => {
        if (this.galleryQueuePreparing || this.galleryImporting || this.pageBusy ||
          !this.gallerySupportsNativeConversion() || this.galleryDetails === undefined ||
          this.galleryClassification === undefined || !this.settingsLoaded || !this.queueLoaded ||
          !this.queueReady || this.queueRecoveryRequired) return;
        void this.convertGallerySelection(false);
      });
    }
    .width('100%')
    .height('100%')
    .zIndex(2)
    .hitTestBehavior(HitTestMode.Transparent);
  }

  @Builder
  private gallerySettingsActionTab() {
    Column({ space: 3 }) {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(20)
        .fontColor([$r('sys.color.font_primary')]);
      Text('转换设置')
        .fontSize(10)
        .fontColor($r('sys.color.font_primary'));
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.Default)
    .accessibilityText('此照片的转换设置')
    .onClick((): void => {
      if (!this.settingsLoaded || this.settingsSaving || this.galleryImporting) return;
      this.openGalleryPhotoSettings();
    });
  }

  private openGalleryPhotoSettings(): void {
    this.galleryPanelMode = 'settings';
    const requestedHeight: number = this.clampGalleryPanelHeight(Math.max(
      this.galleryPanelHeight,
      this.galleryViewportHeight * 0.68
    ));
    const targetHeight: number = this.galleryPanelSnapTarget(requestedHeight);
    this.getUIContext().animateTo({ duration: 260, curve: Curve.Friction }, () => {
      this.galleryPanelHeight = targetHeight;
    });
  }

  private galleryThumbnailStripVisible(): boolean {
    return this.galleryChromeVisible && this.galleryInfoPanelVisible &&
      this.galleryPanelHeight <= GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT + 4 && !this.galleryHeroOpening;
  }

  @Builder
  private galleryThumbnailStrip() {
    Scroll(this.galleryThumbnailScroller) {
      Row({ space: 8 }) {
        LazyForEach(this.gallerySwiperDataSource, (tile: GalleryPhotoTile) => {
          Stack() {
            if (this.galleryCachedThumbnailIds.includes(tile.item.id) &&
              this.galleryThumbnailPixelMapCache.get(tile.item.id) !== undefined) {
              Image(this.galleryThumbnailPixelMapCache.get(tile.item.id) as image.PixelMap)
                .width(58)
                .height(70)
                .orientation(ImageRotateOrientation.AUTO)
                .objectFit(ImageFit.Cover)
                .autoResize(true)
                .backgroundColor('#17191D');
            } else if (this.galleryThumbnailDecodeFailedIds.includes(tile.item.id)) {
              Image('file://' + tile.path)
                .width(58)
                .height(70)
                .orientation(ImageRotateOrientation.AUTO)
                .objectFit(ImageFit.Cover)
                .autoResize(true)
                .dynamicRangeMode(DynamicRangeMode.STANDARD)
                .backgroundColor('#17191D');
            } else {
              Stack({ alignContent: Alignment.Center }) {
                SymbolGlyph($r('sys.symbol.picture'))
                  .fontSize(16)
                  .fontColor(['#55FFFFFF']);
              }
              .width(58)
              .height(70)
              .backgroundColor('#17191D');
            }
            if (tile.item.id === this.galleryCurrentItem?.id) {
              Blank()
                .width(58)
                .height(70)
                .border({ width: 2, color: $r('sys.color.ohos_id_color_activated') })
                .borderRadius(9);
            }
          }
          .width(58)
          .height(70)
          .clip(true)
          .borderRadius(9)
          .backgroundColor('#17191D')
          .onAppear((): void => {
            this.touchGalleryThumbnail(tile);
          })
          .onClick((): void => {
              const targetIndex: number = this.galleryPhotos.findIndex(
                (photo: GalleryPhotoTile): boolean => photo.item.id === tile.item.id
              );
              if (targetIndex < 0) return;
              this.centerGalleryThumbnail(targetIndex);
              if (targetIndex !== this.galleryCurrentPhotoIndex()) {
                try {
                  this.galleryDetailSwiperController.changeIndex(targetIndex, false);
                } catch (error) {
                  void this.inspectGallerySelection(tile, false);
                }
              }
          });
        }, (tile: GalleryPhotoTile): string => tile.item.id);
      }
      .padding({ left: 18, right: 18 });
    }
    .width('100%')
    .height(74)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .onAppear((): void => {
      this.centerGalleryThumbnail(this.galleryCurrentPhotoIndex(), false);
    })
    .position({
      x: 0,
      y: Math.max(0, this.galleryViewportHeight - GALLERY_DETAIL_PANEL_BOTTOM_INSET -
        GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT - GALLERY_DETAIL_THUMBNAIL_GAP -
        GALLERY_DETAIL_THUMBNAIL_STRIP_HEIGHT)
    })
    .opacity(this.galleryThumbnailStripVisible() ? 1 : 0)
    .hitTestBehavior(this.galleryThumbnailStripVisible() ? HitTestMode.Default : HitTestMode.None)
    .zIndex(9);
  }

  @Builder
  private gallerySdrCompareButton() {
    if (this.canCompareGallerySdr()) {
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        Text(this.gallerySdrCompareLoading ? '…' : this.gallerySdrCompareActive ? 'SDR' : 'HDR')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'));
      }
      .width(40)
      .height(40)
      .systemMaterial(this.galleryTopActionMaterial())
      .backgroundColor(Color.Transparent)
      .accessibilityText('按住显示 SDR，松开恢复 HDR')
      .gesture(
        LongPressGesture({ repeat: false, duration: 450 })
          .onAction((): void => {
            void this.beginGallerySdrCompare();
          })
          .onActionEnd((): void => {
            this.endGallerySdrCompare();
          })
      )
      .zIndex(22);
    }
  }

  private galleryTopActionMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      colorInvert: false,
      interactive: true,
      // Keep the system's neutral white light response; the accent-color tint
      // made the glass look blue at rest.
      lightEffect: {}
    });
  }

  @Builder
  private galleryDeleteButton() {
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(18)
        .fontColor([$r('sys.color.font_primary')]);
    }
    .width(40)
    .height(40)
    .systemMaterial(this.galleryTopActionMaterial())
    .backgroundColor(Color.Transparent)
    .accessibilityText('删除本地照片')
    .onClick((): void => {
      this.confirmDeleteCurrentGalleryPhoto();
    });
  }

  @Builder
  private galleryShareButton() {
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      SymbolGlyph($r('sys.symbol.share'))
        .fontSize(18)
        .fontColor([$r('sys.color.font_primary')]);
    }
    .width(40)
    .height(40)
    .systemMaterial(this.galleryTopActionMaterial())
    .backgroundColor(Color.Transparent)
    .accessibilityText('分享照片')
    .onClick((): void => {
      void this.shareCurrentGalleryPhoto();
    });
  }

  @Builder
  private galleryDetailTopActionBar() {
    if (this.galleryChromeVisible && this.galleryCurrentItem !== undefined) {
      Stack() {
        Button({ type: ButtonType.Circle, stateEffect: false }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(18)
            .fontColor([$r('sys.color.font_primary')]);
        }
        .width(40)
        .height(40)
        .systemMaterial(this.galleryTopActionMaterial())
        .backgroundColor(Color.Transparent)
        .accessibilityText('返回图库')
        .onClick((): void => {
          this.closeGalleryDetail();
        })
        .position({ x: 20, y: 0 })
        .zIndex(24);

        Row({ space: 8 }) {
          if (this.canCompareGallerySdr()) {
            this.gallerySdrCompareButton();
          }
          this.galleryDeleteButton();
          this.galleryShareButton();
        }
        .width('100%')
        .height(40)
        .padding({ right: 12 })
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
        .position({ x: 0, y: 0 })
        .zIndex(23);
      }
      .width('100%')
      .height(40)
      .position({ x: 0, y: 0 });
    }
  }

  @Builder
  private galleryDetailInfoPanel() {
    Stack() {
      if (this.galleryPanelHeight > GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT + 1) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundEffect({
            radius: 32,
            saturation: 1.12,
            brightness: 1.0
          })
          .backgroundColor(this.galleryDetailScrimColor())
          .borderRadius(26)
          .hitTestBehavior(HitTestMode.None);
      }
      Column() {
      Row() {
        Blank();
        Column()
          .width(38)
          .height(5)
          .backgroundColor(this.galleryPanelHeight <= GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT + 1
            ? '#80FFFFFF' : '#AFFFFFFF')
          .borderRadius(3)
          .shadow({ radius: 5, color: '#99000000', offsetY: 1 });
        Blank();
      }
      .width('100%')
      .height(GALLERY_DETAIL_PANEL_HANDLE_HEIGHT)
      .justifyContent(FlexAlign.Center)
      .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
      .priorityGesture(
        PanGesture({ fingers: 1, distance: 2 })
          .onActionStart((): void => {
            this.galleryPanelDragStart();
          })
          .onActionUpdate((event: GestureEvent): void => {
            this.galleryPanelDragUpdate(event);
          })
          .onActionEnd((event: GestureEvent): void => {
            this.galleryPanelDragEnd(event);
          }),
        GestureMask.IgnoreInternal
      );
      Scroll() {
      Column() {
        if (this.galleryPanelMode === 'settings') {
          this.galleryPhotoConversionSettingsPanel();
        } else {
        Row() {
          Column() {
            Text(this.galleryFormatLabel())
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.galleryInfoPanelPrimaryTextColor());
            Text(String(this.galleryDetails?.width ?? 0) + ' × ' +
              String(this.galleryDetails?.height ?? 0) + ' · ' +
              this.display(this.galleryDetails?.hdrKind))
              .fontSize(14)
              .fontColor(this.galleryInfoPanelSecondaryTextColor())
              .margin({ top: 4 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);
          Text(this.galleryClassification?.family ?? '照片')
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_activated'))
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor($r('sys.color.background_tertiary'))
            .borderRadius(18);
        }
        .width('100%');

        Text(this.galleryCurrentItem?.displayName ?? '本地照片')
          .fontSize(13)
          .fontColor(this.galleryInfoPanelSecondaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 8 });
        if (this.gallerySandboxPath.length > 0) {
          Text('本地图库原图已校验 · ' + String(this.galleryCopiedBytes) + ' B')
            .fontSize(12)
            .fontColor(this.galleryInfoPanelSecondaryTextColor())
            .width('100%')
            .margin({ top: 6 });
        }

        Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ top: 14, bottom: 12 });
        Text('转换方式')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.galleryInfoPanelPrimaryTextColor())
          .width('100%');
        Text('此照片设置：' + (this.settingsLoaded ? this.galleryPhotoSettingsSummary() : '设置加载中…'))
          .fontSize(14)
          .fontColor(this.galleryInfoPanelPrimaryTextColor())
          .width('100%')
          .margin({ top: 6 });
        Text('转换会生成新图片并保留原图；导出时可选择保存位置。')
          .fontSize(12)
          .fontColor(this.galleryInfoPanelSecondaryTextColor())
          .width('100%')
          .margin({ top: 4, bottom: 10 });
        Text(this.galleryStatus)
          .fontSize(12)
          .fontColor(this.galleryStatus.indexOf('失败') >= 0
            ? $r('sys.color.ohos_id_color_alert')
            : this.galleryInfoPanelSecondaryTextColor())
          .width('100%')
          .margin({ top: 8 });

        Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ top: 14, bottom: 6 });
        Text('照片信息')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.galleryInfoPanelPrimaryTextColor())
          .width('100%')
          .margin({ top: 8, bottom: 4 });
        if (this.galleryDetails !== undefined) {
          Text('相机  ' + this.display(this.galleryDetails.make) + ' ' + this.display(this.galleryDetails.model))
            .fontSize(14)
            .fontColor(this.galleryInfoPanelPrimaryTextColor())
            .width('100%');
          Text('拍摄时间  ' + this.display(this.galleryDetails.dateTime))
            .fontSize(13)
            .fontColor(this.galleryInfoPanelSecondaryTextColor())
            .width('100%')
            .margin({ top: 8 });
          Text('曝光  ' + this.display(this.galleryDetails.exposureTime) + ' · 光圈  ' +
            this.display(this.galleryDetails.fNumber) + ' · ISO  ' + this.display(this.galleryDetails.iso))
            .fontSize(13)
            .fontColor(this.galleryInfoPanelSecondaryTextColor())
            .width('100%')
            .margin({ top: 8 });
          Text('焦距  ' + this.display(this.galleryDetails.focalLength) + ' · 35mm  ' +
            this.display(this.galleryDetails.focalLength35mm) + ' · 曝光补偿  ' +
            this.display(this.galleryDetails.exposureBias))
            .fontSize(13)
            .fontColor(this.galleryInfoPanelSecondaryTextColor())
            .width('100%')
            .margin({ top: 8 });
          Text('拍摄分类  ' + (this.galleryClassification?.family ?? '未知') +
            (this.galleryClassification?.modeKey !== null && this.galleryClassification?.modeKey !== undefined
              ? ' · ' + this.galleryClassification.modeKey
              : ''))
            .fontSize(13)
            .fontColor(this.galleryInfoPanelSecondaryTextColor())
            .width('100%')
            .margin({ top: 8 });
        }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        const contentHeight: number = Number(newArea.height);
        if (Math.abs(contentHeight - this.galleryInfoPanelContentHeight) < 1) return;
        this.galleryInfoPanelContentHeight = contentHeight;
        if (this.galleryPanelHeight > GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT + 1) {
          const targetHeight: number = this.galleryPanelMaximumHeight();
          if (Math.abs(targetHeight - this.galleryPanelHeight) > 2) {
            this.galleryPanelHeight = targetHeight;
          }
        }
      });
    }
      .layoutWeight(1)
      .width('100%')
      .padding({ bottom: 24 })
      .opacity(Math.max(0, Math.min(1,
        (this.galleryPanelHeight - GALLERY_DETAIL_PANEL_COLLAPSED_HEIGHT) / 76)))
      .parallelGesture(
        PanGesture({ fingers: 1, distance: 2 })
          .onActionStart((): void => {
            this.galleryPanelBodyDragStart();
          })
          .onActionUpdate((event: GestureEvent): void => {
            this.galleryPanelBodyDragUpdate(event);
          })
          .onActionEnd((event: GestureEvent): void => {
            this.galleryPanelBodyDragEnd(event);
          }),
        GestureMask.Normal
      )
      .nestedScroll({
        scrollForward: NestedScrollMode.PARENT_FIRST,
        scrollBackward: NestedScrollMode.SELF_FIRST
      })
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        this.galleryInfoPanelScrollViewportHeight = Number(newArea.height);
      });
      Blank()
        .height(GALLERY_DETAIL_BAR_HEIGHT)
        .hitTestBehavior(HitTestMode.None);
    }
    .width('100%')
    .height(this.galleryPanelHeight)
    .padding({ left: 18, right: 18, bottom: 0 })
  }
  .width(Math.max(0, this.galleryViewportWidth - 32))
  .height(this.galleryPanelHeight)
    .position({ x: 16, y: this.galleryPanelTop() })
    .zIndex(8);
  }

  @Builder
  private galleryPhotoConversionSettingsPanel() {
    Column() {
      Row() {
        Button('‹ 返回照片信息')
          .fontSize(13)
          .height(38)
          .onClick((): void => {
            this.galleryPanelMode = 'info';
          });
        Blank();
        Text('仅此照片')
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_activated'))
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor($r('sys.color.background_tertiary'))
          .borderRadius(16);
      }
      .width('100%');

      Text('转换设置')
        .fontSize(25)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.galleryInfoPanelPrimaryTextColor())
        .width('100%')
        .margin({ top: 8 });
      Text(this.galleryCurrentItem?.displayName ?? '本地照片')
        .fontSize(13)
        .fontColor(this.galleryInfoPanelSecondaryTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 4 });
      Text('设置只随这张照片的转换任务保存，不会改动全局设置。')
        .fontSize(12)
        .fontColor(this.galleryInfoPanelSecondaryTextColor())
        .width('100%')
        .margin({ top: 5, bottom: 12 });

      Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ bottom: 12 });
      Text('此照片可用的输出格式')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.galleryInfoPanelPrimaryTextColor())
        .width('100%');

      if (this.gallerySupportedOutputModes().length === 0) {
        Text('未检测到 XDRemux 支持的 ProXDR 数据，暂时没有可用的转换格式。')
          .fontSize(14)
          .fontColor(this.galleryInfoPanelSecondaryTextColor())
          .lineHeight(21)
          .width('100%')
          .margin({ top: 8 });
      } else {
        if (this.gallerySupportedOutputModes().includes('oppo')) {
          Row() {
            Radio({ value: 'oppo', group: 'xdremux-gallery-output-mode' })
              .checked(this.galleryPhotoSettingsView.outputMode === 'oppo')
              .onChange((checked: boolean): void => {
                if (checked) this.setGalleryPhotoOutputMode('oppo');
              });
            Text('OPPO 兼容')
              .fontSize(14)
              .fontColor(this.galleryInfoPanelPrimaryTextColor())
              .margin({ left: 9 });
          }
          .width('100%')
          .height(46)
          .onClick((): void => {
            this.setGalleryPhotoOutputMode('oppo');
          });
        }
        if (this.gallerySupportedOutputModes().includes('apple')) {
          Row() {
            Radio({ value: 'apple', group: 'xdremux-gallery-output-mode' })
              .checked(this.galleryPhotoSettingsView.outputMode === 'apple')
              .onChange((checked: boolean): void => {
                if (checked) this.setGalleryPhotoOutputMode('apple');
              });
            Text('Apple 标准')
              .fontSize(14)
              .fontColor(this.galleryInfoPanelPrimaryTextColor())
              .margin({ left: 9 });
          }
          .width('100%')
          .height(46)
          .onClick((): void => {
            this.setGalleryPhotoOutputMode('apple');
          });
        }

        if (this.galleryPhotoSettingsView.outputMode === 'oppo') {
          Text('OPPO 兼容模式')
            .fontSize(14)
            .fontColor(this.galleryInfoPanelPrimaryTextColor())
            .width('100%')
            .margin({ top: 8 });
          Select(OPPO_COMPAT_OPTIONS.map((option: SettingsOption): SelectOption => {
            return { value: option.label };
          }))
            .selected(this.compatIndex(this.galleryPhotoSettingsView.oppoCompat))
            .value(compatLabel(this.galleryPhotoSettingsView.oppoCompat))
            .fontColor(this.galleryInfoPanelPrimaryTextColor())
            .optionFont({ size: 14, weight: FontWeight.Regular })
            .selectedOptionFont({ size: 14, weight: FontWeight.Medium })
            .width('100%')
            .margin({ top: 5 })
            .onSelect((index: number, text?: string): void => {
              if (index >= 0 && index < OPPO_COMPAT_OPTIONS.length) {
                this.setGalleryPhotoCompat(OPPO_COMPAT_OPTIONS[index].value);
              }
            });
          Text('保留相机附加信息')
            .fontSize(14)
            .fontColor(this.galleryInfoPanelPrimaryTextColor())
            .width('100%')
            .margin({ top: 10 });
          Select(OPPO_CAMERA_TAIL_OPTIONS.map((option: SettingsOption): SelectOption => {
            return { value: option.label };
          }))
            .selected(this.cameraTailIndex(this.galleryPhotoSettingsView.oppoCameraTail))
            .value(cameraTailLabel(this.galleryPhotoSettingsView.oppoCameraTail))
            .fontColor(this.galleryInfoPanelPrimaryTextColor())
            .optionFont({ size: 14, weight: FontWeight.Regular })
            .selectedOptionFont({ size: 14, weight: FontWeight.Medium })
            .width('100%')
            .margin({ top: 5 })
            .onSelect((index: number, text?: string): void => {
              if (index >= 0 && index < OPPO_CAMERA_TAIL_OPTIONS.length) {
                this.setGalleryPhotoCameraTail(OPPO_CAMERA_TAIL_OPTIONS[index].value);
              }
            });
        } else {
          Text(this.gallerySupportsApplePhotoData()
            ? '本图为 HEIC/HEIF，可用的 Apple 摄影数据选项如下。'
            : '本图不支持 Apple 摄影风格或人像数据，因此只显示 Apple 标准输出。')
            .fontSize(12)
            .fontColor(this.galleryInfoPanelSecondaryTextColor())
            .lineHeight(19)
            .width('100%')
            .margin({ top: 6, bottom: 4 });
          if (this.gallerySupportsApplePhotoData()) {
            Row() {
              Text('摄影风格数据')
                .fontSize(14)
                .fontColor(this.galleryInfoPanelPrimaryTextColor())
                .layoutWeight(1);
              Toggle({ type: ToggleType.Switch, isOn: this.galleryPhotoSettingsView.applePhotographicStyles })
                .enabled(!this.galleryPhotoSettingsView.applePhotographicStyles3)
                .onChange((isOn: boolean): void => {
                  this.setGalleryPhotoStyles(isOn);
                });
            }
            .width('100%')
            .height(46);
            Row() {
              Text('摄影风格 3（质感 + 颗粒）')
                .fontSize(14)
                .fontColor(this.galleryInfoPanelPrimaryTextColor())
                .layoutWeight(1);
              Toggle({ type: ToggleType.Switch, isOn: this.galleryPhotoSettingsView.applePhotographicStyles3 })
                .onChange((isOn: boolean): void => {
                  this.setGalleryPhotoStyles3(isOn);
                });
            }
            .width('100%')
            .height(46);
          }
          if (this.gallerySupportsPortraitData()) {
            Row() {
              Text('Apple 人像数据')
                .fontSize(14)
                .fontColor(this.galleryInfoPanelPrimaryTextColor())
                .layoutWeight(1);
              Toggle({ type: ToggleType.Switch, isOn: this.galleryPhotoSettingsView.applePortrait })
                .onChange((isOn: boolean): void => {
                  this.setGalleryPhotoPortrait(isOn);
                });
            }
            .width('100%')
            .height(46);
          }
        }

        Row() {
          Text('严格 ISO 兼容')
            .fontSize(14)
            .fontColor(this.galleryInfoPanelPrimaryTextColor())
            .layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.galleryPhotoSettingsView.strictTmap })
            .onChange((isOn: boolean): void => {
              this.setGalleryPhotoStrictTmap(isOn);
            });
        }
        .width('100%')
        .height(46)
        .margin({ top: 8 });
      }

      Text('当前转换：' + this.galleryPhotoSettingsSummary())
        .fontSize(13)
        .fontColor(this.galleryInfoPanelSecondaryTextColor())
        .width('100%')
        .margin({ top: 12 });
      Button('完成')
        .width('100%')
        .height(44)
        .margin({ top: 12 })
        .onClick((): void => {
          this.galleryPanelMode = 'info';
        });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 18, right: 18, top: 12, bottom: 28 });
  }

  @Builder
  private galleryDetailPage() {
    Stack() {
      Stack() {
        Stack() {
        if (this.galleryPhotos.length > 0) {
          Swiper(this.galleryDetailSwiperController) {
            LazyForEach(this.gallerySwiperDataSource, (tile: GalleryPhotoTile) => {
                Stack({ alignContent: Alignment.Center }) {
                  Stack() {
                    if (tile.item.id === this.galleryCurrentItem?.id && this.gallerySdrCompareActive &&
                      this.gallerySdrPreviewItemId === tile.item.id && this.gallerySdrPreviewPixelMap !== undefined) {
                      Image(this.gallerySdrPreviewPixelMap as image.PixelMap)
                        .width('100%')
                        .height('100%')
                        .orientation(ImageRotateOrientation.AUTO)
                        .objectFit(ImageFit.Contain)
                        .autoResize(true)
                        .dynamicRangeMode(DynamicRangeMode.STANDARD)
                        .onComplete((event): void => {
                          this.onGalleryDetailImageDecoded(tile.item.id, Number(event?.width ?? 0),
                            Number(event?.height ?? 0), false);
                        });
                    } else if (tile.item.id === this.galleryCurrentItem?.id && this.galleryHeroOpening) {
                      // Keep the shared element on the original image and its
                      // natural aspect ratio; only promote it to HDR after the
                      // geometry transition has settled.
                      Image('file://' + tile.path)
                        .width('100%')
                        .height('100%')
                        .orientation(ImageRotateOrientation.AUTO)
                        .objectFit(ImageFit.Contain)
                        .autoResize(true)
                        .dynamicRangeMode(DynamicRangeMode.STANDARD)
                        .onComplete((event): void => {
                          this.onGalleryDetailImageDecoded(tile.item.id, Number(event?.width ?? 0),
                            Number(event?.height ?? 0), false);
                        });
                    } else {
                      Image('file://' + tile.path)
                        .width('100%')
                        .height('100%')
                        .orientation(ImageRotateOrientation.AUTO)
                        .objectFit(ImageFit.Contain)
                        .autoResize(true)
                        .dynamicRangeMode(tile.item.id === this.galleryCurrentItem?.id
                          ? DynamicRangeMode.HIGH : DynamicRangeMode.STANDARD)
                        .onComplete((event): void => {
                          this.onGalleryDetailImageDecoded(tile.item.id, Number(event?.width ?? 0),
                            Number(event?.height ?? 0));
                        });
                    }
                    if (tile.item.id === this.galleryCurrentItem?.id && !this.galleryHeroOpening &&
                      this.galleryThumbnailPixelMapCache.get(tile.item.id) !== undefined) {
                      Image(this.galleryThumbnailPixelMapCache.get(tile.item.id) as image.PixelMap)
                        .width('100%')
                        .height('100%')
                        .orientation(ImageRotateOrientation.AUTO)
                        .objectFit(ImageFit.Contain)
                        .autoResize(true)
                        .dynamicRangeMode(DynamicRangeMode.STANDARD)
                        .opacity(this.galleryDetailLoadedImageId === tile.item.id ? 0 : 1)
                        .hitTestBehavior(HitTestMode.None);
                    }
                  }
                  .width(this.galleryImageFrameWidth(tile.item.id))
                  .height(this.galleryImageFrameHeight(tile.item.id))
                  .clip(true)
                  .scale({
                    x: tile.item.id === this.galleryCurrentItem?.id ? this.galleryZoomScale : 1,
                    y: tile.item.id === this.galleryCurrentItem?.id ? this.galleryZoomScale : 1
                  })
                  .translate({
                    x: tile.item.id === this.galleryCurrentItem?.id ? this.galleryPanOffsetX : 0,
                    y: (tile.item.id === this.galleryCurrentItem?.id ? this.galleryPanOffsetY : 0) +
                      this.galleryPhotoVerticalOffset()
                  })
                  .geometryTransition(tile.item.id === this.galleryCurrentItem?.id
                    ? this.galleryTransitionId(tile.item.id) : '')
                  .transition(TransitionEffect.IDENTITY);
                }
                .width('100%')
                .height('100%')
                .clip(true)
                .gesture(
                  GestureGroup(GestureMode.Parallel,
                    PanGesture({ fingers: 1, distance: this.galleryZoomScale > 1.02 ? 3 : 50 })
                      .onActionStart((event: GestureEvent): void => {
                        this.galleryPanStart(event);
                      })
                      .onActionUpdate((event: GestureEvent): void => {
                        this.galleryPanUpdate(event);
                      })
                      .onActionEnd((event: GestureEvent): void => {
                        this.galleryPanEnd(event);
                      }),
                    PinchGesture({ fingers: 2, distance: 1 })
                      .onActionStart((event: GestureEvent): void => {
                        this.galleryPinchStart(event);
                      })
                      .onActionUpdate((event: GestureEvent): void => {
                        this.galleryPinchUpdate(event);
                      })
                      .onActionEnd((): void => {
                        this.galleryPinchEnd();
                      }),
                    GestureGroup(GestureMode.Exclusive,
                      TapGesture({ count: 2 })
                        .onAction((event: GestureEvent): void => {
                          this.toggleGalleryZoom(event);
                        }),
                      TapGesture({ count: 1 })
                        .onAction((): void => {
                          this.toggleGalleryChrome();
                        })
                    )
                  )
                );
            }, (tile: GalleryPhotoTile): string => tile.item.id);
          }
          .width('100%')
          .height('100%')
          .index(Math.max(0, this.galleryCurrentPhotoIndex()))
          .loop(true)
          .duration(260)
          .cachedCount(1)
          .indicator(false)
          .disableSwipe(this.galleryZoomScale > 1.02)
          .onChange((index: number): void => {
            this.onGallerySwiperChange(index);
          });
        } else {
          Column() {
            if (this.galleryImporting) {
              LoadingProgress().width(34).height(34);
            }
            Text(this.galleryImporting ? '正在读取所选照片…' : this.galleryStatus)
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .margin({ top: 12 });
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor($r('sys.color.background_tertiary'));
        }

      if (this.galleryDetailVisible && this.gallerySandboxPath.length > 0 && this.galleryPhotos.length > 1) {
        this.galleryThumbnailStrip();
      }
      if (this.galleryChromeVisible && this.galleryInfoPanelVisible) {
        this.galleryDetailInfoPanel();
      }
      }

      .width('100%')
      .height('100%')
      .backgroundColor(this.galleryHeroTransitionActive ? Color.Transparent : '#000000')
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        this.galleryViewportWidth = Number(newArea.width);
        this.galleryViewportHeight = Number(newArea.height);
      });
      if (this.galleryChromeVisible) {
        Column()
          .width('100%')
          .height(104)
          .backgroundEffect({ radius: 32, saturation: 1.12, brightness: 1.0 })
          .backgroundColor(this.galleryDetailScrimColor())
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
          .hitTestBehavior(HitTestMode.None)
          .position({ x: 0, y: 0 })
          .zIndex(19);
      }
      HdsNavigation() {
        Row() {}
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None);
      }
      .width('100%')
      .height(104)
      .titleBar({
        padding: {
          start: LengthMetrics.vp(68),
          end: LengthMetrics.vp(156)
        },
        content: {
          title: {
            mainTitle: this.galleryPhotoTitleLabel(),
            subTitle: this.galleryDetailSubtitle()
          },
          stackBuilder: (): void => this.galleryDetailTopActionBar()
        },
        style: {
          blurStrategy: BlurStrategy.DISABLE,
          systemMaterialEffect: {
            materialType: this.hdsSystemMaterialType(),
            materialLevel: this.hdsSystemMaterialLevel()
          },
          originalStyle: {
            backgroundStyle: { backgroundColor: '#00000000' },
            contentStyle: { titleStyle: { mainTitleColor: '#00000000' } }
          },
          scrollEffectStyle: {
            backgroundStyle: { backgroundColor: '#00000000' },
            contentStyle: { titleStyle: { mainTitleColor: '#00000000' } }
          }
        },
        avoidLayoutSafeArea: true,
        enableComponentSafeArea: true
      })
      .titleMode(HdsNavigationTitleMode.MINI)
      .hideTitleBar(!this.galleryChromeVisible, true)
      .hideBackButton(true)
      .hideToolBar(true)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
      .backgroundColor(Color.Transparent)
      .hitTestBehavior(HitTestMode.None)
      .position({ x: 0, y: 0 })
      .zIndex(20);
    }
    .width('100%')
    .height('100%')
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .zIndex(10);

      if (this.galleryChromeVisible && this.galleryInfoPanelVisible) {
        HdsTabs() {
          TabContent() {
            this.galleryActionTabContent();
          }
          .tabBar(this.galleryConvertActionTab())

          TabContent() {
            this.galleryActionTabContent();
          }
          .tabBar(this.galleryQueueActionTab())

          TabContent() {
            this.galleryActionTabContent();
          }
          .tabBar(this.gallerySettingsActionTab())
        }
        .barOverlap(true)
        .barPosition(BarPosition.End)
        .vertical(false)
        .barMode(BarMode.Fixed)
        .barHeight(GALLERY_DETAIL_BAR_HEIGHT)
        .scrollable(false)
        .barFloatingStyle({
          barWidth: { smallWidth: 280, mediumWidth: 280, largeWidth: 280 },
          barBottomMargin: 28,
          adaptToHandedness: false,
          barOpacity: 1,
          gradientMask: { maskColor: Color.Transparent, maskHeight: 1 },
          systemMaterialEffect: {
            materialType: this.hdsTabBarMaterialType(),
            materialLevel: this.hdsTabBarMaterialLevel()
          }
        })
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(HitTestMode.Transparent)
        .zIndex(15);
      }
      this.galleryPhotoTitleOverlay();
    }
    .width('100%')
    .height('100%')
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .translate({ x: 0, y: this.galleryDismissOffsetY })
    .opacity(Math.max(0.7, 1 - Math.abs(this.galleryDismissOffsetY) /
      Math.max(this.galleryViewportHeight, 1) * 0.3))
    .backgroundColor(this.galleryHeroTransitionActive ? Color.Transparent : '#000000')
    .zIndex(10)
    .transition(TransitionEffect.IDENTITY)
    .parallelGesture(
      PanGesture({ fingers: 1, distance: 10 })
        .onActionStart((event: GestureEvent): void => {
          this.galleryPagePanStart(event);
        })
        .onActionUpdate((event: GestureEvent): void => {
          this.galleryPagePanUpdate(event);
        })
        .onActionEnd((event: GestureEvent): void => {
          this.galleryPagePanEnd(event);
        }),
      GestureMask.Normal
    );
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

  private nextGalleryOutputPaths(): Array<string> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('应用上下文不可用');
    }
    this.outputSerial += 1;
    const stem: string = 'xdremux-gallery-' + String(Date.now()) + '-' + String(this.outputSerial);
    const outputDirectory: string = context.filesDir + '/outputs';
    const temporaryPath: string = outputDirectory + '/' + stem + '.heic.tmp';
    const finalPath: string = outputDirectory + '/' + stem + '.heic';
    if (this.queueSandbox !== undefined) {
      this.queueSandbox.pathPolicy.validate(temporaryPath);
      this.queueSandbox.pathPolicy.validate(finalPath);
    }
    return [temporaryPath, finalPath];
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

  private selectedShareRequiresReselection(): boolean {
    const selected: QueueItem | undefined = this.selectedItem();
    return selected !== undefined && selected.sourceKind === 'share' && selected.status === 'failed' &&
      selected.inputPath.length === 0;
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
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .margin({ top: 14, bottom: 6 });
      Text('识别和拆分只使用当前项目的沙盒输入；结果绑定当前项目并保留在本次运行，重启后可重新识别和拆分。')
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%');
      Text('当前输入：' + this.display(this.motionInspection.inputPath))
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
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
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .margin({ top: 6 });
        Text('静态范围：' + String(this.motionInspection.report.stillStart) + '–' +
          String(this.motionInspection.report.stillEnd) + ' · 视频范围：' +
          String(this.motionInspection.report.videoStart) + '–' +
          String(this.motionInspection.report.videoEnd))
          .fontSize(13)
          .fontColor($r('sys.color.font_primary'))
          .width('100%');
        if (this.motionInspection.report.primaryBytes !== undefined ||
          this.motionInspection.report.secondaryBytes !== undefined) {
          Text('视频字节：主 ' + this.displayNumber(this.motionInspection.report.primaryBytes) +
            ' · 副 ' + this.displayNumber(this.motionInspection.report.secondaryBytes))
            .fontSize(13)
            .fontColor($r('sys.color.font_primary'))
            .width('100%');
        }
        Text('视频：' + this.displayNumber(this.motionInspection.report.videoWidth) + ' × ' +
          this.displayNumber(this.motionInspection.report.videoHeight) + ' · 时长(ms)：' +
          this.displayNumber(this.motionInspection.report.durationMs) + ' · FPS：' +
          this.displayNumber(this.motionInspection.report.fps))
          .fontSize(13)
          .fontColor($r('sys.color.font_primary'))
          .width('100%');
        Text('编码：' + this.display(this.motionInspection.report.videoCodec) + ' · ' +
          '音频：' + this.motionAudioLabel(this.motionInspection.report.hasAudio) +
          (this.motionInspection.report.audioCodec !== undefined
            ? ' · ' + this.motionInspection.report.audioCodec : ''))
          .fontSize(13)
          .fontColor($r('sys.color.font_primary'))
          .width('100%');
        if (this.motionInspection.report.secondaryWidth !== undefined ||
          this.motionInspection.report.secondaryHeight !== undefined ||
          this.motionInspection.report.secondaryFps !== undefined) {
          Text('副视频：' + this.displayNumber(this.motionInspection.report.secondaryWidth) + ' × ' +
            this.displayNumber(this.motionInspection.report.secondaryHeight) + ' · FPS：' +
            this.displayNumber(this.motionInspection.report.secondaryFps))
            .fontSize(13)
            .fontColor($r('sys.color.font_primary'))
            .width('100%');
        }
        Button(this.motionSplitButtonLabel())
          .fontSize(14)
          .width('100%')
          .height(44)
          .margin({ top: 8 })
          .enabled(!this.motionSplitting && !this.motionInspecting && !this.pageBusy &&
            !this.queueRunning && !this.batchExportRunning && !this.cleanupRunning &&
            !this.settingsSaving && this.queueLoaded && this.queueReady &&
            !this.queueLoading && !this.queueRecoveryRequired && !this.queuePersistenceFailed())
          .onClick(() => {
            this.splitSelectedMotionPhoto();
          });
        if (this.motionSplitResult !== undefined) {
          Text('已拆分资源：')
            .fontSize(13)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
            .margin({ top: 8 });
          if (this.motionSplitAsset('still') !== undefined) {
            Row() {
              Text(this.motionSplitAssetDescription('still'))
                .fontSize(12)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1);
              Button('导出')
                .fontSize(12)
                .onClick(() => {
                  this.exportMotionSplitAsset('still');
                });
            }
            .width('100%')
            .margin({ top: 4 });
          }
          if (this.motionSplitAsset('video') !== undefined) {
            Row() {
              Text(this.motionSplitAssetDescription('video'))
                .fontSize(12)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1);
              Button('导出')
                .fontSize(12)
                .onClick(() => {
                  this.exportMotionSplitAsset('video');
                });
            }
            .width('100%')
            .margin({ top: 4 });
          }
          if (this.motionSplitAsset('primary') !== undefined) {
            Row() {
              Text(this.motionSplitAssetDescription('primary'))
                .fontSize(12)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1);
              Button('导出')
                .fontSize(12)
                .onClick(() => {
                  this.exportMotionSplitAsset('primary');
                });
            }
            .width('100%')
            .margin({ top: 4 });
          }
          if (this.motionSplitResult.cleanupWarning.length > 0) {
            Text('临时输入清理提示：' + this.motionSplitResult.cleanupWarning)
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_alert'))
              .width('100%')
              .margin({ top: 4 });
          }
        }
        Text('Live Photo 配对')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .margin({ top: 12, bottom: 4 });
        Text(this.canMakeLivePhotoPair()
          ? '来源已绑定：当前 Motion Photo 原图 + 同一原图对应的 Apple HEIC 转换结果。'
          : '请先将当前 Motion Photo 原图转换为 Apple HEIC；旧转换记录缺少来源绑定时需重新转换。')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%');
        Button(this.livePhotoPairButtonLabel())
          .fontSize(14)
          .width('100%')
          .height(44)
          .margin({ top: 8 })
          .enabled(this.canMakeLivePhotoPair() && !this.livePhotoPairing && !this.livePhotoPairExporting &&
            !this.motionSplitting && !this.motionInspecting && !this.pageBusy && !this.queueRunning &&
            !this.batchExportRunning && !this.cleanupRunning && !this.settingsSaving && this.queueReady &&
            !this.queueRecoveryRequired && !this.queuePersistenceFailed())
          .onClick(() => {
            this.makeSelectedLivePhotoPair();
          });
        if (this.livePhotoPairResult !== undefined) {
          Text('配对文件：' + this.livePhotoPairResult.stillPath.substring(
            this.livePhotoPairResult.stillPath.lastIndexOf('/') + 1) + ' (' +
            String(this.livePhotoPairResult.stillSize) + ' 字节) + ' +
            this.livePhotoPairResult.movPath.substring(this.livePhotoPairResult.movPath.lastIndexOf('/') + 1) +
            ' (' + String(this.livePhotoPairResult.movSize) + ' 字节)')
            .fontSize(12)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
            .margin({ top: 6 });
          Text('标识：' + this.livePhotoPairResult.contentIdentifier +
            ' · Rust 已确认 HEIC/MOV 标识匹配；尚未验证系统图库导入或 Apple Photos 播放。')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .margin({ top: 4 });
          if (this.livePhotoPairResult.cleanupWarning.length > 0) {
            Text('临时输入清理提示：' + this.livePhotoPairResult.cleanupWarning + '；文件仍归当前队列项目管理。')
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_alert'))
              .width('100%')
              .margin({ top: 4 });
          }
          Button(this.livePhotoPairExporting ? '正在导出 HEIC + MOV…' : '成对导出 HEIC + MOV')
            .fontSize(14)
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .enabled(!this.livePhotoPairExporting && !this.livePhotoPairing && !this.motionSplitting &&
              !this.motionInspecting && !this.pageBusy && !this.queueRunning && !this.batchExportRunning &&
              !this.cleanupRunning && !this.settingsSaving && !this.queuePersistenceFailed())
            .onClick(() => {
              this.exportSelectedLivePhotoPair();
            });
          if (this.livePhotoPairExportEntries.length > 0) {
            Text(this.livePhotoExportSummaryText())
              .fontSize(13)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
              .margin({ top: 6 });
            ForEach(this.livePhotoPairExportEntries, (entry: LivePhotoExportEntry) => {
              Text(this.livePhotoExportStatusLabel(entry))
                .fontSize(12)
                .fontColor(entry.status === 'failed' ? '#B3261E' :
                  (entry.status === 'succeeded' ? '#16845B' : '#52606D'))
                .width('100%')
                .margin({ top: 3 });
            }, (entry: LivePhotoExportEntry) => entry.kind);
          }
        }
      }
      Button(this.motionInspectButtonLabel())
        .fontSize(14)
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
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius(10)
    .margin({ top: 10 });
  }

  @Builder
  private settingsPanel(): void {
    Column() {
      Row() {
        Text('转换设置')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1);
        Button('放弃更改')
          .fontSize(13)
          .enabled(!this.settingsSaving)
          .onClick(() => {
            this.cancelSettings();
          });
      }
      .width('100%');
      Text('先编辑草稿，再点击保存；保存失败时草稿会保留。运行中的项目继续使用开始时的完整快照。')
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
        .margin({ top: 6, bottom: 12 });

      Text('输出模式')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%');
      Row() {
        Row() {
          Radio({ value: 'oppo', group: 'xdremux-output-mode' })
            .checked(this.draftOutputMode === 'oppo')
            .enabled(!this.settingsSaving)
            .onChange((checked: boolean): void => {
              if (checked) {
                this.setDraftOutputMode('oppo');
              }
            });
          Text('OPPO 兼容')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .margin({ left: 8 })
            .onClick(() => {
              this.setDraftOutputMode('oppo');
            });
        }
          .layoutWeight(1)
          .height(44)
          .onClick(() => {
            this.setDraftOutputMode('oppo');
          });
        Row() {
          Radio({ value: 'apple', group: 'xdremux-output-mode' })
            .checked(this.draftOutputMode === 'apple')
            .enabled(!this.settingsSaving)
            .onChange((checked: boolean): void => {
              if (checked) {
                this.setDraftOutputMode('apple');
              }
            });
          Text('Apple 标准')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .margin({ left: 8 })
            .onClick(() => {
              this.setDraftOutputMode('apple');
            });
        }
          .layoutWeight(1)
          .height(44)
          .margin({ left: 8 })
          .onClick(() => {
            this.setDraftOutputMode('apple');
          });
      }
      .width('100%')
      .margin({ top: 8, bottom: 12 });

      if (this.draftOutputMode === 'oppo') {
        Text('OPPO 兼容模式')
          .fontSize(15)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .margin({ top: 4 });
        Select(OPPO_COMPAT_OPTIONS.map((option: SettingsOption): SelectOption => {
          return { value: option.label };
        }))
          .selected(this.compatIndex(this.draftOppoCompat))
          .value(compatLabel(this.draftOppoCompat))
          .fontColor($r('sys.color.font_primary'))
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
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 4 });

        Text('保留 OPPO 相机附加信息')
          .fontSize(15)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .margin({ top: 12 });
        Select(OPPO_CAMERA_TAIL_OPTIONS.map((option: SettingsOption): SelectOption => {
          return { value: option.label };
        }))
          .selected(this.cameraTailIndex(this.draftOppoCameraTail))
          .value(cameraTailLabel(this.draftOppoCameraTail))
          .fontColor($r('sys.color.font_primary'))
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
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 4 });
      } else {
        Text('Apple 标准会关闭 OPPO 路由和相机附加信息；下面的 Apple 选项写入可继续编辑的数据。')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 4, bottom: 4 });
      }

      Text('Apple 照片功能（实验性）')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .margin({ top: 14 });
      Text('开启后自动使用 Apple 标准输出；这里写入可继续调节的数据，不会把风格直接烘焙进照片。人像选项写入可编辑人像数据，需要源照片具备可用景深信息。')
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
        .margin({ top: 4, bottom: 4 });
      Row() {
        Text('摄影风格数据')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.draftApplePhotographicStyles })
          .enabled(!this.settingsSaving && !this.draftApplePhotographicStyles3)
          .onChange((isOn: boolean): void => {
            this.setDraftAppleStyles(isOn);
          });
      }
      .width('100%')
      .margin({ top: 4 });
      Row() {
        Text('摄影风格 3（质感 + 颗粒）')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.draftApplePhotographicStyles3 })
          .enabled(!this.settingsSaving)
          .onChange((isOn: boolean): void => {
            this.setDraftAppleStyles3(isOn);
          });
      }
      .width('100%')
      .margin({ top: 4 });
      Text('开启后自动使用 Apple 输出并启用基础摄影风格，用于支持设备上的质感与颗粒编辑；部分图片格式可能无法转换。')
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
        .margin({ top: 3 });
      Row() {
        Text('人像数据')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.draftApplePortrait })
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
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.draftStrictTmap })
          .enabled(!this.settingsSaving)
          .onChange((isOn: boolean): void => {
            this.setDraftStrict(isOn);
          });
      }
      .width('100%')
      .margin({ top: 4 });
      Text('仅用于严格 ISO 21496-1 测试；普通用户建议关闭，可能降低部分相册兼容性。')
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
        .margin({ top: 3 });

      Text('草稿摘要：' + this.draftSettingsLabel())
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .margin({ top: 12 });
      if (this.settingsError.length > 0) {
        Text(this.settingsError)
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_alert'))
          .width('100%')
          .margin({ top: 6 });
      }
      Row() {
        Button('恢复默认')
          .fontSize(13)
          .layoutWeight(1)
          .height(44)
          .enabled(!this.settingsSaving)
          .onClick(() => {
            this.restoreDefaultSettings();
          });
        Button(this.settingsSaving ? '保存中…' : '保存设置')
          .fontSize(14)
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
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius(12)
    .margin({ top: 8, bottom: 14 });
  }

  @Builder
  private selectedDetails(): void {

            Column() {
              Text('当前项目详情')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')
                .margin({ bottom: 8 });
              Text('项目 ID：' + this.selectedItemRequired().id + ' · 文件：' + this.selectedItemRequired().displayName)
                .fontSize(14)
                .fontColor($r('sys.color.font_primary'))
                .width('100%');
              Text('源 URI：' + this.display(this.selectedItemRequired().sourceUri))
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .margin({ top: 4 });
              Text('沙盒输入：' + this.display(this.selectedItemRequired().inputPath))
                .fontSize(12)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')
                .margin({ top: 4, bottom: 10 });

              if (this.selectedItemRequired().details !== undefined) {
                Text('照片详情')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%')
                  .margin({ bottom: 6 });
                Text('厂商：' + this.display(this.selectedItemRequired().details?.make) + ' · 型号：' +
                  this.display(this.selectedItemRequired().details?.model))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%');
                Text('时间：' + this.display(this.selectedItemRequired().details?.dateTime))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%');
                Text('曝光：' + this.display(this.selectedItemRequired().details?.exposureTime) + ' · 光圈：' +
                  this.display(this.selectedItemRequired().details?.fNumber) + ' · ISO：' + this.display(this.selectedItemRequired().details?.iso))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%');
                Text('焦距：' + this.display(this.selectedItemRequired().details?.focalLength) + ' · 35mm：' +
                  this.display(this.selectedItemRequired().details?.focalLength35mm) + ' · 曝光补偿：' +
                  this.display(this.selectedItemRequired().details?.exposureBias))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%');
                Text('尺寸：' + this.displayNumber(this.selectedItemRequired().details?.width) + ' × ' +
                  this.displayNumber(this.selectedItemRequired().details?.height) + ' · HDR：' +
                  this.display(this.selectedItemRequired().details?.hdrKind))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%')
                  .margin({ bottom: 10 });
              }

              if (this.selectedItemRequired().classification !== undefined) {
                Text('分类结果')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%')
                  .margin({ bottom: 6 });
                Text('状态：' + this.display(this.selectedItemRequired().classification?.status))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%');
                Text('模式：' + this.display(this.selectedItemRequired().classification?.modeKey) +
                  ' · 目录：' + this.display(this.selectedItemRequired().classification?.folderName))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%');
                Text('HDR：' + this.display(this.selectedItemRequired().classification?.hdrKind) + ' · 家族：' +
                  this.display(this.selectedItemRequired().classification?.family))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%');
                Text('标签：' + String(this.selectedItemRequired().classification?.hasTagFlags) + ' · 标志：' +
                  this.displayBigInt(this.selectedItemRequired().classification?.tagFlags) + ' · 未知：' +
                  this.displayBigInt(this.selectedItemRequired().classification?.unknownFlags))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%')
                  .margin({ bottom: 10 });
              }

              if (this.selectedItemRequired().result !== undefined) {
                Text('上次成功结果：' + this.selectedItemRequired().result?.modeLabel)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%')
                  .margin({ bottom: 6 });
                Text('结果路径：' + this.selectedItemRequired().result?.outputPath)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%');
                Text('核心模式：' + this.display(this.selectedItemRequired().result?.conversion.mode) +
                  ' · 家族：' + this.display(this.selectedItemRequired().result?.conversion.family))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%');
                if (this.selectedItemRequired().attemptStatus === 'failed' && this.selectedItemRequired().errorMessage.length > 0) {
                  Text('最新重转换失败；上次成功结果仍保留：' + this.selectedItemRequired().errorMessage)
                    .fontSize(13)
                    .fontColor($r('sys.color.ohos_id_color_alert'))
                    .width('100%')
                    .margin({ top: 4 });
                }
                if (this.selectedItemRequired().exportedUri.length > 0) {
                  Text('已导出：' + this.selectedItemRequired().exportedUri)
                    .fontSize(12)
                    .fontColor($r('sys.color.ohos_id_color_connected'))
                    .width('100%')
                    .margin({ top: 4 });
                }
              }

              this.motionPhotoPanel();

              Row() {
                Button(this.selectedShareRequiresReselection() ? '需重新选择图片' : '重试失败项目')
                  .fontSize(14)
                  .layoutWeight(1)
                  .height(44)
                  .enabled(!this.pageBusy && !this.selectedItemRequired().externalBusy &&
                    this.selectedItemRequired().status === 'failed' && !this.selectedShareRequiresReselection())
                  .onClick(() => {
                    this.retrySelected();
                  });
                Button('重新转换')
                  .fontSize(14)
                  .layoutWeight(1)
                  .height(44)
                  .margin({ left: 8 })
                  .enabled(!this.pageBusy && !this.selectedItemRequired().externalBusy && this.selectedItemRequired().status === 'succeeded')
                  .onClick(() => {
                    this.reconvertSelected();
                  });
                Button('删除项目')
                  .fontSize(14)
                  .fontColor($r('sys.color.ohos_id_color_primary_contrary'))
                  .backgroundColor($r('sys.color.ohos_id_color_alert'))
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
            .backgroundColor($r('sys.color.background_secondary'))
            .borderRadius(12)
            .margin({ top: 8, bottom: 18 });
  }

  @Builder
  private settingsPage() {
    Column() {
      Scroll(this.settingsScrollController) {
        Column() {
          if (!this.shouldUseImmersiveMainChrome()) {
            Text('设置')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
              .width('100%');
          }
          Text('调整输出格式与转换时保留的照片信息')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .margin({ top: 4, bottom: 14 });

          Row() {
            Text('Rust 核心')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1);
            Text('xdremux ' + this.coreVersion)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'));
          }
          .width('100%')
          .padding(14)
          .backgroundColor($r('sys.color.background_secondary'))
          .borderRadius(14)
          .margin({ bottom: 10 });

          if (this.settingsWarning.length > 0) {
            Text(this.settingsWarning)
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_warning'))
              .width('100%')
              .margin({ bottom: 8 });
          }

          if (this.settingsLoaded) {
            this.settingsPanel();
          } else if (this.settingsLoading) {
            Text('正在读取已保存设置…')
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .padding(16)
              .backgroundColor($r('sys.color.background_secondary'))
              .borderRadius(14);
          } else {
            if (this.settingsError.length > 0) {
              Text(this.settingsError)
                .fontSize(13)
                .fontColor($r('sys.color.ohos_id_color_alert'))
                .width('100%')
                .margin({ bottom: 8 });
            }
            Button('重试加载设置')
              .width('100%')
              .height(44)
              .onClick(() => {
                this.loadSettings();
              });
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 20, right: 20, top: this.shouldUseImmersiveMainChrome() ? 98 : 24, bottom: 108 });
      }
      .layoutWeight(1)
      .width('100%')
      .clipContent(ContentClipMode.BOUNDARY)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP]);
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'));
  }

  @Builder
  private queuePage() {
    Column() {
        Scroll(this.queueScrollController) {
        Column() {
          if (!this.shouldUseImmersiveMainChrome()) {
            Text('转换队列')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
              .margin({ bottom: 6 });
          }
          Text('批量处理照片，查看进度并导出结果')
            .fontSize(15)
            .fontColor($r('sys.color.font_secondary'))
            .margin({ bottom: 18 });

          if (this.queueLoading) {
            Text('正在校验并恢复队列记录…')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .margin({ top: 8, bottom: 8 });
          }
          if (this.queueRecoveryRequired) {
            Text(this.queueWarning.length > 0 ? this.queueWarning :
              '队列记录无法安全读取；不会自动删除或覆盖原记录。')
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_warning'))
              .width('100%')
              .margin({ top: 8, bottom: 6 });
            Row() {
              Button('备份并新建空队列')
                .fontSize(14)
                .fontColor($r('sys.color.ohos_id_color_primary_contrary'))
                .backgroundColor($r('sys.color.ohos_id_color_warning'))
                .layoutWeight(1)
                .height(44)
                .enabled(!this.pageBusy && !this.queueLoading && !this.cleanupRunning)
                .onClick(() => {
                  this.recoverQueueRecord();
                });
              Button('重试读取')
                .fontSize(14)
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
              .fontColor($r('sys.color.ohos_id_color_alert'))
              .width('100%')
              .margin({ top: 6, bottom: 6 });
            Button('重试保存队列记录')
              .fontSize(14)
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
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .margin({ top: 8 });
          Button(this.cleanupRunning ? '清理沙盒中…' : '清理未引用沙盒文件')
            .fontSize(13)
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
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .margin({ bottom: 8 });

          Button('从文件选择')
            .fontSize(14)
            .width('100%')
            .height(50)
            .enabled(this.queueLoaded && this.queueReady && !this.queueLoading &&
              !this.queueRecoveryRequired && !this.queuePersistenceFailed() &&
              !this.pageBusy && !this.queueRunning)
            .onClick(() => {
              this.chooseAndImport(false);
            });

          Row() {
            Button(this.queueRunning ? '处理中…' : '开始 / 继续队列')
              .fontSize(16)
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
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
              .margin({ top: 8, bottom: 6 });
            Text('系统可能会先创建空目标文件；写入失败时不会自动删除用户选择的位置，沙盒结果仍可重试导出。')
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .margin({ bottom: 6 });
            ForEach(this.batchExportEntries, (entry: BatchExportEntry) => {
              Column() {
                Row() {
                  Text(entry.displayName)
                    .fontSize(14)
                    .fontColor($r('sys.color.font_primary'))
                    .layoutWeight(1);
                  Text(this.batchExportStatusLabel(entry))
                    .fontSize(12)
                    .fontColor(entry.status === 'failed' || entry.status === 'journal-failed' ?
                      '#B3261E' : (entry.exported ? '#16845B' : '#52606D'));
                }
                Text(entry.fileName)
                  .fontSize(11)
                  .fontColor($r('sys.color.font_secondary'))
                  .width('100%')
                  .margin({ top: 3 });
                if (entry.errorMessage.length > 0) {
                  Text(entry.errorMessage)
                    .fontSize(11)
                    .fontColor($r('sys.color.ohos_id_color_alert'))
                    .width('100%')
                    .margin({ top: 3 });
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding(10)
              .backgroundColor($r('sys.color.background_secondary'))
              .borderRadius(8)
              .margin({ bottom: 6 });
            }, (entry: BatchExportEntry) => entry.id + '-' + entry.fileName + '-' + entry.status + '-' +
              String(entry.copySucceeded) + '-' + String(entry.exported));
          }

          Text(this.operationStatus)
            .fontSize(15)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
            .margin({ top: 14, bottom: 8 });
          Text('队列项目：' + String(this.queueItems.length) +
            ' · 关键状态会保存；重启后需手动继续，转换仅在前台运行')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .margin({ bottom: 10 });

          if (this.queueItems.length === 0) {
            Text('尚未加入照片')
              .fontSize(16)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%');
          } else {
            Text('项目列表（点击项目查看详情）')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
              .margin({ bottom: 8 });
            ForEach(this.queueItems, (item: QueueItem) => {
              Row() {
                Column() {
                  Text(item.displayName)
                    .fontSize(15)
                    .fontColor($r('sys.color.font_primary'))
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
                      .fontColor($r('sys.color.font_secondary'))
                      .width('100%')
                      .margin({ top: 3 });
                  }
                  if (item.errorMessage.length > 0) {
                    Text(item.errorMessage)
                      .fontSize(12)
                      .fontColor($r('sys.color.ohos_id_color_alert'))
                      .width('100%')
                      .margin({ top: 3 });
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);
                Text(item.id === this.activeItemId ? '当前' : (item.id === this.selectedItemId ? '已选' : ''))
                  .fontSize(13)
                  .fontColor($r('sys.color.ohos_id_color_activated'));
              }
              .width('100%')
              .padding(12)
              .backgroundColor(item.id === this.selectedItemId ? $r('sys.color.background_tertiary') : $r('sys.color.background_secondary'))
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
        .padding({ left: 24, right: 24, top: this.shouldUseImmersiveMainChrome() ? 98 : 28, bottom: 96 });
      }
      .layoutWeight(1)
      .width('100%')
      .clipContent(ContentClipMode.BOUNDARY)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP]);
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'));
  }

  @Available({ minApiVersion: '26.0.0' })
  private getTabsController(): HdsTabsController {
    let controller: HdsTabsController | undefined = this.tabsController;
    if (controller === undefined) {
      controller = new HdsTabsController();
      this.tabsController = controller;
    }
    return controller;
  }

  @Available({ minApiVersion: '26.0.0' })
  private setImportMiniBarExpanded(expanded: boolean): void {
    this.importMiniBarExpanded = expanded;
    this.getTabsController().applyMiniBarStyle(expanded ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE);
  }

  private expandGalleryImportMiniBarOnScroll(): void {
    if (!this.shouldUseImmersiveMainChrome() || this.mainTabIndex !== 0 || this.galleryDetailMounted ||
      this.importMiniBarExpanded || this.galleryPhotos.length === 0) {
      return;
    }
    this.setImportMiniBarExpanded(true);
  }

  private mainTabTitle(): string {
    if (this.mainTabIndex === 0) {
      return '图库';
    }
    if (this.mainTabIndex === 1) {
      return '转换队列';
    }
    return '设置';
  }

  private shouldHideMainTabTitle(): boolean {
    return this.galleryHeroPreloadPending || this.galleryHeroTransitionActive || this.galleryDetailMounted;
  }

  private mainPageScroller(): Scroller {
    if (this.mainTabIndex === 0) {
      return this.galleryScrollController;
    }
    if (this.mainTabIndex === 1) {
      return this.queueScrollController;
    }
    return this.settingsScrollController;
  }

  private canRunMiniBarAction(): boolean {
    if (this.mainTabIndex === 0) {
      return !this.galleryImporting && !this.galleryLoading && !this.pageBusy && !this.queueRunning;
    }
    if (this.mainTabIndex === 1) {
      return this.queueLoaded && this.queueReady && this.settingsLoaded && !this.queueLoading &&
        !this.queueRecoveryRequired && !this.queuePersistenceFailed() &&
        !this.pageBusy && !this.queueRunning && !this.cleanupRunning &&
        this.queueItems.some((item: QueueItem): boolean => item.status === 'pending' && !item.externalBusy);
    }
    return false;
  }

  @Available({ minApiVersion: '26.0.0' })
  private canImportQueueMiniBarAction(): boolean {
    const controller: QueueController | undefined = this.queueController;
    return this.queueLoaded && this.queueReady && !this.queueLoading && !this.queueRecoveryRequired &&
      this.settingsLoaded && !this.pageBusy && !this.queueRunning && !this.cleanupRunning &&
      !this.queuePersistenceFailed() && controller !== undefined && !this.queueHasBlockingOperation(controller);
  }

  @Available({ minApiVersion: '26.0.0' })
  private async runMiniBarAction(): Promise<void> {
    const tabIndex: number = this.mainTabIndex;
    this.setImportMiniBarExpanded(false);
    if (tabIndex === 0) {
      await this.importGalleryPhotos();
    } else if (tabIndex === 1) {
      await this.startQueue();
    }
  }

  @Available({ minApiVersion: '26.0.0' })
  @Builder
  private importMiniBar() {
    if (this.importMiniBarExpanded) {
      if (this.mainTabIndex === 1) {
        Row() {
          Button({ type: ButtonType.Circle, stateEffect: false }) {
            Text('+')
              .fontSize(28)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.ohos_id_color_primary_contrary'));
          }
          .width(52)
          .height(52)
          .backgroundColor(this.systemAccentColorWithAlpha(0.72))
          .enabled(this.canImportQueueMiniBarAction())
          .onClick((): void => {
            // Queue imports use the system photo picker and are copied into the
            // queue sandbox by chooseAndImport before any Rust processing.
            void this.chooseAndImport(true, false);
          });

          Button('开始转换')
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_primary_contrary'))
            .width(112)
            .height(48)
            .backgroundColor(this.systemAccentColorWithAlpha(0.6))
            .border({ width: 1, color: '#66FFFFFF' })
            .borderRadius(24)
            .enabled(this.canRunMiniBarAction())
            .onClick((): void => {
              void this.runMiniBarAction();
            });
        }
        .width(200)
        .height(56)
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({ left: 8, right: 8 });
      } else {
        Row() {
          Button('导入新照片')
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_primary_contrary'))
            .width(112)
            .height(44)
            .backgroundColor(this.systemAccentColorWithAlpha(0.4))
            .border({ width: 1, color: '#66FFFFFF' })
            .borderRadius(24)
            .enabled(this.canRunMiniBarAction())
            .onClick((): void => {
              void this.runMiniBarAction();
            });

          Button('全部加入队列')
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_primary_contrary'))
            .width(128)
            .height(44)
            .backgroundColor(this.systemAccentColorWithAlpha(0.4))
            .border({ width: 1, color: '#66FFFFFF' })
            .borderRadius(24)
            .enabled(this.canImportQueueMiniBarAction() && this.galleryLibraryReady && this.galleryPhotos.length > 0)
            .onClick((): void => {
              void this.enqueueAllGalleryPhotos();
            });
        }
        .width(280)
        .height(56)
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({ left: 8, right: 8 });
      }
    } else {
      Stack({ alignContent: Alignment.Center }) {
        Button({ type: ButtonType.Circle, stateEffect: false }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(25)
            .fontColor([$r('sys.color.ohos_id_color_primary_contrary')])
            .hitTestBehavior(HitTestMode.None);
        }
        .width(52)
        .height(52)
        .backgroundColor(this.systemAccentColorWithAlpha(0.72))
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THIN,
          materialColor: this.systemAccentColorWithAlpha(0.72),
          interactive: true
        }))
        .opacity(this.mainTabIndex === 1
          ? this.canImportQueueMiniBarAction() || this.canRunMiniBarAction() ? 1 : 0.45
          : this.canRunMiniBarAction() ? 1 : 0.45)
        .accessibilityText('打开导入与转换操作')
        .onClick((): void => {
          if (this.mainTabIndex === 1
            ? this.canImportQueueMiniBarAction() || this.canRunMiniBarAction()
            : this.canRunMiniBarAction()) {
            this.setImportMiniBarExpanded(true);
          }
        });
      }
      .width(56)
      .height(56);
    }
  }

  @Available({ minApiVersion: '26.0.0' })
  @Builder
  private immersiveTabs() {
    HdsTabs({ index: this.mainTabIndex, controller: this.getTabsController() }) {
      TabContent() {
        this.ownGalleryPage();
      }
      .tabBar(new BottomTabBarStyle({
        normal: new SymbolGlyphModifier($r('sys.symbol.picture'))
          .fontColor([$r('sys.color.font_primary')]),
        selected: new SymbolGlyphModifier($r('sys.symbol.picture_fill'))
          .fontColor([$r('sys.color.ohos_id_color_activated')])
      }, '图库')
        .labelStyle({
          selectedColor: $r('sys.color.ohos_id_color_activated'),
          unselectedColor: $r('sys.color.font_primary')
        })
        .iconStyle({
          selectedColor: $r('sys.color.ohos_id_color_activated'),
          unselectedColor: $r('sys.color.font_primary')
        }))

      TabContent() {
        this.queuePage();
      }
      .tabBar(new BottomTabBarStyle({
        normal: new SymbolGlyphModifier($r('sys.symbol.list_bullet'))
          .fontColor([$r('sys.color.font_primary')]),
        selected: new SymbolGlyphModifier($r('sys.symbol.list_bullet'))
          .fontColor([$r('sys.color.ohos_id_color_activated')])
      }, '队列')
        .labelStyle({
          selectedColor: $r('sys.color.ohos_id_color_activated'),
          unselectedColor: $r('sys.color.font_primary')
        })
        .iconStyle({
          selectedColor: $r('sys.color.ohos_id_color_activated'),
          unselectedColor: $r('sys.color.font_primary')
        }))

      TabContent() {
        this.settingsPage();
      }
      .tabBar(new BottomTabBarStyle({
        normal: new SymbolGlyphModifier($r('sys.symbol.gearshape'))
          .fontColor([$r('sys.color.font_primary')]),
        selected: new SymbolGlyphModifier($r('sys.symbol.gearshape_fill'))
          .fontColor([$r('sys.color.ohos_id_color_activated')])
      }, '设置')
        .labelStyle({
          selectedColor: $r('sys.color.ohos_id_color_activated'),
          unselectedColor: $r('sys.color.font_primary')
        })
        .iconStyle({
          selectedColor: $r('sys.color.ohos_id_color_activated'),
          unselectedColor: $r('sys.color.font_primary')
        }))
    }
    .barPosition(BarPosition.End)
    .vertical(false)
    .barMode(BarMode.Fixed)
    .barHeight(56)
    .barOverlap(true)
    .scrollable(true)
    .onChange((index: number) => {
      this.onMainTabChange(index);
    })
    .barFloatingStyle(this.mainTabIndex === 2 ? {
      barWidth: { smallWidth: 280, mediumWidth: 280, largeWidth: 280 },
      barBottomMargin: 28,
      adaptToHandedness: true,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    } : {
      barWidth: { smallWidth: 280, mediumWidth: 280, largeWidth: 280 },
      barBottomMargin: 28,
      adaptToHandedness: true,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      miniBar: {
        miniBarBuilder: () => this.importMiniBar(),
        miniBarWidth: { smallWidth: 280, mediumWidth: 280, largeWidth: 280 },
        miniBarStyle: this.importMiniBarExpanded ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE,
        enableMiniBarBackground: true,
        onBarStyleChange: (miniBarStyle: HdsBarStyle): void => {
          this.importMiniBarExpanded = miniBarStyle === HdsBarStyle.EXPAND;
        }
      }
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .width('100%')
    .height(LayoutPolicy.matchParent)
    .backgroundColor($r('sys.color.background_primary'));
  }

  @Available({ minApiVersion: '26.0.0' })
  @Builder
  private immersiveMainNavigation() {
    HdsNavigation() {
      this.immersiveTabs();
    }
    .width('100%')
    .height('100%')
    .titleBar({
      padding: {
        start: LengthMetrics.vp(20),
        end: LengthMetrics.vp(20)
      },
      content: {
        title: {
          mainTitle: this.mainTabTitle()
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(28)
        },
        blurStrategy: BlurStrategy.ADAPTIVE,
        originalStyle: {
          backgroundStyle: { backgroundColor: '#00FFFFFF' },
          contentStyle: {
            titleStyle: {
              mainTitleColor: this.shouldHideMainTabTitle() ? '#00000000' : $r('sys.color.font_primary')
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: '#00FFFFFF' },
          contentStyle: {
            titleStyle: {
              mainTitleColor: this.shouldHideMainTabTitle() ? '#00000000' : $r('sys.color.font_primary')
            }
          }
        }
      },
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true
    })
    .bindToScrollable([this.mainPageScroller()])
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .hideToolBar(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .backgroundColor(Color.Transparent)
    .transition(TransitionEffect.IDENTITY);
  }

  @Builder
  private standardTabs() {
    Tabs({ barPosition: BarPosition.End, index: this.mainTabIndex }) {
      TabContent() {
        this.ownGalleryPage();
      }
      .tabBar(new BottomTabBarStyle({
        normal: new SymbolGlyphModifier($r('sys.symbol.picture')),
        selected: new SymbolGlyphModifier($r('sys.symbol.picture_fill'))
      }, '图库'))

      TabContent() {
        this.queuePage();
      }
      .tabBar(new BottomTabBarStyle({
        normal: new SymbolGlyphModifier($r('sys.symbol.list_bullet')),
        selected: new SymbolGlyphModifier($r('sys.symbol.list_bullet'))
      }, '队列'))

      TabContent() {
        this.settingsPage();
      }
      .tabBar(new BottomTabBarStyle({
        normal: new SymbolGlyphModifier($r('sys.symbol.gearshape')),
        selected: new SymbolGlyphModifier($r('sys.symbol.gearshape_fill'))
      }, '设置'))
    }
    .barPosition(BarPosition.End)
    .barMode(BarMode.Fixed)
    .barHeight(64)
    .scrollable(true)
    .onChange((index: number) => {
      this.onMainTabChange(index);
    })
    .expandSafeArea([SafeAreaType.SYSTEM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
    .transition(TransitionEffect.IDENTITY);
  }

  build() {
    Stack() {
      if (this.shouldUseImmersiveMainChrome()) {
        this.immersiveMainNavigation();
      } else {
        this.standardTabs();
      }
      if (this.galleryDetailMounted) {
        this.galleryDetailPage();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'));
  }

}
