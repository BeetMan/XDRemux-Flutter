/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import Log from './Log';

const TAG: string = "PathUtils";

/**
 * Utility class for path operations in OpenHarmony.
 * Provides methods for getting application directories.
 */
export default class PathUtils {
  /**
   * Gets the files directory for the application.
   * @param context - The application context
   * @returns The files directory path.
   */
  static getFilesDir(context: common.Context): string {
    return context.filesDir;
  }

  /**
   * Gets the cache directory for the application.
   * @param context - The application context
   * @returns The cache directory path.
   */
  static getCacheDirectory(context: common.Context): string {
    return context.cacheDir;
  }

  /**
   * Gets or creates the Flutter data directory.
   * @param context - The application context
   * @returns The Flutter data directory path, or null if creation fails.
   */
  static getDataDirectory(context: common.Context): string | null {
    const name = "flutter";
    const flutterDir = context.filesDir + "/" + name;
    if (!fs.accessSync(flutterDir)) {
      try {
        fs.mkdirSync(flutterDir);
      } catch (err) {
        Log.e(TAG, "mkdirSync failed err:" + err);
        return null;
      }
    }
    return flutterDir;
  }
}