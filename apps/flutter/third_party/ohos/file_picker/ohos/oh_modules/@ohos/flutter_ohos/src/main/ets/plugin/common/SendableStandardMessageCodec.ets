/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on StandardMessageCodec.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import Any from './Any';

import { ByteBuffer } from '../../util/ByteBuffer';
import SendableMessageCodec from './SendableMessageCodec';
import StringUtils from '../../util/StringUtils';
import TreeMap from '@ohos.util.TreeMap';
import HashMap from '@ohos.util.HashMap';
import LightWeightMap from '@ohos.util.LightWeightMap';
import PlainArray from '@ohos.util.PlainArray';
import List from '@ohos.util.List';
import LinkedList from '@ohos.util.LinkedList';

/**
 * MessageCodec using the Flutter standard binary encoding.
 *
 * This codec is guaranteed to be compatible with the corresponding `SendableStandardMessageCodec`
 * on the Dart side. These parts of the Flutter SDK are evolved synchronously.
 *
 * Supported messages are acyclic values of these forms:
 *   null
 *   Booleans
 *   number
 *   BigIntegers (see below)
 *   Int8Array, Int32Array, Float32Array, Float64Array
 *   Strings
 *   Array[]
 *   Lists of supported values
 *   Maps with supported keys and values
 *
 * On the Dart side, these values are represented as follows:
 *   null: null
 *   Boolean: bool
 *   Byte, Short, Integer, Long: int
 *   Float, Double: double
 *   String: String
 *   byte[]: Uint8List
 *   int[]: Int32List
 *   long[]: Int64List
 *   float[]: Float32List
 *   double[]: Float64List
 *   List: List
 *   Map: Map
 *
 * BigIntegers are represented in Dart as strings with the hexadecimal representation of the
 * integer's value.
 *
 * To extend the codec, overwrite the writeValue and readValueOfType methods.
 */
/**
 * A sendable MessageCodec using the Flutter standard binary encoding.
 * This codec can be used in background threads and worker contexts.
 */
@Sendable
export default class SendableStandardMessageCodec implements SendableMessageCodec<Any> {
  /** Singleton instance of SendableStandardMessageCodec. */
  static INSTANCE: SendableStandardMessageCodec = new SendableStandardMessageCodec();

  /**
   * Encodes a message into binary format using the standard encoding.
   * @param message - The message to encode
   * @returns The encoded message as an ArrayBuffer
   */
  encodeMessage(message: Any): ArrayBuffer {
    const stream = ByteBuffer.from(new ArrayBuffer(1024))
    this.writeValue(stream, message);
    return stream.buffer
  }

  /**
   * Decodes a binary message from the standard encoding.
   * @param message - The binary message to decode, possibly null
   * @returns The decoded message
   */
  decodeMessage(message: ArrayBuffer | null): Any {
    if (message == null) {
      return null
    }
    const buffer = ByteBuffer.from(message)
    return this.readValue(buffer)
  }

  private static NULL: number = 0;
  private static TRUE: number = 1;
  private static FALSE: number = 2;
  private static INT32: number = 3;
  private static INT64: number = 4;
  private static BIGINT: number = 5;
  private static FLOAT64: number = 6;
  private static STRING: number = 7;
  private static UINT8_ARRAY: number = 8;
  private static INT32_ARRAY: number = 9;
  private static INT64_ARRAY: number = 10;
  private static FLOAT64_ARRAY: number = 11;
  private static LIST: number = 12;
  private static MAP: number = 13;
  private static FLOAT32_ARRAY: number = 14;

  /**
   * Writes a value to the byte buffer using the standard encoding.
   * @param stream - The ByteBuffer to write to
   * @param value - The value to write
   * @returns The ByteBuffer stream
   */
  writeValue(stream: ByteBuffer, value: Any): Any {
    if (value == null || value == undefined) {
      stream.writeInt8(SendableStandardMessageCodec.NULL);
    } else if (typeof value === "boolean") {
      stream.writeInt8(value ? SendableStandardMessageCodec.TRUE : SendableStandardMessageCodec.FALSE)
    } else if (typeof value === "number") {
      if (Number.isInteger(value)) { //整型
        if (-0x7fffffff - 1 <= value && value <= 0x7fffffff) { //int32
          stream.writeInt8(SendableStandardMessageCodec.INT32);
          stream.writeInt32(value, true);
        } else if (Number.MIN_SAFE_INTEGER <= value && value <= Number.MAX_SAFE_INTEGER) { //int64 number整型取值范围
          stream.writeInt8(SendableStandardMessageCodec.INT64);
          stream.writeInt64(value, true);
        } else { //被判为整型的double型
          stream.writeInt8(SendableStandardMessageCodec.FLOAT64);
          this.writeAlignment(stream, 8);
          stream.writeFloat64(value, true);
        }
      } else { //浮点型
        stream.writeInt8(SendableStandardMessageCodec.FLOAT64);
        this.writeAlignment(stream, 8);
        stream.writeFloat64(value, true);
      }
    } else if (typeof value === "bigint") {
      //
      // The format is first the type byte (0x05), then the actual number
      // as an ASCII string giving the hexadecimal representation of the
      // integer, with the string's length as encoded by writeSize
      // followed by the string bytes.
      stream.writeInt8(SendableStandardMessageCodec.BIGINT);
      // Convert bigint to a hexadecimal string
      const hexString = value.toString(16);
      // Map each character in the hexadecimal string to its ASCII code
      const asciiString = hexString.split('').map(char => char.charCodeAt(0));
      this.writeBytes(stream, Uint8Array.from(asciiString));
    } else if (typeof value === "string") {
      stream.writeInt8(SendableStandardMessageCodec.STRING);
      let stringBuff = StringUtils.stringToArrayBuffer(value);
      this.writeBytes(stream, new Uint8Array(stringBuff));
    } else if (value instanceof Uint8Array) {
      stream.writeInt8(SendableStandardMessageCodec.UINT8_ARRAY);
      this.writeBytes(stream, value)
    } else if (value instanceof Int32Array) {
      stream.writeInt8(SendableStandardMessageCodec.INT32_ARRAY);
      this.writeSize(stream, value.length);
      this.writeAlignment(stream, 4);
      value.forEach(item => stream.writeInt32(item, true));
    } else if (value instanceof BigInt64Array) {
      stream.writeInt8(SendableStandardMessageCodec.INT64_ARRAY);
      this.writeSize(stream, value.length);
      this.writeAlignment(stream, 8);
      value.forEach(item => stream.writeBigInt64(item, true));
    } else if (value instanceof Float32Array) {
      stream.writeInt8(SendableStandardMessageCodec.FLOAT32_ARRAY);
      this.writeSize(stream, value.length);
      this.writeAlignment(stream, 4);
      value.forEach(item => stream.writeFloat32(item, true));
    } else if (value instanceof Float64Array) {
      stream.writeInt8(SendableStandardMessageCodec.FLOAT64_ARRAY);
      this.writeSize(stream, value.length);
      this.writeAlignment(stream, 8);
      value.forEach(item => stream.writeFloat64(item, true));
    } else if (value instanceof Array || value instanceof Int8Array || value instanceof Int16Array
      || value instanceof Uint16Array || value instanceof Uint32Array || value instanceof List
      || value instanceof LinkedList) {
      stream.writeInt8(SendableStandardMessageCodec.LIST)
      this.writeSize(stream, value.length);
      value.forEach((item: Any): void => this.writeValue(stream, item));
    } else if (value instanceof Map) {
      stream.writeInt8(SendableStandardMessageCodec.MAP);
      this.writeSize(stream, value.size);
      value.forEach((value: Any, key: Any) => {
        this.writeValue(stream, key);
        this.writeValue(stream, value);
      });
    } else if (value instanceof HashMap || value instanceof TreeMap || value instanceof LightWeightMap
      || value instanceof PlainArray) {
      stream.writeInt8(SendableStandardMessageCodec.MAP);
      this.writeSize(stream, value.length);
      value.forEach((value: Any, key: Any) => {
        this.writeValue(stream, key);
        this.writeValue(stream, value);
      });
    } else if (typeof value == 'object') {
      let map: Map<string, Any> = new Map();
      Object.keys(value).forEach(key => {
        map.set(key, value[key]);
      });
      this.writeValue(stream, map);
    } else {
      throw new Error("Unsupported value: " + value);
      stream.writeInt8(SendableStandardMessageCodec.NULL);
    }
    return stream;
  }

  /**
   * Writes alignment padding to the stream.
   * @param stream - The ByteBuffer to write to
   * @param alignment - The alignment requirement (e.g., 4, 8)
   */
  writeAlignment(stream: ByteBuffer, alignment: number) {
    let mod: number = stream.byteOffset % alignment;
    if (mod != 0) {
      for (let i = 0; i < alignment - mod; i++) {
        stream.writeInt8(0);
      }
    }
  }

  /**
   * Writes a size value to the stream using compact encoding.
   * @param stream - The ByteBuffer to write to
   * @param value - The size value to write
   */
  writeSize(stream: ByteBuffer, value: number) {
    if (value < 254) {
      stream.writeUint8(value);
    } else if (value <= 0xffff) {
      stream.writeUint8(254);
      stream.writeUint16(value, true);
    } else {
      stream.writeUint8(255);
      stream.writeUint32(value, true);
    }
  }

  /**
   * Writes a byte array to the stream.
   * @param stream - The ByteBuffer to write to
   * @param bytes - The byte array to write
   */
  writeBytes(stream: ByteBuffer, bytes: Uint8Array) {
    this.writeSize(stream, bytes.length)
    stream.writeUint8Array(bytes);
  }

  /**
   * Reads a size value from the buffer using compact encoding.
   * @param buffer - The ByteBuffer to read from
   * @returns The size value
   */
  readSize(buffer: ByteBuffer) {
    let value = buffer.readUint8() & 0xff;
    if (value < 254) {
      return value;
    } else if (value == 254) {
      return buffer.readUint16(true);
    } else {
      return buffer.readUint32(true);
    }
  }

  /**
   * Reads alignment padding from the buffer.
   * @param buffer - The ByteBuffer to read from
   * @param alignment - The alignment requirement (e.g., 4, 8)
   */
  readAlignment(buffer: ByteBuffer, alignment: number) {
    let mod = buffer.byteOffset % alignment;
    if (mod != 0) {
      buffer.skip(alignment - mod);
    }
  }

  /**
   * Reads a value from the buffer using the standard encoding.
   * @param buffer - The ByteBuffer to read from
   * @returns The decoded value
   */
  readValue(buffer: ByteBuffer): Any {
    let type = buffer.readUint8()
    return this.readValueOfType(type, buffer);
  }

  /**
   * Reads a byte array from the buffer.
   * @param buffer - The ByteBuffer to read from
   * @returns The byte array
   */
  readBytes(buffer: ByteBuffer): Uint8Array {
    let length = this.readSize(buffer);
    let bytesBuffer = new ArrayBuffer(length);
    let bytes = new Uint8Array(bytesBuffer);
    bytes.set(buffer.readUint8Array(length));
    return bytes;
  }

  /**
   * Reads a value of a specific type from the buffer.
   * @param type - The type code to read
   * @param buffer - The ByteBuffer to read from
   * @returns The decoded value
   * @throws Error if the type is unknown or the message is corrupted
   */
  readValueOfType(type: number, buffer: ByteBuffer): Any {
    let result: Any;
    switch (type) {
      case SendableStandardMessageCodec.NULL:
        result = null;
        break;
      case SendableStandardMessageCodec.TRUE:
        result = true;
        break;
      case SendableStandardMessageCodec.FALSE:
        result = false;
        break;
      case SendableStandardMessageCodec.INT32:
        result = buffer.readInt32(true);
        break;
      case SendableStandardMessageCodec.INT64:
        result = buffer.readInt64(true);
        if (Number.MIN_SAFE_INTEGER <= result && result <= Number.MAX_SAFE_INTEGER) {
          result = Number(result);
        }
        break;
      case SendableStandardMessageCodec.BIGINT:
        let bytes: Uint8Array = this.readBytes(buffer);
      // Convert the byte array to a UTF-8 encoded string
        const hexString: string = String.fromCharCode(...bytes);
      // Parse the string as a hexadecimal BigInt
        result = BigInt(`0x${hexString}`);
        break;
      case SendableStandardMessageCodec.FLOAT64:
        this.readAlignment(buffer, 8);
        result = buffer.readFloat64(true)
        break;
      case SendableStandardMessageCodec.STRING: {
        let bytes: Uint8Array = this.readBytes(buffer);
        result = StringUtils.uint8ArrayToString(bytes);
        break;
      }
      case SendableStandardMessageCodec.UINT8_ARRAY: {
        result = this.readBytes(buffer);
        break;
      }
      case SendableStandardMessageCodec.INT32_ARRAY: {
        let length = this.readSize(buffer);
        let array = new Int32Array(length)
        this.readAlignment(buffer, 4);
        for (let i = 0; i < length; i++) {
          array[i] = buffer.readInt32(true)
        }
        result = array;
        break;
      }
      case SendableStandardMessageCodec.INT64_ARRAY: {
        let length = this.readSize(buffer);
        let array = new BigInt64Array(length)
        this.readAlignment(buffer, 8);
        for (let i = 0; i < length; i++) {
          array[i] = buffer.readBigInt64(true)
        }
        result = array;
        break;
      }
      case SendableStandardMessageCodec.FLOAT64_ARRAY: {
        let length = this.readSize(buffer);
        let array = new Float64Array(length)
        this.readAlignment(buffer, 8);
        for (let i = 0; i < length; i++) {
          array[i] = buffer.readFloat64(true)
        }
        result = array;
        break;
      }
      case SendableStandardMessageCodec.LIST: {
        let length = this.readSize(buffer);
        let array: Array<Any> = new Array(length)
        for (let i = 0; i < length; i++) {
          array[i] = this.readValue(buffer)
        }
        result = array;
        break;
      }
      case SendableStandardMessageCodec.MAP: {
        let size = this.readSize(buffer);
        let map: Map<Any, Any> = new Map()
        for (let i = 0; i < size; i++) {
          map.set(this.readValue(buffer), this.readValue(buffer));
        }
        result = map;
        break;
      }
      case SendableStandardMessageCodec.FLOAT32_ARRAY: {
        let length = this.readSize(buffer);
        let array = new Float32Array(length);
        this.readAlignment(buffer, 4);
        for (let i = 0; i < length; i++) {
          array[i] = buffer.readFloat32(true)
        }
        result = array;
        break;
      }
      default:
        throw new Error("Message corrupted, type=" + type);
    }
    return result;
  }
}
