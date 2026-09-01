/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
*/

/**
 * Represents raw pointer coordinates with additional touch information.
 * This class holds detailed information about a pointer event.
 */
export class RawPointerCoords {
  private orientation: number = 0;
  private pressure: number = 0;
  private size: number = 0;
  private toolMajor: number = 0;
  private toolMinor: number = 0;
  private touchMajor: number = 0;
  private touchMinor: number = 0;
  private x: number = 0;
  private y: number = 0;

  /**
   * Constructs a new RawPointerCoords instance.
   * @param orientation - The orientation angle in radians
   * @param pressure - The pressure value (0.0 to 1.0)
   * @param size - The size value
   * @param toolMajor - The major axis of the tool ellipse
   * @param toolMinor - The minor axis of the tool ellipse
   * @param touchMajor - The major axis of the touch ellipse
   * @param touchMinor - The minor axis of the touch ellipse
   * @param x - The X coordinate
   * @param y - The Y coordinate
   */
  constructor(orientation: number, pressure: number, size: number, toolMajor: number, toolMinor: number,
    touchMajor: number, touchMinor: number, x: number, y: number) {
    this.orientation = orientation;
    this.pressure = pressure;
    this.size = size;
    this.toolMajor = toolMajor;
    this.toolMinor = toolMinor;
    this.touchMajor = touchMajor;
    this.touchMinor = touchMinor;
    this.x = x;
    this.y = y;
  }

  /**
   * Gets the X coordinate.
   * @returns The X coordinate value
   */
  getX(): number {
    return this.x;
  }

  /**
   * Gets the Y coordinate.
   * @returns The Y coordinate value
   */
  getY(): number {
    return this.y;
  }
}