/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on MethodChannel.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import Log from '../../util/Log';
import MessageChannelUtils from '../../util/MessageChannelUtils';
import StringUtils from '../../util/StringUtils';
import { BinaryMessageHandler, BinaryMessenger, BinaryReply } from './BinaryMessenger';
import Any from './Any';
import MethodCall from './MethodCall';
import MethodCodec from './MethodCodec';
import StandardMethodCodec from './StandardMethodCodec';

/**
 * A named channel for communicating with the Flutter application using asynchronous method calls.
 *
 * Incoming method calls are decoded from binary on receipt, and results are encoded into
 * binary before being transmitted back to Flutter. The {@link MethodCodec} used must be compatible
 * with the one used by the Flutter application. This can be achieved by creating a `MethodChannel` counterpart of this
 * channel on the Dart side. The type of method call arguments and results is {@code Any},
 * but only values supported by the specified {@link MethodCodec} can be used.
 *
 * The logical identity of the channel is given by its name. Identically named channels will
 * interfere with each other's communication.
 */

export default class MethodChannel {
  /** Tag for logging. */
  static TAG = "MethodChannel#";
  private messenger: BinaryMessenger;
  private name: string;
  private codec: MethodCodec;

  /**
   * Constructs a new MethodChannel instance.
   * @param messenger - The BinaryMessenger to use for communication
   * @param name - The channel name
   * @param codec - The MethodCodec to use for encoding/decoding, defaults to StandardMethodCodec.INSTANCE
   */
  constructor(messenger: BinaryMessenger, name: string, codec: MethodCodec = StandardMethodCodec.INSTANCE) {
    this.messenger = messenger
    this.name = name
    this.codec = codec
  }

  /**
   * Invokes a method on this channel, optionally expecting a result.
   *
   * Any uncaught exception thrown by the result callback will be caught and logged.
   *
   * @param method - The name of the method
   * @param args - The arguments for the invocation, possibly null
   * @param callback - A {@link MethodResult} callback for the invocation result, or null
   */
  invokeMethod(method: string, args: Any, callback?: MethodResult): void {
    this.messenger.send(this.name, this.codec.encodeMethodCall(new MethodCall(method, args)),
      callback == null ? null : new IncomingResultHandler(callback, this.codec));
  }

  /**
   * Registers a method call handler on this channel.
   *
   * Overrides any existing handler registration for (the name of) this channel.
   *
   * If no handler has been registered, any incoming method call on this channel will be handled
   * silently by sending a null reply. This results in a `MissingPluginException` on the Dart side, unless an
   * `OptionalMethodChannel` is used.
   * 
   * @param handler - A {@link MethodCallHandler}, or null to deregister
   */
  setMethodCallHandler(handler: MethodCallHandler | null): void {
    this.messenger.setMessageHandler(this.name,
      handler == null ? null : new IncomingMethodCallHandler(handler, this.codec));
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

/** A handler of incoming method calls. */
export interface MethodCallHandler {
  /**
   * Handles the specified method call received from Flutter.
   *
   * Handler implementations must submit a result for all incoming calls, by making a single
   * call on the given {@link MethodResult} callback. Failure to do so will result in lingering Flutter
   * result handlers. The result may be submitted asynchronously and on any thread. Calls to
   * unknown or unimplemented methods should be handled using the notImplemented method of {@link MethodResult}.
   *
   * Any uncaught exception thrown by this method will be caught by the channel implementation
   * and logged, and an error result will be sent back to Flutter.
   *
   * The handler is called on the platform thread (OpenHarmony main thread) by default, or otherwise on the thread
   * specified by the {@link TaskQueue} provided to the associated {@link MethodChannel} when it was created.
   *
   * @param call - A {@link MethodCall}
   * @param result - A {@link MethodResult} used for submitting the result of the call
   */
  onMethodCall(call: MethodCall, result: MethodResult): void;
}

/**
 * Method call result callback. Supports dual use: Implementations of methods to be invoked by
 * Flutter act as clients of this interface for sending results back to Flutter. Invokers of
 * Flutter methods provide implementations of this interface for handling results received from
 * Flutter.
 *
 * All methods of this class can be invoked on any thread.
 */
export interface MethodResult {
  /**
   * Handles a successful result.
   *
   * @param result - The result, possibly null. The result must be an Object type supported by the
   *     codec. For instance, if you are using {@link StandardMessageCodec} (default), please see
   *     its documentation on what types are supported.
   */
  success: (result: Any) => void;

  /**
   * Handles an error result.
   *
   * @param errorCode - An error code string
   * @param errorMessage - A human-readable error message, possibly null
   * @param errorDetails - Error details, possibly null. The details must be an Object type
   *     supported by the codec. For instance, if you are using {@link StandardMessageCodec}
   *     (default), please see its documentation on what types are supported.
   */
  error: (errorCode: string, errorMessage: string, errorDetails: Any) => void;

  /** Handles a call to an unimplemented method. */
  notImplemented: () => void;
}

/**
 * Internal handler for incoming method call results from Flutter.
 */
export class IncomingResultHandler implements BinaryReply {
  private callback: MethodResult;
  private codec: MethodCodec;

  /**
   * Constructs a new IncomingResultHandler instance.
   * @param callback - The MethodResult callback to invoke
   * @param codec - The MethodCodec to use for decoding
   */
  constructor(callback: MethodResult, codec: MethodCodec) {
    this.callback = callback;
    this.codec = codec
  }

  /**
   * Handles a binary reply from Flutter.
   * @param reply - The binary reply, possibly null
   */
  reply(reply: ArrayBuffer | null): void {
    try {
      if (reply == null) {
        this.callback.notImplemented();
      } else {
        try {
          this.callback.success(this.codec.decodeEnvelope(reply));
        } catch (e) {
          this.callback.error(e.code, e.getMessage(), e.details);
        }
      }
    } catch (e) {
      Log.e(MethodChannel.TAG, "Failed to handle method call result", e);
    }
  }
}

/**
 * Internal handler for incoming method calls from Flutter.
 */
export class IncomingMethodCallHandler implements BinaryMessageHandler {
  private handler: MethodCallHandler;
  private codec: MethodCodec;

  /**
   * Constructs a new IncomingMethodCallHandler instance.
   * @param handler - The MethodCallHandler to delegate to
   * @param codec - The MethodCodec to use for encoding/decoding
   */
  constructor(handler: MethodCallHandler, codec: MethodCodec) {
    this.handler = handler;
    this.codec = codec
  }

  /**
   * Handles a binary method call from Flutter.
   * @param message - The binary message containing the method call
   * @param reply - The BinaryReply callback to send a response
   */
  onMessage(message: ArrayBuffer, reply: BinaryReply): void {
    const call = this.codec.decodeMethodCall(message);
    try {
      this.handler.onMethodCall(
        call, {
        success: (result: Any): void => {
          reply.reply(this.codec.encodeSuccessEnvelope(result));
        },

        error: (errorCode: string, errorMessage: string, errorDetails: Any): void => {
          reply.reply(this.codec.encodeErrorEnvelope(errorCode, errorMessage, errorDetails));
        },

        notImplemented: (): void => {
          Log.w(MethodChannel.TAG, "method not implemented");
          reply.reply(null);
        }
      });
    } catch (e) {
      Log.e(MethodChannel.TAG, "Failed to handle method call", e);
      const errMsg = e instanceof Error ? (e.message ?? '') : String(e);
      const errStack = e instanceof Error ? (e.stack ?? '') : '';
      reply.reply(this.codec.encodeErrorEnvelopeWithStacktrace("error", errMsg, null, errStack));
    }
  }
}
