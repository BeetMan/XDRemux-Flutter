/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import BasicMessageChannel from '../../../plugin/common/BasicMessageChannel';
import StringCodec from '../../../plugin/common/StringCodec';
import Log from '../../../util/Log';
import DartExecutor from '../dart/DartExecutor';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

const TAG: string = "SplitViewConfigSystemChannel";
const CHANNEL_NAME: string = "flutter/split_view_config_system";
const CONFIG_FILE_NAME: string = "split_config.json";

export default class SplitViewConfigSystemChannel {
  private channel: BasicMessageChannel<string>;
  private context: common.Context | null = null;
  private cachedConfigStr: string = '';

  constructor(dartExecutor: DartExecutor, context: common.Context) {
    this.channel = new BasicMessageChannel<string>(dartExecutor, CHANNEL_NAME, StringCodec.INSTANCE);
    this.context = context;
  }

  sendConfigToFlutter(): void {
    if (this.context === null) {
      Log.e(TAG, 'Context is null, cannot send config');
      return;
    }
    let configStr = this.cachedConfigStr;
    if (configStr === null || configStr === '') {
      configStr = this.readConfigFromRawfile() ?? '';
    }
    if (configStr === '') {
      Log.w(TAG, 'Config content is empty, skip sending');
      return;
    }
    const iconBase64 = this.getAppIconBase64();
    if (iconBase64.length > 0) {
      try {
        const config = JSON.parse(configStr) as Record<string, Object>;
        config['placeholderIconData'] = iconBase64;
        configStr = JSON.stringify(config);
      } catch (e) {
        Log.e(TAG, `Error injecting placeholderIconData: ${e}`);
      }
    }
    this.channel.resizeChannelBuffer(1);
    Log.i(TAG, 'Sending split view config to Dart via SystemChannel');
    this.channel.send(configStr);
  }

  private readConfigFromRawfile(): string | null {
    if (this.context === null) {
      return null;
    }
    try {
      const fileData = this.context.resourceManager.getRawFileContentSync(CONFIG_FILE_NAME);
      const decoder = util.TextDecoder.create('utf-8');
      const configStr = decoder.decodeToString(fileData);
      this.cachedConfigStr = configStr;
      return configStr;
    } catch (e) {
      Log.e(TAG, `Error reading rawfile: ${e}`);
      return null;
    }
  }

  private getAppIconBase64(): string {
    if (this.context === null) {
      return '';
    }
    try {
      const iconData: Uint8Array = this.context.resourceManager.getMediaByNameSync('app_icon');
      const base64Helper = new util.Base64Helper();
      return base64Helper.encodeToStringSync(iconData);
    } catch (e) {
      Log.e(TAG, `Error getting app icon: ${e}`);
      return '';
    }
  }
}
