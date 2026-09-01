/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on PlatformView.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import { DVModel, DynamicView } from '../../view/DynamicView/dynamicView'

/**
 * Parameters for platform view rendering.
 * This class contains the configuration needed to render a platform view.
 */
export declare class Params {
  /** The text direction for the platform view */
  direction: Direction
  /** The platform view instance to render */
  platformView: PlatformView
}

export declare class PlatformViewVisibleAreaEventOptions {
  enable: boolean // Enable variable area monitoring
  ratios: Array<number> // Ratio thresholds for visible area changes, e.g., [0.0, 1.0] means 0% to 100% visible
  expectedUpdateInterval: number // Expected interval for visible area updates in milliseconds
  onInactiveThreshold: number // Texture continuous production pause operation visible area threshold
  onActiveThreshold: number // Texture continuous production activation operation visible area threshold
}

// unit: ms
const defaultExpectedUpdateInterval: number = 1000;

/** A handle to an DynamicView to be embedded in the Flutter hierarchy. */
export default abstract class PlatformView {  

  /**
   * Gets the type of this platform view.
   * @returns The view type string
   */
  getType(): string {
    return 'default';
  }

  /** Returns the DynamicView to be embedded in the Flutter hierarchy. */
  abstract getView(): WrappedBuilder<[Params]>;

  /**
   * Called by the FlutterEngine that owns this PlatformView when the DynamicView responsible
   * for rendering a Flutter UI is associated with the FlutterEngine.
   *
   * This means that our associated FlutterEngine can now render a UI and interact with the user.
   *
   * Some platform views may have unusual dependencies on the DynamicView that renders Flutter
   * UIs, such as unique keyboard interactions. That DynamicView is provided here for those
   * purposes. Use of this DynamicView should be avoided if it is not absolutely necessary, because
   * depending on this DynamicView will tend to make platform view code more brittle to future
   * changes.
   * @param dvModel - The DynamicView model associated with the Flutter view
   */
  onFlutterViewAttached(dvModel: DVModel): void {
  }

  /**
   * Called by the FlutterEngine that owns this PlatformView when the DynamicView responsible
   * for rendering a Flutter UI is detached and disassociated from the FlutterEngine.
   *
   * This means that our associated FlutterEngine no longer has a rendering surface, or a user
   * interaction surface of any kind.
   *
   * This platform view must release any references related to the DynamicView that was
   * provided in onFlutterViewAttached.
   */
  onFlutterViewDetached(): void {
  }

  /**
   * Disposes this platform view.
   *
   * The PlatformView object is unusable after this method is called.
   *
   * Plugins implementing PlatformView must clear all references to the DynamicView object and
   * the PlatformView after this method is called. Failing to do so will result in a memory leak.
   *
   * References related to the DynamicView attached in onFlutterViewAttached
   * must be released in dispose() to avoid memory leaks.
   */
  abstract dispose(): void;

  /**
   * Callback fired when the platform's input connection is locked, or should be used.
   *
   * This hook only exists for rare cases where the plugin relies on the state of the input
   * connection. This probably doesn't need to be implemented.
   */
  onInputConnectionLocked(): void {
  }

  /**
   * Callback fired when the platform input connection has been unlocked.
   *
   * This hook only exists for rare cases where the plugin relies on the state of the input
   * connection. This probably doesn't need to be implemented.
   */
  onInputConnectionUnlocked(): void {
  }

  // Obtain the parameters related to the changes in the visible area of the external texture
  getPlatformViewVisibleAreaEventOptions(): PlatformViewVisibleAreaEventOptions {
    return {
      enable: false,
      ratios: [0.0, 1.0],
      expectedUpdateInterval: defaultExpectedUpdateInterval,
      onInactiveThreshold : 0.0,
      onActiveThreshold : 1.0
    } as PlatformViewVisibleAreaEventOptions;
  }

  // The operation to pause the continuous production of external textures, including animations and videos
  onInactive(): void {
  }

  // The operation to resume the continuous production of external textures, including animations and videos
  onActive(): void {
  }
}