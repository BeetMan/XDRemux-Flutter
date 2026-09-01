/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
*/

/**
 * Custom implementation of TouchEvent for platform views.
 * This class wraps touch event data for communication between Flutter and native views.
 */
export class CustomTouchEvent implements TouchEvent {
  /** The type of touch event. */
  type: TouchType = 0;
  /** Array of all touch points in this event. */
  touches: CustomTouchObject[];
  /** Array of touch points that changed in this event. */
  changedTouches: CustomTouchObject[];
  /** Function to stop event propagation. */
  stopPropagation: () => void = () => {
  };
  /** The timestamp when the event occurred. */
  timestamp: number;
  /** The source type of the touch event. */
  source: SourceType;
  /** The pressure value of the touch. */
  pressure: number;
  /** The X-axis tilt value of the touch. */
  tiltX: number;
  /** The Y-axis tilt value of the touch. */
  tiltY: number;
  /** The source tool type for the touch. */
  sourceTool: SourceTool;

  /**
   * Constructs a new CustomTouchEvent instance.
   * @param type - The touch event type
   * @param touches - Array of all touch points
   * @param changedTouches - Array of touch points that changed
   * @param timestamp - The event timestamp
   * @param source - The source type of the touch
   * @param pressure - The pressure value
   * @param tiltX - The X-axis tilt value
   * @param tiltY - The Y-axis tilt value
   * @param sourceTool - The source tool type
   */
  constructor(type: TouchType, touches: CustomTouchObject[], changedTouches: CustomTouchObject[], timestamp: number,
    source: SourceType, pressure: number, tiltX: number, tiltY: number, sourceTool: SourceTool) {
    this.type = type;
    this.touches = touches;
    this.changedTouches = changedTouches;
    this.timestamp = timestamp;
    this.source = source;
    this.pressure = pressure;
    this.tiltX = tiltX;
    this.tiltY = tiltY;
    this.sourceTool = sourceTool;
  }

  /** Function to prevent the default action. */
  preventDefault: () => void = () => {
  };

  /**
   * Gets the modifier key state.
   * @param keys - Array of key names to check
   * @returns True if any of the keys are pressed
   * @throws Error as this method is not implemented
   */
  getModifierKeyState(keys: string[]): boolean {
    throw new Error('Method not implemented.');
  }

  /** The event target for this touch event. */
  target: EventTarget = new CustomEventTarget(new CustomArea(0, 0, { x: 0, y: 0 }, { x: 0, y: 0 }));

  /**
   * Gets historical touch points.
   * @returns Array of historical points
   * @throws Error as this method is not implemented
   */
  getHistoricalPoints(): HistoricalPoint[] {
    throw new Error('Method not implemented.');
  }
}

/**
 * Custom implementation of EventTarget for touch events.
 * This class provides a target for touch events in platform views.
 */
class CustomEventTarget implements EventTarget {
  /** The area associated with this event target */
  area: Area = new CustomArea(0, 0, { x: 0, y: 0 }, { x: 0, y: 0 });

  /**
   * Constructs a new CustomEventTarget instance.
   * @param area - The area associated with this event target
   */
  constructor(area: Area) {
    this.area = area;
  }
}

/**
 * Custom implementation of Area for touch events.
 * This class represents a rectangular area with position and size information.
 */
class CustomArea implements Area {
  /** The width of the area. */
  width: Length = 0;
  /** The height of the area. */
  height: Length = 0;
  /** The local position of the area. */
  position: Position = { x: 0, y: 0 };
  /** The global position of the area. */
  globalPosition: Position = { x: 0, y: 0 };

  /**
   * Constructs a new CustomArea instance.
   * @param width - The width of the area
   * @param height - The height of the area
   * @param position - The local position
   * @param globalPosition - The global position
   */
  constructor(width: Length, height: Length, position: Position, globalPosition: Position) {
    this.width = width;
    this.height = height;
    this.position = position;
    this.globalPosition = globalPosition;
  }
}

/**
 * Custom implementation of TouchObject for platform views.
 */
export class CustomTouchObject implements TouchObject {
  /** The type of touch. */
  type: TouchType;
  /** The unique identifier for this touch point. */
  id: number;
  /** The X coordinate in display space. */
  displayX: number;
  /** The Y coordinate in display space. */
  displayY: number;
  /** The X coordinate in window space. */
  windowX: number;
  /** The Y coordinate in window space. */
  windowY: number;
  /** The X coordinate in screen space. */
  screenX: number;
  /** The Y coordinate in screen space. */
  screenY: number;
  /** The X coordinate in local space. */
  x: number;
  /** The Y coordinate in local space. */
  y: number;

  /**
   * Constructs a new CustomTouchObject instance.
   * @param type - The touch type
   * @param id - The touch point ID
   * @param displayX - The X coordinate in display space
   * @param displayY - The Y coordinate in display space
   * @param windowX - The X coordinate in window space
   * @param windowY - The Y coordinate in window space
   * @param screenX - The X coordinate in screen space
   * @param screenY - The Y coordinate in screen space
   * @param x - The X coordinate in local space
   * @param y - The Y coordinate in local space
   */
  constructor(type: TouchType, id: number, displayX: number, displayY: number, windowX: number, windowY: number,
    screenX: number, screenY: number, x: number, y: number) {
    this.type = type;
    this.id = id;
    this.displayX = displayX;
    this.displayY = displayY;
    this.windowX = windowX;
    this.windowY = windowY;
    this.screenX = screenX;
    this.screenY = screenY;
    this.x = x;
    this.y = y;
  }
}