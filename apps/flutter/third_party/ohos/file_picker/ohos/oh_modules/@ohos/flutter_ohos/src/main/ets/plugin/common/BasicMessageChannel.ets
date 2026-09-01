/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on BasicMessageChannel.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import MessageChannelUtils from '../../util/MessageChannelUtils';
import { BinaryMessageHandler } from './BinaryMessenger';
import Log from '../../util/Log';
import { BinaryReply } from './BinaryMessenger';
import { TaskQueue } from './BinaryMessenger';
import MessageCodec from './MessageCodec';
import { BinaryMessenger } from './BinaryMessenger';
import StringUtils from '../../util/StringUtils';

/**
 * A named channel for communicating with the Flutter application using basic, asynchronous message
 * passing.
 *
 * Messages are encoded into binary before being sent, and binary messages received are decoded
 * into objects. The {@link MessageCodec} used must be compatible with the one used by the
 * Flutter application. This can be achieved by creating a `BasicMessageChannel`
 * counterpart of this channel on the Dart side. The static type of messages sent and received
 * is `Object`, but only values supported by the specified {@link MessageCodec} can be used.
 *
 * The logical identity of the channel is given by its name. Identically named channels will
 * interfere with each other's communication.
 */
export default class BasicMessageChannel<T> {
  /** Tag for logging. */
  public static TAG = "BasicMessageChannel#";
  /** Channel name for buffer management. */
  public static CHANNEL_BUFFERS_CHANNEL = "dev.flutter/channel-buffers";
  private messenger: BinaryMessenger;
  private name: string;
  private codec: MessageCodec<T>;

  /**
   * Constructs a new BasicMessageChannel instance.
   * @param messenger - The BinaryMessenger to use for communication
   * @param name - The channel name
   * @param codec - The MessageCodec to use for encoding/decoding messages
   */
  constructor(messenger: BinaryMessenger, name: string, codec: MessageCodec<T>) {
    this.messenger = messenger
    this.name = name
    this.codec = codec
  }

  /**
   * Sends the specified message to the Flutter application, optionally expecting a reply.
   *
   * Any uncaught exception thrown by the reply callback will be caught and logged.
   *
   * @param message - The message, possibly null
   * @param callback - A {@link Reply} callback, possibly null
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
   * @param handler - A {@link MessageHandler}, or null to deregister
   */
  setMessageHandler(handler: MessageHandler<T> | null): void {
    this.messenger.setMessageHandler(this.name,
      handler == null ? null : new IncomingMessageHandler(handler, this.codec));
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
 * Interface for handling message replies in BasicMessageChannel.
 * @template T - The type of message being replied to
 */
export interface Reply<T> {
  /**
   * Handles the specified message reply.
   *
   * @param reply - The reply, possibly null
   */
  reply: (reply: T) => void;
}

/**
 * Interface for handling incoming messages in BasicMessageChannel.
 * @template T - The type of message being handled
 */
export interface MessageHandler<T> {

  /**
   * Handles the specified message received from Flutter.
   *
   * Handler implementations must reply to all incoming messages, by submitting a single reply
   * message to the given {@link Reply}. Failure to do so will result in lingering Flutter reply
   * handlers. The reply may be submitted asynchronously and invoked on any thread.
   *
   * Any uncaught exception thrown by this method, or the preceding message decoding, will be
   * caught by the channel implementation and logged, and a null reply message will be sent back
   * to Flutter.
   *
   * Any uncaught exception thrown during encoding a reply message submitted to the {@link Reply}
   * is treated similarly: the exception is logged, and a null reply is sent to Flutter.
   *
   * @param message - The message, possibly null
   * @param reply - A {@link Reply} for sending a single message reply back to Flutter
   */
  onMessage(message: T, reply: Reply<T>): void;
}

/**
 * Internal handler for incoming replies from Flutter.
 * @template T - The type of message being handled
 */
class IncomingReplyHandler<T> implements BinaryReply {
  private callback: (reply: T) => void;
  private codec: MessageCodec<T>

  /**
   * Constructs a new IncomingReplyHandler instance.
   * @param callback - The callback to invoke with the decoded reply
   * @param codec - The MessageCodec to use for decoding
   */
  constructor(callback: (reply: T) => void, codec: MessageCodec<T>) {
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
      Log.e(BasicMessageChannel.TAG, "Failed to handle message reply", e);
    }
  }
}

/**
 * Internal handler for incoming messages from Flutter.
 * @template T - The type of message being handled
 */
class IncomingMessageHandler<T> implements BinaryMessageHandler {
  private handler: MessageHandler<T>
  private codec: MessageCodec<T>

  /**
   * Constructs a new IncomingMessageHandler instance.
   * @param handler - The MessageHandler to delegate to
   * @param codec - The MessageCodec to use for encoding/decoding
   */
  constructor(handler: MessageHandler<T>, codec: MessageCodec<T>) {
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
      Log.e(BasicMessageChannel.TAG, "Failed to handle message", e);
      callback.reply(StringUtils.stringToArrayBuffer(""));
    }
  }
}
