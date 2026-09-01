/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on KeyEventChannel.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import BasicMessageChannel from '../../../plugin/common/BasicMessageChannel';
import { BinaryMessenger } from '../../../plugin/common/BinaryMessenger';
import Log from '../../../util/Log';
import JSONMessageCodec from '../../../plugin/common/JSONMessageCodec';
import { KeyCode } from '@kit.InputKit';
import { ModifierKeyMetaInfo } from '../../ohos/KeyboardMap'
import Any from '../../../plugin/common/Any';

/**
 * Channel for handling keyboard key events between OpenHarmony and Flutter.
 * This channel manages communication of key events, including both hardware keyboard events
 * and simulated key events for soft-keyboard text-editing. It uses a BasicMessageChannel
 * with JSON encoding to send key event data to the Flutter framework.
 */
export default class KeyEventChannel {
  private static TAG = "KeyEventChannel";
  private static CHANNEL_NAME = "flutter/keyevent";
  private channel: BasicMessageChannel<Object>;

  /**
   * Constructs a new KeyEventChannel instance.
   * @param binaryMessenger - The BinaryMessenger for sending messages to Dart
   */
  constructor(binaryMessenger: BinaryMessenger) {
    this.channel = new BasicMessageChannel<Object>(binaryMessenger, KeyEventChannel.CHANNEL_NAME,
      JSONMessageCodec.INSTANCE);
  }

  /**
   * Sends a hardware key event to the Flutter framework.
   * The event is encoded and sent asynchronously. The response handler will be called
   * when Flutter responds, indicating whether the event was handled.
   * @param keyEvent - The FlutterKeyEvent containing the OpenHarmony key event data
   * @param isKeyUp - Whether this is a key up event (true) or key down event (false)
   * @param responseHandler - Handler to receive the response from Flutter indicating if the event was handled
   */
  sendFlutterKeyEvent(keyEvent: FlutterKeyEvent,
    isKeyUp: boolean,
    responseHandler: EventResponseHandler): void {
    this.channel.send(this.encodeKeyEvent(keyEvent, isKeyUp),
      (message: Object) => {
        let isEventHandled = false;
        try {
          if (message != null) {
            const tmp: Record<string, Any> = message as Record<string, Any>;
            isEventHandled = tmp["handled"] || false;
          }
        } catch (e) {
          Log.e(KeyEventChannel.TAG, "Unable to unpack JSON message: " + e);
        }
        responseHandler.onFrameworkResponse(isEventHandled);
      }
    );
  }

  private encodeKeyEvent(keyEvent: FlutterKeyEvent, isKeyUp: boolean): Map<String, Object> {
    let message: Map<String, Object> = new Map();
    message.set("type", isKeyUp ? "keyup" : "keydown");
    message.set("keymap", "ohos");
    message.set("keyCode", keyEvent.event.keyCode);
    message.set("deviceId", keyEvent.event.deviceId);
    message.set("flags", keyEvent.event.keyText);
    // the keyEvent of ohos do not support the getMetaState feature,
    // so the flutter-ohos side adapts the getMetaState() method
    message.set("metaState", keyEvent.getMetaState());
    message.set("source", keyEvent.event.keySource);
    message.set("intentionCode", keyEvent.event.intentionCode);
    return message;
  }

  /**
   * Sends a simulated key event for soft-keyboard text-editing in the input method.
   * This method is used for virtual keyboard events (e.g., arrow keys, selection keys)
   * that are generated programmatically rather than from hardware input.
   * @param keyEvent - The SimulateKeyEvent containing the simulated key data
   * @param isKeyUp - Whether this is a key up event (true) or key down event (false)
   * @param responseHandler - Handler to receive the response from Flutter indicating if the event was handled
   */
  simulateSendFlutterKeyEvent(keyEvent: SimulateKeyEvent,
    isKeyUp: boolean,
    responseHandler: EventResponseHandler): void {
    this.channel.send(this.encodeSimulatedKeyEvent(keyEvent, isKeyUp),
      (message: Object) => {
        let isEventHandled = false;
        try {
          if (message !== null) {
            const tmp: Record<string, Any> = message as Record<string, Any>;
            isEventHandled = tmp["handled"] || false;
          }
        } catch (e) {
          Log.e(KeyEventChannel.TAG, "Unable to unpack JSON message: " + e);
        }
        responseHandler.onFrameworkResponse(isEventHandled);
      }
    );
  }

  private encodeSimulatedKeyEvent(keyEvent: SimulateKeyEvent, isKeyUp: boolean): Map<String, Object> {
    let message: Map<String, Object> = new Map();
    message.set("type", isKeyUp ? "keyup" : "keydown");
    message.set("keymap", "ohos");
    message.set("keyCode", keyEvent.keyCode);
    message.set("flags", keyEvent.keyText);
    return message;
  }
}

/**
 * Interface for handling event responses from the Flutter framework.
 * Implementations of this interface receive callbacks when Flutter processes
 * key events and indicates whether the event was handled.
 */
export interface EventResponseHandler {
  /**
   * Called when Flutter responds to a key event.
   * This callback is invoked asynchronously after Flutter processes the key event.
   * @param isEventHandled - Whether Flutter handled the event (true) or not (false)
   */
  onFrameworkResponse: (isEventHandled: boolean) => void;
}

/**
 * Wrapper for OpenHarmony KeyEvent that provides Flutter-compatible meta state information.
 * OpenHarmony KeyEvent does not natively support meta state tracking for modifier keys
 * (Ctrl, Alt, Shift) in the same way Flutter expects. This class supplements the missing
 * functionality by tracking modifier key states and providing a getMetaState() method
 * that returns a bitmask compatible with Flutter's key event handling.
 */
export class FlutterKeyEvent {
  /** The underlying OpenHarmony KeyEvent instance. */
  event: KeyEvent;
  private mMetaState: number;
  private isCtrlPressed: boolean | undefined = false;
  private isAltPressed: boolean | undefined = false;
  private isShiftPressed: boolean | undefined = false;

  /**
   * Constructs a new FlutterKeyEvent instance.
   * @param ohosKeyEvent - The OpenHarmony KeyEvent to wrap
   */
  constructor(ohosKeyEvent: KeyEvent) {
    this.event = ohosKeyEvent;
    this.mMetaState = ModifierKeyMetaInfo.NONE;
    this.isCtrlPressed = ohosKeyEvent.getModifierKeyState && ohosKeyEvent.getModifierKeyState(['Ctrl']);
    this.isAltPressed = ohosKeyEvent.getModifierKeyState && ohosKeyEvent.getModifierKeyState(['Alt']);
    this.isShiftPressed = ohosKeyEvent.getModifierKeyState && ohosKeyEvent.getModifierKeyState(['Shift']);
    this.didUpdateOhosMetaState();
  }

  /**
   * Gets the meta state value as a bitmask.
   * This supplements the missing metaState feature of OpenHarmony when pressing
   * modifier keys (Ctrl, Alt, Shift) to perform combination key operations.
   * The meta state is a bitmask that indicates which modifier keys are currently pressed.
   * Currently only supports metaState tracking for Ctrl, Alt, and Shift keys.
   * @returns The meta state value as a bitmask indicating pressed modifier keys
   */
  getMetaState(): number {
    return this.mMetaState;
  }

  private didUpdateOhosMetaState(): void {
    // The ohos platform only supports whether the Ctrl/Alt/Shift key or combination of them is pressed or not,
    // and cannot distinguish the left or right directions.
    // Here, the left direction key of ctrl/alt/shift is used by default
    if (this.isCtrlPressed != undefined) {
      this.updateMetaStateIfNeeded(KeyCode.KEYCODE_CTRL_LEFT, this.isCtrlPressed);
    }
    if (this.isAltPressed != undefined) {
      this.updateMetaStateIfNeeded(KeyCode.KEYCODE_ALT_LEFT, this.isAltPressed);
    }
    if (this.isShiftPressed != undefined) {
      this.updateMetaStateIfNeeded(KeyCode.KEYCODE_SHIFT_LEFT, this.isShiftPressed);
    }
  }

  private updateMetaStateIfNeeded(keyCode: number, isPressed: boolean): void {
    const oldMetaState: number = this.mMetaState;
    const newMetaState: number = this.updateMetaState(keyCode, isPressed, oldMetaState);
    const isMetaStateChanged: number = oldMetaState ^ newMetaState;
    if (isMetaStateChanged) {
      this.mMetaState = newMetaState;
    }
  }

  private updateMetaState(keyCode: number, isPressed: boolean, oldMetaState: number): number {
    switch (keyCode) {
      case KeyCode.KEYCODE_ALT_LEFT:
        return this.setMetaState(ModifierKeyMetaInfo.ALT_LEFT, isPressed, oldMetaState);
      case KeyCode.KEYCODE_ALT_RIGHT:
        return this.setMetaState(ModifierKeyMetaInfo.ALT_RIGHT, isPressed, oldMetaState);
      case KeyCode.KEYCODE_SHIFT_LEFT:
        return this.setMetaState(ModifierKeyMetaInfo.SHIFT_LEFT, isPressed, oldMetaState);
      case KeyCode.KEYCODE_SHIFT_RIGHT:
        return this.setMetaState(ModifierKeyMetaInfo.SHIFT_RIGHT, isPressed, oldMetaState);
      case KeyCode.KEYCODE_CTRL_LEFT:
        return this.setMetaState(ModifierKeyMetaInfo.CTRL_LEFT, isPressed, oldMetaState);
      case KeyCode.KEYCODE_CTRL_RIGHT:
        return this.setMetaState(ModifierKeyMetaInfo.CTRL_RIGHT, isPressed, oldMetaState);
      default:
        return oldMetaState;
    }
  }

  private setMetaState(mask: number, isPressed: boolean, oldMetaState: number): number {
    let newMetaState: number;
    if (isPressed) { // set the metaState of the pressed modifier key
      newMetaState = oldMetaState | mask;
    } else { // reset/clear the metaState of all modifier keys (ctrl|alt|shift|win/cmd)
      newMetaState = oldMetaState &
        ~(mask | ModifierKeyMetaInfo.CTRL | ModifierKeyMetaInfo.ALT |
        ModifierKeyMetaInfo.SHIFT | ModifierKeyMetaInfo.META);
    }
    // Update the non-sided modifier key metaState to match the content of the sided ones.
    if (newMetaState & (ModifierKeyMetaInfo.ALT_LEFT | ModifierKeyMetaInfo.ALT_RIGHT)) {
      newMetaState |= ModifierKeyMetaInfo.ALT;
    }
    if (newMetaState & (ModifierKeyMetaInfo.SHIFT_LEFT | ModifierKeyMetaInfo.SHIFT_RIGHT)) {
      newMetaState |= ModifierKeyMetaInfo.SHIFT;
    }
    if (newMetaState & (ModifierKeyMetaInfo.CTRL_LEFT | ModifierKeyMetaInfo.CTRL_RIGHT)) {
      newMetaState |= ModifierKeyMetaInfo.CTRL;
    }
    return newMetaState;
  }
}

/**
 * Simulated key event used in soft-keyboard text-editing.
 * This class represents a programmatically generated key event, typically used
 * for virtual keyboard interactions such as arrow keys, selection keys, or
 * other input method editor (IME) operations. Unlike FlutterKeyEvent, this
 * does not wrap a hardware KeyEvent and contains only the essential key information.
 */
export class SimulateKeyEvent {
  /** The key code value identifying which key was pressed. */
  keyCode: number;
  /** The text representation of the key (e.g., "Arrow Up", "Shift"). */
  keyText: string;
  /**
   * Constructs a new SimulateKeyEvent instance.
   * @param keyCode - The key code value (e.g., KeyCode.KEYCODE_DPAD_UP)
   * @param keyText - The text representation of the key (e.g., "Arrow Up")
   */
  constructor(keyCode: number, keyText: string) {
    this.keyCode = keyCode;
    this.keyText = keyText;
  }
}