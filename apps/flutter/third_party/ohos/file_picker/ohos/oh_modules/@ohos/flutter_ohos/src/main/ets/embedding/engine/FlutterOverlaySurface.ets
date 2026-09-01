/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterOverlaySurface.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

/**
 * Represents an overlay surface in the Flutter rendering system.
 * Overlay surfaces are used for displaying content above the main Flutter view.
 */
export class FlutterOverlaySurface {
  private id: number;

  /**
   * Constructs a new FlutterOverlaySurface instance.
   * @param id - The unique identifier for this overlay surface
   */
  constructor(id: number) {
    this.id = id
  }

  /**
   * Gets the unique identifier of this overlay surface.
   * @returns The overlay surface ID
   */
  getId(): number {
    return this.id;
  }
}