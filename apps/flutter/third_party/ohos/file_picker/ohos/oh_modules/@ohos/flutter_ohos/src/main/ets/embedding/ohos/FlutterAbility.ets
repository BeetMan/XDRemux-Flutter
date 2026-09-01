/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { FlutterAbilityAndEntryDelegate, Host } from './FlutterAbilityAndEntryDelegate';
import Log from '../../util/Log';
import FlutterEngine from '../engine/FlutterEngine';
import PlatformPlugin from '../../plugin/PlatformPlugin';
import SensitiveContentPlugin from '../../plugin/view/SensitiveContentPlugin';
import FlutterShellArgs from '../engine/FlutterShellArgs';
import FlutterAbilityLaunchConfigs from './FlutterAbilityLaunchConfigs';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import { FlutterPlugin } from '../engine/plugins/FlutterPlugin';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import I18n from '@ohos.i18n'
import { PlatformBrightness } from '../engine/systemchannels/SettingsChannel';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { Configuration } from '@ohos.app.ability.Configuration';
import { deviceInfo } from '@kit.BasicServicesKit';
import ExclusiveAppComponent from './ExclusiveAppComponent';
import errorManager from '@ohos.app.ability.errorManager';
import appRecovery from '@ohos.app.ability.appRecovery';
import FlutterManager from './FlutterManager';
import { FlutterView } from '../../view/FlutterView';
import ApplicationInfoLoader from '../engine/loader/ApplicationInfoLoader';
import { accessibility } from '@kit.AccessibilityKit';

const TAG = "FlutterAbility";

/**
 * Base Flutter Ability for OpenHarmony.
 * Main responsibilities:
 * 1. Holds and initializes FlutterAbilityDelegate
 * 2. Forwards lifecycle events
 * 
 * Main abilities should inherit from this class.
 */
export class FlutterAbility extends UIAbility implements Host {
  private delegate?: FlutterAbilityAndEntryDelegate | null;
  private flutterView: FlutterView | null = null;
  private mainWindow?: window.Window | null;
  private errorManagerId: number = 0;

  /**
   * Gets the FlutterView instance.
   * @returns The FlutterView instance, or null if not available
   */
  getFlutterView(): FlutterView | null {
    return this.flutterView;
  }

  /**
   * Gets the page path for loading content.
   * @returns The page path string
   */
  pagePath(): string {
    return "pages/Index"
  }

  /**
   * Determines whether FlutterAbility should be full screen by default.
   * Can be overridden to customize full screen behavior.
   * Default value: based on device type, determines if full screen is needed.
   * @returns True if full screen by default, false otherwise
   */
  isDefaultFullScreen(): boolean {
    return deviceInfo.deviceType != '2in1';
  }

  /**
   * Called when the ability is created.
   * 1. Creates and attaches delegate
   * 2. Configures windows (transparency not needed)
   * 3. Handles lifecycle.onCreate
   * 4. setContentView() not needed
   * @param want - The Want object
   * @param launchParam - The launch parameters
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    // On cold start, get the current system font size from the context and store it
    AppStorage.setOrCreate('fontSizeScale', this.context.config.fontSizeScale);
    Log.i(TAG, "this.context.config.fontSizeScale = " + this.context.config.fontSizeScale);

    Log.i(TAG, "bundleCodeDir=" + this.context.bundleCodeDir);
    FlutterManager.getInstance().pushUIAbility(this)

    this.delegate = new FlutterAbilityAndEntryDelegate(this);
    this?.delegate?.onAttach(this.context);
    Log.i(TAG, 'onAttach end');
    this?.delegate?.platformPlugin?.setUIAbilityContext(this.context);
    this?.delegate?.onRestoreInstanceState(want);

    if (this.stillAttachedForEvent("onWindowStageCreate")) {
      this?.delegate?.onWindowStageCreate();
    }

    Log.i(TAG, 'MyAbility onCreate');

    let observer: errorManager.ErrorObserver = {
      onUnhandledException(errorMsg) {
        Log.e(TAG, "onUnhandledException, errorMsg:", errorMsg);
        appRecovery.saveAppState();
        appRecovery.restartApp();
      }
    }
    this.errorManagerId = errorManager.on('error', observer);

    let flutterApplicationInfo = ApplicationInfoLoader.load(this.context);

    if (flutterApplicationInfo.isDebugMode) {
      this.delegate?.initWindow();
    }
  }

  /**
   * Called when the ability is destroyed.
   * Cleans up resources and removes the ability from FlutterManager.
   */
  onDestroy() {
    FlutterManager.getInstance().popUIAbility(this);

    errorManager.off('error', this.errorManagerId);

    if (this.flutterView != null) {
      this.flutterView.onDestroy()
      this.flutterView = null;
    }

    if (this.stillAttachedForEvent("onDestroy")) {
      this?.delegate?.onDetach();
    }

    this.release()
  }

  /**
   * Called to save the ability state.
   * @param reason - The reason for saving state
   * @param wantParam - The parameters to save state to
   * @returns The save result
   */
  onSaveState(reason: AbilityConstant.StateType, wantParam: Record<string, Object>): AbilityConstant.OnSaveResult {
    return this?.delegate?.onSaveState(reason, wantParam) ?? AbilityConstant.OnSaveResult.ALL_REJECT;
  }

  protected windowStageEventCallback = (data: window.WindowStageEventType) => {
    this.delegate?.onWindowStageChanged(data)
  }

  /**
   * Called when the window stage is created.
   * @param windowStage - The WindowStage instance
   */
  onWindowStageCreate(windowStage: window.WindowStage) {
    FlutterManager.getInstance().pushWindowStage(this, windowStage);
    this.delegate?.initWindow();
    this.mainWindow = windowStage.getMainWindowSync();
    try {
      windowStage.on('windowStageEvent', this.windowStageEventCallback);
      this.flutterView = this.delegate!!.createView(this.context)
      Log.i(TAG, 'onWindowStageCreate:' + this.flutterView!!.getId());
      let storage: LocalStorage = new LocalStorage();
      storage.setOrCreate("viewId", this.flutterView!!.getId())
      windowStage.loadContent(this.pagePath(), storage, (err, data) => {
        if (err.code) {
          Log.e(TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
          return;
        }
        this.flutterView?.onWindowCreated();

        Log.i(TAG, 'Succeeded in loading the content. Data: %{public}s', JSON.stringify(data) ?? '');
      });
      if (this.isDefaultFullScreen()) {
        FlutterManager.getInstance().setUseFullScreen(true, this.context);
      }
    } catch (exception) {
      Log.e(TAG, 'Failed to enable the listener for window stage event changes. Cause:' + JSON.stringify(exception));
    }
  }

  /**
   * Called when a new Want is received.
   * @param want - The new Want object
   * @param launchParams - The launch parameters
   */
  onNewWant(want: Want, launchParams: AbilityConstant.LaunchParam): void {
    this?.delegate?.onNewWant(want, launchParams)
  }

  /**
   * Called when the window stage is destroyed.
   */
  onWindowStageDestroy() {
    FlutterManager.getInstance().popWindowStage(this);
    if (this.stillAttachedForEvent("onWindowStageDestroy")) {
      this?.delegate?.onWindowStageDestroy();
    }
  }

  /**
   * Called when the ability comes to foreground.
   */
  onForeground() {
    if (this.stillAttachedForEvent("onForeground")) {
      this?.delegate?.onShow();
    }
  }

  /**
   * Called when the ability goes to background.
   */
  onBackground() {
    if (this.stillAttachedForEvent("onBackground")) {
      this?.delegate?.onHide();
    }
  }

  /**
   * Called when the window stage is about to be destroyed.
   * @param windowStage - The WindowStage instance
   */
  onWindowStageWillDestroy(windowStage: window.WindowStage) {
    try {
      windowStage.off('windowStageEvent', this.windowStageEventCallback);
    } catch (err) {
      Log.e(TAG, "windowStage off failed");
    }
  }

  /**
   * Releases all held objects.
   */
  release() {
    if (this?.delegate != null) {
      this?.delegate?.release();
      this.delegate = null;
    }
  }

  /**
   * Gets the UIAbility instance.
   * @returns This UIAbility instance
   */
  getAbility(): UIAbility {
    return this;
  }

  /**
   * Gets the FlutterAbilityAndEntryDelegate instance.
   * @returns The delegate instance, or null if not available
   */
  getFlutterAbilityAndEntryDelegate(): FlutterAbilityAndEntryDelegate | null {
    return this.delegate ?? null;
  }

  /**
   * Determines whether to dispatch app lifecycle state changes.
   * @returns True to dispatch lifecycle state, false otherwise
   */
  shouldDispatchAppLifecycleState(): boolean {
    return true;
  }

  /**
   * Provides a FlutterEngine instance.
   * @param context - The context
   * @returns A FlutterEngine instance, or null if not provided
   */
  provideFlutterEngine(context: common.Context): FlutterEngine | null {
    return null;
  }

  /**
   * Provides a PlatformPlugin instance.
   * @param flutterEngine - The FlutterEngine instance
   * @returns A PlatformPlugin instance
   */
  providePlatformPlugin(flutterEngine: FlutterEngine): PlatformPlugin | undefined {
    return new PlatformPlugin(flutterEngine.getPlatformChannel()!, this.context, this);
  }

  /**
   * Provides a SensitiveContentPlugin instance.
   * @param flutterEngine - The FlutterEngine instance
   * @returns A SensitiveContentPlugin instance
   */
  provideSensitiveContentPlugin(flutterEngine: FlutterEngine): SensitiveContentPlugin | undefined {
    return new SensitiveContentPlugin(flutterEngine.getSensitiveContentChannel()!);
  }

  /**
   * Configures the Flutter engine.
   * @param flutterEngine - The FlutterEngine to configure
   */
  configureFlutterEngine(flutterEngine: FlutterEngine) {

  }

  /**
   * Cleans up the Flutter engine.
   * @param flutterEngine - The FlutterEngine to clean up
   */
  cleanUpFlutterEngine(flutterEngine: FlutterEngine) {

  }

  /**
   * Gets Flutter shell arguments from the Want.
   * @returns A FlutterShellArgs instance
   */
  getFlutterShellArgs(): FlutterShellArgs {
    return FlutterShellArgs.fromWant(this.getWant());
  }

  /**
   * Gets Dart entrypoint arguments from launch parameters.
   * @returns Array of entrypoint arguments
   */
  getDartEntrypointArgs(): Array<string> {
    if (this.launchWant.parameters![FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT_ARGS]) {
      return this.launchWant.parameters![FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT_ARGS] as Array<string>;
    }
    return new Array<string>()
  }

  /**
   * Detaches from the Flutter engine.
   */
  detachFromFlutterEngine() {
    if (this?.delegate != null) {
      this?.delegate?.onDetach();
    }
  }

  /**
   * Determines whether to pop the system navigator.
   * @returns False by default
   */
  popSystemNavigator(): boolean {
    return false;
  }

  /**
   * Determines whether to attach the engine to the ability.
   * @returns True to attach the engine, false otherwise
   */
  shouldAttachEngineToAbility(): boolean {
    return true;
  }

  /**
   * Gets the Dart entrypoint library URI.
   * @returns The library URI string
   */
  getDartEntrypointLibraryUri(): string {
    return "";
  }

  /**
   * Gets the app bundle path.
   * @returns The bundle path string
   */
  getAppBundlePath(): string {
    return "";
  }

  /**
   * Gets the Dart entrypoint function name from launch parameters.
   * @returns The entrypoint function name, or default if not set
   */
  getDartEntrypointFunctionName(): string {
    if (this.launchWant.parameters![FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT]) {
      return this.launchWant.parameters![FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT] as string;
    }
    return FlutterAbilityLaunchConfigs.DEFAULT_DART_ENTRYPOINT
  }

  /**
   * Gets the initial route from launch parameters.
   * @returns The initial route string, or empty string if not set
   */
  getInitialRoute(): string {
    if (this.launchWant.parameters![FlutterAbilityLaunchConfigs.EXTRA_INITIAL_ROUTE]) {
      return this.launchWant.parameters![FlutterAbilityLaunchConfigs.EXTRA_INITIAL_ROUTE] as string;
    }
    return ""
  }

  /**
   * Gets the Want object.
   * @returns The launch Want instance
   */
  getWant(): Want {
    return this.launchWant;
  }

  /**
   * Determines whether to destroy the engine when the host is destroyed.
   * @returns True to destroy the engine, false otherwise
   */
  shouldDestroyEngineWithHost(): boolean {
    if ((this.getCachedEngineId() != null && this.getCachedEngineId().length > 0) ||
    this.delegate!!.isFlutterEngineFromHost()) {
      // Only destroy a cached engine if explicitly requested by app developer.
      return false;
    }
    return true;
  }

  /**
   * Determines whether to automatically attach to the engine.
   * @returns True to attach automatically, false otherwise
   */
  attachToEngineAutomatically(): boolean {
    return true;
  }

  /**
   * Determines whether to restore and save state.
   * @returns True to restore and save state, false otherwise
   */
  shouldRestoreAndSaveState(): boolean {
    if (this.launchWant.parameters![FlutterAbilityLaunchConfigs.EXTRA_CACHED_ENGINE_ID] != undefined) {
      return this.launchWant.parameters![FlutterAbilityLaunchConfigs.EXTRA_CACHED_ENGINE_ID] as boolean;
    }
    if (this.getCachedEngineId() != null && this.getCachedEngineId().length > 0) {
      // Prevent overwriting the existing state in a cached engine with restoration state.
      return false;
    }
    return true;
  }

  /**
   * Gets the exclusive app component.
   * @returns The ExclusiveAppComponent instance, or null
   */
  getExclusiveAppComponent(): ExclusiveAppComponent<UIAbility> | null {
    return this.delegate ? this.delegate : null
  }

  /**
   * Gets the cached engine ID from launch parameters.
   * @returns The cached engine ID string
   */
  getCachedEngineId(): string {
    return this.launchWant.parameters![FlutterAbilityLaunchConfigs.EXTRA_CACHED_ENGINE_ID] as string
  }

  /**
   * Gets the cached engine group ID from launch parameters.
   * @returns The cached engine group ID string, or null if not set
   */
  getCachedEngineGroupId(): string | null {
    return this.launchWant.parameters![FlutterAbilityLaunchConfigs.EXTRA_CACHED_ENGINE_GROUP_ID] as string
  }

  /**
   * Checks if the delegate is still attached for an event.
   * @param event - The event name
   * @returns True if attached, false otherwise
   */
  private stillAttachedForEvent(event: string) {
    Log.i(TAG, 'Ability ' + event);
    if (this?.delegate == null) {
      Log.w(TAG, "FlutterAbility " + event + " call after release.");
      return false;
    }
    if (!this?.delegate?.isAttached) {
      Log.w(TAG, "FlutterAbility " + event + " call after detach.");
      return false;
    }
    return true;
  }

  /**
   * Adds a Flutter plugin.
   * @param plugin - The FlutterPlugin to add
   */
  addPlugin(plugin: FlutterPlugin): void {
    if (this?.delegate != null) {
      this?.delegate?.addPlugin(plugin)
    }
  }

  /**
   * Removes a Flutter plugin.
   * @param plugin - The FlutterPlugin to remove
   */
  removePlugin(plugin: FlutterPlugin): void {
    if (this?.delegate != null) {
      this?.delegate?.removePlugin(plugin)
    }
  }

  /**
   * Called when memory level changes.
   * @param level - The memory level
   */
  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    Log.i(TAG, 'onMemoryLevel: ' + level);
    if (level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_CRITICAL) {
      this?.delegate?.onLowMemory();
    }
    this.delegate?.getFlutterNapi()?.SetQosOnLowMemory(level as number);
  }

  /**
   * Called when configuration is updated.
   * @param config - The new configuration
   */
  onConfigurationUpdate(config: Configuration) {
    Log.i(TAG, 'onConfigurationUpdate config:' + JSON.stringify(config));
    this?.delegate?.flutterEngine?.getSettingsChannel()?.startMessage()
      .setNativeSpellCheckServiceDefined(false)
      .setBrieflyShowPassword(false)
      .setAlwaysUse24HourFormat(I18n.System.is24HourClock())
      .setPlatformBrightness(config.colorMode != ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        ? PlatformBrightness.LIGHT : PlatformBrightness.DARK)
      .setTextScaleFactor(config.fontSizeScale == undefined ? 1.0 : config.fontSizeScale)
      .send(); //热启动生命周期内，实时监听系统设置环境改变并实时发送相应信息

    //实时获取系统字体加粗系数
    this.delegate?.getFlutterNapi()?.setFontWeightScale(config.fontWeightScale == undefined ? 0 :
    config.fontWeightScale);
    Log.i(TAG, 'fontWeightScale: ' + JSON.stringify(config.fontWeightScale));

    if (config.language != '') {
      this.getFlutterEngine()?.getLocalizationPlugin()?.sendLocaleToFlutter();
    }
    this?.delegate?.onCheckAndReloadFont();
    this.delegate?.changeColorMode(config.colorMode);
  }

  /**
   * Gets the FlutterEngine instance.
   * @returns The FlutterEngine instance, or null if not available
   */
  getFlutterEngine(): FlutterEngine | null {
    return this.delegate?.flutterEngine || null;
  }
}