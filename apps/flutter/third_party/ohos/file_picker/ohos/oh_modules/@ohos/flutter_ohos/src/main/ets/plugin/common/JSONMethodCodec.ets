/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on JSONMethodCodec.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import Log from '../../util/Log';

import ToolUtils from '../../util/ToolUtils';
import FlutterException from './FlutterException';
import Any from './Any';
import JSONMessageCodec from './JSONMessageCodec';
import MethodCall from './MethodCall';
import MethodCodec from './MethodCodec';

/**
 * A {@link MethodCodec} using UTF-8 encoded JSON method calls and result envelopes.
 *
 * This codec is guaranteed to be compatible with the corresponding `JSONMethodCodec` on
 * the Dart side. These parts of the Flutter SDK are evolved synchronously.
 *
 * Values supported as methods arguments and result payloads are those supported by {@link JSONMessageCodec}.
 */
export default class JSONMethodCodec implements MethodCodec {
  /** Singleton instance of JSONMethodCodec. */
  static INSTANCE = new JSONMethodCodec();

  /**
   * Encodes a method call into JSON binary format.
   * @param methodCall - The MethodCall to encode
   * @returns The encoded method call as an ArrayBuffer
   * @throws Error if encoding fails
   */
  encodeMethodCall(methodCall: MethodCall): ArrayBuffer {
    try {
      const map: Record<string, Any> = {
        "method": methodCall.method, "args": methodCall.args
      }

      return JSONMessageCodec.INSTANCE.encodeMessage(map);
    } catch (e) {
      throw new Error("Invalid JSON");
    }
  }

  /**
   * Decodes a method call from JSON binary format.
   * @param message - The binary message to decode
   * @returns The decoded MethodCall
   * @throws Error if decoding fails or the message is invalid
   */
  decodeMethodCall(message: ArrayBuffer): MethodCall {
    try {
      const json: Any = JSONMessageCodec.INSTANCE.decodeMessage(message);
      if (ToolUtils.isObj(json)) {
        const method: string = json["method"];
        const args: Any = json["args"];
        if (typeof method == 'string') {
          return new MethodCall(method, args);
        }
      }
      throw new Error("Invalid method call: " + json);
    } catch (e) {
      throw new Error("Invalid JSON:" + JSON.stringify(e));
    }
  }

  /**
   * Encodes a successful result into a JSON envelope.
   * @param result - The result value, possibly null
   * @returns The encoded envelope as an ArrayBuffer
   */
  encodeSuccessEnvelope(result: Any): ArrayBuffer {
    return JSONMessageCodec.INSTANCE.encodeMessage([result]);
  }

  /**
   * Encodes an error result into a JSON envelope.
   * @param errorCode - The error code
   * @param errorMessage - The error message, possibly null
   * @param errorDetails - Error details, possibly null
   * @returns The encoded envelope as an ArrayBuffer
   */
  encodeErrorEnvelope(errorCode: Any, errorMessage: string, errorDetails: Any): ArrayBuffer {
    return JSONMessageCodec.INSTANCE.encodeMessage([errorCode, errorMessage, errorDetails]);
  }

  /**
   * Encodes an error result into a JSON envelope with stacktrace.
   * @param errorCode - The error code
   * @param errorMessage - The error message, possibly null
   * @param errorDetails - Error details, possibly null
   * @param errorStacktrace - The platform stacktrace, possibly null
   * @returns The encoded envelope as an ArrayBuffer
   */
  encodeErrorEnvelopeWithStacktrace(errorCode: string, errorMessage: string, errorDetails: Any,
    errorStacktrace: string): ArrayBuffer {
    return JSONMessageCodec.INSTANCE.encodeMessage([errorCode, errorMessage, errorDetails, errorStacktrace])
  }

  /**
   * Decodes a result envelope from JSON binary format.
   * @param envelope - The binary envelope to decode
   * @returns The decoded result value
   * @throws FlutterException if the envelope contains an error
   * @throws Error if the envelope is invalid
   */
  decodeEnvelope(envelope: ArrayBuffer): Any {
    try {
      const json: Any = JSONMessageCodec.INSTANCE.decodeMessage(envelope);
      if (json instanceof Array) {
        if (json.length == 1) {
          return json[0];
        }
        if (json.length == 3) {
          const code: string = json[0];
          const message: string = json[1];
          const details: Any = json[2];
          if (typeof code == 'string' && (message == null || typeof message == 'string')) {
            throw new FlutterException(code, message, details);
          }
        }
      }
      throw new Error("Invalid envelope: " + json);
    } catch (e) {
      throw new Error("Invalid JSON");
    }
  }
}