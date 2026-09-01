/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import FlutterApplicationInfo from './FlutterApplicationInfo';
import common from '@ohos.app.ability.common';

/**
 * Loader for Flutter application information.
 * This class provides a static method to load FlutterApplicationInfo from the application context.
 */
export default class ApplicationInfoLoader {
  /**
   * Loads FlutterApplicationInfo from the application context.
   * @param context - The application context
   * @returns A FlutterApplicationInfo instance with default or context-based values
   */
  static load(context: common.Context) {
    let applicationInfo =
      new FlutterApplicationInfo(null, null, null, null, null, context.bundleCodeDir + '/libs/arm64', true);
    return applicationInfo
  }
}