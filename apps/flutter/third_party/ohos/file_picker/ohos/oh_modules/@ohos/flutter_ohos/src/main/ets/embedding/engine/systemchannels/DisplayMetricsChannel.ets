/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import MethodCall from '../../../plugin/common/MethodCall';
import MethodChannel, { MethodCallHandler, MethodResult } from '../../../plugin/common/MethodChannel';
import StandardMethodCodec from '../../../plugin/common/StandardMethodCodec';
import Log from '../../../util/Log';
import DartExecutor from '../dart/DartExecutor';
import { common } from '@kit.AbilityKit';

const TAG: string = 'DisplayMetricsChannel';

/**
 * System channel ({@code flutter/displaymetrics}) for display-metric requests from Flutter to the OpenHarmony embedding.
 *
 * **Supported incoming methods** (invoke from Dart via this channel; all others get {@code notImplemented}):
 * - {@code updateDpiScale} — arguments include {@code dpiScale} (number). Emits {@code changeDevicePixelRatio} on
 *   {@code context.eventHub}; {@code FlutterView} handles it in {@code onDevicePixelRatioChange} to update viewport metrics.
 *
 * Construct alongside {@code DartExecutor} and {@code common.Context}, register the handler in the constructor, and keep
 * the instance alive for the engine lifetime so Flutter can push DPI / display updates during runtime.
 *
 * @example Typical wiring: {@code new DisplayMetricsChannel(dartExecutor, context);} — the constructor registers
 * the handler; Dart then invokes e.g. {@code updateDpiScale} on {@code flutter/displaymetrics}.
 */
export default class DisplayMetricsChannel implements MethodCallHandler {
  public channel: MethodChannel;
  public context: common.Context;
  private customDpiActive: boolean = false;
 	private currentUri: string = '';

  /**
   * Handles method calls on {@code flutter/displaymetrics} from Flutter.
   * - {@code updateDpiScale}: reads numeric {@code dpiScale} from call arguments, emits {@code changeDevicePixelRatio}
   *   on {@code this.context.eventHub}, then {@code result.success(true)}.
   * - Any other method name: {@code result.notImplemented()}.
   */
  onMethodCall(call: MethodCall, result: MethodResult): void {
    let method: string = call.method;
    Log.i(TAG, "Received '" + method + "' message.");
    try {
      // More methods are expected to be added here, hence the switch.
      switch (method) {
        case "updateDpiScale":
          if (this.customDpiActive && this.currentUri) {
            result.success(true);
            Log.i(TAG, "Custom DPI for this page" + this.currentUri);
            break;
          }
          let dpiScaleFactor: number = call.argument('dpiScale');
          Log.i(TAG, "Received dpiScaleFactor '" + dpiScaleFactor + "' message.");
          this.context.eventHub.emit('changeDevicePixelRatio', dpiScaleFactor)
          result.success(true);
          break;
        default:
          result.notImplemented();
          break;
      }
    } catch (error) {
      result.error("error", "UnHandled error: " + JSON.stringify(error), null)
    }
  }

  setCustomDpiActive(active: boolean): void {
    this.customDpiActive = active;
    Log.i(TAG, "setCustomDpiActive: " + active);
  }

  isCustomDpiActive(): boolean {
    return this.customDpiActive;
  }

  setCurrentUri(uri: string): void {
    this.currentUri = uri;
    Log.i(TAG, "setCurrentUri: " + uri);
  }

  getCurrentUri(): string {
    return this.currentUri;
  }

  /**
   * @param dartExecutor - Dart executor whose binary messenger backs {@code flutter/displaymetrics}
   * @param context - Application context whose {@code eventHub} receives {@code changeDevicePixelRatio}
   */
  constructor(dartExecutor: DartExecutor, context: common.Context) {
    this.channel = new MethodChannel(dartExecutor, "flutter/displaymetrics", StandardMethodCodec.INSTANCE);
    this.channel.setMethodCallHandler(this);
    this.context = context;
  }
}

