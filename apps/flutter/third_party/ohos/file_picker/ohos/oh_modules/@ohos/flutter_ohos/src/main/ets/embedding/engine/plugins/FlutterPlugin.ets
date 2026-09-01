/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterPlugin.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import common from '@ohos.app.ability.common';
import { BinaryMessenger } from '../../../plugin/common/BinaryMessenger';
import PlatformViewFactory from '../../../plugin/platform/PlatformViewFactory';
import PlatformViewRegistry from '../../../plugin/platform/PlatformViewRegistry';
import { TextureRegistry } from '../../../view/TextureRegistry';
import FlutterEngine from '../FlutterEngine';

/**
 * Interface to be implemented by all Flutter plugins.
 *
 * A Flutter plugin allows Flutter developers to interact with a host platform, e.g., OpenHarmony,
 * via Dart code. It includes platform code, as well as Dart code. A plugin author is responsible
 * for setting up an appropriate MethodChannel to communicate between platform code and Dart code.
 *
 * A Flutter plugin has a lifecycle. First, a developer must add a FlutterPlugin to an instance
 * of FlutterEngine. To do this, obtain a PluginRegistry with FlutterEngine.getPlugins(), then call
 * PluginRegistry.add(FlutterPlugin), passing the instance of the Flutter plugin. During the call
 * to PluginRegistry.add(FlutterPlugin), the FlutterEngine will invoke onAttachedToEngine(FlutterPluginBinding)
 * on the given FlutterPlugin. If the FlutterPlugin is removed from the FlutterEngine via
 * PluginRegistry.remove(pluginClassName), or if the FlutterEngine is destroyed, the FlutterEngine will invoke
 * onDetachedFromEngine(FlutterPluginBinding) on the given FlutterPlugin.
 *
 * Once a FlutterPlugin is attached to a FlutterEngine, the plugin's code is permitted to access
 * and invoke methods on resources within the FlutterPlugin.FlutterPluginBinding that the FlutterEngine
 * gave to the FlutterPlugin in onAttachedToEngine(FlutterPluginBinding). This includes, for example,
 * the application Context for the running app.
 *
 * The FlutterPlugin.FlutterPluginBinding provided in onAttachedToEngine(FlutterPluginBinding) is
 * no longer valid after the execution of onDetachedFromEngine(FlutterPluginBinding). Do not access
 * any properties of the FlutterPlugin.FlutterPluginBinding after the completion of
 * onDetachedFromEngine(FlutterPluginBinding).
 *
 * To register a MethodChannel, obtain a BinaryMessenger via the FlutterPlugin.FlutterPluginBinding.
 *
 * An OpenHarmony Flutter plugin may require access to app resources or other artifacts that can only
 * be retrieved through a Context. Developers can access the application context via
 * FlutterPlugin.FlutterPluginBinding.getApplicationContext().
 *
 * Some plugins may require access to the UIAbility that is displaying a Flutter experience, or
 * may need to react to UIAbility lifecycle events, e.g., onCreate(), onWindowStageCreate(), onForeground(),
 * onBackground(), onWindowStageDestroy(), onDestroy(). Any such plugin should implement AbilityAware
 * in addition to implementing FlutterPlugin. AbilityAware provides callback hooks that expose access
 * to an associated UIAbility and its Lifecycle. All plugins must respect the possibility that a Flutter
 * experience may never be associated with a UIAbility, e.g., when Flutter is used for background
 * behavior. Additionally, all plugins must respect that UIAbilities may come and go over time, thus
 * requiring plugins to cleanup resources and recreate those resources as the UIAbility comes and goes.
 */
export interface FlutterPlugin {
  /**
   * Gets the unique class name of this plugin.
   * Similar to Android's Class<? extends FlutterPlugin>, but in TypeScript this must be user-defined.
   * @returns The unique class name of this plugin
   */
  getUniqueClassName(): string

  /**
   * This FlutterPlugin has been associated with a FlutterEngine instance.
   *
   * Relevant resources that this FlutterPlugin may need are provided via the binding.
   * The binding may be cached and referenced until onDetachedFromEngine is invoked and returns.
   * @param binding - The FlutterPluginBinding providing access to engine resources
   */
  onAttachedToEngine(binding: FlutterPluginBinding): void;

  /**
   * This FlutterPlugin has been removed from a FlutterEngine instance.
   *
   * The binding passed to this method is the same instance that was passed in
   * onAttachedToEngine. It is provided again in this method as a convenience.
   * The binding may be referenced during the execution of this method, but it
   * must not be cached or referenced after this method returns.
   *
   * FlutterPlugins should release all resources in this method.
   * @param binding - The FlutterPluginBinding that was provided in onAttachedToEngine
   */
  onDetachedFromEngine(binding: FlutterPluginBinding): void;
}

/**
 * Binding that provides Flutter plugins with access to Flutter engine resources.
 * This class holds references to the engine, messenger, assets, and registries that plugins may need.
 */
export class FlutterPluginBinding {
  private applicationContext: common.Context;
  private flutterEngine: FlutterEngine;
  private binaryMessenger: BinaryMessenger;
  private flutterAssets: FlutterAssets;
  private textureRegistry: TextureRegistry;
  private platformViewRegistry: PlatformViewRegistry;

  /**
   * Constructs a new FlutterPluginBinding instance.
   * @param applicationContext - The application context
   * @param flutterEngine - The FlutterEngine instance
   * @param binaryMessenger - The BinaryMessenger for platform communication
   * @param flutterAssets - The FlutterAssets for accessing Flutter assets
   * @param textureRegistry - The TextureRegistry for managing textures
   * @param platformViewRegistry - Optional PlatformViewRegistry, will be created if not provided
   */
  constructor(applicationContext: common.Context, flutterEngine: FlutterEngine, binaryMessenger: BinaryMessenger,
    flutterAssets: FlutterAssets, textureRegistry: TextureRegistry, platformViewRegistry?: PlatformViewRegistry) {
    this.applicationContext = applicationContext;
    this.flutterEngine = flutterEngine;
    this.binaryMessenger = binaryMessenger;
    this.flutterAssets = flutterAssets;
    this.textureRegistry = textureRegistry;
    this.platformViewRegistry = platformViewRegistry ?? new EmptyPlatformViewRegistry();
  }

  /**
   * Gets the application context.
   * @returns The application context
   */
  getApplicationContext(): common.Context {
    return this.applicationContext;
  }

  /**
   * Gets the FlutterEngine instance.
   * @returns The FlutterEngine instance
   */
  getFlutterEngine(): FlutterEngine {
    return this.flutterEngine;
  }

  /**
   * Gets the BinaryMessenger for platform communication.
   * @returns The BinaryMessenger instance
   */
  getBinaryMessenger(): BinaryMessenger {
    return this.binaryMessenger;
  }

  /**
   * Gets the FlutterAssets for accessing Flutter assets.
   * @returns The FlutterAssets instance
   */
  getFlutterAssets(): FlutterAssets {
    return this.flutterAssets;
  }

  /**
   * Gets the TextureRegistry for managing textures.
   * @returns The TextureRegistry instance
   */
  getTextureRegistry(): TextureRegistry {
    return this.textureRegistry;
  }

  /**
   * Gets the PlatformViewRegistry for managing platform views.
   * @returns The PlatformViewRegistry instance
   */
  public getPlatformViewRegistry(): PlatformViewRegistry {
    return this.platformViewRegistry;
  }
}

/** Provides Flutter plugins with access to Flutter asset information. */
export interface FlutterAssets {
  /**
   * Returns the relative file path to the Flutter asset with the given name, including the file's
   * extension, e.g., "myImage.jpg".
   *
   * The returned file path is relative to the OpenHarmony app's standard assets directory.
   * Therefore, the returned path is appropriate to pass to OpenHarmony's ResourceManager, but
   * the path is not appropriate to load as an absolute path.
   * @param assetFileName - The name of the asset file
   * @returns The relative file path to the asset
   */
  getAssetFilePathByName(assetFileName: string): string;

  /**
   * Same as getAssetFilePathByName but with added support for an explicit bundleName.
   * @param assetFileName - The name of the asset file
   * @param bundleName - The bundle name
   * @returns The relative file path to the asset
   */
  getAssetFilePathByName(assetFileName: string, bundleName: string): string;

  /**
   * Returns the relative file path to the Flutter asset with the given subpath, including the
   * file's extension, e.g., "/dir1/dir2/myImage.jpg".
   *
   * The returned file path is relative to the OpenHarmony app's standard assets directory.
   * Therefore, the returned path is appropriate to pass to OpenHarmony's ResourceManager, but
   * the path is not appropriate to load as an absolute path.
   * @param assetSubpath - The subpath of the asset
   * @returns The relative file path to the asset
   */
  getAssetFilePathBySubpath(assetSubpath: string): string;

  /**
   * Same as getAssetFilePathBySubpath but with added support for an explicit bundleName.
   * @param assetSubpath - The subpath of the asset
   * @param bundleName - The bundle name
   * @returns The relative file path to the asset
   */
  getAssetFilePathBySubpath(assetSubpath: string, bundleName: string): string;
}

/**
 * Empty implementation of PlatformViewRegistry that does nothing.
 */
class EmptyPlatformViewRegistry implements PlatformViewRegistry {
  /**
   * Attempts to register a view factory, but always returns false.
   * @param viewTypeId - The view type identifier
   * @param factory - The PlatformViewFactory to register
   * @returns Always returns false
   */
  registerViewFactory(viewTypeId: string, factory: PlatformViewFactory): boolean {
    return false;
  }
}