/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on MouseCursorChannel.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import HashMap from '@ohos.util.HashMap';
import MethodCall from '../../../plugin/common/MethodCall';
import MethodChannel, { MethodCallHandler, MethodResult } from '../../../plugin/common/MethodChannel';
import StandardMethodCodec from '../../../plugin/common/StandardMethodCodec';
import Log from '../../../util/Log';
import DartExecutor from '../dart/DartExecutor';

const TAG: string = 'MouseCursorChannel';

/**
 * Channel for handling mouse cursor changes.
 * This channel manages communication between Flutter and OpenHarmony for cursor appearance changes.
 */
export default class MouseCursorChannel implements MethodCallHandler {
  /** The MethodChannel for mouse cursor communication with Flutter. */
  public channel: MethodChannel;
  private mouseCursorMethodHandler: MouseCursorMethodHandler | null = null;

  /**
   * Handles method calls from Dart.
   * @param call - The method call from Dart
   * @param result - The result callback to send a response
   */
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (this.mouseCursorMethodHandler === null) {
      // if no explicit mouseCursorMethodHandler has been registered then we don't
      // need to formed this call to an API. Return
      Log.e(TAG, "mouseCursorMethodHandler is null")
      return;
    }

    let method: string = call.method;
    Log.i(TAG, "Received '" + method + "' message.");
    try {
      // More methods are expected to be added here, hence the switch.
      switch (method) {
        case "activateSystemCursor":
          let argument: HashMap<string, string> = call.args;
          let kind: string = argument.get("kind");
          try {
            this.mouseCursorMethodHandler.activateSystemCursor(kind);
          } catch (err) {
            result.error("error", "Error when setting cursors: " + JSON.stringify(err), null);
            break;
          }
          result.success(true);
          break;
        default:
          break;
      }
    } catch (error) {
      result.error("error", "UnHandled error: " + JSON.stringify(error), null)
    }
  }

  /**
   * Constructs a new MouseCursorChannel instance.
   * @param dartExecutor - The DartExecutor for sending messages to Dart
   */
  constructor(dartExecutor: DartExecutor) {
    this.channel = new MethodChannel(dartExecutor, "flutter/mousecursor", StandardMethodCodec.INSTANCE);
    this.channel.setMethodCallHandler(this);
  }

  /**
   * Sets the MouseCursorMethodHandler which receives all events and requests that are
   * parsed from the underlying platform channel.
   * @param mouseCursorMethodHandler - The MouseCursorMethodHandler instance, or null to remove
   */
  public setMethodHandler(mouseCursorMethodHandler: MouseCursorMethodHandler | null): void {
    this.mouseCursorMethodHandler = mouseCursorMethodHandler;
  }

  /**
   * Synthesizes a method call for testing purposes.
   * @param call - The method call to synthesize
   * @param result - The result callback to send a response
   */
  public synthesizeMethodCall(call: MethodCall, result: MethodResult): void {
    this.onMethodCall(call, result);
  }
}

/**
 * Interface for handling mouse cursor method calls.
 */
export interface MouseCursorMethodHandler {
  /**
   * Called when the pointer should start displaying a system mouse cursor
   * specified by the kind parameter.
   * @param kind - The cursor kind/type to activate
   */
  activateSystemCursor(kind: String): void;
}