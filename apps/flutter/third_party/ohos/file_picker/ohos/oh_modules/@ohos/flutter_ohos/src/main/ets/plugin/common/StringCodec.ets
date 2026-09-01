/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on StringCodec.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import StringUtils from '../../util/StringUtils';
import MessageCodec from './MessageCodec';

/**
 * A {@link MessageCodec} using UTF-8 encoded String messages.
 *
 * This codec is guaranteed to be compatible with the corresponding `StringCodec` on the
 * Dart side. These parts of the Flutter SDK are evolved synchronously.
 */
export default class StringCodec implements MessageCodec<string> {
  /** Singleton instance of StringCodec. */
  static readonly INSTANCE = new StringCodec();

  /**
   * Encodes a string message into binary format.
   * @param message - The string message to encode, possibly null
   * @returns The encoded message as an ArrayBuffer
   */
  encodeMessage(message: string): ArrayBuffer {
    if (message == null) {
      return StringUtils.stringToArrayBuffer("");
    }
    return StringUtils.stringToArrayBuffer(message);
  }

  /**
   * Decodes a binary message into a string.
   * @param message - The binary message to decode, possibly null
   * @returns The decoded string
   */
  decodeMessage(message: ArrayBuffer | null): string {
    if (message == null) {
      return "";
    }
    return StringUtils.arrayBufferToString(message);
  }
}