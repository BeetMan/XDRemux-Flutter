/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import BasicMessageChannel from '../plugin/common/BasicMessageChannel';
import { BinaryMessenger } from '../plugin/common/BinaryMessenger';
import StringUtils from './StringUtils';

/**
 * Utility class for message channel operations.
 */
export default class MessageChannelUtils {
  /**
   * Resizes a channel buffer.
   * @param messenger - The BinaryMessenger to use
   * @param channel - The channel name
   * @param newSize - The new buffer size
   */
  static resizeChannelBuffer(messenger: BinaryMessenger, channel: string, newSize: number) {
    const dataStr = `resize\r${channel}\r${newSize}`
    messenger.send(BasicMessageChannel.CHANNEL_BUFFERS_CHANNEL, StringUtils.stringToArrayBuffer(dataStr));
  }
}