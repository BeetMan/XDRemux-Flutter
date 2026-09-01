/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on MessageCodec.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

/**
 * A message encoding/decoding mechanism.
 * @template T - The type of message being encoded/decoded
 */
export default interface MessageCodec<T> {
  /**
   * Encodes the specified message into binary.
   * @param message - The message to encode
   * @returns The encoded message as an ArrayBuffer
   */
  encodeMessage(message: T): ArrayBuffer;

  /**
   * Decodes the specified message from binary.
   * @param message - The binary message to decode, possibly null
   * @returns The decoded message
   */
  decodeMessage(message: ArrayBuffer | null): T;
}
