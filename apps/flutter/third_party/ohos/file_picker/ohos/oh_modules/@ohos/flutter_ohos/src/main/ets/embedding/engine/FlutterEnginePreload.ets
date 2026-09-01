/*
* Copyright (c) 2025 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import FlutterEngine, { EngineLifecycleListener } from "./FlutterEngine"
import common from '@ohos.app.ability.common'
import display from '@ohos.display';
import FlutterLoader from './loader/FlutterLoader'
import Log from '../../util/Log';
import FlutterManager from '../ohos/FlutterManager';
import FlutterInjector from '../../FlutterInjector'
import FlutterEngineCache from './FlutterEngineCache';
import FlutterEngineGroupCache from './FlutterEngineGroupCache';
import FlutterAbilityLaunchConfigs from '../ohos/FlutterAbilityLaunchConfigs';
import JSONMethodCodec from '../../plugin/common/JSONMethodCodec';
import MethodCall from '../../plugin/common/MethodCall';
import FlutterNapi from './FlutterNapi';
import { ViewportMetrics } from '../../view/FlutterView';

const TAG = "FlutterEnginePreload"

/**
 * Utility class for preloading Flutter engines.
 * This class provides static methods to preload and prepare Flutter engines
 * before they are actually displayed, improving startup performance.
 */
export default class FlutterEnginePreload {
  /**
   * Preloads a Flutter engine with the specified parameters.
   * @param context - The application context
   * @param params - Parameters for engine preloading, including entrypoint, route, etc.
   * @param nextViewId - Optional view ID for the next Flutter view
   */
  static async preloadEngine(context: common.Context, params: Record<string, Object> = {},
    nextViewId: string | null = null) {
    let loader: FlutterLoader = FlutterInjector.getInstance().getFlutterLoader();
    let dartArgs = new Array<string>();
    if (params[FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT_ARGS]) {
      dartArgs = params[FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT_ARGS] as Array<string>;
    }

    if (!loader.initialized) {
      loader.startInitialization(context);
      loader.ensureInitializationComplete(dartArgs);
    }

    let flutterNapi: FlutterNapi | null =
      FlutterEnginePreload.preLoadFlutterNapi(context, loader.findAppBundlePath(), params)
    let viewportMetrics: ViewportMetrics = new ViewportMetrics();
    if (params[FlutterAbilityLaunchConfigs.PRELOAD_VIEWPORT_METRICS_KEY]) {
      viewportMetrics = params[FlutterAbilityLaunchConfigs.PRELOAD_VIEWPORT_METRICS_KEY] as ViewportMetrics;
    } else {
      let display_info: display.Display = display.getDefaultDisplaySync();
      viewportMetrics.physicalWidth = display_info.width;
      viewportMetrics.physicalHeight = display_info.height;
      viewportMetrics.devicePixelRatio = display_info.densityPixels;
      viewportMetrics.physicalTouchSlop = 1.0 * display_info.densityPixels;
    }
    if (flutterNapi) {
      if (!nextViewId) {
        nextViewId = FlutterManager.getInstance().getNextFlutterViewId();
      }
      flutterNapi.setPreloading();
      flutterNapi.xComponentPreDraw(nextViewId, viewportMetrics.physicalWidth, viewportMetrics.physicalHeight);
      flutterNapi.setViewportMetrics(viewportMetrics.devicePixelRatio,
        viewportMetrics.physicalWidth,
        viewportMetrics.physicalHeight,
        viewportMetrics.physicalViewPaddingTop,
        viewportMetrics.physicalViewPaddingRight,
        viewportMetrics.physicalViewPaddingBottom,
        viewportMetrics.physicalViewPaddingLeft,
        viewportMetrics.physicalViewInsetTop,
        viewportMetrics.physicalViewInsetRight,
        viewportMetrics.physicalViewInsetBottom,
        viewportMetrics.physicalViewInsetLeft,
        viewportMetrics.systemGestureInsetTop,
        viewportMetrics.systemGestureInsetRight,
        viewportMetrics.systemGestureInsetBottom,
        viewportMetrics.systemGestureInsetLeft,
        viewportMetrics.physicalTouchSlop,
        new Array(0),
        new Array(0),
        new Array(0)
      );
    }
  }

  /**
   * Prepares an existing engine for drawing by setting up viewport metrics and pre-drawing.
   * @param engine - The FlutterEngine instance to prepare
   * @param params - Parameters for engine preparation, including viewport metrics
   * @param nextViewId - Optional view ID for the next Flutter view
   */
  static predrawEngine(engine: FlutterEngine, params: Record<string, Object> = {}, nextViewId: string | null = null) {
    if (!engine) {
      return;
    }
    let flutterNapi = engine.getFlutterNapi();
    if (!flutterNapi.isAttached()) {
      flutterNapi.attachToNative();
    }
    if (!nextViewId) {
      nextViewId = FlutterManager.getInstance().getNextFlutterViewId();
    }
    let viewportMetrics: ViewportMetrics = new ViewportMetrics();
    if (params[FlutterAbilityLaunchConfigs.PRELOAD_VIEWPORT_METRICS_KEY]) {
      viewportMetrics = params[FlutterAbilityLaunchConfigs.PRELOAD_VIEWPORT_METRICS_KEY] as ViewportMetrics;
    } else {
      let display_info: display.Display = display.getDefaultDisplaySync();
      viewportMetrics.physicalWidth = display_info.width;
      viewportMetrics.physicalHeight = display_info.height;
      viewportMetrics.devicePixelRatio = display_info.densityPixels;
      viewportMetrics.physicalTouchSlop = 1.0 * display_info.densityPixels;
    }
    flutterNapi.setPreloading();
    flutterNapi.xComponentPreDraw(nextViewId, viewportMetrics.physicalWidth, viewportMetrics.physicalHeight);
    flutterNapi.setViewportMetrics(viewportMetrics.devicePixelRatio,
      viewportMetrics.physicalWidth,
      viewportMetrics.physicalHeight,
      viewportMetrics.physicalViewPaddingTop,
      viewportMetrics.physicalViewPaddingRight,
      viewportMetrics.physicalViewPaddingBottom,
      viewportMetrics.physicalViewPaddingLeft,
      viewportMetrics.physicalViewInsetTop,
      viewportMetrics.physicalViewInsetRight,
      viewportMetrics.physicalViewInsetBottom,
      viewportMetrics.physicalViewInsetLeft,
      viewportMetrics.systemGestureInsetTop,
      viewportMetrics.systemGestureInsetRight,
      viewportMetrics.systemGestureInsetBottom,
      viewportMetrics.systemGestureInsetLeft,
      viewportMetrics.physicalTouchSlop,
      new Array(0),
      new Array(0),
      new Array(0)
    );
  }

  /**
   * Preloads a FlutterNapi instance with the specified configuration.
   * @param context - The application context
   * @param bundlePath - Path to the Flutter bundle
   * @param params - Parameters for NAPI preloading, including cached engine ID, entrypoint, etc.
   * @returns The preloaded FlutterNapi instance, or null if preloading fails
   */
  static preLoadFlutterNapi(context: common.Context, bundlePath: string,
    params: Record<string, Object> = {}): FlutterNapi | null {

    let cachedEngineId = params[FlutterAbilityLaunchConfigs.EXTRA_CACHED_ENGINE_ID] as string;
    let cachedEngineGroupId = params[FlutterAbilityLaunchConfigs.EXTRA_CACHED_ENGINE_GROUP_ID] as string;

    let dartEntrypoint = FlutterAbilityLaunchConfigs.DEFAULT_DART_ENTRYPOINT;
    if (params[FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT]) {
      dartEntrypoint = params[FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT] as string;
    }

    let dartEntrypointLibraryUri = "";
    if (params[FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT_LIBRARY_URI]) {
      dartEntrypointLibraryUri = params[FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT_LIBRARY_URI] as string;
    }

    let initialRoute = "";
    if (params[FlutterAbilityLaunchConfigs.EXTRA_INITIAL_ROUTE]) {
      initialRoute = params[FlutterAbilityLaunchConfigs.EXTRA_INITIAL_ROUTE] as string
    }

    let dartArgs = new Array<string>();
    if (params[FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT_ARGS]) {
      dartArgs = params[FlutterAbilityLaunchConfigs.EXTRA_DART_ENTRYPOINT_ARGS] as Array<string>;
    }

    Log.d(TAG, "cachedEngineId=" + cachedEngineId);
    let flutterNapi: FlutterNapi | null = null;
    if (cachedEngineId && cachedEngineId.length > 0) {
      let engine = FlutterEngineCache.getInstance().get(cachedEngineId);
      if (engine) {
        flutterNapi = engine.getFlutterNapi();
      }
    }
    if (cachedEngineGroupId && cachedEngineGroupId.length > 0) {
      let flutterEngineGroup = FlutterEngineGroupCache.instance.get(cachedEngineGroupId);
      if (flutterEngineGroup) {
        let defaultEngine = flutterEngineGroup.getDefaultEngine();
        if (defaultEngine) {
          let oldFlutterNapi = defaultEngine.getFlutterNapi();
          return oldFlutterNapi.preSpawn(dartEntrypoint, dartEntrypointLibraryUri, initialRoute, dartArgs);
        }
      }
    }

    if (!flutterNapi) {
      flutterNapi = FlutterInjector.getInstance().getPreloadFlutterNapi();
    }
    if (flutterNapi) {
      if (!flutterNapi.isAttached()) {
        flutterNapi.attachToNative();
      }
      Log.d(TAG, "setInitialRoute: " + initialRoute);
      let message = JSONMethodCodec.INSTANCE.encodeMethodCall(new MethodCall("setInitialRoute", initialRoute));
      flutterNapi.dispatchPlatformMessage("flutter/navigation", message, message.byteLength, 0);

      flutterNapi.runBundleAndSnapshotFromLibrary(
        bundlePath,
        dartEntrypoint,
        dartEntrypointLibraryUri,
        context.resourceManager,
        dartArgs);
    }
    return flutterNapi;
  }
}