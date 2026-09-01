/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on KeyboardManager.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import TextInputPlugin from '../../plugin/editing/TextInputPlugin';
import FlutterEngine from '../engine/FlutterEngine';
import KeyEventChannel, { FlutterKeyEvent } from '../engine/systemchannels/KeyEventChannel';
import KeyboardChannel from '../engine/systemchannels/KeyboardChannel';
import KeyEmbedderResponder from './KeyEmbedderResponder';
import { BinaryMessenger } from '../../plugin/common/BinaryMessenger';
import { KeyEventHandler } from './KeyEventHandler';
import HashSet from '@ohos.util.HashSet';
import { KeyCode } from '@kit.InputKit';

/**
 * Manages keyboard events and state for Flutter.
 * This class coordinates between key event channels, keyboard channels, and text input handling.
 */
export default class KeyboardManager {
  private keyEventChannel: KeyEventChannel | null = null;
  private keyboardChannel: KeyboardChannel | null = null;
  /** The key embedder responder for handling key events. */
  protected keyEmbedderResponder: KeyEmbedderResponder;
  private keyEventHandler: KeyEventHandler;

  /**
   * Constructs a new KeyboardManager instance.
   * @param engine - The FlutterEngine instance
   * @param textInputPlugin - The TextInputPlugin instance
   */
  constructor(engine: FlutterEngine, textInputPlugin: TextInputPlugin) {
    this.keyEventChannel = new KeyEventChannel(engine.dartExecutor);
    this.keyboardChannel = new KeyboardChannel(engine.dartExecutor);
    this.keyboardChannel.setKeyboardMethodHandler(this);
    this.keyEmbedderResponder = new KeyEmbedderResponder(engine.dartExecutor);
    this.keyEventHandler = new KeyEventHandler(textInputPlugin);
  }

  /**
   * Handles key events before they are processed by the input method editor.
   * @param event - The key event
   * @returns Whether the event was handled
   */
  onKeyPreIme(event: KeyEvent) : boolean {
    return false;
  }

  /**
   * Handles key events.
   * @param event - The key event
   * @returns Whether the event was handled
   */
  onKeyEvent(event: KeyEvent) : boolean {
    this.keyEmbedderResponder.handleKeyEvent(event);

    this.keyEventChannel?.sendFlutterKeyEvent(new FlutterKeyEvent(event), event.type == KeyType.Up, {
      onFrameworkResponse: (isEventHandled: boolean): void => {
      }
    })
    this.keyEventHandler.handleKeyEvent(event);
    return false;
  }

  /**
   * Gets the current keyboard state (pressed keys).
   * @returns A map of pressed key codes
   */
  public getKeyboardState(): Map<number, number> {
    return this.keyEmbedderResponder.getPressedKeys();
  }
}

/**
 * Interface for handling key events.
 */
export interface Responder {
  /**
   * Handles a key event.
   * @param keyEvent - The key event to handle
   */
  handleKeyEvent(keyEvent: KeyEvent): void;
}