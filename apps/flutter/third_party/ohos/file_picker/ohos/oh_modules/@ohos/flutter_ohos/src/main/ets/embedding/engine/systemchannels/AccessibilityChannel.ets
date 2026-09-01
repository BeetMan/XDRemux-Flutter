/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on AccessibilityChannel.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import Log from '../../../util/Log';
import DartExecutor from '../dart/DartExecutor';
import BasicMessageChannel, { MessageHandler, Reply } from '../../../plugin/common/BasicMessageChannel';
import HashMap from '@ohos.util.HashMap';
import FlutterNapi, { AccessibilityDelegate } from '../FlutterNapi';
import StandardMessageCodec from '../../../plugin/common/StandardMessageCodec';
import StringUtils from '../../../util/StringUtils';
import Any from '../../../plugin/common/Any';
import flutter from 'libflutter.so';
import { ByteBuffer } from '../../../util/ByteBuffer';

/**
 * Channel for handling accessibility-related communication between Flutter and OpenHarmony.
 * This channel manages accessibility features, semantics, and accessibility events.
 */
export default class AccessibilityChannel implements MessageHandler<object> {
  private static TAG = "AccessibilityChannel";
  private static CHANNEL_NAME = "flutter/accessibility";
  private channel: BasicMessageChannel<object>;
  private flutterNapi: FlutterNapi;
  private handler: AccessibilityMessageHandler;
  private nextReplyId: number = 1;

  /**
   * Handles messages from Dart.
   * @param message - The message object from Dart
   * @param reply - The reply callback to send a response
   */
  onMessage(message: object, reply: Reply<object>): void {
    if (this.handler == null) {
      Log.i(AccessibilityChannel.TAG, "handler == NULL");
      reply.reply(StringUtils.stringToArrayBuffer(""));
      return;
    }
    let annotatedEvent: HashMap<string, Any> = message as HashMap<string, Any>;
    let type: string = annotatedEvent.get("type") as string;
    let data: HashMap<string, Any> = annotatedEvent.get("data") as HashMap<string, Any>;

    Log.i(AccessibilityChannel.TAG, "Received " + type + " message.");
    switch (type) {
      case "announce": {
        Log.i(AccessibilityChannel.TAG, "Announce");
        let announceMessage: string = data.get("message");
        if (announceMessage != null) {
          Log.i(AccessibilityChannel.TAG, "message is " + announceMessage);
          this.handler.announce(announceMessage);
        }
        break;
      }
      case "tap": {
        Log.i(AccessibilityChannel.TAG, "Tag");
        let nodeId: number = annotatedEvent.get("nodeId");
        if (nodeId != null) {
          this.handler.onTap(nodeId);
        }
        break;
      }
      case "longPress": {
        Log.i(AccessibilityChannel.TAG, "LongPress");
        let nodeId: number = annotatedEvent.get("nodeId");
        if (nodeId != null) {
          this.handler.onLongPress(nodeId);
        }
        break;
      }
      case "tooltip": {
        Log.i(AccessibilityChannel.TAG, "ToolTip");
        let tooltipMessage: string = data.get("message");
        if (tooltipMessage != null) {
          this.handler.onTooltip(tooltipMessage);
        }
        break;
      }
    }
    reply.reply(StringUtils.stringToArrayBuffer(""));
  }

  /**
   * Constructs a new AccessibilityChannel instance.
   * @param dartExecutor - The DartExecutor for sending messages to Dart
   * @param flutterNapi - The FlutterNapi instance for native communication
   */
  constructor(dartExecutor: DartExecutor, flutterNapi: FlutterNapi) {
    Log.i(AccessibilityChannel.TAG, "Channel entered");
    this.channel =
      new BasicMessageChannel<object>(dartExecutor, AccessibilityChannel.CHANNEL_NAME, StandardMessageCodec.INSTANCE);
    this.channel.setMessageHandler(this);
    this.flutterNapi = flutterNapi;
    this.handler = new DefaultHandler(this.flutterNapi);
  }

  /**
   * Called when OpenHarmony accessibility is enabled.
   */
  onOhosAccessibilityEnabled(): void {
    let replyId: number = this.nextReplyId++;
    this.flutterNapi.setSemanticsEnabledWithRespId(true, replyId);
    Log.i(AccessibilityChannel.TAG, "onOhosAccessibilityEnabled = true");
  }

  /**
   * Called when OpenHarmony accessibility features change.
   * @param accessibilityFeatureFlags - The accessibility feature flags
   */
  onOhosAccessibilityFeatures(accessibilityFeatureFlags: number): void {
    let replyId: number = this.nextReplyId++;
    this.flutterNapi.setAccessibilityFeatures(accessibilityFeatureFlags, replyId);
    Log.i(AccessibilityChannel.TAG, "onOhosAccessibilityFeatures");
  }

  /**
   * Dispatches a semantics action to Flutter.
   * @param virtualViewId - The virtual view ID
   * @param action - The accessibility action to dispatch
   */
  dispatchSemanticsAction(virtualViewId: number, action: Action): void {
    let replyId: number = this.nextReplyId++;
    this.flutterNapi.dispatchSemanticsAction(virtualViewId, action, replyId);
    Log.i(AccessibilityChannel.TAG, "dispatchSemanticsAction");
  }

  /**
   * Sets the accessibility message handler.
   * @param handler - The AccessibilityMessageHandler instance
   */
  setAccessibilityMessageHandler(handler: AccessibilityMessageHandler): void {
    this.handler = handler;
    let replyId: number = this.nextReplyId++;
    this.flutterNapi.setAccessibilityDelegate(handler, replyId);
  }
}

/**
 * Interface for handling accessibility messages.
 */
export interface AccessibilityMessageHandler extends AccessibilityDelegate {
  /**
   * Announces a message to the user.
   * @param message - The message to announce
   */
  announce(message: string): void;

  /**
   * Handles a tap event on an accessibility node.
   * @param nodeId - The ID of the accessibility node
   */
  onTap(nodeId: number): void;

  /**
   * Handles a long press event on an accessibility node.
   * @param nodeId - The ID of the accessibility node
   */
  onLongPress(nodeId: number): void;

  /**
   * Handles a tooltip event.
   * @param nodeId - The tooltip node ID
   */
  onTooltip(nodeId: string): void;
}

/**
 * Default implementation of AccessibilityMessageHandler.
 * Handles accessibility events and forwards them to the native Flutter engine.
 */
export class DefaultHandler implements AccessibilityMessageHandler {
  private static TAG = "AccessibilityMessageHandler";
  private flutterNapi: FlutterNapi;

  /**
   * Constructs a new DefaultHandler instance.
   * @param flutterNapi - The FlutterNapi instance for native communication
   */
  constructor(flutterNapi: FlutterNapi) {
    this.flutterNapi = flutterNapi;
  }

  /**
   * Announces a message to the user.
   * @param message - The message to announce
   */
  announce(message: string): void {
    Log.i(DefaultHandler.TAG, "handler announce.");
    flutter.nativeAccessibilityAnnounce(this.flutterNapi.nativeShellHolderId!, message);
  }

  /**
   * Handles a tap event on an accessibility node.
   * @param nodeId - The ID of the accessibility node
   */
  onTap(nodeId: number): void {
    Log.i(DefaultHandler.TAG, "handler onTap.");
    flutter.nativeAccessibilityOnTap(this.flutterNapi.nativeShellHolderId!, nodeId);
  }

  /**
   * Handles a long press event on an accessibility node.
   * @param nodeId - The ID of the accessibility node
   */
  onLongPress(nodeId: number): void {
    Log.i(DefaultHandler.TAG, "handler onLongPress.");
    flutter.nativeAccessibilityOnLongPress(this.flutterNapi.nativeShellHolderId!, nodeId);
  }

  /**
   * Handles a tooltip event.
   * @param message - The tooltip message
   */
  onTooltip(message: string): void {
    Log.i(DefaultHandler.TAG, "handler onTooltip.");
    flutter.nativeAccessibilityOnTooltip(this.flutterNapi.nativeShellHolderId!, message);
  }

  /**
   * Called when accessibility state changes.
   * @param state - The new accessibility state
   */
  accessibilityStateChange(state: Boolean): void {
    Log.i(DefaultHandler.TAG, "handler accessibilityStateChange");
  }
}

/**
 * Accessibility actions that can be performed on semantic nodes.
 */
export enum Action {
  TAP = 1 << 0,
  LONG_PRESS = 1 << 1,
  SCROLL_LEFT = 1 << 2,
  SCROLL_RIGHT = 1 << 3,
  SCROLL_UP = 1 << 4,
  SCROLL_DOWN = 1 << 5,
  INCREASE = 1 << 6,
  DECREASE = 1 << 7,
  SHOW_ON_SCREEN = 1 << 8,
  MOVE_CURSOR_FORWARD_BY_CHARACTER = 1 << 9,
  MOVE_CURSOR_BACKWARD_BY_CHARACTER = 1 << 10,
  SET_SELECTION = 1 << 11,
  COPY = 1 << 12,
  CUT = 1 << 13,
  PASTE = 1 << 14,
  DID_GAIN_ACCESSIBILITY_FOCUS = 1 << 15,
  DID_LOSE_ACCESSIBILITY_FOCUS = 1 << 16,
  CUSTOM_ACTION = 1 << 17,
  DISMISS = 1 << 18,
  MOVE_CURSOR_FORWARD_BY_WORD = 1 << 19,
  MOVE_CURSOR_BACKWARD_BY_WORD = 1 << 20,
  SET_NEXT = 1 << 21,
}