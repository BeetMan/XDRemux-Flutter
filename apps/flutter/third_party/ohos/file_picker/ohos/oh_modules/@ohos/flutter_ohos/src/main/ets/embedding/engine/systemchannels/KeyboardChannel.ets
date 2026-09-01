/*
 * Copyright (c) 2021-2025 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */


import DartExecutor from '../dart/DartExecutor';
import MethodChannel, { MethodCallHandler, MethodResult } from '../../../plugin/common/MethodChannel';
import MethodCall from '../../../plugin/common/MethodCall';
import StandardMethodCodec from '../../../plugin/common/StandardMethodCodec';
import Log from '../../../util/Log';

/**
 * Channel for handling keyboard-related communication between Flutter and OpenHarmony.
 * This channel manages keyboard state queries and keyboard method calls.
 */
export default class KeyboardChannel implements MethodCallHandler {
  private static TAG = "KeyboardChannel";
  private static CHANNEL_NAME = "flutter/keyboard";
  private channel: MethodChannel;
  private handler: KeyboardMethodHandler | null = null;

  /**
   * Handles method calls from Dart.
   * @param call - The method call from Dart
   * @param result - The result callback to send a response
   */
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (this.handler == null) {
      Log.i(KeyboardChannel.TAG, "KeyboardMethodHandler is null");
      return;
    }

    let method: string = call.method;
    switch (method) {
      case "getKeyboardState": {
        Log.i(KeyboardChannel.TAG, "getKeyboardState enter");
        result.success(this.handler?.getKeyboardState());
        break;
      }
      default: {
        result.notImplemented();
        break;
      }
    }
  }

  /**
   * Constructs a new KeyboardChannel instance.
   * @param dartExecutor - The DartExecutor for sending messages to Dart
   */
  constructor(dartExecutor: DartExecutor) {
    this.channel = new MethodChannel(dartExecutor, KeyboardChannel.CHANNEL_NAME, StandardMethodCodec.INSTANCE);
    this.channel.setMethodCallHandler(this);
  }

  /**
   * Sets the keyboard method handler for processing keyboard-related requests.
   * @param keyboardMessageHandler - The KeyboardMethodHandler instance, or null to remove
   */
  public setKeyboardMethodHandler(keyboardMessageHandler: KeyboardMethodHandler | null): void {
    this.handler = keyboardMessageHandler;
  }
}

/**
 * Interface for handling keyboard method calls.
 */
export interface KeyboardMethodHandler {
  /**
   * Gets the current keyboard state.
   * @returns A map containing keyboard state information
   */
  getKeyboardState(): Map<number, number>;
}