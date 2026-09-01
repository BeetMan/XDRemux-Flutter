/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import FlutterEngine from '../embedding/engine/FlutterEngine';
import Log from '../util/Log';
import { DVModel, DVModelChildren, DVModelEvents, DVModelParameters } from './DynamicView/dynamicView';
import { display } from '@kit.ArkUI'
import FlutterManager from '../embedding/ohos/FlutterManager';
import window from '@ohos.window';
import KeyboardManager from '../embedding/ohos/KeyboardManager';
import MouseCursorPlugin from '../plugin/mouse/MouseCursorPlugin';
import Settings from '../embedding/ohos/Settings';
import ArrayList from '@ohos.util.ArrayList';
import { EmbeddingNodeController } from '../embedding/ohos/EmbeddingNodeController';
import PlatformView, { Params } from '../plugin/platform/PlatformView';
import hiTraceMeter from '@ohos.hiTraceMeter'
import { JSON } from '@kit.ArkTS';
import TextInputPlugin from '../plugin/editing/TextInputPlugin';
import { accessibility } from '@kit.AccessibilityKit';
import { uiObserver } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import KeyEventChannel from '../embedding/engine/systemchannels/KeyEventChannel';
import StatusBarClickChannel from '../embedding/engine/systemchannels/StatusBarClickChannel';
import FlutterNapi, { LTPOSwitchState } from '../embedding/engine/FlutterNapi';
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';

const TAG = "FlutterViewTag";
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS';
const DPI_SCALE_RESET: number = -1;

/**
 * Metrics describing the viewport dimensions and insets.
 * This class holds information about the physical dimensions, padding, insets, and display features.
 */
export class ViewportMetrics {
  /** Device pixel ratio for converting logical to physical pixels. */
  devicePixelRatio: number = 1.0;
  /** Physical width of the viewport in pixels. */
  physicalWidth: number = 0;
  /** Physical height of the viewport in pixels. */
  physicalHeight: number = 0;
  /** Top padding of the viewport in physical pixels. */
  physicalViewPaddingTop: number = 0;
  /** Right padding of the viewport in physical pixels. */
  physicalViewPaddingRight: number = 0;
  /** Bottom padding of the viewport in physical pixels. */
  physicalViewPaddingBottom: number = 0;
  /** Left padding of the viewport in physical pixels. */
  physicalViewPaddingLeft: number = 0;
  /** Top inset of the viewport in physical pixels. */
  physicalViewInsetTop: number = 0;
  /** Right inset of the viewport in physical pixels. */
  physicalViewInsetRight: number = 0;
  /** Bottom inset of the viewport in physical pixels. */
  physicalViewInsetBottom: number = 0;
  /** Left inset of the viewport in physical pixels. */
  physicalViewInsetLeft: number = 0;
  /** Top system gesture inset in physical pixels. */
  systemGestureInsetTop: number = 0;
  /** Right system gesture inset in physical pixels. */
  systemGestureInsetRight: number = 0;
  /** Bottom system gesture inset in physical pixels. */
  systemGestureInsetBottom: number = 0;
  /** Left system gesture inset in physical pixels. */
  systemGestureInsetLeft: number = 0;
  /** Physical touch slop value, or -1 if not set. */
  physicalTouchSlop: number = -1;
  /** List of display features such as folds, hinges, or cutouts. */
  displayFeatures: ArrayList<DisplayFeature> = new ArrayList();

  /**
   * Creates a deep copy of this ViewportMetrics instance.
   * @returns A new ViewportMetrics instance with copied values
   */
  clone(): ViewportMetrics {
    const copy = new ViewportMetrics();
    copy.devicePixelRatio = this.devicePixelRatio;
    copy.physicalWidth = this.physicalWidth;
    copy.physicalHeight = this.physicalHeight;
    copy.physicalViewPaddingTop = this.physicalViewPaddingTop;
    copy.physicalViewPaddingRight = this.physicalViewPaddingRight;
    copy.physicalViewPaddingBottom = this.physicalViewPaddingBottom;
    copy.physicalViewPaddingLeft = this.physicalViewPaddingLeft;
    copy.physicalViewInsetTop = this.physicalViewInsetTop;
    copy.physicalViewInsetRight = this.physicalViewInsetRight;
    copy.physicalViewInsetBottom = this.physicalViewInsetBottom;
    copy.physicalViewInsetLeft = this.physicalViewInsetLeft;
    copy.systemGestureInsetTop = this.systemGestureInsetTop;
    copy.systemGestureInsetRight = this.systemGestureInsetRight;
    copy.systemGestureInsetBottom = this.systemGestureInsetBottom;
    copy.systemGestureInsetLeft = this.systemGestureInsetLeft;
    copy.physicalTouchSlop = this.physicalTouchSlop;
    copy.displayFeatures = this.displayFeatures;
    return copy;
  }

  /**
   * Checks if this ViewportMetrics is equal to another.
   * @param other - The other ViewportMetrics to compare with
   * @returns True if all metrics are equal, false otherwise
   */
  isEqual(other: ViewportMetrics): boolean {
    return this.devicePixelRatio === other.devicePixelRatio &&
      this.physicalWidth === other.physicalWidth &&
      this.physicalHeight === other.physicalHeight &&
      this.physicalViewPaddingTop === other.physicalViewPaddingTop &&
      this.physicalViewPaddingRight === other.physicalViewPaddingRight &&
      this.physicalViewPaddingBottom === other.physicalViewPaddingBottom &&
      this.physicalViewPaddingLeft === other.physicalViewPaddingLeft &&
      this.physicalViewInsetTop === other.physicalViewInsetTop &&
      this.physicalViewInsetRight === other.physicalViewInsetRight &&
      this.physicalViewInsetBottom === other.physicalViewInsetBottom &&
      this.physicalViewInsetLeft === other.physicalViewInsetLeft &&
      this.systemGestureInsetTop === other.systemGestureInsetTop &&
      this.systemGestureInsetRight === other.systemGestureInsetRight &&
      this.systemGestureInsetBottom === other.systemGestureInsetBottom &&
      this.systemGestureInsetLeft === other.systemGestureInsetLeft &&
      this.physicalTouchSlop === other.physicalTouchSlop &&
      this.displayFeatures === other.displayFeatures;
  }
}

/**
 * Represents a display feature such as a fold, hinge, or cutout.
 */
export class DisplayFeature {
  /** Bounding rectangle of the display feature. */
  bound: display.Rect;
  /** Type of the display feature (fold, hinge, cutout, etc.). */
  type: DisplayFeatureType;
  /** State of the display feature. */
  state: DisplayFeatureState;

  /**
   * Constructs a new DisplayFeature instance.
   * @param bound - The bounding rectangle of the feature
   * @param type - The type of display feature
   * @param state - The state of the display feature
   */
  constructor(bound: display.Rect, type: DisplayFeatureType, state: DisplayFeatureState) {
    this.bound = bound;
    this.type = type;
    this.state = state;
  }

  /**
   * Gets the bounding rectangle of the display feature.
   * @returns The bounding rectangle
   */
  getBound(): display.Rect {
    return this.bound;
  }

  /**
   * Gets the type of the display feature.
   * @returns The display feature type
   */
  getType(): DisplayFeatureType {
    return this.type;
  }

  /**
   * Gets the state of the display feature.
   * @returns The display feature state
   */
  getState(): DisplayFeatureState {
    return this.state
  }

  /**
   * Sets the bounding rectangle of the display feature.
   * @param bound - The bounding rectangle to set
   */
  setBound(bound: display.Rect): void {
    this.bound = bound;
  }

  /**
   * Sets the type of the display feature.
   * @param type - The display feature type to set
   */
  setType(type: DisplayFeatureType): void {
    this.type = type;
  }

  /**
   * Sets the state of the display feature.
   * @param state - The display feature state to set
   */
  setState(state: DisplayFeatureState): void {
    this.state = state;
  }
}

/**
 * Enumeration of display feature types.
 */
export enum DisplayFeatureType {
  /** Unknown display feature type */
  UNKNOWN = 0,
  /** Fold display feature */
  FOLD = 1,
  /** Hinge display feature */
  HINGE = 2,
  /** Cutout display feature */
  CUTOUT = 3
}

/**
 * Enumeration of display feature states.
 */
export enum DisplayFeatureState {
  /** Unknown state */
  UNKNOWN = 0,
  /** Flat posture */
  POSTURE_FLAT = 1,
  /** Half-opened posture */
  POSTURE_HALF_OPENED = 2,
}

/**
 * Enumeration of display fold status.
 */
export enum DisplayFoldStatus {
  /** Unknown fold status */
  FOLD_STATUS_UNKNOWN = 0,
  /** Display is expanded */
  FOLD_STATUS_EXPANDED = 1,
  /** Display is folded */
  FOLD_STATUS_FOLDED = 2,
  /** Display is half-folded */
  FOLD_STATUS_HALF_FOLDED = 3
}

type callbackNumber = () => number

/**
 * Parameters for platform view layout.
 * @deprecated since 3.7
 */
export class PlatformViewParas {
  /** The width of the platform view. */
  width: number = 0.0;
  /** The height of the platform view. */
  height: number = 0.0;
  /** The top position of the platform view. */
  top: number = 0.0;
  /** The left position of the platform view. */
  left: number = 0.0;
  /** The layout direction for the platform view. */
  direction: Direction = Direction.Auto;

  /**
   * Sets the layout values.
   * @param width - The width
   * @param height - The height
   * @param top - The top position
   * @param left - The left position
   */
  setValue(width: number, height: number, top: number, left: number): void {
    this.width = width;
    this.height = height;
    this.top = top;
    this.left = left;
  }

  /**
   * Sets the offset position.
   * @param top - The top offset
   * @param left - The left offset
   */
  setOffset(top: number, left: number): void {
    this.top = top;
    this.left = left;
  }
}

/**
 * Main view class for rendering Flutter content in OpenHarmony applications.
 * This class manages the Flutter engine, viewport metrics, keyboard handling,
 * and all interactions between Flutter and the native platform.
 */
export class FlutterView {
  private flutterEngine: FlutterEngine | null = null
  private id: string = ""
  private isActive: boolean = true
  private dVModel: DVModel =
    new DVModel("Stack", new DVModelParameters(), new DVModelEvents(), new DVModelChildren(), null);
  /** The wrapped builder for creating the view, or undefined if not set. */
  private wrapBuilder: WrappedBuilder<[Params]> | undefined = undefined;
  private platformView: PlatformView | undefined = undefined;
  private isSurfaceAvailableForRendering: boolean = false
  private isXComponentAttachedToEngine: boolean = false
  private viewportMetrics = new ViewportMetrics();
  private displayInfo?: display.Display;
  private keyboardManager: KeyboardManager | null = null;
  private statusBarClickChannel: StatusBarClickChannel | null = null;
  private mainWindow: window.Window | null = null;
  private mouseCursorPlugin?: MouseCursorPlugin;
  private textInputPlugin?: TextInputPlugin;
  private uiContext?: UIContext | undefined;
  private context: Context;
  private settings?: Settings;
  private mFirstFrameListeners: ArrayList<FirstFrameListener>;
  private mFirstPreloadFrameListeners: ArrayList<FirstPreloadFrameListener>;
  private isFlutterUiDisplayed: boolean = false;
  private isFlutterUiPreload: boolean = false;
  private surfaceLifecycleToken: number = 0;
  private activeSurfaceLifecycleToken: number = 0;
  private surfaceId: string = "0";
  private nodeController: EmbeddingNodeController = new EmbeddingNodeController();
  private platformViewSize: PlatformViewParas = new PlatformViewParas();
  private checkFullScreen: boolean = true;
  private checkKeyboard: boolean = true;
  private checkGesture: boolean = true;
  private checkAiBar: boolean = true;
  private frameCache: boolean = true;
  private paddingTop?: number;
  private paddingBottom?: number;
  private systemAvoidArea: window.AvoidArea;
  private navigationAvoidArea: window.AvoidArea;
  private gestureAvoidArea: window.AvoidArea;
  private keyboardAvoidArea: window.AvoidArea;
  private needSetViewport: boolean = false;
  private windowPosition: window.Rect | null = null;
  // 默认值5，参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-gestures-pangesture
  private callbackValue: callbackNumber = () => 5;
  // DPI update flag to distinguish between system DPI updates and custom DPI updates
  private isDevicePixelRatioAdaptive: boolean = false;
  private lastHeight: number = 0;
  private statusBarClickSubscriber: commonEventManager.CommonEventSubscriber | null = null;

  private ltpoSwitchState: LTPOSwitchState = LTPOSwitchState.NOT_INIT;

  private isAllCallbacksRegistered: boolean = false;

  /**
   * Constructs a new FlutterView instance.
   * @param viewId - The unique identifier for this view
   * @param context - The application context
   */
  constructor(viewId: string, context: Context) {
    this.id = viewId;
    this.context = context;
    this.displayInfo = display.getDefaultDisplaySync();
    this.viewportMetrics.devicePixelRatio = this.displayInfo?.densityPixels;
    this.buildDisplayFeatures(display.getFoldStatus());

    this.mainWindow = FlutterManager.getInstance()
      .getWindowStage(FlutterManager.getInstance().getUIAbility(context))
      ?.getMainWindowSync();

    this.systemAvoidArea = this.mainWindow?.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    this.navigationAvoidArea = this.mainWindow?.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    this.gestureAvoidArea = this.mainWindow?.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM_GESTURE);
    this.keyboardAvoidArea = this.mainWindow?.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);

    this.mFirstFrameListeners = new ArrayList<FirstFrameListener>();
    this.mFirstPreloadFrameListeners = new ArrayList<FirstPreloadFrameListener>();
  }

  onBackPressCallback = () => {
    /// [LTPO] Notifying the VSync signal may require a high frame rate.
    if (this.ltpoSwitchState == LTPOSwitchState.ON) {
      this.flutterEngine?.getFlutterNapi()?.LTPODispatchHighFrameRate();
    }

    if (this.getKeyboardHeight() == 0) {
      this.flutterEngine?.getNavigationChannel()?.popRoute();
    } else {
      this.flutterEngine?.getTextInputChannel()?.textInputMethodHandler?.hide();
    }
  };

  /**
   * Called when the device pixel ratio should be updated from a density scale factor.
   * Refreshes display metadata, updates the text input channel device pixel ratio when a Flutter engine is attached,
   * recomputes viewport device pixel ratio, and triggers onAreaChange when the ratio actually changes.
   *
   * Registered on Context.eventHub for the `changeDevicePixelRatio` event; also invoked internally when
   * uiObserver reports a density update (custom density relative to system density).
   *
   * @param dpiScaleFactor - Multiplier applied to the system display densityPixels for the new device pixel ratio,
   *                         or DPI_SCALE_RESET (-1) to restore the system default.
   */
  onDevicePixelRatioChange = (dpiScaleFactor: number) => {
    try {
      // Get display information
      this.displayInfo = display.getDefaultDisplaySync();

      // Set DPI for text input channel
      this.flutterEngine?.getTextInputChannel()?.setDevicePixelRatio(this.displayInfo.densityPixels);

      // Calculate device pixel ratio
      // When dpiScaleFactor is DPI_SCALE_RESET, reset DPI to system default
      let newDevicePixelRatio: number;
      if (dpiScaleFactor === DPI_SCALE_RESET) {
        newDevicePixelRatio = this.displayInfo.densityPixels;
        Log.d(TAG, "Resetting device pixel ratio to system default: " + newDevicePixelRatio);
        // When resetting DPI, set the flag to false
        this.isDevicePixelRatioAdaptive = false;
      } else {
        newDevicePixelRatio = this.displayInfo.densityPixels * dpiScaleFactor;
        Log.d(TAG, "Scaling device pixel ratio by factor " + dpiScaleFactor + ": " + newDevicePixelRatio);
        // When customizing DPI, set the flag to true
        this.isDevicePixelRatioAdaptive = true;
      }

      // Only update when DPI actually changes
      if (newDevicePixelRatio !== this.viewportMetrics.devicePixelRatio) {
        this.viewportMetrics.devicePixelRatio = newDevicePixelRatio;
        Log.i(TAG, "Device pixel ratio updated: " + newDevicePixelRatio +
          " (scale factor: " + dpiScaleFactor + ", system DPI: " + this.displayInfo.densityPixels + ")");
        this.needSetViewport = true;
        this.onAreaChange(null);
      }
    } catch (e) {
      Log.e(TAG, "Error updating device pixel ratio: " + JSON.stringify(e));
    }
  }

  /**
   * Sets the callback for getting touch slop value.
   * @param callback - The callback function that returns the touch slop value
   */
  setTouchSlopCallbackValue(callback: callbackNumber) {
    this.callbackValue = callback;
  }

  private async buildDisplayFeatures(foldStatus: display.FoldStatus) {
    let displayFeatures: ArrayList<DisplayFeature> = new ArrayList();
    const displayInfo = display.getDefaultDisplaySync();
    /*
    There are some bugs about getCurrentFoldCreaseRegion:
    * 1. the crease region area is inaccurate
    * 2. the creaseRegion.displayId and displayInfo.id are always both 0, in which case it is unable to
    * distinguish whether the crease region is on the current screen.
    * So do not add FOLD feature until the bugs are fixed.
    */
    // if (display.isFoldable()) {
    //   let state: DisplayFeatureState = DisplayFeatureState.UNKNOWN;
    //   if (foldStatus == display.FoldStatus.FOLD_STATUS_EXPANDED) {
    //     state = DisplayFeatureState.POSTURE_FLAT;
    //   } else if (foldStatus == display.FoldStatus.FOLD_STATUS_HALF_FOLDED) {
    //     state = DisplayFeatureState.POSTURE_HALF_OPENED;
    //   } else {
    //     state = DisplayFeatureState.UNKNOWN;
    //   }
    //   let creaseRegion: display.FoldCreaseRegion = display.getCurrentFoldCreaseRegion();
    //   if (creaseRegion.displayId == displayInfo.id) {
    //     for (let bound of creaseRegion.creaseRects) {
    //       displayFeatures.add(new DisplayFeature(bound, DisplayFeatureType.FOLD, state));
    //     }
    //   }
    // }

    let cutoutInfos = await displayInfo?.getCutoutInfo();
    for (let bound of cutoutInfos.boundingRects) {
      displayFeatures.add(new DisplayFeature(bound, DisplayFeatureType.CUTOUT, DisplayFeatureState.UNKNOWN));
    }
    Log.d(TAG, `device displayFeatures is : ${JSON.stringify(displayFeatures)}`);
    this.viewportMetrics.displayFeatures = displayFeatures;
    this.updateViewportMetrics();
  }

  private routerPageUpdateCallback = (info: uiObserver.RouterPageInfo) => {
    if (this.getKeyboardHeight() !== 0 && info.state === uiObserver.RouterPageState.ON_PAGE_SHOW) {
      this.flutterEngine?.getTextInputChannel()?.textInputMethodHandler?.hide();
    }
  }

  private densityUpdateCallback = (info: uiObserver.DensityInfo) => {
    try {
      const sysDensity = display.getDefaultDisplaySync().densityPixels;
      const customDensity = info.density;
      if (sysDensity > 0 && customDensity > 0 && Number.isFinite(customDensity)) {
        const scale = customDensity / sysDensity;
        Log.i(TAG, "densityUpdateCallback: customDensity=" + customDensity + ", sysDensity=" +
          sysDensity + ", scale=" + scale);
        const currentUri = this.flutterEngine?.getDisplayMetricsChannel()?.getCurrentUri() ?? '';
 	      if (currentUri) {
 	        this.flutterEngine?.getDisplayMetricsChannel()?.setCustomDpiActive(true);
 	      }
        this.onDevicePixelRatioChange(scale);
      }
    } catch (e) {
      Log.e(TAG, "densityUpdateCallback error: " + JSON.stringify(e));
    }
  }

  private avoidAreaChangeCallback = (data: window.AvoidAreaOptions) => {
    Log.i(TAG, "avoidAreaChangeCallback, type=" + data.type + ", area=" + JSON.stringify(data.area));

    switch (data.type) {
      case window.AvoidAreaType.TYPE_SYSTEM:
        this.systemAvoidArea = data.area;
        break;
      case window.AvoidAreaType.TYPE_SYSTEM_GESTURE:
        this.gestureAvoidArea = data.area;
        break;
      case window.AvoidAreaType.TYPE_KEYBOARD:
        if (this.getKeyboardHeight() > 0) {
          this.keyboardAvoidArea = data.area;
        } else {
          this.keyboardAvoidArea.bottomRect = { left: 0, top: 0, width: 0, height: 0 };
        }
        break;
      case window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR:
        this.navigationAvoidArea = data.area;
        break;
      default:
        break;
    }
    if (!this.isActive) {
      Log.d(TAG, `${this.id} is not active. Ignoring avoid area change.`);
      return;
    }
    if (this.isAttachedToFlutterEngine()) {
      this.onAreaChange(null);
    }
  }
  private windowSizeChangeCallback = (data: window.Size) => {
    Log.i(TAG, `windowSizeChangeCallback: width=${data.width}, height=${data.height}, lastHeight=${this.lastHeight}`);
    if (!this.isActive) {
      Log.d(TAG, `${this.id} is not active. Ignoring window size change.`);
      return;
    }
    // Only handle when height changes
    if (this.lastHeight !== data.height) {
      try {
        // If DPI has been customized, do not process system DPI changes
        this.displayInfo = display.getDefaultDisplaySync();
        this.flutterEngine?.getTextInputChannel()?.setDevicePixelRatio(this.displayInfo.densityPixels);

        let devicePixelRatio: number = this.displayInfo.densityPixels;
        Log.i(TAG, `windowSizeChangeCallback devicePixelRatio: ${devicePixelRatio}, viewportMetrics.devicePixelRatio: ${this.viewportMetrics.devicePixelRatio}`);

        if (devicePixelRatio !== this.viewportMetrics.devicePixelRatio) {
          this.viewportMetrics.devicePixelRatio = devicePixelRatio;
          Log.i(TAG, `windowSizeChangeCallback: Updated devicePixelRatio to ${devicePixelRatio}`);
          this.needSetViewport = true;
        }
      } catch (e) {
        Log.e(TAG, `windowSizeChangeCallback error: ${JSON.stringify(e)}`);
      }
    }

    // Update lastHeight
    this.lastHeight = data.height;

    // Notify area change, this method handles all necessary view updates
    if (this.isAttachedToFlutterEngine()) {
      this.onAreaChange(null);
    }
  }
  private windowStatusChangeCallback = (data: window.WindowStatusType) => {
    Log.i(TAG, "windowStatusChangeCallback " + data);
    if (!this.isActive) {
      Log.d(TAG, `${this.id} is not active. Ignoring window status change.`);
      return;
    }
    if (this.isAttachedToFlutterEngine()) {
      FlutterManager.getInstance().getFullScreenListener().onScreenStateChanged(data);
    }
  };
  private displayChangeCallback = (data: number) => {
    // If DPI has been customized, do not process system DPI changes
    if (this.isDevicePixelRatioAdaptive) {
      Log.d(TAG, "Skipping display change callback due to custom DPI setting");
      return;
    }
    if (!this.isActive) {
      Log.d(TAG, `${this.id} is not active. Ignoring display change.`);
      return;
    }
    this.displayInfo = display.getDefaultDisplaySync();
    this.flutterEngine?.getTextInputChannel()?.setDevicePixelRatio(this.displayInfo.densityPixels);
    let devicePixelRatio: number = this.displayInfo?.densityPixels;
    Log.i(TAG, "Display on: " + JSON.stringify(this.displayInfo) + ". Display id:" + JSON.stringify(data))
    if (devicePixelRatio != this.viewportMetrics.devicePixelRatio) {
      this.viewportMetrics.devicePixelRatio = devicePixelRatio;
      this.needSetViewport = true;
      this.onAreaChange(null);
    }
    this.flutterEngine?.getFlutterNapi()?.updateRefreshRate(this.displayInfo?.refreshRate);
  }
  private keyboardHeightChangeCallback = (data: number) => {
    Log.i(TAG, "keyboardHeightChangeCallback " + data);
    if (!this.isActive) {
      Log.d(TAG, `${this.id} is not active. Ignoring keyboard height change.`);
      return;
    }
    if (this.keyboardAvoidArea) {
      this.keyboardAvoidArea.bottomRect.height = data;
    }
    this.onAreaChange(null);
  };
  private windowRectChangeCallback = (data: window.RectChangeOptions) => {
    Log.i(TAG, "windowRectChangeCallback " + JSON.stringify(data));
    if (!this.isActive) {
      Log.d(TAG, `${this.id} is not active. Ignoring window rect change.`);
      return;
    }
    this.windowPosition = data.rect as window.Rect;
    this.flutterEngine?.getTextInputChannel()?.setWindowPosition(this.windowPosition);
  }
  private accessibilityStateChangeCallback = (data: boolean) => {
    Log.i(TAG, `subscribe accessibility state change, result: ${JSON.stringify(data)}`);
    this.flutterEngine?.getFlutterNapi()?.accessibilityStateChange(data);
  }
  private foldStatusChangeCallback = (data: display.FoldStatus) => {
    Log.d(TAG, `Fold status change to ${JSON.stringify(data)}`)
    this.buildDisplayFeatures(data);
  }
  private windowTitleButtonRectChangeCallback = (data: window.TitleButtonRect) => {
    Log.i(TAG, "windowTitleButtonRectChangeCallback " + JSON.stringify(data));
    if (!this.isActive) {
      Log.d(TAG, `${this.id} is not active. Ignoring window title button rect change.`);
      return;
    }
    // Clear padding before handling window decoration to allow recalculation
    // This fixes the issue where safe area avoidance is not applied after exiting freeform multi-window mode
    this.paddingTop = undefined;
    FlutterManager.getInstance().handleWindowDecorSafeArea(this.id, this.context);
  }

  private registerAllCallbacks() {
    if (this.isAllCallbacksRegistered) {
      this.unRegisterAllCallbacks();
    }

    try {
      this.mainWindow?.on('windowSizeChange', this.windowSizeChangeCallback);
      this.mainWindow?.on('avoidAreaChange', this.avoidAreaChangeCallback);
      this.mainWindow?.on('windowStatusChange', this.windowStatusChangeCallback);
      this.mainWindow?.on('keyboardHeightChange', this.keyboardHeightChangeCallback);
      this.mainWindow?.on('windowRectChange', this.windowRectChangeCallback);
      this.mainWindow?.on('windowTitleButtonRectChange', this.windowTitleButtonRectChangeCallback);
    } catch (e) {
      Log.e(TAG, "mainWindow on error: " + JSON.stringify(e));
    }

    try {
      //监听系统无障碍服务状态改变
      accessibility.on('accessibilityStateChange', this.accessibilityStateChangeCallback);
    } catch (e) {
      Log.e(TAG, "accessibility on error: " + JSON.stringify(e));
    }

    try {
      this.context.eventHub.on(EVENT_BACK_PRESS, this.onBackPressCallback);
      this.context.eventHub.on('changeDevicePixelRatio', this.onDevicePixelRatioChange);
    } catch (e) {
      Log.e(TAG, "eventHub on error: " + JSON.stringify(e));
    }

    try {
      commonEventManager.createSubscriber(
        { events: ["usual.event.CLICK_STATUSBAR"] }, this.onStatusBarClick);
    } catch (e) {
      Log.e(TAG, "commonEventManager createSubscriber error: " + JSON.stringify(e));
    }

    try {
      // Listen to route navigation (Flutter navigating to HarmonyOS native), soft keyboard management
      uiObserver.on('routerPageUpdate', this.uiContext as UIContext, this.routerPageUpdateCallback);
      uiObserver.on('densityUpdate', this.uiContext as UIContext, this.densityUpdateCallback);
    } catch (e) {
      Log.e(TAG, "uiObserver on error: " + JSON.stringify(e));
    }

    // Subscribes to display changes. Example: event that the display size is changed.
    try {
      display.on('foldStatusChange', this.foldStatusChangeCallback);
      display.on("change", this.displayChangeCallback);
    } catch (e) {
      Log.e(TAG, "displayInfo on error: " + JSON.stringify(e));
    }
    this.isAllCallbacksRegistered = true;
  }

  private unRegisterAllCallbacks() {
    if (!this.isAllCallbacksRegistered) {
      return;
    }

    try {
      this.mainWindow?.off('windowSizeChange', this.windowSizeChangeCallback);
      this.mainWindow?.off('avoidAreaChange', this.avoidAreaChangeCallback);
      this.mainWindow?.off('windowStatusChange', this.windowStatusChangeCallback);
      this.mainWindow?.off('keyboardHeightChange', this.keyboardHeightChangeCallback);
      this.mainWindow?.off('windowRectChange', this.windowRectChangeCallback);
      this.mainWindow?.off('windowTitleButtonRectChange', this.windowTitleButtonRectChangeCallback);
    } catch (e) {
      Log.e(TAG, "mainWindow off error: " + JSON.stringify(e));
    }

    try {
      accessibility.off('accessibilityStateChange', this.accessibilityStateChangeCallback);
    } catch (e) {
      Log.e(TAG, "accessibility off error: " + JSON.stringify(e));
    }

    try {
      this.context.eventHub.off(EVENT_BACK_PRESS, this.onBackPressCallback);
      this.context.eventHub.off('changeDevicePixelRatio', this.onDevicePixelRatioChange);
    } catch (e) {
      Log.e(TAG, "eventHub off error: " + JSON.stringify(e));
    }

    try {
      if (this.statusBarClickSubscriber != null) {
        commonEventManager.unsubscribe(this.statusBarClickSubscriber, (err: BusinessError) => {
          if (err) {
            Log.e(TAG, "Failed to unsubscribe status bar click event: " + JSON.stringify(err));
            return;
          }
          this.statusBarClickSubscriber = null;
        });
      }
    } catch (e) {
      Log.e(TAG, "commonEventManager unsubscribe error: " + JSON.stringify(e));
    }

    try {
      uiObserver.off('routerPageUpdate', this.uiContext as UIContext, this.routerPageUpdateCallback);
      uiObserver.off('densityUpdate', this.uiContext as UIContext, this.densityUpdateCallback);
    } catch (e) {
      Log.e(TAG, "uiObserver off error: " + JSON.stringify(e));
    }

    try {
      display.off('foldStatusChange', this.foldStatusChangeCallback);
      display.off("change", this.displayChangeCallback);
    } catch (e) {
      Log.e(TAG, "displayInfo off error: " + JSON.stringify(e));
    }
    this.isAllCallbacksRegistered = false;
  }

  /**
   * Gets the view ID.
   * @returns The view ID
   */
  getId(): string {
    return this.id;
  }

  /**
   * Sets the active state of the view.
   * @param value - True to activate, false to deactivate
   */
  setActive(value: boolean): void {
    const wasActive = this.isActive;
    this.isActive = value;
    if (value && !wasActive && this.isAttachedToFlutterEngine()) {
      this.displayInfo = display.getDefaultDisplaySync();
      this.onAreaChange(null);
    }
  }

  /**
   * Gets the active state of the view.
   * @returns True if active, false otherwise
   */
  getActive(): boolean {
    return this.isActive;
  }

  /**
   * Sets the surface ID for rendering.
   * @param surfaceId - The surface ID
   */
  setSurfaceId(surfaceId: string): void {
    this.surfaceId = surfaceId;
  }

  /**
   * Gets the surface ID.
   * @returns The surface ID
   */
  getSurfaceId(): string {
    return this.surfaceId;
  }
  
  /**
   * Gets the embedding node controller.
   * @deprecated since 3.7
   * @returns The EmbeddingNodeController instance
   */
  getEmbeddingNodeController(): EmbeddingNodeController {
    return this.nodeController;
  }

  /**
   * Sets the wrapped builder for platform views.
   * @param wrappedBuilder - The WrappedBuilder instance
   */
  setWrappedBuilder(wrappedBuilder: WrappedBuilder<[Params]>) {
    this.wrapBuilder = wrappedBuilder;
  }

  /**
   * Gets the wrapped builder.
   * @returns The WrappedBuilder instance, or undefined if not set
   */
  getWrappedBuilder(): WrappedBuilder<[Params]> | undefined {
    return this.wrapBuilder;
  }

  /**
   * Sets the platform view.
   * @param platformView - The PlatformView instance
   */
  setPlatformView(platformView: PlatformView) {
    this.platformView = platformView;
  }

  /**
   * Gets the platform view.
   * @returns The PlatformView instance, or undefined if not set
   */
  getPlatformView(): PlatformView | undefined {
    return this.platformView;
  }

  /**
   * Gets the platform view size.
   * @deprecated since 3.7
   * @returns The PlatformViewParas instance
   */
  getPlatformViewSize(): PlatformViewParas {
    return this.platformViewSize;
  }

  /**
   * Gets the DynamicView model.
   * @returns The DVModel instance
   */
  getDVModel() {
    return this.dVModel;
  }

  /**
   * Gets the current keyboard height from the cached keyboard avoid area.
   * @returns The keyboard height in pixels, or {@code 0} if the keyboard is not visible or avoid-area data is absent.
   */
  getKeyboardHeight(): number {
    return this.keyboardAvoidArea?.bottomRect.height ?? 0;
  }

  /**
   * Called when the view is being destroyed.
   * Cleans up all event listeners and resources.
   */
  onDestroy() {
    this.unRegisterAllCallbacks();
    this.mainWindow = null;
    FlutterManager.getInstance().deleteFlutterView(this.id, this);

    this.nodeController.disposeFrameNode();
  }

  /**
   * Attaches this view to a Flutter engine.
   * @param flutterEngine - The FlutterEngine to attach to
   */
  attachToFlutterEngine(flutterEngine: FlutterEngine): void {
    hiTraceMeter.startTrace("attachToFlutterEngine", 0);
    if (this.isAttachedToFlutterEngine()) {
      if (flutterEngine == this.flutterEngine) {
        Log.i(TAG, "Already attached to this engine. Doing nothing.");
        return;
      }
      // Detach from a previous FlutterEngine so we can attach to this new one.f
      Log.i(
        TAG,
        "Currently attached to a different engine. Detaching and then attaching"
        + " to new engine.");
      this.detachFromFlutterEngine();
    }
    Log.i(TAG, "attachToFlutterEngine");
    this.flutterEngine = flutterEngine;
    this.flutterEngine?.getFlutterNapi().xComponentAttachFlutterEngine(this.id)
    this.isXComponentAttachedToEngine = true;
    this.flutterEngine?.getFlutterNapi()?.updateRefreshRate(this.displayInfo!.refreshRate)
    this.flutterEngine?.getFlutterNapi()?.updateSize(this.displayInfo!.width, this.displayInfo!.height)
    this.flutterEngine?.getFlutterNapi()?.updateDensity(this.displayInfo!.densityPixels)
    this.flutterEngine?.getFlutterNapi().enableFrameCache(this.frameCache);
    if (accessibility.isOpenAccessibilitySync()) {
      this.flutterEngine?.getFlutterNapi()?.accessibilityStateChange(true);
    }
    flutterEngine.getPlatformViewsController()?.attachToView(this);

    let newArea: Area | null = {
      width: px2vp(this.displayInfo!.width),
      height: px2vp(this.displayInfo!.height),
      position: { x: 0, y: 0 },
      globalPosition: { x: 0, y: 0 }
    };
    if (this.viewportMetrics.physicalWidth != 0 || this.viewportMetrics.physicalHeight != 0) {
      newArea = null;
    }
    this.onAreaChange(newArea, true);

    let windowId = this.mainWindow?.getWindowProperties()?.id ?? 0
    this.mouseCursorPlugin = new MouseCursorPlugin(windowId, this.flutterEngine?.getMouseCursorChannel()!);
    if (this.uiContext === undefined) {
      this.uiContext = this.tryGetUIContext();
    }
    this.textInputPlugin = new TextInputPlugin(this.flutterEngine?.getTextInputChannel()!, this.id,
      new KeyEventChannel(this.flutterEngine.dartExecutor));
    this.statusBarClickChannel = new StatusBarClickChannel(flutterEngine.dartExecutor)
    this.keyboardManager = new KeyboardManager(flutterEngine, this.textInputPlugin!);
    this.settings = new Settings(this.flutterEngine.getSettingsChannel()!);
    this.sendSettings();
    this.isFlutterUiDisplayed = this.flutterEngine.getFlutterNapi().isDisplayingFlutterUi;
    this.isFlutterUiPreload = this.flutterEngine.getFlutterNapi().isPreloadedFlutterUi;
    if (this.isFlutterUiPreload) {
      this.onFirstFrame(1);
    }
    if (this.isFlutterUiDisplayed) {
      this.onFirstFrame();
    }
    if (this.isSurfaceAvailableForRendering) {
      this.flutterEngine?.processPendingMessages();
    }

    if (this.ltpoSwitchState == LTPOSwitchState.NOT_INIT) {
      this.ltpoSwitchState = FlutterNapi.checkLTPOSwitchState() as LTPOSwitchState;
    }

    hiTraceMeter.finishTrace("attachToFlutterEngine", 0);
  }

  /**
   * Called before drawing a frame.
   * @param width - The width of the drawing area, defaults to display width
   * @param height - The height of the drawing area, defaults to display height
   */
  preDraw(width: number = 0, height: number = 0): void {
    if (this.isAttachedToFlutterEngine()) {
      if (width == 0 || height == 0) {
        width = this.displayInfo!.width;
        height = this.displayInfo!.height;
      }
      this.flutterEngine?.getFlutterNapi().xComponentPreDraw(this.id, width, height);
    }
  }

  /**
   * Detaches this view from the Flutter engine.
   * Cleans up all engine-related resources.
   */
  detachFromFlutterEngine(): void {
    Log.i(TAG, "detachFromFlutterEngine");
    if (!this.isAttachedToFlutterEngine()) {
      Log.d(TAG, "FlutterView not attached to an engine. Not detaching.");
      return;
    }
    if (this.isXComponentAttachedToEngine) {
      this.flutterEngine!!.getFlutterNapi().xComponentDetachFlutterEngine(this.id)
      this.isXComponentAttachedToEngine = false;
    }
    this.flutterEngine?.getPlatformViewsController()?.detachFromView(this);
    this.flutterEngine = null;
    this.keyboardManager = null;
    this.textInputPlugin?.destroy();
  }

  /**
   * Safely obtains UIContext. Before loadContent completes, getUIContext() may throw on some API levels.
   */
  private tryGetUIContext(): UIContext | undefined {
    if (this.mainWindow == null) {
      return undefined;
    }
    try {
      return this.mainWindow.getUIContext();
    } catch (error) {
      Log.w(TAG, 'tryGetUIContext failed: ' + JSON.stringify(error));
      return undefined;
    }
  }

  /**
   * Called when the window is created.
   * Initializes the UIContext and sends settings to Flutter.
   */
  onWindowCreated() {
    Log.d(TAG, "received onwindowCreated.");
    this.uiContext = this.tryGetUIContext();
    this.sendSettings();
    this.registerAllCallbacks();
    Log.d(TAG, "uiContext init and sendSettings finished.");
  }

  /**
   * Sends system settings to Flutter.
   */
  sendSettings(): void {
    if (this.uiContext != undefined && this.isAttachedToFlutterEngine()) {
      this.settings?.sendSettings(this.uiContext.getMediaQuery());
    } else {
      Log.e(TAG, "UIContext is null, cannot send Settings!");
    }
  }

  /**
   * Called when the rendering surface is created.
   * Marks the surface as available and processes pending messages.
   *
   * @returns Monotonic surface generation token for this {@code FlutterView} instance: each call assigns
   *          {@code activeSurfaceLifecycleToken = ++surfaceLifecycleToken} (integers). The value is unique among
   *          successive creations on this view until {@code Number.MAX_SAFE_INTEGER} wrap (not practically reachable).
   *          Pass the returned value to `onSurfaceDestroyed` for the same surface instance; when destroy runs,
   *          a matching token clears the active generation (reset to {@code 0}). Stale destroys with an older token are ignored.
   *          This is not a security token—only a generation counter for ordering—not shared across {@code FlutterView} instances.
   *
   * @remarks Threading: In typical ArkUI apps, {@code XComponent.onLoad} / {@code onDestroy} run on the UI thread.
   *          The reference embedding invokes this from those callbacks (see {@code FlutterSurface} in FlutterPage).
   *          {@code activeSurfaceLifecycleToken} and related flags are updated without internal locks; only call
   *          this from the same thread/context as your XComponent lifecycle unless you provide external
   *          synchronization. The token addresses **out-of-order** destroy-after-recreate when the same
   *          {@code FlutterView} is reused—not arbitrary concurrent access from multiple threads.
   */
  onSurfaceCreated(): number {
    // XComponent onDestroy can arrive after a replacement XComponent onLoad
    // during fast ArkUI route changes. Use a generation token so a stale
    // destroy callback cannot detach the current surface.
    this.activeSurfaceLifecycleToken = ++this.surfaceLifecycleToken;
    if (this.isAttachedToFlutterEngine() && !this.isXComponentAttachedToEngine) {
      this.flutterEngine!!.getFlutterNapi().xComponentAttachFlutterEngine(this.id)
      this.isXComponentAttachedToEngine = true;
    }
    this.isSurfaceAvailableForRendering = true;
    this.flutterEngine?.getPlatformViewsController()?.attachToView(this);
    this.flutterEngine?.processPendingMessages();
    return this.activeSurfaceLifecycleToken;
  }

  /**
   * Called when the rendering surface is destroyed.
   * Marks the surface as unavailable and detaches from the engine.
   *
   * @param surfaceLifecycleToken - Optional token previously returned by onSurfaceCreated for this surface instance.
   *                                When provided and it does not match the active generation, the call is ignored
   *                                (guards against out-of-order destroy after recreation). Prefer always passing the
   *                                token from onSurfaceCreated when your embedding tracks XComponent lifecycle (for example FlutterPage).
   *                                Omit only when the token is unavailable; omitting skips the stale-callback guard.
   *
   * @remarks Threading: Same contract as `onSurfaceCreated`—invoke from the XComponent/UI thread in normal
   *          embeddings. Concurrent onSurfaceCreated vs onSurfaceDestroyed on different threads without external
   *          synchronization can race token and attachment flags; the implementation does not use atomics or locks.
   */
  onSurfaceDestroyed(surfaceLifecycleToken?: number) {
    if (surfaceLifecycleToken != undefined && surfaceLifecycleToken != this.activeSurfaceLifecycleToken) {
      return;
    }
    if (!this.isSurfaceAvailableForRendering && !this.isXComponentAttachedToEngine) {
      return;
    }
    this.isSurfaceAvailableForRendering = false;
    if (this.isAttachedToFlutterEngine() && this.isXComponentAttachedToEngine) {
      this.flutterEngine!!.getFlutterNapi().xComponentDetachFlutterEngine(this.id)
      this.isXComponentAttachedToEngine = false;
    }
    this.flutterEngine?.getPlatformViewsController()?.detachFromView(this);
    if (surfaceLifecycleToken == this.activeSurfaceLifecycleToken) {
      this.activeSurfaceLifecycleToken = 0;
    }
  }

  /**
   * Called when the view area changes.
   * Updates viewport metrics based on the new area and avoid areas.
   * @param newArea - The new area, or null to use current display dimensions
   * @param setFullScreen - Whether to set fullscreen mode
   */
  onAreaChange(newArea: Area | null, setFullScreen: boolean = false) {
    const originalMetrics = this.viewportMetrics.clone();
    if (newArea != null) {
      this.viewportMetrics.physicalWidth = vp2px(newArea.width as number);
      this.viewportMetrics.physicalHeight = vp2px(newArea.height as number);
    }
    let fullScreen = false
    // 根据是否全屏显示，设置标题栏高度
    if (this.checkFullScreen &&
      (setFullScreen || FlutterManager.getInstance().getFullScreenListener().useFullScreen())) { // 全屏显示
      fullScreen = true
      if (this.paddingTop != undefined) {
        this.viewportMetrics.physicalViewPaddingTop = this.paddingTop;
      } else {
        this.viewportMetrics.physicalViewPaddingTop =
          this.systemAvoidArea?.topRect.height ?? this.viewportMetrics.physicalViewPaddingTop;
      }
      if (this.paddingBottom != undefined) {
        this.viewportMetrics.physicalViewPaddingBottom = this.paddingBottom;
      } else {
        this.viewportMetrics.physicalViewPaddingBottom =
          this.systemAvoidArea?.bottomRect.height ?? this.viewportMetrics.physicalViewPaddingBottom;
      }
    } else { // 非全屏显示
      this.viewportMetrics.physicalViewPaddingTop = this.paddingTop ?? 0;
      this.viewportMetrics.physicalViewPaddingBottom = this.paddingBottom ?? 0;
    }

    this.viewportMetrics.physicalViewPaddingLeft =
      this.systemAvoidArea?.leftRect.width ?? this.viewportMetrics.physicalViewPaddingLeft;
    this.viewportMetrics.physicalViewPaddingRight =
      this.systemAvoidArea?.rightRect.width ?? this.viewportMetrics.physicalViewPaddingRight;

    this.onKeyboardAreaChange(fullScreen)
    this.onAiBarAreaChange(fullScreen)
    this.onGestureAreaChange(fullScreen)
    if (!this.viewportMetrics.isEqual(originalMetrics) || this.needSetViewport) {
      if (!this.updateViewportMetrics()) {
        this.needSetViewport = true;
      } else {
        this.needSetViewport = false;
      }
    }
  }

  private onAiBarAreaChange(fullScreen: boolean = false) {
    if (this.checkAiBar && this.navigationAvoidArea != null && fullScreen) {
      this.viewportMetrics.physicalViewPaddingBottom =
        Math.max(this.navigationAvoidArea?.bottomRect.height, this.viewportMetrics.physicalViewPaddingBottom)
    }
  }

  private onKeyboardAreaChange(fullScreen: boolean = false) {
    if (this.checkKeyboard && fullScreen) {
      this.viewportMetrics.physicalViewInsetTop =
        this.keyboardAvoidArea?.topRect.height ?? this.viewportMetrics.physicalViewInsetTop
      this.viewportMetrics.physicalViewInsetLeft =
        this.keyboardAvoidArea?.leftRect.width ?? this.viewportMetrics.physicalViewInsetLeft
      this.viewportMetrics.physicalViewInsetBottom =
        this.keyboardAvoidArea?.bottomRect.height ?? this.viewportMetrics.physicalViewInsetBottom
      this.viewportMetrics.physicalViewInsetRight =
        this.keyboardAvoidArea?.rightRect.width ?? this.viewportMetrics.physicalViewInsetRight
    } else {
      this.viewportMetrics.physicalViewInsetTop = 0
      this.viewportMetrics.physicalViewInsetLeft = 0
      this.viewportMetrics.physicalViewInsetBottom = 0
      this.viewportMetrics.physicalViewInsetRight = 0
    }
  }

  private onGestureAreaChange(fullScreen: boolean = false) {
    if (this.checkGesture && fullScreen) {
      this.viewportMetrics.systemGestureInsetTop =
        this.gestureAvoidArea?.topRect.height ?? this.viewportMetrics.systemGestureInsetTop
      this.viewportMetrics.systemGestureInsetLeft =
        this.gestureAvoidArea?.leftRect.width ?? this.viewportMetrics.systemGestureInsetLeft
      this.viewportMetrics.systemGestureInsetBottom =
        Math.max(this.navigationAvoidArea?.bottomRect.height, this.gestureAvoidArea?.bottomRect.height)
      this.viewportMetrics.systemGestureInsetRight =
        this.gestureAvoidArea?.rightRect.width ?? this.viewportMetrics.systemGestureInsetRight
    } else {
      this.viewportMetrics.systemGestureInsetTop = 0
      this.viewportMetrics.systemGestureInsetLeft = 0
      this.viewportMetrics.systemGestureInsetBottom = 0
      this.viewportMetrics.systemGestureInsetRight = 0
    }
  }

  /**
   * Checks if this view is attached to a Flutter engine.
   * @returns True if attached, false otherwise
   */
  public isAttachedToFlutterEngine(): boolean {
    return this.flutterEngine != null
  }

  /**
   * Checks if this view is attached to an engine with the specified shell holder ID.
   * @param id - The shell holder ID to check
   * @returns True if attached to an engine with the specified ID, false otherwise
   */
  public isSameEngineShellHolderId(id: number): boolean {
    if (this.flutterEngine) {
      let flutterNapi = this.flutterEngine.getFlutterNapi();
      if (flutterNapi.nativeShellHolderId == id && id != 0) {
        return true;
      }
    }
    return false;
  }

  private updateViewportMetrics(): boolean {
    if (this.isAttachedToFlutterEngine()) {
      const displayFeatures = this.viewportMetrics.displayFeatures;
      let displayFeatureBound: number[] = new Array(displayFeatures.length * 4);
      let displayFeatureType: number[] = new Array(displayFeatures.length);
      let displayFeatureStatus: number[] = new Array(displayFeatures.length);
      for (let i = 0; i < displayFeatures.length; i++) {
        let singleFeatureBound = displayFeatures[i].getBound();
        displayFeatureBound[4 * i] = singleFeatureBound.left;
        displayFeatureBound[4 * i + 1] = singleFeatureBound.top
        displayFeatureBound[4 * i + 2] = singleFeatureBound.left + singleFeatureBound.width;
        displayFeatureBound[4 * i + 3] = singleFeatureBound.top + singleFeatureBound.height;
        displayFeatureType[i] = displayFeatures[i].getType();
        displayFeatureStatus[i] = displayFeatures[i].getState();
      }

      this.viewportMetrics.physicalTouchSlop = this.callbackValue();
      this?.flutterEngine?.getFlutterNapi()?.setViewportMetrics(this.viewportMetrics.devicePixelRatio,
        this.viewportMetrics.physicalWidth,
        this.viewportMetrics.physicalHeight,
        this.viewportMetrics.physicalViewPaddingTop,
        this.viewportMetrics.physicalViewPaddingRight,
        this.viewportMetrics.physicalViewPaddingBottom,
        this.viewportMetrics.physicalViewPaddingLeft,
        this.viewportMetrics.physicalViewInsetTop,
        this.viewportMetrics.physicalViewInsetRight,
        this.viewportMetrics.physicalViewInsetBottom,
        this.viewportMetrics.physicalViewInsetLeft,
        this.viewportMetrics.systemGestureInsetTop,
        this.viewportMetrics.systemGestureInsetRight,
        this.viewportMetrics.systemGestureInsetBottom,
        this.viewportMetrics.systemGestureInsetLeft,
        this.viewportMetrics.physicalTouchSlop,
        displayFeatureBound,
        displayFeatureType,
        displayFeatureStatus)
      return true
    }
    return false
  }

  /**
   * Handles status-bar click subscription setup for OpenHarmony common events.
   *
   * Used as the callback passed to commonEventManager.createSubscriber for {@code usual.event.CLICK_STATUSBAR}.
   * Stores the subscriber and registers commonEventManager.subscribe so each delivered click forwards to Flutter via
   * StatusBarClickChannel.sendClick from FlutterView.
   *
   * @param err - Business error from the common-event subsystem when creating the subscriber, if any; otherwise unused on success.
   * @param subscriber - The common-event subscriber instance that receives {@code usual.event.CLICK_STATUSBAR} events.
   */
  onStatusBarClick = (err: BusinessError, subscriber: commonEventManager.CommonEventSubscriber) => {
    this.statusBarClickSubscriber = subscriber
    if (subscriber !== null) {
      commonEventManager.subscribe(subscriber, (err, data) => {
        this.statusBarClickChannel?.sendClick()
      })
    }
  }

  /**
   * Handles key events before they reach the input method editor.
   * @param event - The key event
   * @returns True if the event was handled, false otherwise
   */
  onKeyPreIme(event: KeyEvent): boolean {
    return this.keyboardManager?.onKeyPreIme(event) ?? false;
  }

  /**
   * Handles key events.
   * @param event - The key event
   * @returns True if the event was handled, false otherwise
   */
  onKeyEvent(event: KeyEvent): boolean {
    return this.keyboardManager?.onKeyEvent(event) ?? false;
  }

  /**
   * Handles mouse wheel events.
   * @param eventType - The event type
   * @param event - The pan gesture event
   */
  onMouseWheel(eventType: string, event: PanGestureEvent) {
    if (deviceInfo.sdkApiVersion < 15) { // API15 及以后通过轴事件处理滚动
      this.flutterEngine?.getFlutterNapi()?.xComponentDisPatchMouseWheel(this.id, eventType, event);
    }
  }

  /**
   * Adds a listener for the first frame event.
   * @param listener - The listener to add
   */
  addFirstFrameListener(listener: FirstFrameListener) {
    this.mFirstFrameListeners.add(listener);
  }

  /**
   * Removes a first frame listener.
   * @param listener - The listener to remove
   */
  removeFirstFrameListener(listener: FirstFrameListener) {
    this.mFirstFrameListeners.remove(listener);
  }

  /**
   * Adds a listener for the first preload frame event.
   * @param listener - The listener to add
   */
  addFirstPreloadFrameListener(listener: FirstPreloadFrameListener) {
    this.mFirstPreloadFrameListeners.add(listener);
  }

  /**
   * Removes a first preload frame listener.
   * @param listener - The listener to remove
   */
  removeFirstPreloadFrameListener(listener: FirstPreloadFrameListener) {
    this.mFirstPreloadFrameListeners.remove(listener);
  }

  /**
   * Checks if the first frame has been rendered.
   * @returns True if the first frame has been rendered, false otherwise
   */
  hasRenderedFirstFrame(): boolean {
    return this.isFlutterUiDisplayed;
  }

  /**
   * Called when the first frame is rendered.
   * Notifies all registered listeners.
   * @param isPreload - 1 for preload frame, 0 for normal first frame
   */
  onFirstFrame(isPreload: number = 0) {
    if (isPreload) {
      let listeners = this.mFirstPreloadFrameListeners.clone();
      listeners.forEach((listener) => {
        listener.onFirstPreloadFrame();
      })
    } else {
      let listeners = this.mFirstFrameListeners.clone();
      listeners.forEach((listener) => {
        listener.onFirstFrame();
      })
    }
  }

  /**
   * Sets whether to check fullscreen mode.
   * @param check - True to check fullscreen, false otherwise
   */
  setCheckFullScreen(check: boolean) {
    this.checkFullScreen = check;
  }

  /**
   * Sets whether to check keyboard area.
   * @param check - True to check keyboard area, false otherwise
   */
  setCheckKeyboard(check: boolean) {
    this.checkKeyboard = check
  }

  /**
   * Sets whether to check gesture area.
   * @param check - True to check gesture area, false otherwise
   */
  setCheckGesture(check: boolean) {
    this.checkGesture = check
  }

  /**
   * Sets whether to check AI bar area.
   * @param check - True to check AI bar area, false otherwise
   */
  setCheckAiBar(check: boolean) {
    this.checkAiBar = check
  }

  /**
   * Sets the top padding value.
   * @param paddingTop - The top padding value, or undefined to use default
   */
  setPaddingTop(paddingTop?: number) {
    this.paddingTop = paddingTop;
    this.onAreaChange(null);
  }

  /**
   * Sets the bottom padding value.
   * @param paddingBottom - The bottom padding value, or undefined to use default
   */
  setPaddingBottom(paddingBottom?: number) {
    this.paddingBottom = paddingBottom;
    this.onAreaChange(null);
  }

  /**
   * Enables or disables frame caching.
   * @param cacheEnable - True to enable frame cache, false to disable
   */
  enableFrameCache(cacheEnable: boolean) {
    this.frameCache = cacheEnable;
    if (this.isAttachedToFlutterEngine()) {
      this.flutterEngine?.getFlutterNapi().enableFrameCache(cacheEnable);
    }
  }
}

/**
 * Listener interface for first frame events.
 */
export interface FirstFrameListener {
  /**
   * Called when the first frame is rendered.
   */
  onFirstFrame(): void;
}

/**
 * Listener interface for first preload frame events.
 */
export interface FirstPreloadFrameListener {
  /**
   * Called when the first preload frame is rendered.
   */
  onFirstPreloadFrame(): void;
}
