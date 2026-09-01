/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on LocalizationPlugin.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import LocalizationChannel, {
  LocalizationMessageHandler
} from '../../embedding/engine/systemchannels/LocalizationChannel'
import common from '@ohos.app.ability.common';
import intl from '@ohos.intl';
import Log from '../../util/Log';
import i18n from '@ohos.i18n';

const TAG = "LocalizationPlugin";

/**
 * Plugin for handling localization in Flutter applications.
 * This class manages the interaction between Flutter's localization system
 * and the OpenHarmony resource management system.
 */
export default class LocalizationPlugin {
  private localizationChannel: LocalizationChannel;
  private context: common.Context;

  /**
   * Converts a locale string to an intl.Locale object.
   * @param localeString - The locale string (e.g., "en_US" or "zh-CN")
   * @returns The corresponding intl.Locale object
   */
  localeFromString(localeString: string): intl.Locale {
    localeString = localeString.replace('_', '-');
    let parts: string[] = localeString.split('-', -1);
    let languageCode = parts[0];
    let scriptCode = "";
    let countryCode = "";
    let index: number = 1;

    if (parts.length > index && parts[index].length == 4) {
      scriptCode = parts[index];
      index++;
    }

    if (parts.length > index && parts[index].length >= 2 && parts[index].length <= 3) {
      countryCode = parts[index];
      index++;
    }
    return new intl.Locale(languageCode + '-' + countryCode + '-' + scriptCode);
  }

  private localizationMessageHandler: LocalizationMessageHandler =
    new enterGetStringResource((key: string, localeString: string | null) => {

      Log.i(TAG, "getStringResource,key: " + key + ",localeString: " + localeString);
      let localContext: common.Context = this.context;
      let stringToReturn: string | null = null;
      // 获取资源管理器
      let resMgr = localContext.resourceManager;

      try {
        // 如果localeString不为空，则更新为指定地区的资源管理器
        if (localeString) {
          let overrideConfig = resMgr.getOverrideConfiguration();
          overrideConfig.locale = localeString;
          let overrideResMgr = resMgr.getOverrideResourceManager(overrideConfig);
          stringToReturn = overrideResMgr.getStringByNameSync(key);
        } else {
          stringToReturn = resMgr.getStringByNameSync(key);
        }
      } catch (e) {
        Log.e(TAG, e);
        return null;
      }

      return stringToReturn;
    })

  /**
   * Constructs a new LocalizationPlugin instance.
   * @param context - The application context
   * @param localizationChannel - The LocalizationChannel for communication with Flutter
   */
  constructor(context: common.Context, localizationChannel: LocalizationChannel) {
    this.context = context;
    this.localizationChannel = localizationChannel;
    this.localizationChannel.setLocalizationMessageHandler(this.localizationMessageHandler);
  }

  /**
   * Sends the system locale to Flutter.
   */
  sendLocaleToFlutter(): void {
    let systemLocale: string = i18n.System.getSystemLocale();
    let data: Array<string> = [];
    data.push(systemLocale);
    this.localizationChannel.sendLocales(data);
  }

  /**
   * Called when the application locale is changed via dart:ui setApplicationLocale.
   * @param locale - The application locale in BCP 47 format
   */
  onApplicationLocaleChanged(locale: string): void {
    Log.i(TAG, "onApplicationLocaleChanged: " + locale);
  }
}

/**
 * Implementation of LocalizationMessageHandler for getting string resources.
 */
class enterGetStringResource {
  /**
   * The function to get string resources.
   * @param key - The resource key
   * @param localeString - The locale string, or null to use the default locale
   * @returns The localized string, or null if not found
   */
  getStringResource: (key: string, localeString: string | null) => string | null

  /**
   * Constructs a new enterGetStringResource instance.
   * @param getStringResource - The function to get string resources
   */
  constructor(getStringResource: (key: string, localeString: string | null) => string | null) {
    this.getStringResource = getStringResource
  }
}