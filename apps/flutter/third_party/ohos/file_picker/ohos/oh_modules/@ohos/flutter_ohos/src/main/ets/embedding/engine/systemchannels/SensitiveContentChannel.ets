/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import Any from '../../../plugin/common/Any';
import DartExecutor from '../dart/DartExecutor';
import StandardMethodCodec from '../../../plugin/common/StandardMethodCodec';
import Log from '../../../util/Log';
import MethodCall from '../../../plugin/common/MethodCall';
import MethodChannel, { MethodCallHandler, MethodResult } from '../../../plugin/common/MethodChannel';

const TAG = "SensitiveContentChannel";

export const SENSITIVE_CONTENT_SENSITIVITY = 1;
export const NOT_SENSITIVE_CONTENT_SENSITIVITY = 2;

export default class SensitiveContentChannel implements MethodCallHandler {
  private static CHANNEL_NAME = "flutter/sensitivecontent";
  private channel: MethodChannel;
  private sensitiveContentMethodHandler: SensitiveContentMethodHandler | null = null;

  constructor(dartExecutor: DartExecutor) {
    this.channel = new MethodChannel(dartExecutor, SensitiveContentChannel.CHANNEL_NAME, StandardMethodCodec.INSTANCE);
    this.channel.setMethodCallHandler(this);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (this.sensitiveContentMethodHandler == null) {
      // No SensitiveContentChannel registered, call not forwarded to sensitive content API.
      return;
    }
    let method: string = call.method;
    Log.d(TAG, "Received '" + method + "' message.");
    switch (method) {
      case "SensitiveContent.setContentSensitivity":
        this.setContentSensitivity(call, result);
        break;
      case "SensitiveContent.getContentSensitivity":
        this.getContentSensitivity(call, result);
        break;
      case "SensitiveContent.isSupported":
        this.isSupported(call, result);
        break;
      default:
        Log.d(TAG, "Method " + method + " is not implemented for the SensitiveContentChannel.");
        result.notImplemented();
        break;
    }
  }

  private setContentSensitivity(call: MethodCall, result: MethodResult): void {
    try {
      const contentSensitivityLevel: number = call.args as number;
      const deserializedValue = this.deserializeContentSensitivity(contentSensitivityLevel);
      this.sensitiveContentMethodHandler!.setContentSensitivity(deserializedValue);
      result.success(null);
    } catch (error) {
      result.error("error", (error as Error).message, null);
    }
  }

  private getContentSensitivity(call: MethodCall, result: MethodResult): void {
    try {
      const currentContentSensitivity: number = this.sensitiveContentMethodHandler!.getContentSensitivity();
      const serializedValue = this.serializeContentSensitivity(currentContentSensitivity);
      result.success(serializedValue);
    } catch (error) {
      result.error("error", (error as Error).message, null);
    }
  }

  private isSupported(call: MethodCall, result: MethodResult): void {
    const isSupported: boolean = this.sensitiveContentMethodHandler!.isSupported();
    result.success(isSupported);
  }

  /**
   * Deserializes Flutter content sensitivity index to native value.
   */
  private deserializeContentSensitivity(contentSensitivityIndex: number): number {
    switch (contentSensitivityIndex) {
      case NOT_SENSITIVE_CONTENT_SENSITIVITY:
        return NOT_SENSITIVE_CONTENT_SENSITIVITY;
      case SENSITIVE_CONTENT_SENSITIVITY:
        return SENSITIVE_CONTENT_SENSITIVITY;
      default:
        throw new Error(
          "contentSensitivityIndex " + contentSensitivityIndex + " not known to the SensitiveContentChannel."
        );
    }
  }

  /**
   * Serializes native content sensitivity value to Flutter index.
   */
  private serializeContentSensitivity(contentSensitivityValue: number): number {
    switch (contentSensitivityValue) {
      case NOT_SENSITIVE_CONTENT_SENSITIVITY:
        return NOT_SENSITIVE_CONTENT_SENSITIVITY;
      case SENSITIVE_CONTENT_SENSITIVITY:
        return SENSITIVE_CONTENT_SENSITIVITY;
      default:
        return NOT_SENSITIVE_CONTENT_SENSITIVITY;
    }
  }

  /**
   * Sets the {@link SensitiveContentMethodHandler} which receives all requests to get and set a
   * particular content sensitivity level sent through this channel.
   */
  setSensitiveContentMethodHandler(sensitiveContentMethodHandler: SensitiveContentMethodHandler | null): void {
    this.sensitiveContentMethodHandler = sensitiveContentMethodHandler;
  }
}

export interface SensitiveContentMethodHandler {
  /**
   * Requests that a native Flutter OpenHarmony View sets its content sensitivity level to
   * {@code requestedContentSensitivity}.
   */
  setContentSensitivity(requestedContentSensitivity: number): void;

  /**
   * Returns the current content sensitivity level of a Flutter OpenHarmony View.
   */
  getContentSensitivity(): number;

  /**
   * Returns whether or not setting/getting content sensitivity via OpenHarmony APIs is supported on
   * the device.
   */
  isSupported(): boolean;
}

