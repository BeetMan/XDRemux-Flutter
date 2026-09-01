/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import SensitiveContentChannel, { SensitiveContentMethodHandler } from '../../embedding/engine/systemchannels/SensitiveContentChannel';
import Log from '../../util/Log';
import { BusinessError } from '@kit.BasicServicesKit';
import window from '@ohos.window';

import {
  SENSITIVE_CONTENT_SENSITIVITY,
  NOT_SENSITIVE_CONTENT_SENSITIVITY,
} from '../../embedding/engine/systemchannels/SensitiveContentChannel';
const TAG = "SensitiveContentChannel";
export default class SensitiveContentPlugin implements SensitiveContentMethodHandler {
  private readonly sensitiveContentChannel: SensitiveContentChannel;
  private currentContentSensitivity: number = NOT_SENSITIVE_CONTENT_SENSITIVITY;

  constructor(
    sensitiveContentChannel: SensitiveContentChannel
  ) {
    this.sensitiveContentChannel = sensitiveContentChannel;
    this.sensitiveContentChannel.setSensitiveContentMethodHandler(this);
  }

  setContentSensitivity(requestedContentSensitivity: number): void {
    let isPrivacyMode: boolean;
    switch (requestedContentSensitivity) {
      case SENSITIVE_CONTENT_SENSITIVITY:
        isPrivacyMode = true;
        break;
      case NOT_SENSITIVE_CONTENT_SENSITIVITY:
        isPrivacyMode = false;
        break;
      default:
        isPrivacyMode = false;
        requestedContentSensitivity = NOT_SENSITIVE_CONTENT_SENSITIVITY;
        break;
    }
    if (this.currentContentSensitivity === requestedContentSensitivity) {
      // Content sensitivity for the requested View already set to requestedContentSensitivity.
      return;
    }
    try {
      window.getLastWindow(getContext(), (err: BusinessError, data) => {
        const errCode = err.code;
        if (errCode) {
          return;
        }
        // Set requestedContentSensitivity on the View.
        let promise = data.setWindowPrivacyMode(isPrivacyMode);
        promise.then(() => {
          Log.d(TAG, "success to set the window to privacy mode.");
          this.currentContentSensitivity = requestedContentSensitivity;
        }).catch((err: BusinessError) => {
          Log.e(TAG, "Failed to set the window to privacy mode. Cause: " + JSON.stringify(err));
        });
      })
    } catch (exception) {
      Log.e(TAG, "Exception when setting window privacy mode: " + JSON.stringify(exception));
    }
  }

  getContentSensitivity(): number {
   return this.currentContentSensitivity;
  }

  isSupported(): boolean {
    return true;
  }

  destroy(): void {
    this.sensitiveContentChannel.setSensitiveContentMethodHandler(null);
  }
}

