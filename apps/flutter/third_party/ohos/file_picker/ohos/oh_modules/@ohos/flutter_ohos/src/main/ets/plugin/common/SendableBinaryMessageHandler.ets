/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/
import { lang } from '@kit.ArkTS';
import { BinaryReply } from './BinaryMessenger';

type ISendable = lang.ISendable;

/**
 * Interface for sendable binary message handlers that can be used in background threads.
 * This interface extends ISendable to allow handlers to be passed across thread boundaries.
 */
export default interface SendableBinaryMessageHandler extends ISendable {
  /**
   * Handles a binary message received from Flutter.
   * @param message - The binary message received
   * @param reply - The reply callback to send a response
   * @param args - Additional arguments passed to the handler
   */
  onMessage(message: ArrayBuffer, reply: BinaryReply, ...args: Object[]): void;
}
