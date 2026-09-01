/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on TextEditingDelta.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import Log from '../../util/Log';

/**
 * Represents a delta (change) in text editing state.
 * This class tracks changes to text, selection, and composing regions.
 */
export class TextEditingDelta {
  private static TAG = "TextEditingDelta";
  private oldText: string = "";
  private deltaText: string = "";
  private deltaStart: number = 0;
  private deltaEnd: number = 0;
  private newSelectionStart: number;
  private newSelectionEnd: number;
  private newComposingStart: number;
  private newComposingEnd: number;

  /**
   * Constructs a new TextEditingDelta instance.
   * @param oldEditable - The text before the change
   * @param selectionStart - The new selection start position
   * @param selectionEnd - The new selection end position
   * @param composingStart - The new composing region start position
   * @param composingEnd - The new composing region end position
   * @param replacementDestinationStart - Optional start position of the replacement destination
   * @param replacementDestinationEnd - Optional end position of the replacement destination
   * @param replacementSource - Optional replacement text
   */
  constructor(oldEditable: string,
    selectionStart: number,
    selectionEnd: number,
    composingStart: number,
    composingEnd: number,
    replacementDestinationStart?: number,
    replacementDestinationEnd?: number,
    replacementSource?: string) {
    this.newSelectionStart = selectionStart;
    this.newSelectionEnd = selectionEnd;
    this.newComposingStart = composingStart;
    this.newComposingEnd = composingEnd;
    if (replacementDestinationStart === undefined ||
      replacementDestinationEnd === undefined ||
      replacementSource === undefined) {
      this.setDeltas(oldEditable, "", -1, -1);
    } else {
      this.setDeltas(
        oldEditable,
        replacementSource,
        replacementDestinationStart,
        replacementDestinationEnd);
    }
  }

  /**
   * Sets the delta information for this change.
   * @param oldText - The text before the change
   * @param newText - The replacement text
   * @param newStart - The start position of the replacement
   * @param newExtent - The end position of the replacement
   */
  setDeltas(oldText: string, newText: string, newStart: number, newExtent: number): void {
    this.oldText = oldText;
    this.deltaText = newText;
    this.deltaStart = newStart;
    this.deltaEnd = newExtent;
  }

  /**
   * Converts this delta to a JSON representation.
   * @returns A JSON object containing all delta information
   */
  toJSON(): TextEditingDeltaJson {
    let state: TextEditingDeltaJson = {
      oldText: this.oldText.toString(),
      deltaText: this.deltaText.toString(),
      deltaStart: this.deltaStart,
      deltaEnd: this.deltaEnd,
      selectionBase: this.newSelectionStart,
      selectionExtent: this.newSelectionEnd,
      composingBase: this.newComposingStart,
      composingExtent: this.newComposingEnd,
    };
    return state;
  }
}

/**
 * JSON representation of a text editing delta.
 */
export interface TextEditingDeltaJson {
  /** The text before the change */
  oldText: string;
  /** The replacement text */
  deltaText: string;
  /** The start position of the replacement */
  deltaStart: number;
  /** The end position of the replacement */
  deltaEnd: number;
  /** The new selection start position */
  selectionBase: number;
  /** The new selection end position */
  selectionExtent: number;
  /** The new composing region start position */
  composingBase: number;
  /** The new composing region end position */
  composingExtent: number;
}
