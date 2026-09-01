/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/
import Any from '../plugin/common/Any';

/**
 * Utility class for object operations.
 */
export default class ToolUtils {
  /**
   * Checks if a value is an object.
   * @param object - The value to check
   * @returns True if the value is an object, false otherwise.
   */
  static isObj(object: Object): boolean {
    return object && typeof (object) == 'object';
  }

  /**
   * Checks if an object implements a specific method (interface check).
   * @param obj - The object to check
   * @param method - The method name to check for
   * @returns True if the object has the method and it's a function, false otherwise.
   */
  static implementsInterface(obj: Any, method: string): boolean {
    return Reflect.has(obj, method) && typeof obj[method] === 'function'
  }
}