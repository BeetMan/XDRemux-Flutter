/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterEngineConnectionRegistry.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import PluginRegistry from './plugins/PluginRegistry';
import { FlutterAssets, FlutterPlugin, FlutterPluginBinding } from './plugins/FlutterPlugin';
import FlutterEngine from './FlutterEngine';
import AbilityAware from './plugins/ability/AbilityAware';
import UIAbility from '@ohos.app.ability.UIAbility';
import {
  AbilityPluginBinding,
  WindowFocusChangedListener,
  OnSaveStateListener,
  NewWantListener
} from './plugins/ability/AbilityPluginBinding';
import HashSet from '@ohos.util.HashSet';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import common from '@ohos.app.ability.common';
import FlutterLoader from './loader/FlutterLoader';
import Log from '../../util/Log';
import ToolUtils from '../../util/ToolUtils';
import AbilityControlSurface from './plugins/ability/AbilityControlSurface';
import ExclusiveAppComponent from '../ohos/ExclusiveAppComponent';
import FlutterEngineGroup from './FlutterEngineGroup';
import Any from '../../plugin/common/Any';
import SplitViewConfigPlugin from '../../plugin/splitview/SplitViewConfigPlugin';

const TAG = "FlutterEngineCxnRegistry";

/**
 * Registry for managing Flutter plugins and their connections to the engine and ability.
 * This class implements both PluginRegistry and AbilityControlSurface interfaces,
 * providing a unified way to manage plugin lifecycle and ability-related operations.
 */
export default class FlutterEngineConnectionRegistry implements PluginRegistry, AbilityControlSurface {
  private plugins = new Map<string, FlutterPlugin>();
  private defaultPlugin: FlutterPlugin = new EmptyPlugin();
  private flutterEngine: FlutterEngine;
  private pluginBinding: FlutterPluginBinding;
  private abilityAwarePlugins = new Map<string, AbilityAware>();
  private exclusiveAbility: ExclusiveAppComponent<UIAbility> | null = null;
  private abilityPluginBinding: FlutterEngineAbilityPluginBinding | null = null;

  /**
   * Constructs a new FlutterEngineConnectionRegistry instance.
   * @param appContext - The application context
   * @param flutterEngine - The FlutterEngine instance this registry is associated with
   * @param flutterLoader - The FlutterLoader instance for asset management
   */
  constructor(appContext: common.Context, flutterEngine: FlutterEngine, flutterLoader: FlutterLoader) {
    this.flutterEngine = flutterEngine;
    this.pluginBinding = new FlutterPluginBinding(appContext, flutterEngine, flutterEngine.getDartExecutor(),
      new DefaultFlutterAssets(flutterLoader), flutterEngine.getFlutterRenderer(),
      flutterEngine.getPlatformViewsController()?.getRegistry());
      this.add(new SplitViewConfigPlugin());
  }

  /**
   * Adds a plugin to this registry.
   * @param plugin - The FlutterPlugin instance to add
   */
  add(plugin: FlutterPlugin): void {
    try {
      if (this.has(plugin.getUniqueClassName())) {
        Log.w(
          TAG,
          "Attempted to register plugin ("
            + plugin
            + ") but it was "
            + "already registered with this FlutterEngine ("
            + this.flutterEngine
            + ").");
        return;
      }

      Log.w(TAG, "Adding plugin: " + plugin.getUniqueClassName());
      // Add the plugin to our generic set of plugins and notify the plugin
      // that is has been attached to an engine.
      this.plugins.set(plugin.getUniqueClassName(), plugin);
      plugin.onAttachedToEngine(this.pluginBinding);

      // For AbilityAware plugins, add the plugin to our set of AbilityAware
      // plugins, and if this engine is currently attached to an Ability,
      // notify the AbilityAware plugin that it is now attached to an Ability.
      if (ToolUtils.implementsInterface(plugin, "onAttachedToAbility")) {
        const abilityAware: Any = plugin;
        this.abilityAwarePlugins.set(plugin.getUniqueClassName(), abilityAware);
        if (this.isAttachedToAbility()) {
          abilityAware.onAttachedToAbility(this.abilityPluginBinding);
        }
      }
    } finally {

    }
  }

  /**
   * Adds multiple plugins to this registry.
   * @param plugins - Set of FlutterPlugin instances to add
   */
  addList(plugins: Set<FlutterPlugin>): void {
    plugins.forEach(plugin => this.add(plugin))
  }

  /**
   * Checks if a plugin with the given class name is registered.
   * @param pluginClassName - The class name of the plugin to check
   * @returns true if the plugin is registered, false otherwise
   */
  has(pluginClassName: string): boolean {
    return this.plugins.has(pluginClassName);
  }

  /**
   * Gets a plugin by its class name.
   * @param pluginClassName - The class name of the plugin to retrieve
   * @returns The FlutterPlugin instance, or a default empty plugin if not found
   */
  get(pluginClassName: string): FlutterPlugin {
    return this.plugins.get(pluginClassName) ?? this.defaultPlugin;
  }

  /**
   * Removes a plugin from this registry.
   * @param pluginClassName - The class name of the plugin to remove
   */
  remove(pluginClassName: string): void {
    const plugin = this.plugins.get(pluginClassName);
    if (plugin == null) {
      return;
    }
    if (ToolUtils.implementsInterface(plugin, "onAttachedToAbility")) {
      if (this.isAttachedToAbility()) {
        const abilityAware: Any = plugin;
        abilityAware.onDetachedFromAbility();
      }
      this.abilityAwarePlugins.delete(pluginClassName);
    }
    // Notify the plugin that is now detached from this engine. Then remove
    // it from our set of generic plugins.
    plugin.onDetachedFromEngine(this.pluginBinding);
    this.plugins.delete(pluginClassName)
  }

  /**
   * Removes multiple plugins from this registry.
   * @param pluginClassNames - Set of plugin class names to remove
   */
  removeList(pluginClassNames: Set<string>): void {
    pluginClassNames.forEach(plugin => this.remove(plugin))
  }

  /**
   * Removes all plugins from this registry.
   */
  removeAll(): void {
    this.removeList(new Set(this.plugins.keys()));
    this.plugins.clear();
  }

  private isAttachedToAbility(): boolean {
    return this.exclusiveAbility != null;
  }

  /**
   * Attaches this registry to an ability.
   * @param exclusiveAbility - The exclusive app component (UIAbility) to attach to
   */
  attachToAbility(exclusiveAbility: ExclusiveAppComponent<UIAbility>): void {
    if (this.exclusiveAbility != null) {
      this.exclusiveAbility.detachFromFlutterEngine();
    }
    // If we were already attached to an app component, detach from it.
    this.detachFromAppComponent();
    this.exclusiveAbility = exclusiveAbility;
    this.attachToAbilityInternal(exclusiveAbility.getAppComponent(),);
  }

  /**
   * Detaches this registry from the current ability.
   */
  detachFromAbility(): void {
    if (this.isAttachedToAbility()) {
      try {
        this.abilityAwarePlugins.forEach(abilityAware => abilityAware.onDetachedFromAbility())
      } catch (e) {
        Log.e(TAG, "abilityAwarePlugins DetachedFromAbility failed, msg:" + e);
      }
      this.detachFromAbilityInternal();
    } else {
      Log.e(TAG, "Attempted to detach plugins from an Ability when no Ability was attached.");
    }
  }

  /**
   * Handles a new Want event from the ability.
   * @param want - The Want object containing the intent
   * @param launchParams - The launch parameters
   */
  onNewWant(want: Want, launchParams: AbilityConstant.LaunchParam): void {
    this.abilityPluginBinding?.onNewWant(want, launchParams);
  }

  /**
   * Handles window focus change events from the ability.
   * @param hasFocus - Whether the window has focus
   */
  onWindowFocusChanged(hasFocus: boolean): void {
    this.abilityPluginBinding?.onWindowFocusChanged(hasFocus);
  }

  /**
   * Handles save state requests from the ability.
   * @param reason - The reason for saving state
   * @param wantParam - Parameters to save
   * @returns The result of the save state operation
   */
  onSaveState(reason: AbilityConstant.StateType, wantParam: Record<string, Object>): AbilityConstant.OnSaveResult {
    return this.abilityPluginBinding?.onSaveState(reason, wantParam) ?? AbilityConstant.OnSaveResult.ALL_REJECT;
  }

  private detachFromAppComponent(): void {
    if (this.isAttachedToAbility()) {
      this.detachFromAbility();
    }
  }

  private attachToAbilityInternal(ability: UIAbility): void {
    this.abilityPluginBinding = new FlutterEngineAbilityPluginBinding(ability);
    // Notify all AbilityAware plugins that they are now attached to a new Ability.
    this.abilityAwarePlugins.forEach(abilityAware => abilityAware.onAttachedToAbility(this.abilityPluginBinding!));
  }

  private detachFromAbilityInternal(): void {
    this.exclusiveAbility = null;
    this.abilityPluginBinding = null;
  }

  /**
   * Destroys this registry and removes all plugins.
   */
  destroy(): void {
    this.detachFromAppComponent();
    // Remove all registered plugins.
    this.removeAll();
  }
}

/**
 * Implementation of AbilityPluginBinding for FlutterEngine.
 * Manages ability-related listeners and events for plugins.
 */
class FlutterEngineAbilityPluginBinding implements AbilityPluginBinding {
  private ability: UIAbility;
  private onNewWantListeners = new HashSet<NewWantListener>();
  private onWindowFocusChangedListeners = new HashSet<WindowFocusChangedListener>();
  private onSaveStateListeners = new HashSet<OnSaveStateListener>();

  /**
   * Constructs a new FlutterEngineAbilityPluginBinding instance.
   * @param ability - The UIAbility instance this binding is associated with
   */
  constructor(ability: UIAbility) {
    this.ability = ability;

  }

  /**
   * Gets the UIAbility instance.
   * @returns The UIAbility instance
   */
  getAbility(): UIAbility {
    return this.ability;
  }

  /**
   * Adds a listener for new Want events.
   * @param listener - The NewWantListener to add
   */
  addOnNewWantListener(listener: NewWantListener): void {
    this.onNewWantListeners.add(listener)
  }

  /**
   * Removes a listener for new Want events.
   * @param listener - The NewWantListener to remove
   */
  removeOnNewWantListener(listener: NewWantListener): void {
    this.onNewWantListeners.remove(listener)
  }

  /**
   * Adds a listener for window focus change events.
   * @param listener - The WindowFocusChangedListener to add
   */
  addOnWindowFocusChangedListener(listener: WindowFocusChangedListener): void {
    this.onWindowFocusChangedListeners.add(listener)
  }

  /**
   * Removes a listener for window focus change events.
   * @param listener - The WindowFocusChangedListener to remove
   */
  removeOnWindowFocusChangedListener(listener: WindowFocusChangedListener): void {
    this.onWindowFocusChangedListeners.remove(listener)
  }

  /**
   * Adds a listener for save state events.
   * @param listener - The OnSaveStateListener to add
   */
  addOnSaveStateListener(listener: OnSaveStateListener) {
    this.onSaveStateListeners.add(listener)
  }

  /**
   * Removes a listener for save state events.
   * @param listener - The OnSaveStateListener to remove
   */
  removeOnSaveStateListener(listener: OnSaveStateListener) {
    this.onSaveStateListeners.remove(listener)
  }

  /**
   * Notifies all registered listeners of a new Want event.
   * @param want - The Want object
   * @param launchParams - The launch parameters
   */
  onNewWant(want: Want, launchParams: AbilityConstant.LaunchParam): void {
    this.onNewWantListeners.forEach((listener, key) => {
      listener?.onNewWant(want, launchParams)
    });
  }

  /**
   * Notifies all registered listeners of a window focus change.
   * @param hasFocus - Whether the window has focus
   */
  onWindowFocusChanged(hasFocus: boolean): void {
    this.onWindowFocusChangedListeners.forEach((listener, key) => {
      listener?.onWindowFocusChanged(hasFocus)
    });
  }

  /**
   * Notifies all registered listeners of a save state request.
   * @param reason - The reason for saving state
   * @param wantParam - Parameters to save
   * @returns The result of the save state operation
   */
  onSaveState(reason: AbilityConstant.StateType, wantParam: Record<string, Object>): AbilityConstant.OnSaveResult {
    this.onSaveStateListeners.forEach((listener, key) => {
      listener?.onSaveState(reason, wantParam)
    });
    return AbilityConstant.OnSaveResult.ALL_AGREE;
  }
}

/**
 * Default implementation of FlutterAssets using FlutterLoader.
 */
class DefaultFlutterAssets implements FlutterAssets {
  private flutterLoader: FlutterLoader;

  /**
   * Constructs a new DefaultFlutterAssets instance.
   * @param flutterLoader - The FlutterLoader instance for asset lookup
   */
  constructor(flutterLoader: FlutterLoader) {
    this.flutterLoader = flutterLoader;
  }

  /**
   * Gets the file path for an asset by name.
   * @param assetFileName - The name of the asset file
   * @param packageName - Optional package name
   * @returns The file path for the asset
   */
  getAssetFilePathByName(assetFileName: string, packageName?: string): string {
    return this.flutterLoader.getLookupKeyForAsset(assetFileName, packageName);
  }

  /**
   * Gets the file path for an asset by subpath.
   * @param assetSubpath - The subpath of the asset
   * @param packageName - Optional package name
   * @returns The file path for the asset
   */
  getAssetFilePathBySubpath(assetSubpath: string, packageName?: string) {
    return this.flutterLoader.getLookupKeyForAsset(assetSubpath, packageName);
  }
}

/**
 * Empty plugin implementation used as a default when a plugin is not found.
 */
class EmptyPlugin implements FlutterPlugin {
  /**
   * Gets the unique class name of this plugin.
   * @returns An empty string
   */
  getUniqueClassName(): string {
    return '';
  }

  /**
   * Called when this plugin is attached to an engine.
   * @param binding - The FlutterPluginBinding instance
   */
  onAttachedToEngine(binding: FlutterPluginBinding) {

  }

  /**
   * Called when this plugin is detached from an engine.
   * @param binding - The FlutterPluginBinding instance
   */
  onDetachedFromEngine(binding: FlutterPluginBinding) {

  }
}