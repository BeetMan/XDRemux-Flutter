/*
* Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_HW file.
*/

import DartExecutor from '../dart/DartExecutor';
import { BinaryMessenger } from '../../../plugin/common/BinaryMessenger';
import MethodChannel from '../../../plugin/common/MethodChannel';
import JSONMethodCodec from '../../../plugin/common/JSONMethodCodec';

export default class StatusBarClickChannel {
  private static CHANNEL_NAME = "flutter/status_bar";
  private channel: MethodChannel;

  constructor(binaryMessenger: BinaryMessenger) {
    this.channel = new MethodChannel(binaryMessenger, StatusBarClickChannel.CHANNEL_NAME, JSONMethodCodec.INSTANCE);
  }
  sendClick() {
    this.channel.invokeMethod('handleScrollToTop', null);
  }
}