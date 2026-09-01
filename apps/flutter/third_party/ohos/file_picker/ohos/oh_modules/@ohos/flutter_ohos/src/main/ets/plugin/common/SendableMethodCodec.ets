/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on MethodCodec.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import { lang } from '@kit.ArkTS';

import Any from './Any';
import MethodCall from './MethodCall';

/**
 * A codec for method calls and enveloped results.
 *
 * Method calls are encoded as binary messages with enough structure that the codec can extract a
 * method name and arguments. These data items are used to populate a {@link MethodCall}.
 *
 * All operations throw an Error if conversion fails.
 */
type ISendable = lang.ISendable;

export default interface SendableMethodCodec extends ISendable {
  /**
   * Encodes a message call into binary.
   *
   * @param methodCall - A {@link MethodCall}
   * @returns An {@link ArrayBuffer} containing the encoded method call
   */
  encodeMethodCall(methodCall: MethodCall): ArrayBuffer;

  /**
   * Decodes a message call from binary.
   *
   * @param methodCall - The binary encoding of the method call as an {@link ArrayBuffer}
   * @returns A {@link MethodCall} representation of the binary data
   */
  decodeMethodCall(methodCall: ArrayBuffer): MethodCall;

  /**
   * Encodes a successful result into a binary envelope message.
   *
   * @param result - The result value, possibly null
   * @returns An {@link ArrayBuffer} containing the encoded envelope
   */
  encodeSuccessEnvelope(result: Any): ArrayBuffer;

  /**
   * Encodes an error result into a binary envelope message.
   *
   * @param errorCode - An error code string
   * @param errorMessage - An error message string, possibly null
   * @param errorDetails - Error details, possibly null. Consider supporting {@link Error} in your
   *     codec. This is the most common value passed to this field.
   * @returns An {@link ArrayBuffer} containing the encoded envelope
   */
  encodeErrorEnvelope(errorCode: string, errorMessage: string, errorDetails: Any): ArrayBuffer;

  /**
   * Encodes an error result into a binary envelope message with the native stacktrace.
   *
   * @param errorCode - An error code string
   * @param errorMessage - An error message string, possibly null
   * @param errorDetails - Error details, possibly null. Consider supporting {@link Error} in your
   *     codec. This is the most common value passed to this field.
   * @param errorStacktrace - Platform stacktrace for the error, possibly null
   * @returns An {@link ArrayBuffer} containing the encoded envelope
   */
  encodeErrorEnvelopeWithStacktrace(errorCode: string, errorMessage: string, errorDetails: Any,
    errorStacktrace: string): ArrayBuffer;

  /**
   * Decodes a result envelope from binary.
   *
   * @param envelope - The binary encoding of a result envelope as an {@link ArrayBuffer}
   * @returns The enveloped result value
   * @throws FlutterException if the envelope was an error envelope
   */
  decodeEnvelope(envelope: ArrayBuffer): Any;
}
