/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on PluginRegistry.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import { FlutterPlugin } from './FlutterPlugin';

/**
 * Registry for managing Flutter plugins.
 * This interface provides methods to add, remove, and query plugins attached to a FlutterEngine.
 */
export default interface PluginRegistry {
  /**
   * Attaches the given plugin to the FlutterEngine associated with this PluginRegistry.
   * @param plugin - The FlutterPlugin to attach
   */
  add(plugin: FlutterPlugin): void;

  /**
   * Attaches the given plugins to the FlutterEngine associated with this PluginRegistry.
   * @param plugins - The set of FlutterPlugins to attach
   */
  addList(plugins: Set<FlutterPlugin>): void;

  /**
   * Checks if a plugin of the given type is currently attached to the FlutterEngine
   * associated with this PluginRegistry.
   * @param pluginClassName - The class name of the plugin to check
   * @returns True if the plugin is attached, false otherwise
   */
  has(pluginClassName: string): boolean;

  /**
   * Gets the instance of a plugin that is currently attached to the FlutterEngine
   * associated with this PluginRegistry, which matches the given pluginClassName.
   *
   * If no matching plugin is found, null is returned.
   * @param pluginClassName - The class name of the plugin to get
   * @returns The FlutterPlugin instance, or null if not found
   */
  get(pluginClassName: string): FlutterPlugin;

  /**
   * Detaches the plugin of the given type from the FlutterEngine
   * associated with this PluginRegistry.
   *
   * If no such plugin exists, this method does nothing.
   * @param pluginClassName - The class name of the plugin to remove
   */
  remove(pluginClassName: string): void;

  /**
   * Detaches the plugins of the given types from the FlutterEngine
   * associated with this PluginRegistry.
   *
   * If no such plugins exist, this method does nothing.
   * @param pluginClassNames - The set of plugin class names to remove
   */
  removeList(pluginClassNames: Set<string>): void;

  /**
   * Detaches all plugins that are currently attached to the FlutterEngine
   * associated with this PluginRegistry.
   *
   * If no plugins are currently attached, this method does nothing.
   */
  removeAll(): void;
}