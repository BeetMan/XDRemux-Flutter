/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterEngine.java originally written by
* Copyright (C) Copyright 2013 The Flutter Authors.
*
*/

import LifecycleChannel from './systemchannels/LifecycleChannel';
import DartExecutor, { DartEntrypoint } from './dart/DartExecutor';
import FlutterShellArgs from './FlutterShellArgs';
import FlutterInjector from '../../FlutterInjector';
import FlutterLoader from './loader/FlutterLoader';
import common from '@ohos.app.ability.common';
import resourceManager from '@ohos.resourceManager';
import FlutterNapi from './FlutterNapi';
import NavigationChannel from './systemchannels/NavigationChannel';
import Log from '../../util/Log';
import TestChannel from './systemchannels/TestChannel'
import FlutterEngineConnectionRegistry from './FlutterEngineConnectionRegistry';
import PluginRegistry from './plugins/PluginRegistry';
import AbilityControlSurface from './plugins/ability/AbilityControlSurface';
import TextInputChannel from './systemchannels/TextInputChannel';
import TextInputPlugin from '../../plugin/editing/TextInputPlugin';
import PlatformChannel from './systemchannels/PlatformChannel';
import SystemChannel from './systemchannels/SystemChannel';
import SplitViewConfigSystemChannel from './systemchannels/SplitViewConfigSystemChannel';
import MouseCursorChannel from './systemchannels/MouseCursorChannel';
import DisplayMetricsChannel from './systemchannels/DisplayMetricsChannel';
import RestorationChannel from './systemchannels/RestorationChannel';
import LocalizationChannel from './systemchannels/LocalizationChannel';
import AccessibilityChannel from './systemchannels/AccessibilityChannel';
import LocalizationPlugin from '../../plugin/localization/LocalizationPlugin'
import SettingsChannel from './systemchannels/SettingsChannel';
import SensitiveContentChannel from './systemchannels/SensitiveContentChannel';
import PlatformViewsController from '../../plugin/platform/PlatformViewsController';
import { FlutterRenderer } from './renderer/FlutterRenderer';
import NativeVsyncChannel from './systemchannels/NativeVsyncChannel';
import PiPVisibilityBridge from '../ohos/PiPVisibilityBridge';

const TAG = "FlutterEngine";

/**
 * A single Flutter execution environment.
 *
 * The FlutterEngine is the container through which Dart code can be run in an OpenHarmony application.
 *
 * Dart code in a FlutterEngine can execute in the background, or it can be rendered to the screen by
 * using the accompanying FlutterRenderer and Dart code using the Flutter framework on the Dart side.
 * Rendering can be started and stopped, thus allowing a FlutterEngine to move from UI interaction
 * to data-only processing and then back to UI interaction.
 *
 * Multiple FlutterEngines may exist, execute Dart code, and render UIs within a single OpenHarmony app.
 * For better memory performance characteristics, construct multiple FlutterEngines via FlutterEngineGroup
 * rather than via FlutterEngine's constructor directly.
 *
 * To start running Dart and/or Flutter within this FlutterEngine, get a reference to this engine's
 * DartExecutor and then use DartExecutor.executeDartEntrypoint(DartEntrypoint). The
 * DartExecutor.executeDartEntrypoint(DartEntrypoint) method must not be invoked twice on the same FlutterEngine.
 *
 * To start rendering Flutter content to the screen, use getFlutterRenderer() to obtain a FlutterRenderer
 * and then attach a RenderSurface. Consider using a FlutterView as a RenderSurface.
 *
 * Instantiating the first FlutterEngine per process will also load the Flutter engine's native library
 * and start the Dart VM. Subsequent FlutterEngines will run on the same VM instance but will have
 * their own Dart Isolate when the DartExecutor is run. Each Isolate is a self-contained Dart environment
 * and cannot communicate with each other except via Isolate ports.
 */
export default class FlutterEngine implements EngineLifecycleListener {
  private engineLifecycleListeners = new Set<EngineLifecycleListener>();
  dartExecutor: DartExecutor;
  private flutterLoader: FlutterLoader;
  private assetManager: resourceManager.ResourceManager;
  //channel定义
  private lifecycleChannel: LifecycleChannel | null = null;
  private navigationChannel: NavigationChannel | null = null;
  private textInputChannel: TextInputChannel | null = null;
  private testChannel: TestChannel | null = null;
  private platformChannel: PlatformChannel | null = null;
  private sensitiveContentChannel: SensitiveContentChannel  | null = null;
  private systemChannel: SystemChannel | null = null;
  private splitViewConfigSystemChannel: SplitViewConfigSystemChannel | null = null;
  private mouseCursorChannel: MouseCursorChannel | null = null;
  private displayMetricsChannel: DisplayMetricsChannel | null = null;
  private restorationChannel: RestorationChannel | null = null;
  private accessibilityChannel: AccessibilityChannel | null = null;
  private localeChannel: LocalizationChannel | null = null;
  private flutterNapi: FlutterNapi;
  private renderer: FlutterRenderer;
  private pluginRegistry: FlutterEngineConnectionRegistry | null = null;
  private textInputPlugin: TextInputPlugin | null = null;
  private localizationPlugin: LocalizationPlugin | null = null;
  private settingsChannel: SettingsChannel | null = null;
  private platformViewsController: PlatformViewsController;
  private nativeVsyncChannel: NativeVsyncChannel | null = null;
  private readonly pipVisibilityListener = (visible: boolean): void => {
    this.flutterNapi?.setPipVisible(visible);
  };

  /**
   * Constructs a new FlutterEngine instance.
   * Initializes DartExecutor, channels, plugins, FlutterLoader, FlutterNapi, and lifecycle listeners.
   * @param context - The application context
   * @param flutterLoader - Optional FlutterLoader instance, will be created if null
   * @param flutterNapi - Optional FlutterNapi instance, will be created if null
   * @param platformViewsController - Optional PlatformViewsController, will be created if null
   */
  constructor(context: common.Context, flutterLoader: FlutterLoader | null, flutterNapi: FlutterNapi | null,
    platformViewsController: PlatformViewsController | null) {
    const injector: FlutterInjector = FlutterInjector.getInstance();
    if (flutterNapi == null) {
      flutterNapi = FlutterInjector.getInstance().getFlutterNapi();
    }
    this.flutterNapi = flutterNapi;
    this.assetManager = context.resourceManager;

    this.dartExecutor = new DartExecutor(this.flutterNapi, this.assetManager);
    this.dartExecutor.onAttachedToNAPI();

    if (flutterLoader == null) {
      flutterLoader = injector.getFlutterLoader();
    }
    this.flutterLoader = flutterLoader;

    this.renderer = new FlutterRenderer(this.flutterNapi);

    if (platformViewsController == null) {
      platformViewsController = new PlatformViewsController();
    }
    this.platformViewsController = platformViewsController;
    this.platformViewsController.attach(context, this.renderer, this.dartExecutor);
  }

  /**
   * Initializes the Flutter engine.
   * Sets up all channels, plugins, and attaches to the native engine.
   * @param context - The application context
   * @param dartVmArgs - Optional Dart VM arguments
   * @param waitForRestorationData - Whether to wait for restoration data
   */
  init(context: common.Context, dartVmArgs: Array<string> | null, waitForRestorationData: boolean) {
    if (!this.flutterNapi.isAttached()) {
      this.flutterLoader.startInitialization(context)
      this.flutterLoader.ensureInitializationComplete(dartVmArgs);
    }
    //channel初始化
    this.lifecycleChannel = new LifecycleChannel(this.dartExecutor);
    this.displayMetricsChannel = new DisplayMetricsChannel(this.dartExecutor, context);
 	  this.navigationChannel = new NavigationChannel(this.dartExecutor, context, this.displayMetricsChannel);
    this.textInputChannel = new TextInputChannel(this.dartExecutor);
    this.testChannel = new TestChannel(this.dartExecutor);
    this.platformChannel = new PlatformChannel(this.dartExecutor, this.flutterNapi);
    this.sensitiveContentChannel = new SensitiveContentChannel(this.dartExecutor);
    this.systemChannel = new SystemChannel(this.dartExecutor);
    this.splitViewConfigSystemChannel = new SplitViewConfigSystemChannel(this.dartExecutor, context);
    this.mouseCursorChannel = new MouseCursorChannel(this.dartExecutor);
    this.restorationChannel = new RestorationChannel(this.dartExecutor, waitForRestorationData);
    this.settingsChannel = new SettingsChannel(this.dartExecutor);
    this.localeChannel = new LocalizationChannel(this.dartExecutor);
    this.accessibilityChannel = new AccessibilityChannel(this.dartExecutor, this.flutterNapi);
    this.flutterNapi.addEngineLifecycleListener(this);
    this.localizationPlugin = new LocalizationPlugin(context, this.localeChannel);
    this.nativeVsyncChannel = new NativeVsyncChannel(this.dartExecutor, this.flutterNapi);

    // It should typically be a fresh, unattached NAPI. But on a spawned engine, the NAPI instance
    // is already attached to a native shell. In that case, the Java FlutterEngine is created around
    // an existing shell.
    if (!this.flutterNapi.isAttached()) {
      this.attachToNapi();
    }
    this.flutterNapi.setLocalizationPlugin(this.localizationPlugin);

    this.pluginRegistry =
      new FlutterEngineConnectionRegistry(context.getApplicationContext(), this, this.flutterLoader);
    this.localizationPlugin.sendLocaleToFlutter();
    PiPVisibilityBridge.getInstance().register(this.pipVisibilityListener);
    Log.d(TAG, "Call init finished.")
  }

  private attachToNapi(): void {
    Log.d(TAG, "Attaching to NAPI.");
    this.flutterNapi.attachToNative();
    if (!this.isAttachedToNapi()) {
      throw new Error("FlutterEngine failed to attach to its native Object reference.");
    }
  }

  /**
   * Spawns a new Flutter engine from this engine.
   * The spawned engine shares resources with the parent engine.
   * @param context - The application context
   * @param dartEntrypoint - The Dart entrypoint configuration
   * @param initialRoute - The initial route for navigation
   * @param dartEntrypointArgs - Arguments for the Dart entrypoint
   * @param platformViewsController - The platform views controller
   * @param waitForRestorationData - Whether to wait for restoration data
   * @returns The spawned FlutterEngine instance
   * @throws Error if this engine is not fully constructed
   */
  spawn(context: common.Context,
    dartEntrypoint: DartEntrypoint,
    initialRoute: string,
    dartEntrypointArgs: Array<string>,
    platformViewsController: PlatformViewsController,
    waitForRestorationData: boolean) {
    if (!this.isAttachedToNapi()) {
      throw new Error(
        "Spawn can only be called on a fully constructed FlutterEngine");
    }

    const newFlutterNapi =
      this.flutterNapi.spawn(
        dartEntrypoint.dartEntrypointFunctionName,
        dartEntrypoint.dartEntrypointLibrary,
        initialRoute,
        dartEntrypointArgs);
    const flutterEngine = new FlutterEngine(
      context,
      null,
      newFlutterNapi,
      platformViewsController
    );
    flutterEngine.init(context, null, waitForRestorationData)
    return flutterEngine
  }

  private isAttachedToNapi(): boolean {
    return this.flutterNapi.isAttached();
  }

  /**
   * Processes any pending messages from the native side.
   */
  processPendingMessages() {
    if (this.flutterNapi.isAttached()) {
      this.flutterNapi.processPendingMessages();
    }
  }

  /**
   * Gets the lifecycle channel for managing application lifecycle events.
   * @returns The LifecycleChannel instance, or null if not initialized
   */
  getLifecycleChannel(): LifecycleChannel | null {
    return this.lifecycleChannel;
  }

  /**
   * Gets the navigation channel for managing navigation events.
   * @returns The NavigationChannel instance, or null if not initialized
   */
  getNavigationChannel(): NavigationChannel | null {
    return this.navigationChannel;
  }

  /**
   * Gets the text input channel for managing text input events.
   * @returns The TextInputChannel instance, or null if not initialized
   */
  getTextInputChannel(): TextInputChannel | null {
    return this.textInputChannel;
  }

  /**
   * Gets the platform channel for platform-specific communication.
   * @returns The PlatformChannel instance, or null if not initialized
   */
  getPlatformChannel(): PlatformChannel | null {
    return this.platformChannel;
  }

  /**
   * Gets the system channel for system-level communication.
   * @returns The SystemChannel instance, or null if not initialized
   */
  getSystemChannel(): SystemChannel | null {
    return this.systemChannel;
  }

  getSplitViewConfigSystemChannel(): SplitViewConfigSystemChannel | null {
    return this.splitViewConfigSystemChannel;
  }

  /**
   * Gets the localization channel for managing locale information.
   * @returns The LocalizationChannel instance, or null if not initialized
   */
  getLocaleChannel(): LocalizationChannel | null {
    return this.localeChannel;
  }

  /**
   * Gets the mouse cursor channel for managing cursor changes.
   * @returns The MouseCursorChannel instance, or null if not initialized
   */
  getMouseCursorChannel(): MouseCursorChannel | null {
    return this.mouseCursorChannel;
  }

  getDisplayMetricsChannel(): DisplayMetricsChannel | null {
    return this.displayMetricsChannel;
  }

  /**
   * Gets the FlutterNapi instance for native communication.
   * @returns The FlutterNapi instance
   */
  getFlutterNapi(): FlutterNapi {
    return this.flutterNapi;
  }

  /**
   * Gets the FlutterRenderer instance for rendering operations.
   * @returns The FlutterRenderer instance
   */
  getFlutterRenderer(): FlutterRenderer {
    return this.renderer;
  }

  /**
   * Gets the DartExecutor instance for executing Dart code.
   * @returns The DartExecutor instance
   */
  getDartExecutor(): DartExecutor {
    return this.dartExecutor
  }

  getSensitiveContentChannel():SensitiveContentChannel |null {
    return this.sensitiveContentChannel
  }

  /**
   * Gets the plugin registry for managing Flutter plugins.
   * @returns The PluginRegistry instance, or null if not initialized
   */
  getPlugins(): PluginRegistry | null {
    return this.pluginRegistry;
  }

  /**
   * Gets the ability control surface for managing ability-related operations.
   * @returns The AbilityControlSurface instance, or null if not initialized
   */
  getAbilityControlSurface(): AbilityControlSurface | null {
    return this.pluginRegistry;
  }

  /**
   * Gets the settings channel for managing application settings.
   * @returns The SettingsChannel instance, or null if not initialized
   */
  getSettingsChannel() {
    return this.settingsChannel;
  }

  /**
   * Gets the FlutterLoader instance for loading Flutter assets.
   * @returns The FlutterLoader instance
   */
  getFlutterLoader() {
    return this.flutterLoader;
  }

  /**
   * Called before the engine restarts.
   * Notifies all registered lifecycle listeners.
   */
  onPreEngineRestart(): void {
    this.engineLifecycleListeners.forEach(listener => listener.onPreEngineRestart())
  }

  /**
   * Called when the engine is about to be destroyed.
   */
  onEngineWillDestroy(): void {

  }

  /**
   * Adds a lifecycle listener to be notified of engine lifecycle events.
   * @param listener - The EngineLifecycleListener to add
   */
  addEngineLifecycleListener(listener: EngineLifecycleListener): void {
    this.engineLifecycleListeners.add(listener);
  }

  /**
   * Removes a lifecycle listener from the list of registered listeners.
   * @param listener - The EngineLifecycleListener to remove
   */
  removeEngineLifecycleListener(listener: EngineLifecycleListener): void {
    this.engineLifecycleListeners.delete(listener);
  }

  /**
   * Destroys the Flutter engine and releases all resources.
   * Notifies listeners, detaches from ability, and cleans up all components.
   */
  destroy(): void {
    Log.d(TAG, "Destroying.");
    this.flutterNapi?.setPipVisible(false);
    PiPVisibilityBridge.getInstance().unregister(this.pipVisibilityListener);
    this.engineLifecycleListeners.forEach(listener => listener.onEngineWillDestroy())
    this.flutterNapi.removeEngineLifecycleListener(this);
    this.pluginRegistry?.detachFromAbility();
    this.platformViewsController?.onDetachedFromNapi();
    this.pluginRegistry?.destroy();
    this.dartExecutor.onDetachedFromNAPI();
    this.flutterNapi.detachFromNativeAndReleaseResources();
  }

  /**
   * Gets the restoration channel for managing state restoration.
   * @returns The RestorationChannel instance, or null if not initialized
   */
  getRestorationChannel(): RestorationChannel | null {
    return this.restorationChannel;
  }

  /**
   * Gets the accessibility channel for managing accessibility features.
   * @returns The AccessibilityChannel instance, or null if not initialized
   */
  getAccessibilityChannel(): AccessibilityChannel | null {
    return this.accessibilityChannel;
  }

  /**
   * Gets the localization plugin for managing locale information.
   * @returns The LocalizationPlugin instance, or null if not initialized
   */
  getLocalizationPlugin(): LocalizationPlugin | null {
    return this.localizationPlugin;
  }

  /**
   * Gets the system languages from the native side.
   */
  getSystemLanguages(): void {
    return this.flutterNapi.getSystemLanguages();
  }

  /**
   * Gets the platform views controller for managing platform views.
   * @returns The PlatformViewsController instance, or null if not initialized
   */
  getPlatformViewsController(): PlatformViewsController | null {
    return this.platformViewsController;
  }

  /**
   * Gets the native VSync channel for managing vertical synchronization.
   * @returns The NativeVsyncChannel instance, or null if not initialized
   */
  getNativeVsyncChannel(): NativeVsyncChannel | null {
    return this.nativeVsyncChannel;
  }

  /**
   * Prefetches frame configuration for improved performance.
   */
  async prefetchFramesCfg(): Promise<void> {
    FlutterNapi.prefetchFramesCfg();
  }
}

/**
 * Interface for listening to Flutter engine lifecycle events.
 */
export interface EngineLifecycleListener {
  /**
   * Called before the engine restarts.
   */
  onPreEngineRestart(): void;

  /**
   * Called when the engine is about to be destroyed.
   */
  onEngineWillDestroy(): void;
}