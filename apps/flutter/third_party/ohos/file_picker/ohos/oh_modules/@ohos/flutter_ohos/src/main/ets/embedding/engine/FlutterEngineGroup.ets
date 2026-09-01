/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterEngineGroup.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import FlutterEngine, { EngineLifecycleListener } from "./FlutterEngine"
import common from '@ohos.app.ability.common'
import display from '@ohos.display';
import FlutterLoader from './loader/FlutterLoader'
import FlutterInjector from '../../FlutterInjector'
import { DartEntrypoint } from './dart/DartExecutor'
import PlatformViewsController from '../../plugin/platform/PlatformViewsController'
import ArrayList from '@ohos.util.ArrayList'
import Log from '../../util/Log';
import FlutterManager from '../ohos/FlutterManager';

const TAG = "FlutterEngineGroup"

/**
 * Represents a collection of FlutterEngines who share resources to allow them to be created
 * faster and with less memory than calling the FlutterEngine's constructor multiple times.
 *
 * When creating or recreating the first FlutterEngine in the FlutterEngineGroup, the behavior
 * is the same as creating a FlutterEngine via its constructor. When subsequent FlutterEngines
 * are created, resources from an existing living FlutterEngine is re-used.
 *
 * The shared resources are kept until the last surviving FlutterEngine is destroyed.
 *
 * Deleting a FlutterEngineGroup doesn't invalidate its existing FlutterEngines, but it eliminates
 * the possibility to create more FlutterEngines in that group.
 */
export default class FlutterEngineGroup {
  private activeEngines: ArrayList<FlutterEngine> = new ArrayList<FlutterEngine>();

  /**
   * Constructs a new FlutterEngineGroup instance.
   */
  constructor() {

  }

  /**
   * Checks and initializes the FlutterLoader if not already initialized.
   * @param context - The application context
   * @param args - Command-line arguments for Dart VM initialization
   */
  checkLoader(context: common.Context, args: Array<string>) {
    let loader: FlutterLoader = FlutterInjector.getInstance().getFlutterLoader();
    if (!loader.initialized) {
      loader.startInitialization(context);
      loader.ensureInitializationComplete(args);
    }
  }

  /**
   * Creates and runs a Flutter engine based on the provided options.
   * If no engines exist, creates a new engine. Otherwise, spawns from the first engine.
   * @param options - Configuration options for engine creation
   * @returns The created or spawned FlutterEngine instance
   */
  createAndRunEngineByOptions(options: Options) {
    let engine: FlutterEngine | null = null;
    let context: common.Context = options.getContext();
    let dartEntrypoint: DartEntrypoint | null = options.getDartEntrypoint();
    let initialRoute: string = options.getInitialRoute();
    let dartEntrypointArgs: Array<string> = options.getDartEntrypointArgs();
    let platformViewsController: PlatformViewsController | null = options.getPlatformViewsController();
    let waitForRestorationData: boolean = options.getWaitForRestorationData();

    if (dartEntrypoint == null) {
      dartEntrypoint = DartEntrypoint.createDefault();
    }

    if (platformViewsController == null) {
      platformViewsController = new PlatformViewsController();
    }

    Log.i(TAG, "shellHolder, this.activeEngines.length=" + this.activeEngines.length)
    if (this.activeEngines.length == 0) {
      engine = this.createEngine(context, platformViewsController);
      engine.init(context, null, // String[]. The Dart VM has already started, this arguments will have no effect.
        waitForRestorationData)
      if (initialRoute != null) {
        engine.getNavigationChannel()?.setInitialRoute(initialRoute);
      }
      engine.getDartExecutor().executeDartEntrypoint(dartEntrypoint, dartEntrypointArgs);
      engine.prefetchFramesCfg();
    } else {
      engine = this.activeEngines[0]
        .spawn(
          context,
          dartEntrypoint,
          initialRoute,
          dartEntrypointArgs,
          platformViewsController,
          waitForRestorationData);
    }
    this.activeEngines.add(engine);

    const engineToCleanUpOnDestroy = engine;
    let listener: EngineLifecycleListener = new EngineLifecycleListenerImpl(
      platformViewsController,
      this.activeEngines,
      engineToCleanUpOnDestroy);
    engine?.addEngineLifecycleListener(listener);
    return engine;
  }

  /**
   * Creates a new FlutterEngine instance.
   * @param context - The application context
   * @param platformViewsController - The platform views controller for the engine
   * @returns A new FlutterEngine instance
   */
  createEngine(context: common.Context, platformViewsController: PlatformViewsController): FlutterEngine {
    return new FlutterEngine(context, null, null, platformViewsController);
  }

  /**
   * Gets the default (first) engine in this group.
   * @returns The default FlutterEngine, or null if no engines exist
   */
  getDefaultEngine(): FlutterEngine | null {
    let engine: FlutterEngine | null = null;
    if (this.activeEngines.length != 0) {
      engine = this.activeEngines[0];
    }
    return engine;
  }
}

/**
 * Implementation of EngineLifecycleListener for managing engine lifecycle in a group.
 */
class EngineLifecycleListenerImpl implements EngineLifecycleListener {
  private platformViewsController: PlatformViewsController;
  private activeEngines: ArrayList<FlutterEngine> = new ArrayList();
  private engine: FlutterEngine | null;

  /**
   * Constructs a new EngineLifecycleListenerImpl instance.
   * @param platformViewsController - The platform views controller
   * @param activeEngines - List of active engines in the group
   * @param engine - The engine this listener is associated with
   */
  constructor(
    platformViewsController: PlatformViewsController,
    activeEngines: ArrayList<FlutterEngine>,
    engine: FlutterEngine | null) {
    this.platformViewsController = platformViewsController;
    this.activeEngines = activeEngines;
    this.engine = engine;
  }

  /**
   * Called before the engine restarts.
   */
  onPreEngineRestart(): void {
    this.platformViewsController.onPreEngineRestart();
  }

  /**
   * Called when the engine is about to be destroyed.
   * Removes the engine from the active engines list.
   */
  onEngineWillDestroy(): void {
    this.activeEngines.remove(this.engine);
  }
}

/**
 * Options that control how a FlutterEngine should be created..
 */
export class Options {
  private context: common.Context;
  private dartEntrypoint: DartEntrypoint | null = null;
  private initialRoute: string = '';
  private dartEntrypointArgs: Array<string> = [];
  private platformViewsController: PlatformViewsController | null = null;
  private waitForRestorationData: boolean = false;

  /**
   * Constructs a new Options instance.
   * @param context - The application context
   */
  constructor(context: common.Context) {
    this.context = context;
  }

  /**
   * Gets the application context.
   * @returns The context
   */
  getContext(): common.Context {
    return this.context;
  }

  /**
   * Gets the Dart entrypoint configuration.
   * @returns The DartEntrypoint, or null if not set
   */
  getDartEntrypoint(): DartEntrypoint | null {
    return this.dartEntrypoint;
  }

  /**
   * Gets the initial route for navigation.
   * @returns The initial route string
   */
  getInitialRoute(): string {
    return this.initialRoute;
  }

  /**
   * Gets the Dart entrypoint arguments.
   * @returns Array of entrypoint arguments
   */
  getDartEntrypointArgs(): Array<string> {
    return this.dartEntrypointArgs;
  }

  /**
   * Gets whether to wait for restoration data.
   * @returns true if waiting for restoration data, false otherwise
   */
  getWaitForRestorationData(): boolean {
    return this.waitForRestorationData;
  }

  /**
   * Gets the platform views controller.
   * @returns The PlatformViewsController, or null if not set
   */
  getPlatformViewsController(): PlatformViewsController | null {
    return this.platformViewsController;
  }

  /**
   * Sets the Dart entrypoint configuration.
   * @param dartEntrypoint - The DartEntrypoint to set
   * @returns This Options instance for method chaining
   */
  setDartEntrypoint(dartEntrypoint: DartEntrypoint): Options {
    this.dartEntrypoint = dartEntrypoint;
    return this;
  }

  /**
   * Sets the initial route for navigation.
   * @param initialRoute - The initial route string
   * @returns This Options instance for method chaining
   */
  setInitialRoute(initialRoute: string): Options {
    this.initialRoute = initialRoute;
    return this;
  }

  /**
   * Sets the Dart entrypoint arguments.
   * @param dartEntrypointArgs - Array of entrypoint arguments
   * @returns This Options instance for method chaining
   */
  setDartEntrypointArgs(dartEntrypointArgs: Array<string>): Options {
    this.dartEntrypointArgs = dartEntrypointArgs;
    return this;
  }

  /**
   * Sets whether to wait for restoration data.
   * @param waitForRestorationData - Whether to wait for restoration data
   * @returns This Options instance for method chaining
   */
  setWaitForRestorationData(waitForRestorationData: boolean): Options {
    this.waitForRestorationData = waitForRestorationData;
    return this;
  }

  /**
   * Sets the platform views controller.
   * @param platformViewsController - The PlatformViewsController to set
   * @returns This Options instance for method chaining
   */
  setPlatformViewsController(platformViewsController: PlatformViewsController): Options {
    this.platformViewsController = platformViewsController;
    return this;
  }
}