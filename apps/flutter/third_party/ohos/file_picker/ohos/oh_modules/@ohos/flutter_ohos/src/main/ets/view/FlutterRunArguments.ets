/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterRunArguments.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

/**
 * A class containing arguments for entering a FlutterNativeView's isolate for the first time.
 * Contains the bundle path, entrypoint, and library path.
 */
export default class FlutterRunArguments {
  /** The path to the Flutter bundle. */
  public bundlePath: string;
  /** The entrypoint function name. */
  public entrypoint: string;
  /** The path to the Dart library. */
  public libraryPath: string;

  /**
   * Constructs a new FlutterRunArguments instance.
   * @param bundlePath - The path to the Flutter bundle
   * @param entrypoint - The entrypoint function name
   * @param libraryPath - The path to the Dart library
   */
  constructor(bundlePath: string, entrypoint: string, libraryPath: string) {
    this.bundlePath = bundlePath;
    this.entrypoint = entrypoint;
    this.libraryPath = libraryPath;
  }
}