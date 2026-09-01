/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/


import PlatformView from '../../plugin/platform/PlatformView';

/**
 * Information about a platform view embedded in Flutter.
 */
export class PlatformViewInfo {
  /** The platform view instance. */
  public platformView: PlatformView;
  /** The surface ID for rendering. */
  public surfaceId: string;
  /** The width of the platform view. */
  public width: number;
  /** The height of the platform view. */
  public height: number;
  /** The top position of the platform view. */
  public top: number;
  /** The left position of the platform view. */
  public left: number;
  /** The layout direction for the platform view. */
  public direction: Direction;

  /**
   * Constructs a new PlatformViewInfo instance.
   * @param platformView - The platform view instance
   * @param surfaceId - The surface ID
   * @param width - The width of the view
   * @param height - The height of the view
   * @param top - The top position
   * @param left - The left position
   * @param direction - The layout direction
   */
  constructor(platformView: PlatformView, surfaceId: string, width: number, height: number, top: number, left: number,
    direction: Direction) {
    this.platformView = platformView;
    this.surfaceId = surfaceId;
    this.width = width;
    this.height = height;
    this.top = top;
    this.left = left;
    this.direction = direction;
  }
}
