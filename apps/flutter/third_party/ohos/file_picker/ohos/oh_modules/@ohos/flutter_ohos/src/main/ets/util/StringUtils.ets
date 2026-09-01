/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import flutter from 'libflutter.so'

/**
 * Utility class for string operations.
 * Provides methods for converting between strings and ArrayBuffer/Uint8Array.
 */
export default class StringUtils {

  /**
   * Converts a string to an ArrayBuffer using UTF-8 encoding.
   * @param str - The string to convert.
   * @returns The ArrayBuffer containing the UTF-8 encoded string.
   */
  static stringToArrayBuffer(str: string): ArrayBuffer {
    if (str.length == 0) {
      return new ArrayBuffer(0);
    }
    return flutter.nativeEncodeUtf8(str).buffer;
  }

  /**
   * Converts an ArrayBuffer to a string using UTF-8 decoding.
   * @param buffer - The ArrayBuffer to convert.
   * @returns The decoded string, or empty string if buffer is empty.
   */
  static arrayBufferToString(buffer: ArrayBuffer): string {
    if (buffer.byteLength <= 0) {
      return "";
    }
    return flutter.nativeDecodeUtf8(new Uint8Array(buffer));
  }

  /**
   * Converts a Uint8Array to a string using UTF-8 decoding.
   * @param buffer - The Uint8Array to convert.
   * @returns The decoded string, or empty string if buffer is empty.
   */
  static uint8ArrayToString(buffer: Uint8Array): string {
    if (buffer.length <= 0) {
      return "";
    }
    return flutter.nativeDecodeUtf8(buffer);
  }

  /**
   * Checks if a string is not empty.
   * @param str - The string to check.
   * @returns True if the string is not null and has length > 0, false otherwise.
   */
  static isNotEmpty(str: string): boolean {
    return str != null && str.length > 0;
  }

  /**
   * Checks if a string is empty.
   * @param str - The string to check
   * @returns True if the string is null, undefined, or has length 0, false otherwise.
   */
  static isEmpty(str: string): boolean {
    return (!str) || str.length == 0;
  }
}