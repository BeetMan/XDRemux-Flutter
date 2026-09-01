/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on SettingsChannel.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import BasicMessageChannel from '../../../plugin/common/BasicMessageChannel';
import JSONMessageCodec from '../../../plugin/common/JSONMessageCodec';
import Log from '../../../util/Log';
import DartExecutor from '../dart/DartExecutor';

/**
 * Platform brightness modes.
 */
export enum PlatformBrightness {
  LIGHT = "light",
  DARK = "dark"
}

const TAG = "SettingsChannel";
const TEXT_SCALE_FACTOR = "textScaleFactor";
const NATIVE_SPELL_CHECK_SERVICE_DEFINED = "nativeSpellCheckServiceDefined";
const BRIEFLY_SHOW_PASSWORD = "brieflyShowPassword";
const ALWAYS_USE_24_HOUR_FORMAT = "alwaysUse24HourFormat";
const PLATFORM_BRIGHTNESS = "platformBrightness";

/**
 * Channel for sending system settings to Flutter.
 * This channel manages settings such as text scale factor, platform brightness, and other system preferences.
 */
export default class SettingsChannel {
  private static CHANNEL_NAME = "flutter/settings";
  private channel: BasicMessageChannel<Object>;
  
  /**
   * Constructs a new SettingsChannel instance.
   * @param dartExecutor - The DartExecutor for sending messages to Dart
   */
  constructor(dartExecutor: DartExecutor) {
    this.channel =
      new BasicMessageChannel<Object>(dartExecutor, SettingsChannel.CHANNEL_NAME, JSONMessageCodec.INSTANCE);
  }

  /**
   * Starts building a settings message.
   * @returns A MessageBuilder instance for constructing the settings message
   */
  startMessage(): MessageBuilder {
    return new MessageBuilder(this.channel);
  }
}

/**
 * Builder for constructing settings messages to send to Flutter.
 */
class MessageBuilder {
  private channel: BasicMessageChannel<Object>;
  private settingsMessage: Map<String, Object> = new Map<String, Object>([
    [TEXT_SCALE_FACTOR, 1.0],
    [NATIVE_SPELL_CHECK_SERVICE_DEFINED, false],
    [BRIEFLY_SHOW_PASSWORD, false],
    [ALWAYS_USE_24_HOUR_FORMAT, false],
    [PLATFORM_BRIGHTNESS, PlatformBrightness.LIGHT]
  ]);

  /**
   * Constructs a new MessageBuilder instance.
   * @param channel - The BasicMessageChannel to send messages through
   */
  constructor(channel: BasicMessageChannel<Object>) {
    this.channel = channel;
  }

  /**
   * Sets the text scale factor.
   * @param textScaleFactor - The text scale factor value
   * @returns This MessageBuilder instance for method chaining
   */
  setTextScaleFactor(textScaleFactor: Number): MessageBuilder {
    this.settingsMessage.set(TEXT_SCALE_FACTOR, textScaleFactor);
    return this;
  }

  /**
   * Sets whether native spell check service is defined.
   * @param nativeSpellCheckServiceDefined - Whether the service is defined
   * @returns This MessageBuilder instance for method chaining
   */
  setNativeSpellCheckServiceDefined(nativeSpellCheckServiceDefined: boolean): MessageBuilder {
    this.settingsMessage.set(NATIVE_SPELL_CHECK_SERVICE_DEFINED, nativeSpellCheckServiceDefined);
    return this;
  }

  /**
   * Sets whether to briefly show password.
   * @param brieflyShowPassword - Whether to briefly show password
   * @returns This MessageBuilder instance for method chaining
   */
  setBrieflyShowPassword(brieflyShowPassword: boolean): MessageBuilder {
    this.settingsMessage.set(BRIEFLY_SHOW_PASSWORD, brieflyShowPassword);
    return this;
  }

  /**
   * Sets whether to always use 24-hour format.
   * @param alwaysUse24HourFormat - Whether to always use 24-hour format
   * @returns This MessageBuilder instance for method chaining
   */
  setAlwaysUse24HourFormat(alwaysUse24HourFormat: boolean): MessageBuilder {
    this.settingsMessage.set(ALWAYS_USE_24_HOUR_FORMAT, alwaysUse24HourFormat);
    return this;
  }

  /**
   * Sets the platform brightness.
   * @param platformBrightness - The platform brightness mode
   * @returns This MessageBuilder instance for method chaining
   */
  setPlatformBrightness(platformBrightness: PlatformBrightness): MessageBuilder {
    this.settingsMessage.set(PLATFORM_BRIGHTNESS, platformBrightness);
    return this;
  }

  /**
   * Sends the constructed settings message to Flutter.
   */
  send(): void {
    Log.i(TAG, "Sending message: "
      + TEXT_SCALE_FACTOR + " : "
      + this.settingsMessage.get(TEXT_SCALE_FACTOR)
      + ", " + NATIVE_SPELL_CHECK_SERVICE_DEFINED + " : "
      + this.settingsMessage.get(NATIVE_SPELL_CHECK_SERVICE_DEFINED)
      + ", " + BRIEFLY_SHOW_PASSWORD + " : "
      + this.settingsMessage.get(BRIEFLY_SHOW_PASSWORD)
      + ", " + ALWAYS_USE_24_HOUR_FORMAT + " : "
      + this.settingsMessage.get(ALWAYS_USE_24_HOUR_FORMAT)
      + ", " + PLATFORM_BRIGHTNESS + " : "
      + this.settingsMessage.get(PLATFORM_BRIGHTNESS));
    this.channel.send(this.settingsMessage)
  }
}