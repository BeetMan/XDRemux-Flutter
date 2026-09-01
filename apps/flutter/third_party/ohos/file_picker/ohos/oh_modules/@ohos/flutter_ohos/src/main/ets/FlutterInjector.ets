/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import FlutterNapi from './embedding/engine/FlutterNapi';
import FlutterLoader from './embedding/engine/loader/FlutterLoader';

/**
 * Singleton holder for Flutter-related main classes.
 * Manages instances of FlutterLoader and FlutterNapi, providing centralized access to these core Flutter components.
 */
export default class FlutterInjector {
  private static instance: FlutterInjector;
  private flutterLoader: FlutterLoader;
  private preloadFlutterNapi: FlutterNapi | null = null;

  /**
   * Gets the singleton instance of FlutterInjector.
   * @returns The FlutterInjector singleton instance
   */
  static getInstance(): FlutterInjector {
    if (FlutterInjector.instance == null) {
      FlutterInjector.instance = new FlutterInjector();
    }
    return FlutterInjector.instance;
  }

  /**
   * 初始化
   */
  private constructor() {
    this.flutterLoader = new FlutterLoader(new FlutterNapi());
  }

  /**
   * Gets the FlutterLoader instance.
   * @returns The FlutterLoader instance
   */
  getFlutterLoader(): FlutterLoader {
    return this.flutterLoader;
  }

  /**
   * Gets a FlutterNapi instance.
   * If a preloaded FlutterNapi exists, it is returned and cleared.
   * Otherwise, a new FlutterNapi instance is created.
   * @returns A FlutterNapi instance
   */
  getFlutterNapi(): FlutterNapi {
    if (this.preloadFlutterNapi) {
      let retFlutterNapi = this.preloadFlutterNapi;
      this.preloadFlutterNapi = null;
      return retFlutterNapi;
    }
    return new FlutterNapi();
  }

  /**
   * Creates a preloaded FlutterNapi instance.
   * This instance will be returned by the next call to getFlutterNapi().
   * If a preloaded instance already exists, it will be replaced with a new one.
   * @returns The newly created preloaded FlutterNapi instance
   */
  getPreloadFlutterNapi(): FlutterNapi {
    this.preloadFlutterNapi = new FlutterNapi();
    return this.preloadFlutterNapi;
  }
}