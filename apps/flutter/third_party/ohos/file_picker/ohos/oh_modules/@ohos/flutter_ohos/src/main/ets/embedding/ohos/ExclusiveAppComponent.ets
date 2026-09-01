/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on ExclusiveAppComponent.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

/**
 * Interface for app components that exclusively attach to a FlutterEngine.
 * @template T - The type of the underlying app component
 */
export default interface ExclusiveAppComponent<T> {
  /**
   * Called when another App Component is about to become attached to the
   * {@link FlutterEngine} this App Component is currently attached to.
   *
   * This App Component's connections to the {@link FlutterEngine}
   * are still valid at the moment of this call.
   */
  detachFromFlutterEngine(): void;

  /**
   * Retrieves the App Component behind this exclusive App Component.
   *
   * @returns The app component
   */
  getAppComponent(): T;
}