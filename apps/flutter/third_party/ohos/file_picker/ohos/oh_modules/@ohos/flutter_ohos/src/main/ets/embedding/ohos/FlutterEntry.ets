/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import FlutterEngine from '../engine/FlutterEngine';
import FlutterEngineCache from '../engine/FlutterEngineCache';
import PlatformPlugin from '../../plugin/PlatformPlugin';
import Want from '@ohos.app.ability.Want';
import FlutterShellArgs from '../engine/FlutterShellArgs';
import UIAbility from '@ohos.app.ability.UIAbility';
import ExclusiveAppComponent from './ExclusiveAppComponent';
import { FlutterAbilityAndEntryDelegate, Host } from './FlutterAbilityAndEntryDelegate';
import FlutterAbilityLaunchConfigs from './FlutterAbilityLaunchConfigs';
import SensitiveContentPlugin from '../../plugin/view/SensitiveContentPlugin';
import Log from '../../util/Log';
import { FlutterView } from '../../view/FlutterView';
import FlutterManager from './FlutterManager';
import window from '@ohos.window';
import FlutterEngineConfigurator from './FlutterEngineConfigurator';
import { FlutterPlugin } from '../engine/plugins/FlutterPlugin';
import { BusinessError } from '@ohos.base';
import { PlatformBrightness } from '../engine/systemchannels/SettingsChannel';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import I18n from '@ohos.i18n'
import { AbilityConstant, EnvironmentCallback } from '@kit.AbilityKit';

const TAG = "FlutterEntry";

/**
 * Entry point for Flutter content in a page component.
 * This class manages the lifecycle of FlutterView and FlutterEngine within a page context.
 */
export default class FlutterEntry implements Host {
  private static ARG_SHOULD_ATTACH_ENGINE_TO_ABILITY: string = "should_attach_engine_to_ability";
  protected uiAbility: UIAbility | null = null
  protected delegate: FlutterAbilityAndEntryDelegate | null = null
  protected flutterView: FlutterView | null = null
  protected context: Context;
  protected windowStage: window.WindowStage | null = null
  private parameters: Record<string, Object> = {};
  protected engineConfigurator: FlutterEngineConfigurator | null = null
  protected hasInit: boolean = false;
  protected callbackId: number | undefined = undefined;
  /**
   * 标记是否有一次onPageShow事件在delegate未初始化前执行
   * 为了保证生命周期事件不丢失，等待delegate初始化完成后再执行一次onShow
   */
  protected pendingOnShow: boolean = false;

  /**
   * Constructs a new FlutterEntry instance.
   * @param context - The page context
   * @param params - Optional parameters for configuration
   */
  constructor(context: Context, params: Record<string, Object> = {}) {
    this.context = context;
    this.uiAbility = FlutterManager.getInstance().getUIAbility(context);
    this.parameters = params;
    this.windowStage = FlutterManager.getInstance().getWindowStage(this.uiAbility);
    this.hasInit = false;
  }

  /**
   * Callback for window stage events.
   * @param data - The window stage event type
   */
  protected windowStageEventCallback = (data: window.WindowStageEventType) => {
    this.delegate?.onWindowStageChanged(data)
  }

  /**
   * Called when the page is about to appear.
   * Initializes the Flutter delegate and view.
   */
  aboutToAppear() {
    Log.i(TAG, 'aboutToAppear');
    if (this.hasInit == false) {
      this.delegate = new FlutterAbilityAndEntryDelegate(this);
      this.flutterView = this.delegate?.createView(this.context);
      this.flutterView?.onWindowCreated();
      this?.delegate?.onAttach(this.context);
      //this.flutterView?.preDraw();
      //Log.d(TAG, "XComponent aboutToAppear predraw");
      Log.i(TAG, 'onAttach end');
      this?.delegate?.platformPlugin?.setUIAbilityContext(this.uiAbility!!.context);
      this.delegate?.onWindowStageCreate()
      this.windowStage?.on('windowStageEvent', this.windowStageEventCallback);
      this.hasInit = true;
      this.delegate?.initWindow();
      if (this.pendingOnShow) {
        // aboutToAppear晚于onPageShow执行时，再执行一次onShow
        this.delegate.onShow();
        this.pendingOnShow = false;
      }
      this.registerEnvironmentCallback();
    }
  }

  /**
   * Registers an environment callback to listen for configuration changes.
   */
  registerEnvironmentCallback() {
    let environmentCallback: EnvironmentCallback = {
      onConfigurationUpdated: (config) => {
        Log.i(TAG, 'onConfigurationUpdate config: ' + JSON.stringify(config));
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
          this.delegate?.flutterEngine?.getLocalizationPlugin()?.sendLocaleToFlutter();
        }
        this?.delegate?.onCheckAndReloadFont();
        this.delegate?.changeColorMode(config.colorMode);
      },
      onMemoryLevel: (level: AbilityConstant.MemoryLevel) => {
        this.delegate?.getFlutterNapi()?.SetQosOnLowMemory(level as number);
      }
    };
    let applicationContext = this.uiAbility?.context.getApplicationContext();
    try {
      this.callbackId = applicationContext?.on('environment', environmentCallback);
    } catch (paramError) {
      Log.e(TAG, 'registerEnvironmentCallback error: ' + (paramError as BusinessError).code + ' message: '
                 + (paramError as BusinessError).message);
    }
  }

  /**
   * Unregisters the environment callback.
   */
  unregisterEnvironmentCallback() {
    let applicationContext = this.uiAbility?.context.getApplicationContext();
    try {
      applicationContext?.off('environment', this.callbackId, (error, data) => {
        if (error && error.code !== 0) {
          Log.e(TAG, 'unregisterEnvironmentCallback fail, error: ' + JSON.stringify(error));
        }
      });
    } catch (paramError) {
      Log.e(TAG, 'error: ' + (paramError as BusinessError).code + ' message: '
                           + (paramError as BusinessError).message);
    }
  }

  /**
   * Sets the Flutter engine configurator.
   * @param configurator - The FlutterEngineConfigurator instance
   */
  setFlutterEngineConfigurator(configurator: FlutterEngineConfigurator) {
    this.engineConfigurator = configurator;
  }

  /**
   * Gets the FlutterView instance.
   * @returns The FlutterView instance
   */
  getFlutterView(): FlutterView {
    return this.flutterView!!
  }

  /**
   * Gets the FlutterEngine instance.
   * @returns The FlutterEngine instance, or null if not available
   */
  getFlutterEngine(): FlutterEngine | null {
    return this.delegate?.flutterEngine!
  }

  /**
   * Called when the page is about to disappear.
   * Cleans up resources and detaches from the Flutter engine.
   */
  aboutToDisappear() {
    Log.d(TAG, "FlutterEntry aboutToDisappear");
    this.unregisterEnvironmentCallback();
    try {
      this.windowStage?.off('windowStageEvent', this.windowStageEventCallback);
    } catch (err) {
      Log.e(TAG, "windowStage off failed");
    }
    if (this.flutterView != null) {
      this.flutterView.onDestroy();
      this.flutterView = null;
    }
    if (this.delegate != null) {
      this.delegate?.onDetach();
      this.delegate?.release()
    }
  }

  /**
   * Called when the page is shown.
   * Notifies the delegate that the page is visible.
   */
  onPageShow() { //生命周期
    Log.d(TAG, "FlutterEntry onPageShow");
    if (this.delegate) {
      this.delegate.onShow();
    } else {
      this.pendingOnShow = true;
    }
  }

  /**
   * Called when the page is hidden.
   * Notifies the delegate that the page is hidden.
   */
  onPageHide() { //生命周期
    Log.d(TAG, "FlutterEntry onPageHide");
    this?.delegate?.onHide();
  }

  /**
   * Called when the back button is pressed.
   * Pops the current route in Flutter navigation.
   */
  onBackPress() {
    Log.d(TAG, "FlutterEntry onBackPress");
    this?.delegate?.flutterEngine?.getNavigationChannel()?.popRoute();
  }

  /**
   * Determines whether to dispatch app lifecycle state changes.
   * @returns True to dispatch lifecycle state, false otherwise
   */
  shouldDispatchAppLifecycleState(): boolean {
    return true;
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
   * Gets the associated UIAbility.
   * @returns The UIAbility instance
   */
  getAbility(): UIAbility {
    return this.uiAbility!!
  }

  /**
   * Loads the page content.
   * This method is called by the framework.
   */
  loadContent() {

  }

  /**
   * Determines whether to attach the engine to the ability.
   * @returns True to attach the engine, false otherwise
   */
  shouldAttachEngineToAbility(): boolean {
    let param = this.parameters![FlutterEntry.ARG_SHOULD_ATTACH_ENGINE_TO_ABILITY];
    if (!param) {
      return true;
    }
    return param as boolean
  }

  /**
   * Gets the cached engine ID from parameters.
   * @returns The cached engine ID, or empty string if not set
   */
  getCachedEngineId(): string {
    let param = this.parameters![FlutterAbilityLaunchConfigs.EXTRA_CACHED_ENGINE_ID];
    if (!param) {
      return "";
    }
    return param as string
  }

  /**
   * Gets the cached engine group ID from parameters.
   * @returns The cached engine group ID, or null if not set
   */
  getCachedEngineGroupId(): string | null {
    let param = this.parameters![FlutterAbilityLaunchConfigs.EXTRA_CACHED_ENGINE_GROUP_ID];
    if (!param) {
      return null;
    }
    return param as string
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

    const engine = this.delegate?.flutterEngine;
    if (engine != null && FlutterEngineCache.getInstance().containsEngine(engine)) {
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
   * Gets Flutter shell arguments.
   * @returns A FlutterShellArgs instance
   */
  getFlutterShellArgs(): FlutterShellArgs {
    return new FlutterShellArgs();
  }

  /**
   * Gets Dart entrypoint arguments from parameters.
   * @returns Array of entrypoint arguments
   */
  getDartEntrypointArgs(): string[] {
    if (this.parameters![FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT_ARGS]) {
      return this.parameters![FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT_ARGS] as Array<string>;
    }
    return new Array<string>()
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
   * Gets the Dart entrypoint function name from parameters.
   * @returns The entrypoint function name, or default if not set
   */
  getDartEntrypointFunctionName(): string {
    if (this.parameters![FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT]) {
      return this.parameters![FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT] as string;
    }
    return FlutterAbilityLaunchConfigs.DEFAULT_DART_ENTRYPOINT
  }

  /**
   * Gets the initial route from parameters.
   * @returns The initial route string, or empty string if not set
   */
  getInitialRoute(): string {
    if (this.parameters![FlutterAbilityLaunchConfigs.EXTRA_INITIAL_ROUTE]) {
      return this.parameters![FlutterAbilityLaunchConfigs.EXTRA_INITIAL_ROUTE] as string
    }
    return "";
  }

  /**
   * Gets the Want object.
   * @returns A new Want instance
   */
  getWant(): Want {
    return new Want();
  }

  /**
   * Determines whether to restore and save state.
   * @returns True to restore and save state, false otherwise
   */
  shouldRestoreAndSaveState(): boolean {
    if (this.parameters![FlutterAbilityLaunchConfigs.EXTRA_CACHED_ENGINE_ID] != undefined) {
      return this.parameters![FlutterAbilityLaunchConfigs.EXTRA_CACHED_ENGINE_ID] as boolean;
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
   * Provides a FlutterEngine instance.
   * @param context - The context
   * @returns A FlutterEngine instance, or null if not provided
   */
  provideFlutterEngine(context: Context): FlutterEngine | null {
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
    if (this.engineConfigurator) {
      this.engineConfigurator.configureFlutterEngine(flutterEngine)
    }
  }

  /**
   * Cleans up the Flutter engine.
   * @param flutterEngine - The FlutterEngine to clean up
   */
  cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    if (this.engineConfigurator) {
      this.engineConfigurator.cleanUpFlutterEngine(flutterEngine)
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
   * Adds a Flutter plugin.
   * @param plugin - The FlutterPlugin to add
   */
  addPlugin(plugin: FlutterPlugin): void {
    this.delegate?.addPlugin(plugin)
  }

  /**
   * Removes a Flutter plugin.
   * @param plugin - The FlutterPlugin to remove
   */
  removePlugin(plugin: FlutterPlugin): void {
    this.delegate?.removePlugin(plugin)
  }
}