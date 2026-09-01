/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on StandardMethodCodec.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import { ByteBuffer } from '../../util/ByteBuffer';
import FlutterException from './FlutterException';
import Any from './Any';
import MethodCall from './MethodCall';
import SendableMethodCodec from './SendableMethodCodec';
import SendableStandardMessageCodec from './SendableStandardMessageCodec';

/**
 * A {@link SendableMethodCodec} using the Flutter standard binary encoding.
 *
 * This codec is guaranteed to be compatible with the corresponding `StandardMethodCodec`
 * on the Dart side. These parts of the Flutter SDK are evolved synchronously.
 *
 * Values supported as method arguments and result payloads are those supported by {@link StandardMessageCodec}.
 */
/**
 * A sendable MethodCodec using the Flutter standard binary encoding.
 * This codec can be used in background threads and worker contexts.
 */
@Sendable
export default class SendableStandardMethodCodec implements SendableMethodCodec {
  private static TAG: string = "SendableStandardMethodCodec";
  /** Singleton instance of SendableStandardMethodCodec. */
  public static INSTANCE: SendableStandardMethodCodec =
    new SendableStandardMethodCodec(SendableStandardMessageCodec.INSTANCE);
  private messageCodec: SendableStandardMessageCodec;

  /**
   * Creates a new method codec based on the specified message codec.
   * @param messageCodec - The SendableStandardMessageCodec to use for encoding/decoding
   */
  constructor(messageCodec: SendableStandardMessageCodec) {
    this.messageCodec = messageCodec;
  }

  /**
   * Encodes a method call into binary format.
   * @param methodCall - The MethodCall to encode
   * @returns The encoded method call as an ArrayBuffer
   */
  encodeMethodCall(methodCall: MethodCall): ArrayBuffer {
    const stream = ByteBuffer.from(new ArrayBuffer(1024));
    this.messageCodec.writeValue(stream, methodCall.method);
    this.messageCodec.writeValue(stream, methodCall.args);
    return stream.buffer;
  }

  /**
   * Decodes a method call from binary format.
   * @param methodCall - The binary message to decode
   * @returns The decoded MethodCall
   * @throws Error if the method call is corrupted
   */
  decodeMethodCall(methodCall: ArrayBuffer): MethodCall {
    const buffer = ByteBuffer.from(methodCall);
    const method: Any = this.messageCodec.readValue(buffer);
    const args: Any = this.messageCodec.readValue(buffer);
    if (typeof method == 'string' && !buffer.hasRemaining()) {
      return new MethodCall(method, args);
    }
    throw new Error("Method call corrupted");
  }

  /**
   * Encodes a successful result into a binary envelope.
   * @param result - The result value, possibly null
   * @returns The encoded envelope as an ArrayBuffer
   */
  encodeSuccessEnvelope(result: Any): ArrayBuffer {
    const stream = ByteBuffer.from(new ArrayBuffer(1024));
    stream.writeInt8(0);
    this.messageCodec.writeValue(stream, result);
    return stream.buffer;
  }

  /**
   * Encodes an error result into a binary envelope.
   * @param errorCode - The error code
   * @param errorMessage - The error message, possibly null
   * @param errorDetails - Error details, possibly null
   * @returns The encoded envelope as an ArrayBuffer
   */
  encodeErrorEnvelope(errorCode: string, errorMessage: string, errorDetails: Any): ArrayBuffer {
    const stream = ByteBuffer.from(new ArrayBuffer(1024));
    stream.writeInt8(1);
    this.messageCodec.writeValue(stream, errorCode);
    this.messageCodec.writeValue(stream, errorMessage);
    if (errorDetails instanceof Error) {
      this.messageCodec.writeValue(stream, errorDetails.stack);
    } else {
      this.messageCodec.writeValue(stream, errorDetails);
    }
    return stream.buffer;
  }

  /**
   * Encodes an error result into a binary envelope with stacktrace.
   * @param errorCode - The error code
   * @param errorMessage - The error message, possibly null
   * @param errorDetails - Error details, possibly null
   * @param errorStacktrace - The platform stacktrace, possibly null
   * @returns The encoded envelope as an ArrayBuffer
   */
  encodeErrorEnvelopeWithStacktrace(errorCode: string, errorMessage: string, errorDetails: Any,
    errorStacktrace: string): ArrayBuffer {
    const stream = ByteBuffer.from(new ArrayBuffer(1024));
    stream.writeInt8(1);
    this.messageCodec.writeValue(stream, errorCode);
    this.messageCodec.writeValue(stream, errorMessage);
    if (errorDetails instanceof Error) {
      this.messageCodec.writeValue(stream, errorDetails.stack);
    } else {
      this.messageCodec.writeValue(stream, errorDetails);
    }
    this.messageCodec.writeValue(stream, errorStacktrace);
    return stream.buffer;
  }

  /**
   * Decodes a result envelope from binary format.
   * @param envelope - The binary envelope to decode
   * @returns The decoded result value
   * @throws FlutterException if the envelope contains an error
   * @throws Error if the envelope is corrupted
   */
  decodeEnvelope(envelope: ArrayBuffer): Any {
    const buffer = ByteBuffer.from(envelope);
    const flag = buffer.readInt8();
    switch (flag) {
      case 0: {
        const result: Any = this.messageCodec.readValue(buffer);
        if (!buffer.hasRemaining()) {
          return result;
        }
        // Falls through intentionally.
      }
      case 1: {
        const code: Any = this.messageCodec.readValue(buffer);
        const message: Any = this.messageCodec.readValue(buffer);
        const details: Any = this.messageCodec.readValue(buffer);
        if (typeof code == 'string' && (message == null || typeof message == 'string') && !buffer.hasRemaining()) {
          throw new FlutterException(code, message, details);
        }
      }
    }
    throw new Error("Envelope corrupted");
  }
}