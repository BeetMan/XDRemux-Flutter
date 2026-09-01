/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on MouseCursorPlugin.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import MouseCursorChannel, { MouseCursorMethodHandler } from '../../embedding/engine/systemchannels/MouseCursorChannel';
import pointer from '@ohos.multimodalInput.pointer';
import HashMap from '@ohos.util.HashMap';
import Log from '../../util/Log';
import Any from '../common/Any';

const TAG: string = "MouseCursorPlugin";

/**
 * Plugin for handling mouse cursor changes in Flutter applications.
 * This class manages the interaction between Flutter's cursor system
 * and the OpenHarmony pointer style system.
 */
export default class MouseCursorPlugin implements MouseCursorMethodHandler {
  private mouseCursorChannel: MouseCursorChannel;
  private systemCursorConstants: HashMap<string, pointer.PointerStyle> | null = null;
  private windowId: number;

  /**
   * Constructs a new MouseCursorPlugin instance.
   * @param windowId - The window ID for setting pointer styles
   * @param mouseCursorChannel - The MouseCursorChannel for communication with Flutter
   */
  constructor(windowId: number, mouseCursorChannel: MouseCursorChannel) {
    this.windowId = windowId;
    this.mouseCursorChannel = mouseCursorChannel;
    this.mouseCursorChannel.setMethodHandler(this);
  }

  /**
   * Activates a system cursor for the specified kind.
   * @param kind - The cursor kind (e.g., "click", "text", "move")
   */
  activateSystemCursor(kind: string): void {
    if (this.windowId < 0) {
      Log.e(TAG, "setPointerStyle failed: windowId is invalid: " + this.windowId);
      return;
    }
    let pointStyle: pointer.PointerStyle = this.resolveSystemCursor(kind);
    try {
      pointer.setPointerStyle(this.windowId, pointStyle, (err: Any) => {
        if (err) {
          Log.e(TAG, "setPointerStyle callback error: kind=" + kind + ", err=" + JSON.stringify(err));
        } else {
          Log.i(TAG, "setPointerStyle success: kind=" + kind);
        }
      })
    } catch (e) {
      Log.e(TAG, "setPointerStyle exception: kind=" + kind + ", error=" + JSON.stringify(e));
    }
  }

  private resolveSystemCursor(kind: string): pointer.PointerStyle {
    if (this.systemCursorConstants == null) {
      this.systemCursorConstants = new HashMap();
      this.systemCursorConstants.set("alias", pointer.PointerStyle.DEFAULT);
      this.systemCursorConstants.set("allScroll", pointer.PointerStyle.MOVE);
      this.systemCursorConstants.set("basic", pointer.PointerStyle.DEFAULT);
      this.systemCursorConstants.set("cell", pointer.PointerStyle.DEFAULT);
      this.systemCursorConstants.set("click", pointer.PointerStyle.HAND_POINTING);
      this.systemCursorConstants.set("contextMenu", pointer.PointerStyle.DEFAULT);
      this.systemCursorConstants.set("copy", pointer.PointerStyle.CURSOR_COPY);
      this.systemCursorConstants.set("forbidden", pointer.PointerStyle.CURSOR_FORBID);
      this.systemCursorConstants.set("grab", pointer.PointerStyle.HAND_OPEN);
      this.systemCursorConstants.set("grabbing", pointer.PointerStyle.HAND_GRABBING);
      this.systemCursorConstants.set("help", pointer.PointerStyle.HELP);
      this.systemCursorConstants.set("move", pointer.PointerStyle.MOVE);
      this.systemCursorConstants.set("none", pointer.PointerStyle.DEFAULT);
      this.systemCursorConstants.set("noDrop", pointer.PointerStyle.DEFAULT);
      this.systemCursorConstants.set("precise", pointer.PointerStyle.CROSS);
      this.systemCursorConstants.set("text", pointer.PointerStyle.TEXT_CURSOR);
      this.systemCursorConstants.set("resizeColum", pointer.PointerStyle.NORTH_SOUTH);
      this.systemCursorConstants.set("resizeDown", pointer.PointerStyle.SOUTH);
      this.systemCursorConstants.set("resizeDownLeft", pointer.PointerStyle.SOUTH_WEST);
      this.systemCursorConstants.set("resizeDownRight", pointer.PointerStyle.SOUTH_EAST);
      this.systemCursorConstants.set("resizeLeft", pointer.PointerStyle.WEST);
      this.systemCursorConstants.set("resizeLeftRight", pointer.PointerStyle.RESIZE_LEFT_RIGHT);
      this.systemCursorConstants.set("resizeRight", pointer.PointerStyle.EAST);
      this.systemCursorConstants.set("resizeRow", pointer.PointerStyle.WEST_EAST);
      this.systemCursorConstants.set("resizeUp", pointer.PointerStyle.NORTH);
      this.systemCursorConstants.set("resizeUpDown", pointer.PointerStyle.RESIZE_UP_DOWN);
      this.systemCursorConstants.set("resizeUpLeft", pointer.PointerStyle.NORTH_WEST);
      this.systemCursorConstants.set("resizeUpRight", pointer.PointerStyle.NORTH_EAST);
      this.systemCursorConstants.set("resizeUpLeftDownRight", pointer.PointerStyle.NORTH_WEST_SOUTH_EAST);
      this.systemCursorConstants.set("resizeUpRightDownLeft", pointer.PointerStyle.NORTH_EAST_SOUTH_WEST);
      this.systemCursorConstants.set("verticalText", pointer.PointerStyle.TEXT_CURSOR);
      this.systemCursorConstants.set("wait", pointer.PointerStyle.DEFAULT);
      this.systemCursorConstants.set("zoomIn", pointer.PointerStyle.ZOOM_IN);
      this.systemCursorConstants.set("zoomOut", pointer.PointerStyle.ZOOM_OUT);
      this.systemCursorConstants.set("middleBtnEast", pointer.PointerStyle.MIDDLE_BTN_EAST);
      this.systemCursorConstants.set("middleBtnWest", pointer.PointerStyle.MIDDLE_BTN_WEST);
      this.systemCursorConstants.set("middleBtnSouth", pointer.PointerStyle.MIDDLE_BTN_SOUTH);
      this.systemCursorConstants.set("middleBtnNorth", pointer.PointerStyle.MIDDLE_BTN_NORTH);
      this.systemCursorConstants.set("middleBtnNorthSouth", pointer.PointerStyle.MIDDLE_BTN_NORTH_SOUTH);
      this.systemCursorConstants.set("middleBtnNorthEast", pointer.PointerStyle.MIDDLE_BTN_NORTH_EAST);
      this.systemCursorConstants.set("middleBtnNorthWest", pointer.PointerStyle.MIDDLE_BTN_NORTH_WEST);
      this.systemCursorConstants.set("middleBtnSouthEast", pointer.PointerStyle.MIDDLE_BTN_SOUTH_EAST);
      this.systemCursorConstants.set("middleBtnSouthWest", pointer.PointerStyle.MIDDLE_BTN_SOUTH_WEST);
      this.systemCursorConstants.set("middleBtnNorthSouthWestEast",
        pointer.PointerStyle.MIDDLE_BTN_NORTH_SOUTH_WEST_EAST);
      this.systemCursorConstants.set("horizontalTextCursor", pointer.PointerStyle.HORIZONTAL_TEXT_CURSOR);
      this.systemCursorConstants.set("cursorCross", pointer.PointerStyle.CURSOR_CROSS);
      this.systemCursorConstants.set("cursorCircle", pointer.PointerStyle.CURSOR_CIRCLE);
      this.systemCursorConstants.set("loading", pointer.PointerStyle.LOADING);
      this.systemCursorConstants.set("running", pointer.PointerStyle.RUNNING);
      this.systemCursorConstants.set("colorSucker", pointer.PointerStyle.COLOR_SUCKER);
      this.systemCursorConstants.set("screenshotChoose", pointer.PointerStyle.SCREENSHOT_CHOOSE);
      this.systemCursorConstants.set("screenshotCursor", pointer.PointerStyle.SCREENSHOT_CURSOR);
    }
    let pointStyle: pointer.PointerStyle = this.systemCursorConstants.get(kind);
    if (pointStyle === null) {
      return pointer.PointerStyle.DEFAULT;
    }
    return pointStyle;
  }

  /**
   * Destroys the mouse cursor plugin and cleans up resources.
   * The MouseCursorPlugin instance should not be used after calling this.
   */
  destroy(): void {
    this.mouseCursorChannel.setMethodHandler(null);
  }
}

