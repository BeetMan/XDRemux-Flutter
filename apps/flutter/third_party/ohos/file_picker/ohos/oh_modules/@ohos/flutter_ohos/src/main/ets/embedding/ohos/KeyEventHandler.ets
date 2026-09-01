/*
 * Copyright (c) 2021-2024 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { HashMap } from '@kit.ArkTS';
import deviceInfo from '@ohos.deviceInfo';
import TextInputPlugin from '../../plugin/editing/TextInputPlugin';
import Log from '../../util/Log';
import { KeyCode } from '@kit.InputKit';
import { ListenableEditingState } from '../../plugin/editing/ListenableEditingState';

const TAG = "KeyEventHandler";

/**
 * Represents text for a key in normal and shift cases.
 */
class KeyText {
  /** The text in normal case. */
  public normalCase: string;
  /** The text in shift case. */
  public shiftCase: string;

  /**
   * Constructs a new KeyText instance.
   * @param normalCase - The text in normal case
   * @param shiftCase - The text in shift case
   */
  constructor(normalCase: string, shiftCase: string) {
    this.normalCase = normalCase;
    this.shiftCase = shiftCase;
  }
}
;

/**
 * Handler for key events in emulator/hdc tool input scenarios.
 * 
 * In the emulator/hdc tool input scenario, all keyevents will be passed to the onKeyEvent callback,
 * so we need to insert the text to textInputPlugin ourselves. In other scenarios like phone/pc/ets,
 * the input method will be responsible for inserting the text to textInputPlugin, consuming 'down' events
 * and letting 'up' events go which will be captured by onKeyEvent.
 * 
 * There is no need to process the status of the capslock button. Because in the scenario of the emulator/hdc tool,
 * if capslock is pressed, os will send a 'shift' keyevent before the keyevent of the input key and we will insert
 * uppercase characters correctly.
 */
export class KeyEventHandler {

  private static keyTextMap: Map<KeyCode, KeyText> = new Map([
    [KeyCode.KEYCODE_0, new KeyText('0', ')')],
    [KeyCode.KEYCODE_1, new KeyText('1', '!')],
    [KeyCode.KEYCODE_2, new KeyText('2', '@')],
    [KeyCode.KEYCODE_3, new KeyText('3', '#')],
    [KeyCode.KEYCODE_4, new KeyText('4', '$')],
    [KeyCode.KEYCODE_5, new KeyText('5', '%')],
    [KeyCode.KEYCODE_6, new KeyText('6', '^')],
    [KeyCode.KEYCODE_7, new KeyText('7', '&')],
    [KeyCode.KEYCODE_8, new KeyText('8', '*')],
    [KeyCode.KEYCODE_9, new KeyText('9', '(')],
    [KeyCode.KEYCODE_A, new KeyText('a', 'A')],
    [KeyCode.KEYCODE_B, new KeyText('b', 'B')],
    [KeyCode.KEYCODE_C, new KeyText('c', 'C')],
    [KeyCode.KEYCODE_D, new KeyText('d', 'D')],
    [KeyCode.KEYCODE_E, new KeyText('e', 'E')],
    [KeyCode.KEYCODE_F, new KeyText('f', 'F')],
    [KeyCode.KEYCODE_G, new KeyText('g', 'G')],
    [KeyCode.KEYCODE_H, new KeyText('h', 'H')],
    [KeyCode.KEYCODE_I, new KeyText('i', 'I')],
    [KeyCode.KEYCODE_J, new KeyText('j', 'J')],
    [KeyCode.KEYCODE_K, new KeyText('k', 'K')],
    [KeyCode.KEYCODE_L, new KeyText('l', 'L')],
    [KeyCode.KEYCODE_M, new KeyText('m', 'M')],
    [KeyCode.KEYCODE_N, new KeyText('n', 'N')],
    [KeyCode.KEYCODE_O, new KeyText('o', 'O')],
    [KeyCode.KEYCODE_P, new KeyText('p', 'P')],
    [KeyCode.KEYCODE_Q, new KeyText('q', 'Q')],
    [KeyCode.KEYCODE_R, new KeyText('r', 'R')],
    [KeyCode.KEYCODE_S, new KeyText('s', 'S')],
    [KeyCode.KEYCODE_T, new KeyText('t', 'T')],
    [KeyCode.KEYCODE_U, new KeyText('u', 'U')],
    [KeyCode.KEYCODE_V, new KeyText('v', 'V')],
    [KeyCode.KEYCODE_W, new KeyText('w', 'W')],
    [KeyCode.KEYCODE_X, new KeyText('x', 'X')],
    [KeyCode.KEYCODE_Y, new KeyText('y', 'Y')],
    [KeyCode.KEYCODE_Z, new KeyText('z', 'Z')],

    [KeyCode.KEYCODE_GRAVE, new KeyText('`', '~')],
    [KeyCode.KEYCODE_MINUS, new KeyText('-', '_')],
    [KeyCode.KEYCODE_EQUALS, new KeyText('=', '+')],
    [KeyCode.KEYCODE_LEFT_BRACKET, new KeyText('[', '{')],
    [KeyCode.KEYCODE_RIGHT_BRACKET, new KeyText(']', '}')],
    [KeyCode.KEYCODE_BACKSLASH, new KeyText('\\', '|')],
    [KeyCode.KEYCODE_SEMICOLON, new KeyText(';', ':')],
    [KeyCode.KEYCODE_APOSTROPHE, new KeyText('\'', '"')],
    [KeyCode.KEYCODE_COMMA, new KeyText(',', '<')],
    [KeyCode.KEYCODE_PERIOD, new KeyText('.', '>')],
    [KeyCode.KEYCODE_SLASH, new KeyText('/', '?')],
    [KeyCode.KEYCODE_SPACE, new KeyText(' ', ' ')],

    [KeyCode.KEYCODE_NUMPAD_0, new KeyText('0', '')],
    [KeyCode.KEYCODE_NUMPAD_1, new KeyText('1', '')],
    [KeyCode.KEYCODE_NUMPAD_2, new KeyText('2', '')],
    [KeyCode.KEYCODE_NUMPAD_3, new KeyText('3', '')],
    [KeyCode.KEYCODE_NUMPAD_4, new KeyText('4', '')],
    [KeyCode.KEYCODE_NUMPAD_5, new KeyText('5', '')],
    [KeyCode.KEYCODE_NUMPAD_6, new KeyText('6', '')],
    [KeyCode.KEYCODE_NUMPAD_7, new KeyText('7', '')],
    [KeyCode.KEYCODE_NUMPAD_8, new KeyText('8', '')],
    [KeyCode.KEYCODE_NUMPAD_9, new KeyText('9', '')],
    [KeyCode.KEYCODE_NUMPAD_DOT, new KeyText('.', '')],
    [KeyCode.KEYCODE_NUMPAD_ADD, new KeyText('+', '')],
    [KeyCode.KEYCODE_NUMPAD_SUBTRACT, new KeyText('-', '')],
    [KeyCode.KEYCODE_NUMPAD_MULTIPLY, new KeyText('*', '')],
    [KeyCode.KEYCODE_NUMPAD_DIVIDE, new KeyText('/', '')],
    [KeyCode.KEYCODE_NUMPAD_EQUALS, new KeyText('=', '')],
  ]);
  private textInputPlugin?: TextInputPlugin;

  /**
   * Constructs a new KeyEventHandler instance.
   * @param textInputPlugin - The TextInputPlugin instance, optional
   */
  constructor(textInputPlugin?: TextInputPlugin) {
    this.textInputPlugin = textInputPlugin;
  }

  /**
   * Gets the text representation of a key event.
   * @param event - The key event
   * @returns The text string for the key, considering shift state
   */
  getKeyText(event: KeyEvent) : string {
    let keyText = KeyEventHandler.keyTextMap.get(event.keyCode);
    if (keyText !== undefined) {
      // Check if it's a letter key (A-Z)
      const isLetter = event.keyCode >= KeyCode.KEYCODE_A && event.keyCode <= KeyCode.KEYCODE_Z;
      // Use event.isCapsLockOn to check CapsLock state
      const isCapsLockOn = event.isCapsLockOn !== undefined ? event.isCapsLockOn : false;
      // Use getModifierKeyState to check Shift state
      const isShiftPressed = this.getModifierKeyStateSafe(event, ['Shift']);
      // If CapsLock is enabled, reverse the case for letter keys
      if (isLetter && isCapsLockOn) {
        // Shift + CapsLock = lowercase (reverses CapsLock effect)
        return isShiftPressed ? keyText.normalCase : keyText.shiftCase;
      } else {
        // Normal case: Shift determines case
        return isShiftPressed ? keyText.shiftCase : keyText.normalCase;
      }
    }
    return '';
  }

  /**
   * Starts a deletion operation.
   * @param code - The key code for deletion
   */
  startDeleting(code: number) {
    this.textInputPlugin?.getEditingState().startDeleting(code);
  }

  /**
   * Ends a deletion operation.
   * @param code - The key code for deletion
   */
  endDeletion(code: number) {
    this.textInputPlugin?.getEditingState().endDeletion(code);
  }

  /**
   * Helper method to safely execute an action on the editing state.
   * @param action - The action to execute with the editing state
   * @returns True if the action was executed, false otherwise
   */
  private withEditingState(action: (editingState: ListenableEditingState) => void): boolean {
    const editingState = this.textInputPlugin?.getEditingState();
    if (editingState) {
      action(editingState);
      return true;
    }
    return false;
  }

  /**
   * Safely gets the modifier key state from a key event.
   * @param event - The key event
   * @param modifierKeys - Array of modifier key names (e.g., ['Shift'], ['Ctrl'], ['Alt'])
   * @returns True if the modifier key is pressed, false otherwise
   */
  private getModifierKeyStateSafe(event: KeyEvent, modifierKeys: string[]): boolean {
    if (!event.getModifierKeyState) {
      return false;
    }
    try {
      return event.getModifierKeyState(modifierKeys) || false;
    } catch (e) {
      const errorMsg = e instanceof Error ? e.message : String(e);
      Log.e(TAG, `Failed to get modifier key state for ${modifierKeys.join(', ')}: ${errorMsg}`);
      return false;
    }
  }

  /**
   * Handles a key event and inserts text if appropriate.
   * @param event - The key event to handle
   */
  handleKeyEvent(event: KeyEvent) {
    Log.i(TAG, JSON.stringify({
      "name": "handleKeyEvent",
      "event": event
    }));
    if (event.type === KeyType.Down) {
      switch (event.keyCode) {
        case KeyCode.KEYCODE_ENTER:
        case KeyCode.KEYCODE_NUMPAD_ENTER: {
          // Handle Enter key (both regular and numpad), insert newline character
          this.withEditingState((editingState) => {
            editingState.handleInsertTextEvent('\n');
            Log.i(TAG, `ENTER: inserted newline`);
          });
          break;
        }
        default: {
          // Check if it's a numpad number key (0-9)
          const isNumpadNumberKey = event.keyCode >= KeyCode.KEYCODE_NUMPAD_0 && event.keyCode <= KeyCode.KEYCODE_NUMPAD_9;
          // Check if it's NUMPAD_DOT key
          const isNumpadDotKey = event.keyCode === KeyCode.KEYCODE_NUMPAD_DOT;
          
          // Use event.isNumLockOn to check NumLock state
          const isNumLockOn = event.isNumLockOn !== undefined ? event.isNumLockOn : true; // Default to true if not available
          
          // When NumLock is on, block numpad number keys (0-9) and NUMPAD_DOT, allow other special keys to input symbols
          if ((isNumpadNumberKey || isNumpadDotKey) && !isNumLockOn) {
            Log.i(TAG, `Numpad key ${event.keyCode} blocked: NumLock is off`);
            return;
          }
          // Other special keys (NUMPAD_ADD, NUMPAD_SUBTRACT, etc.) can input symbols even when NumLock is off
          
          // Use getModifierKeyState to check Ctrl and Alt state
          // Returns true if either Ctrl or Alt (or both) is pressed
          const isCtrlPressed = this.getModifierKeyStateSafe(event, ['Ctrl']);
          const isAltPressed = this.getModifierKeyStateSafe(event, ['Alt']);
          const isCombinationMode = isCtrlPressed || isAltPressed;
          
          // Don't input characters (letters/numbers/symbols) when Ctrl/Alt keys are pressed or data is empty
          if (!isCombinationMode && this.getKeyText(event)) {
            this.withEditingState((editingState) => {
              // Insert character
              editingState.handleInsertTextEvent(this.getKeyText(event));
            });
          }
          break;
        }
      }
    }
  }
}
