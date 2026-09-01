/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/
import MessageChannelUtils from '../../util/MessageChannelUtils';
import Log from '../../util/Log';
import { BinaryReply } from './BinaryMessenger';
import { TaskQueue } from './BinaryMessenger';
import MessageCodec from './MessageCodec';
import { BinaryMessenger } from './BinaryMessenger';
import SendableBinaryMessageHandler from './SendableBinaryMessageHandler'
import SendableMessageCodec from './SendableMessageCodec';
import SendableMessageHandler from './SendableMessageHandler';
import StringUtils from '../../util/StringUtils';

/**
 * A named channel for communicating with Flutter using basic, asynchronous message passing
 * on background threads. This channel uses sendable codecs that can be passed across thread boundaries.
 *
 * Messages are encoded into binary before being sent, and binary messages received are decoded
 * into objects. The {@link SendableMessageCodec} used must be compatible with the one used by the
 * Flutter application. This can be achieved by creating a `BasicMessageChannel` counterpart of this channel
 * on the Dart side. The type of messages sent and received
 * is {@code Any}, but only values supported by the specified {@link SendableMessageCodec} can be used.
 *
 * The logical identity of the channel is given by its name. Identically named channels will
 * interfere with each other's communication.
 * @template T - The type of message being sent/received
 */
export default class BackgroundBasicMessageChannel<T> {
  /** Tag for logging. */
  public static TAG = "BackgroundBasicMessageChannel#";
  /** Channel name for buffer management. */
  public static CHANNEL_BUFFERS_CHANNEL = "dev.flutter/channel-buffers";
  private messenger: BinaryMessenger;
  private name: string;
  private codec: SendableMessageCodec<T>;
  private taskQueue: TaskQueue;

  /**
   * Constructs a new BackgroundBasicMessageChannel instance.
   * @param messenger - The BinaryMessenger to use for communication
   * @param name - The channel name
   * @param codec - The SendableMessageCodec to use for encoding/decoding messages
   * @param taskQueue - Optional TaskQueue for background processing, defaults to a new background task queue
   */
  constructor(messenger: BinaryMessenger, name: string, codec: SendableMessageCodec<T>, taskQueue?: TaskQueue) {
    this.messenger = messenger
    this.name = name
    this.codec = codec
    this.taskQueue = taskQueue ?? messenger.makeBackgroundTaskQueue()
  }

  /**
   * Sends the specified message to the Flutter application, optionally expecting a reply.
   *
   * Any uncaught exception thrown by the reply callback will be caught and logged.
   *
   * @param message - The message, possibly null
   * @param callback - A reply callback, possibly null
   */
  send(message: T, callback?: (reply: T) => void): void {
    this.messenger.send(this.name, this.codec.encodeMessage(message),
      callback == null ? null : new IncomingReplyHandler(callback, this.codec));
  }

  /**
   * Registers a message handler on this channel for receiving messages sent from the Flutter
   * application.
   *
   * Overrides any existing handler registration for (the name of) this channel.
   *
   * If no handler has been registered, any incoming message on this channel will be handled
   * silently by sending a null reply.
   *
   * @param handler - A {@link SendableMessageHandler}, or null to deregister
   */
  setMessageHandler(handler: SendableMessageHandler<T> | null): void {
    this.messenger.setMessageHandler(this.name,
      handler == null ? null : new IncomingSendableMessageHandler(handler, this.codec), this.taskQueue);
  }

  /**
   * Adjusts the number of messages that will get buffered when sending messages to channels that
   * aren't fully set up yet. For example, the engine isn't running yet or the channel's message
   * handler isn't set up on the Dart side yet.
   * @param newSize - The new buffer size
   */
  resizeChannelBuffer(newSize: number): void {
    MessageChannelUtils.resizeChannelBuffer(this.messenger, this.name, newSize);
  }
}


/**
 * Internal handler for incoming replies from Flutter in background threads.
 * @template T - The type of message being handled
 */
class IncomingReplyHandler<T> implements BinaryReply {
  private callback: (reply: T) => void;
  private codec: SendableMessageCodec<T>

  /**
   * Constructs a new IncomingReplyHandler instance.
   * @param callback - The callback to invoke with the decoded reply
   * @param codec - The SendableMessageCodec to use for decoding
   */
  constructor(callback: (reply: T) => void, codec: SendableMessageCodec<T>) {
    this.callback = callback
    this.codec = codec
  }

  /**
   * Handles a binary reply from Flutter.
   * @param reply - The binary reply, possibly null
   */
  reply(reply: ArrayBuffer | null) {
    try {
      this.callback(this.codec.decodeMessage(reply));
    } catch (e) {
      Log.e(BackgroundBasicMessageChannel.TAG, "Failed to handle message reply", e);
    }
  }
}

/**
 * Internal handler for incoming messages from Flutter in background threads.
 * @template T - The type of message being handled
 */
@Sendable
class IncomingSendableMessageHandler<T> implements SendableBinaryMessageHandler {
  private handler: SendableMessageHandler<T>
  private codec: SendableMessageCodec<T>

  /**
   * Constructs a new IncomingSendableMessageHandler instance.
   * @param handler - The SendableMessageHandler to delegate to
   * @param codec - The SendableMessageCodec to use for encoding/decoding
   */
  constructor(handler: SendableMessageHandler<T>, codec: SendableMessageCodec<T>) {
    this.handler = handler;
    this.codec = codec
  }

  /**
   * Handles a binary message from Flutter.
   * @param message - The binary message
   * @param callback - The BinaryReply callback to send a response
   */
  onMessage(message: ArrayBuffer, callback: BinaryReply) {
    try {
      this.handler.onMessage(
        this.codec.decodeMessage(message),
        {
          reply: (reply: T): void => {
            callback.reply(this.codec.encodeMessage(reply));
          }
        });
    } catch (e) {
      Log.e('WARNNING', "Failed to handle message: ", e);
      callback.reply(StringUtils.stringToArrayBuffer(""));
    }
  }
}