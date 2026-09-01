/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import { TouchEvent } from '@ohos.multimodalInput.touchEvent';
import Any from '../../plugin/common/Any';

/**
 * Processor for handling touch events from OpenHarmony.
 * This class processes touch events and converts them for Flutter.
 */
export default class OhosTouchProcessor {
  private static POINTER_DATA_FIELD_COUNT: number = 35;
  /** Number of bytes per field in pointer data. */
  static BYTES_PER_FIELD: number = 8;
  private static POINTER_DATA_FLAG_BATCHED: number = 1;

  /**
   * Processes a touch event.
   * @param event - The touch event from OpenHarmony
   * @param transformMatrix - The transformation matrix to apply
   */
  public onTouchEvent(event: TouchEvent, transformMatrix: Any): void {

  }
}

/**
 * Types of pointer state changes.
 */
export enum PointerChange {
  CANCEL = 0,
  ADD = 1,
  REMOVE = 2,
  HOVER = 3,
  DOWN = 4,
  MOVE = 5,
  UP = 6,
  PAN_ZOOM_START = 7,
  PAN_ZOOM_UPDATE = 8,
  PAN_ZOOM_END = 9
}

/**
 * Types of pointer input devices.
 */
export enum PointerDeviceKind {
  TOUCH = 0,
  MOUSE = 1,
  STYLUS = 2,
  INVERTED_STYLUS = 3,
  TRACKPAD = 4,
  UNKNOWN = 5
}

/**
 * Types of pointer signal events.
 */
export enum PointerSignalKind {
  NONE = 0,
  SCROLL = 1,
  SCROLL_INERTIA_CANCEL = 2,
  SCALE = 3,
  UNKNOWN = 4
}