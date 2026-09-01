/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on MethodCall.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import ToolUtils from '../../util/ToolUtils';
import TreeMap from '@ohos.util.TreeMap';
import HashMap from '@ohos.util.HashMap';
import LightWeightMap from '@ohos.util.LightWeightMap';
import Any from './Any';

/**
 * Command object representing a method call on a MethodChannel.
 */
export default class MethodCall {
  /** The name of the called method. */
  method: string;
  /**
   * Arguments for the call.
   *
   * Consider using the argument() method for cases where a particular run-time type is expected.
   * Consider using argument(key) when that run-time type is Map or Object.
   */
  args: Any;

  /**
   * Constructs a new MethodCall instance.
   * @param method - The name of the method to call
   * @param args - The arguments for the method call
   */
  constructor(method: string, args: Any) {
    this.method = method;
    this.args = args;
  }

  /**
   * Gets an argument value by key.
   * @param key - The argument key
   * @returns The argument value, or null if not found
   * @throws Error if the args cannot be cast to a Map or Object
   */
  argument(key: string): Any {
    if (this.args == null) {
      return null;
    } else if (this.args instanceof Map) {
      return (this.args as Map<Any, Any>).get(key);
    } else if (ToolUtils.isObj(this.args)) {
      return this.args[key];
    } else {
      throw new Error("ClassCastException");
    }
  }

  /**
   * Checks if an argument exists for the given key.
   * @param key - The argument key to check
   * @returns True if the argument exists, false otherwise
   * @throws Error if the args cannot be cast to a Map or Object
   */
  hasArgument(key: string): boolean {
    if (this.args == null) {
      return false;
    } else if (this.args instanceof Map) {
      return (this.args as Map<Any, Any>).has(key);
    } else if (ToolUtils.isObj(this.args)) {
      return this.args.hasOwnProperty(key);
    } else {
      throw new Error("ClassCastException");
    }
  }
}