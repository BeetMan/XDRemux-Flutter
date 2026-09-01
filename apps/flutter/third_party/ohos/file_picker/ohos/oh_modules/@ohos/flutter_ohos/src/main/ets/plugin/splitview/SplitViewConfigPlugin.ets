/*
 * Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { FlutterPlugin, FlutterPluginBinding } from '../../embedding/engine/plugins/FlutterPlugin';
import MethodChannel, { MethodCallHandler, MethodResult } from '../common/MethodChannel';
import MethodCall from '../common/MethodCall';
import Log from '../../util/Log';
import { common } from '@kit.AbilityKit';
import { JSON, util } from '@kit.ArkTS';

const TAG = 'SplitViewConfigPlugin';
const CHANNEL_NAME = 'flutter/split_view_config';
const CONFIG_FILE_NAME = 'split_config.json';

/**
 * Split view config plugin for loading split view configuration from platform.
 *
 * This plugin handles the 'getSplitViewConfig' method call and reads
 * the configuration from the app's rawfile (split_config.json).
 * 
 * Note: This plugin is automatically registered by FlutterEngineConnectionRegistry.ets.
 */
class SplitViewConfigPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.Context | null = null;

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    Log.i(TAG, 'SplitViewConfigPlugin attached to engine');
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    Log.i(TAG, 'SplitViewConfigPlugin detached from engine');
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {

    if (call.method === 'getSplitViewConfig') {
      const configContent = this.readConfigFromRawfile();
      if (configContent === null || configContent === '') {
        Log.w(TAG, 'Failed to read config file, returning empty config');
        result.success({});
        return;
      }
      const config = this.parseConfigJson(configContent);
      // Add app icon as base64 encoded data
      const iconBase64 = this.getAppIconBase64();
      if (iconBase64 !== null && iconBase64.length > 0) {
        Log.i(TAG, 'Adding placeholderIconData to config');
        config['placeholderIconData'] = iconBase64;
      } else {
        Log.w(TAG, 'App icon data is empty, not adding to config');
      }
      result.success(config);
    } else {
      result.notImplemented();
    }
  }

  private readConfigFromRawfile(): string | null {
    if (this.context === null) {
      Log.e(TAG, 'Context is null, cannot read config file');
      return null;
    }
    try {
      const fileData = this.context.resourceManager.getRawFileContentSync(CONFIG_FILE_NAME);
      const decoder = util.TextDecoder.create('utf-8');
      const configStr = decoder.decodeToString(fileData);
      Log.i(TAG, `SplitView Config file content: ${configStr}`);
      return configStr;
    } catch (e) {
      Log.e(TAG, `Error reading rawfile: ${e}`);
      return null;
    }
  }

  private parseConfigJson(jsonStr: string): Record<string, Object> {
    try {
      const config = JSON.parse(jsonStr) as Record<string, Object>;

      // Validate splitOptions exists and is a valid object
      if (!JSON.has(config, 'splitOptions')) {
        Log.w(TAG, 'Config missing splitOptions key, using empty config');
        return {};
      }

      const splitOptions = config['splitOptions'];
      if (typeof splitOptions !== 'object' || Array.isArray(splitOptions)) {
        Log.w(TAG, 'splitOptions is not an object, using empty config');
        return {};
      }

      return config;
    } catch (e) {
      Log.e(TAG, `Error parsing JSON: ${e}`);
      return {};
    }
  }

  getAppIconBase64(): string {
    if (this.context === null) {
      Log.e(TAG, 'Context is null, cannot get app icon');
      return '';
    }
    try {
      // Get app icon from media resource (resources/base/media/app_icon.png)
      // Use getMediaByNameSync - resource name without extension
      const iconData: Uint8Array = this.context.resourceManager.getMediaByNameSync('app_icon');
      // Convert to base64 using util.Base64Helper
      const base64Helper = new util.Base64Helper();
      const encoded: string = base64Helper.encodeToStringSync(iconData);
      Log.i(TAG, `App icon base64 encoded, length: ${encoded.length}`);
      return encoded;
    } catch (e) {
      Log.e(TAG, `Error getting app icon: ${e}`);
      return '';
    }
  }

  getUniqueClassName(): string {
    return 'SplitViewConfigPlugin';
  }
}

export default SplitViewConfigPlugin;
