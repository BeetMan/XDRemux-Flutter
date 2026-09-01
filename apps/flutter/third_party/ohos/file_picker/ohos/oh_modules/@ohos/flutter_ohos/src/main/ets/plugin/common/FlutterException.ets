/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterException.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import Any from './Any';

/**
 * Exception class for Flutter platform channel errors.
 * This class represents errors that occur during communication between Flutter and the platform.
 */
export default class FlutterException implements Error {
  /** Optional stack trace for the error. */
  stack?: string;
  /** The error message. */
  message: string;
  /** The error name. */
  name: string = "";
  /** The error code. */
  code: string;
  /** Additional error details. */
  details: Any

  /**
   * Constructs a new FlutterException instance.
   * @param code - The error code
   * @param message - The error message
   * @param details - Additional error details
   */
  constructor(code: string, message: string, details: Any) {
    this.message = message;
    this.code = code;
    this.details = details;
  }
}