/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterUiDisplayListener.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

/**
 * Listener interface for Flutter UI display state changes.
 * Implementations of this interface are notified when Flutter UI is displayed or hidden.
 */
export interface FlutterUiDisplayListener {
  /**
   * Called when Flutter UI is displayed for the first time.
   */
  onFlutterUiDisplayed(): void;

  /**
   * Called when Flutter UI is no longer displayed.
   */
  onFlutterUiNoLongerDisplayed(): void;
}