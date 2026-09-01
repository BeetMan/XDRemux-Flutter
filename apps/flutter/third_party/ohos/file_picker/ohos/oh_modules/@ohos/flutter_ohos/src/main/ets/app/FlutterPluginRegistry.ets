/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
*/
import { FlutterView } from '../view/FlutterView';
import common from '@ohos.app.ability.common';
import PlatformViewController from '../plugin/platform/PlatformViewsController'

/**
 * Registry for managing Flutter plugins and platform views.
 * This class handles the lifecycle of FlutterView, Context, and PlatformViewController,
 * providing methods to attach, detach, and manage resources during engine restarts.
 */
export default class FlutterPluginRegistry {
  private mPlatformViewsController: PlatformViewController;
  private mFlutterView: FlutterView | null = null;
  private mContext: common.Context | null = null;

  /**
   * Constructs a new FlutterPluginRegistry instance.
   * Initializes the platform views controller and sets FlutterView and Context to null.
   */
  constructor() {
    this.mPlatformViewsController = new PlatformViewController();
    this.mFlutterView = null;
    this.mContext = null;
  }

  /**
   * Attaches a FlutterView and Context to this registry.
   * @param flutterView - The FlutterView instance to attach
   * @param context - The application context to attach
   */
  attach(flutterView: FlutterView, context: common.Context): void {
    this.mFlutterView = flutterView;
    this.mContext = context;
  }

  /**
   * Detaches the FlutterView and Context from this registry.
   * Cleans up the platform views controller and resets all references.
   */
  detach(): void {
    this.mPlatformViewsController.detach();
    this.mPlatformViewsController.onDetachedFromNapi();
    this.mFlutterView = null;
    this.mContext = null;
  }

  /**
   * Destroys this registry instance.
   * Notifies the platform views controller that it has been detached from NAPI.
   */
  destroy(): void {
    this.mPlatformViewsController.onDetachedFromNapi();
  }

  /**
   * Called before the Flutter engine restarts.
   * Notifies the platform views controller to prepare for engine restart.
   */
  onPreEngineRestart(): void {
    this.mPlatformViewsController.onPreEngineRestart();
  }
}