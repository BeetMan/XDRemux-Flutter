/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterEngineProvider.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import FlutterEngine from '../engine/FlutterEngine';
import common from '@ohos.app.ability.common';

/**
 * Interface for providing FlutterEngine instances.
 * Implementations of this interface can provide custom FlutterEngine instances.
 */
export default interface FlutterEngineProvider {
  /**
   * Provides a FlutterEngine instance for the given context.
   * @param context - The application context
   * @returns A FlutterEngine instance, or null if no engine should be provided
   */
  provideFlutterEngine(context: common.Context): FlutterEngine | null;
}