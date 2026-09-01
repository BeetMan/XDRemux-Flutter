/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import BasicMessageChannel, { MessageHandler, Reply } from '../../../plugin/common/BasicMessageChannel';
import JSONMessageCodec from '../../../plugin/common/JSONMessageCodec';
import DartExecutor from '../dart/DartExecutor';
import Log from '../../../util/Log';

const TAG = "TestChannel"

/**
 * Test channel for Flutter testing purposes.
 * This channel provides a simple echo mechanism for testing message passing.
 */
export default class TestChannel {
  private channel: BasicMessageChannel<String>;

  /**
   * Constructs a new TestChannel instance.
   * @param dartExecutor - The DartExecutor for sending messages to Dart
   */
  constructor(dartExecutor: DartExecutor) {
    this.channel = new BasicMessageChannel<String>(dartExecutor, "flutter/test", JSONMessageCodec.INSTANCE);
    let callback = new MessageCallback();
    this.channel.setMessageHandler(callback);
  }
}

/**
 * Message callback handler for the test channel.
 */
class MessageCallback implements MessageHandler<string> {
  /**
   * Handles incoming messages and echoes them back.
   * @param message - The message received from Dart
   * @param reply - The reply callback to send a response
   */
  onMessage(message: string, reply: Reply<string>) {
    Log.d(TAG, "receive msg = " + message);
    reply.reply("收到消息啦：" + message);
  }
}