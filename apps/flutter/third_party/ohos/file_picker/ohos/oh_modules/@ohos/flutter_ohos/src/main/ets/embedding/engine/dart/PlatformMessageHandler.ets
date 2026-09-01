/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on PlatformMessageHandler.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

/**
 * Interface for handling platform messages from Dart.
 * This interface provides methods to receive messages from the Dart side of the Flutter application.
 */
export interface PlatformMessageHandler {

  /**
   * Handles a message received from Dart over a specific channel.
   * @param channel - The channel name for the message
   * @param message - The message data as an ArrayBuffer
   * @param replyId - The reply ID for responding to the message
   * @param messageData - Additional message data
   */
  handleMessageFromDart(channel: String, message: ArrayBuffer, replyId: number, messageData: number): void;

  /**
   * Handles a platform message response from Dart.
   * @param replyId - The reply ID that was sent with the original message
   * @param reply - The reply data as an ArrayBuffer
   */
  handlePlatformMessageResponse(replyId: number, reply: ArrayBuffer): void;

}