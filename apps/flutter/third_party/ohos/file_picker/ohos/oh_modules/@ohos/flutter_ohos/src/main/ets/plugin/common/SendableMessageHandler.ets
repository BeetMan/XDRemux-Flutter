/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/
import { lang } from '@kit.ArkTS';
import { Reply } from './BasicMessageChannel';

type ISendable = lang.ISendable;

/**
 * Interface for sendable message handlers that can be used in background threads.
 * This interface extends ISendable to allow handlers to be passed across thread boundaries.
 * @template T - The type of message being handled
 */
export default interface SendableMessageHandler<T> extends ISendable {
  /**
   * Handles a message received from Flutter.
   * @param message - The message received
   * @param reply - The reply callback to send a response
   */
  onMessage(message: T, reply: Reply<T>): void;
}
