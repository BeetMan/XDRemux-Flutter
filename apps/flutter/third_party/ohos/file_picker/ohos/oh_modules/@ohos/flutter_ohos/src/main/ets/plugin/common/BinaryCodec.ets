/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on BinaryCodec.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import MessageCodec from './MessageCodec';

/**
 * A {@link MessageCodec} using unencoded binary messages, represented as {@link ArrayBuffer}s.
 *
 * This codec is guaranteed to be compatible with the corresponding `BinaryCodec` on the Dart side.
 * These parts of the Flutter SDK are evolved synchronously.
 *
 * On the Dart side, messages are represented using {@code ByteData}.
 */

export default class BinaryCodec implements MessageCodec<ArrayBuffer> {
  private returnsDirectByteBufferFromDecoding: boolean = false;
  /** Direct instance that returns the direct buffer from decoding. */
  static readonly INSTANCE_DIRECT = new BinaryCodec(true);

  /**
   * Constructs a new BinaryCodec instance.
   * @param returnsDirectByteBufferFromDecoding - Whether to return the direct buffer from decoding
   */
  constructor(returnsDirectByteBufferFromDecoding: boolean) {
    this.returnsDirectByteBufferFromDecoding = returnsDirectByteBufferFromDecoding;
  }

  /**
   * Encodes a binary message (no-op for binary codec).
   * @param message - The ArrayBuffer message to encode
   * @returns The same ArrayBuffer
   */
  encodeMessage(message: ArrayBuffer): ArrayBuffer {
    return message
  }

  /**
   * Decodes a binary message.
   * @param message - The ArrayBuffer message to decode, possibly null
   * @returns The decoded ArrayBuffer, or a copy depending on configuration
   */
  decodeMessage(message: ArrayBuffer | null): ArrayBuffer {
    if (message == null) {
      return new ArrayBuffer(0);
    } else if (this.returnsDirectByteBufferFromDecoding) {
      return message;
    } else {
      return message.slice(0, message.byteLength);
    }
  }
}