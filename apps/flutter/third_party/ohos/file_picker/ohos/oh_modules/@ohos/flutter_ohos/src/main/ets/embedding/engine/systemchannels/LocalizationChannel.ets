/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on LocalizationChannel.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import DartExecutor from '../dart/DartExecutor';
import MethodChannel, { MethodCallHandler, MethodResult } from '../../../plugin/common/MethodChannel';
import MethodCall from '../../../plugin/common/MethodCall';
import List from '@ohos.util.List';
import JSONMethodCodec from '../../../plugin/common/JSONMethodCodec';
import intl from '@ohos.intl';
import Log from '../../../util/Log';

const TAG = "LocalizationChannel";

/**
 * Channel for handling localization-related communication between Flutter and OpenHarmony.
 * This channel manages locale information and string resource retrieval.
 */
export default class LocalizationChannel implements MethodCallHandler {
  private static TAG = "LocalizationChannel";
  private static CHANNEL_NAME = "flutter/localization";
  private channel: MethodChannel;
  private localizationMessageHandler: LocalizationMessageHandler | null = null;

  /**
   * Handles method calls from Dart.
   * @param call - The method call from Dart
   * @param result - The result callback to send a response
   */
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (this.localizationMessageHandler == null) {
      Log.e(TAG, "localizationMessageHandler is null");
      return;
    }
    let method: string = call.method;
    switch (method) {
      case "Localization.getStringResource": {
        Log.i(TAG, "Localization.getStringResource enter");
        let key: string = call.argument("key");
        let localeString: string = "";
        if (call.hasArgument("locale")) {
          localeString = call.argument("locale");
        }
        result.success(this.localizationMessageHandler?.getStringResource(key, localeString));
        break;
      }
      default: {
        result.notImplemented();
        break;
      }
    }
  }

  /**
   * Constructs a new LocalizationChannel instance.
   * @param dartExecutor - The DartExecutor for sending messages to Dart
   */
  constructor(dartExecutor: DartExecutor) {
    this.channel = new MethodChannel(dartExecutor, LocalizationChannel.CHANNEL_NAME, JSONMethodCodec.INSTANCE);
    this.channel.setMethodCallHandler(this);
  }

  /**
   * Sets the localization message handler for processing localization requests.
   * @param localizationMessageHandler - The LocalizationMessageHandler instance
   */
  setLocalizationMessageHandler(localizationMessageHandler: LocalizationMessageHandler): void {
    this.localizationMessageHandler = localizationMessageHandler;
  }

  /**
   * Sends locale information to Flutter.
   * @param locales - Array of locale strings to send
   */
  sendLocales(locales: string[]): void {
    let data: string[] = [];
    for (let i = 0; i < locales.length; i++) {
      let locale = new intl.Locale(locales[i]);
      data.push(locale.language);
      data.push(locale.region);
      data.push(locale.script);
      data.push(''); // locale.getVariant locale的一种变体
    }
    this.channel.invokeMethod("setLocale", data);
  }
}

/**
 * Interface for handling localization message requests.
 */
export interface LocalizationMessageHandler {
  /**
   * Gets a string resource by key and locale.
   * @param key - The resource key
   * @param local - The locale string
   */
  getStringResource(key: string, local: string): void;
}