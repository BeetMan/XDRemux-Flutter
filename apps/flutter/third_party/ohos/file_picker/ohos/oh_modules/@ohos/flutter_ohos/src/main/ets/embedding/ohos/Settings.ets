/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import SettingsChannel, { PlatformBrightness } from '../engine/systemchannels/SettingsChannel'
import I18n from '@ohos.i18n'
import Log from '../../util/Log';
import { MediaQuery } from '@ohos.arkui.UIContext';


const TAG = "Settings";

/**
 * Manages and sends system settings to Flutter.
 * This class handles theme mode, text scale factor, and other system preferences.
 */
export default class Settings {
  /** The SettingsChannel for sending settings to Flutter, or null if not set. */
  settingsChannel: SettingsChannel | null;

  /**
   * Constructs a new Settings instance.
   * @param settingsChannel - The SettingsChannel instance, or null
   */
  constructor(settingsChannel: SettingsChannel | null) {
    this.settingsChannel = settingsChannel;
  }

  /**
   * Sends current system settings to Flutter.
   * @param mediaQuery - The MediaQuery instance for detecting theme mode
   */
  sendSettings(mediaQuery: MediaQuery): void {
    this.settingsChannel?.startMessage()
      .setAlwaysUse24HourFormat(I18n.System.is24HourClock())
      .setNativeSpellCheckServiceDefined(false)
      .setBrieflyShowPassword(false)
      .setPlatformBrightness(this.getThemeMode(mediaQuery))
      .setTextScaleFactor(this.getTextScaleFactor())
      .send();
  }

  /**
   * Gets the current theme mode (light or dark).
   * @param mediaQuery - The MediaQuery instance for detecting dark mode
   * @returns The platform brightness mode
   */
  getThemeMode(mediaQuery: MediaQuery): PlatformBrightness {

    let listener = mediaQuery.matchMediaSync('(dark-mode: true)');
    if (listener.matches) {
      Log.i(TAG, "return dark");
      return PlatformBrightness.DARK;
    } else {
      Log.i(TAG, "return light");
      return PlatformBrightness.LIGHT;
    }
  }

  /**
   * Gets the text scale factor from system settings.
   * @returns The text scale factor value
   */
  getTextScaleFactor() : number {
    let sysTextScaleFactor = AppStorage.get<number>('fontSizeScale');
    if(sysTextScaleFactor == undefined) {
      sysTextScaleFactor = 1.0;
      Log.e(TAG, 'get textScaleFactor error, it is assigned to ' + JSON.stringify(sysTextScaleFactor));
    }
    Log.i(TAG, "return textScaleFactor = " + JSON.stringify(sysTextScaleFactor))
    return sysTextScaleFactor;
  }

}