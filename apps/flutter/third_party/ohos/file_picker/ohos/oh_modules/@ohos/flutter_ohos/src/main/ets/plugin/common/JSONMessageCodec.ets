/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on JSONMessageCodec.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import StringUtils from '../../util/StringUtils';

import MessageCodec from './MessageCodec';
import StringCodec from './StringCodec';
import TreeMap from '@ohos.util.TreeMap';
import HashMap from '@ohos.util.HashMap';
import LightWeightMap from '@ohos.util.LightWeightMap';
import PlainArray from '@ohos.util.PlainArray';
import List from '@ohos.util.List';
import LinkedList from '@ohos.util.LinkedList';
import Any from './Any';

/**
 * A {@link MessageCodec} using UTF-8 encoded JSON messages.
 *
 * This codec is guaranteed to be compatible with the corresponding `JSONMessageCodec` on the Dart side.
 * These parts of the Flutter SDK are evolved synchronously.
 *
 * On the Dart side, JSON messages are handled by the JSON facilities of the `dart:convert` package.
 */
export default class JSONMessageCodec implements MessageCodec<Object> {
  /** Singleton instance of JSONMessageCodec. */
  static INSTANCE = new JSONMessageCodec();

  /**
   * Encodes a message into JSON binary format.
   * @param message - The message to encode, possibly null
   * @returns The encoded message as an ArrayBuffer
   */
  encodeMessage(message: Any): ArrayBuffer {
    if (message == null) {
      return StringUtils.stringToArrayBuffer("");
    }
    return StringCodec.INSTANCE.encodeMessage(JSON.stringify(this.toBaseData(message)));
  }

  /**
   * Decodes a binary message from JSON format.
   * @param message - The binary message to decode, possibly null
   * @returns The decoded message object
   * @throws Error if the JSON is invalid
   */
  decodeMessage(message: ArrayBuffer | null): Any {
    if (message == null) {
      return StringUtils.stringToArrayBuffer("");
    }
    try {
      const jsonStr = StringCodec.INSTANCE.decodeMessage(message);
      let jsonObj: Record<string, Any> = JSON.parse(jsonStr);
      if (jsonObj instanceof Object) {
        const list = Object.keys(jsonObj);
        if (list.includes('args')) {
          let args: Any = jsonObj['args'];
          if (args instanceof Object && !(args instanceof Array)) {
            let argsMap: Map<string, Any> = new Map();
            Object.keys(args).forEach(key => {
              argsMap.set(key, args[key]);
            })
            jsonObj['args'] = argsMap;
          }
        }
      }
      return jsonObj;
    } catch (e) {
      throw new Error("Invalid JSON");
    }
  }

  /**
   * Converts a message to base data types suitable for JSON serialization.
   * @param message - The message to convert
   * @returns The converted message with base data types
   */
  toBaseData(message: Any): Any {
    if (message == null || message == undefined) {
      return null;
    } else if (message instanceof List || message instanceof LinkedList) {
      return this.toBaseData(message.convertToArray());
    } else if (message instanceof Map || message instanceof HashMap || message instanceof TreeMap
      || message instanceof LightWeightMap || message instanceof PlainArray) {
      let messageObj: Any = {};
      message.forEach((value: Any, key: Any) => {
        messageObj[this.toBaseData(key)] = this.toBaseData(value);
      });
      return messageObj;
    } else if (message instanceof Array) {
      let messageArr: Array<Any> = [];
      message.forEach((value: Any) => {
        messageArr.push(this.toBaseData(value));
      })
      return messageArr;
    } else if (message instanceof Object) {
      let messageObj: Any = {};
      Object.keys(message).forEach((key: Any) => {
        messageObj[this.toBaseData(key)] = this.toBaseData(message[key]);
      })
      return messageObj;
    } else {
      return message;
    }
  }
}