/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterEngineConfigurator.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import FlutterEngine from '../engine/FlutterEngine';

/**
 * Interface for configuring FlutterEngine instances.
 * Implementations can customize engine setup and cleanup.
 */
export default interface FlutterEngineConfigurator {
  /**
   * Configures a FlutterEngine instance.
   * @param flutterEngine - The FlutterEngine to configure
   */
  configureFlutterEngine: (flutterEngine: FlutterEngine) => void;
  
  /**
   * Cleans up a FlutterEngine instance.
   * @param flutterEngine - The FlutterEngine to clean up
   */
  cleanUpFlutterEngine: (flutterEngine: FlutterEngine) => void;
}