/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterTextUtils.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import FlutterNapi from '../../embedding/engine/FlutterNapi';
import Log from '../../util/Log';

const LINE_FEED: number = 0x0A;
const CARRIAGE_RETURN: number = 0x0D;
const COMBINING_ENCLOSING_KEYCAP: number = 0x20E3;
const CANCEL_TAG: number = 0xE007F;
const ZERO_WIDTH_JOINER: number = 0x200D;

const TAG = "TextUtils";

/**
 * Half-open UTF-16 range removed by one IME-aware preview Backspace at caret `offset`.
 */
export class ImePreviewBackspaceRange {
  delStart: number;
  delEnd: number;

  constructor(delStart: number, delEnd: number) {
    this.delStart = delStart;
    this.delEnd = delEnd;
  }
}

/**
 * Utility class for text processing operations, including Unicode code point handling,
 * emoji detection, and text offset calculations.
 */
export class FlutterTextUtils {
    
  /**
   * Checks if a Unicode code point represents an emoji.
   * @param code - The Unicode code point to check
   * @returns True if the code point is an emoji, false otherwise
   */
  static isEmoji(code: number): boolean {
    return FlutterNapi.unicodeIsEmoji(code);
  }

  /**
   * Checks if a Unicode code point represents an emoji modifier.
   * @param code - The Unicode code point to check
   * @returns True if the code point is an emoji modifier, false otherwise
   */
  static isEmojiModifier(code: number): boolean {
    return FlutterNapi.unicodeIsEmojiModifier(code);
  }
  
  /**
   * Checks if a Unicode code point represents an emoji modifier base.
   * @param code - The Unicode code point to check
   * @returns True if the code point is an emoji modifier base, false otherwise
   */
  static isEmojiModifierBase(code: number): boolean {
    return FlutterNapi.unicodeIsEmojiModifierBase(code);
  }

  /**
   * Checks if a Unicode code point represents a variation selector.
   * @param code - The Unicode code point to check
   * @returns True if the code point is a variation selector, false otherwise
   */
  static isVariationSelector(code: number): boolean {
    return FlutterNapi.unicodeIsVariationSelector(code);
  }

  /**
   * Checks if a Unicode code point represents a regional indicator symbol.
   * @param code - The Unicode code point to check
   * @returns True if the code point is a regional indicator symbol, false otherwise
   */
  static isRegionalIndicatorSymbol(code: number): boolean {
    return FlutterNapi.unicodeIsRegionalIndicatorSymbol(code);
  }

  /**
   * Checks if a Unicode code point is a tag specification character.
   * @param code - The Unicode code point to check
   * @returns True if the code point is a tag specification character, false otherwise
   */
  static isTagSpecChar(code: number): boolean {
    return 0xE0020 <= code && code <= 0xE007E;
  }

  /**
   * Checks if a Unicode code point is a keycap base character (0-9, #, *).
   * @param code - The Unicode code point to check
   * @returns True if the code point is a keycap base, false otherwise
   */
  static isKeycapBase(code: number): boolean {
    return ('0'.charCodeAt(0) <= code && code <= '9'.charCodeAt(0)) || code == '#'.charCodeAt(0) || code == '*'.charCodeAt(0);
  }

  /**
   * Gets the Unicode code point before the specified offset in the text.
   * Handles surrogate pairs correctly.
   * @param text - The text to examine
   * @param offset - The offset position
   * @returns The Unicode code point before the offset
   * @throws RangeError if the offset is out of range
   */
  static codePointBefore(text: string, offset: number): number {
    if (offset <= 0 || offset > text.length) {
        throw new RangeError('Offset out of range');
    }

    // Get the character before the offset
    const char = text[offset - 1];

    // Check if it is a low surrogate (part of a surrogate pair)
    if (offset > 1 && char >= '\uDC00' && char <= '\uDFFF') {
        const prevChar = text[offset - 2];
        // Check if the previous character is a high surrogate
        if (prevChar >= '\uD800' && prevChar <= '\uDBFF') {
          // If it is, combine the surrogate pair into a full Unicode code point
          return (prevChar.charCodeAt(0) - 0xD800) * 0x400 + (char.charCodeAt(0) - 0xDC00) + 0x10000;
        }
    }

    // Return the code point of the single character (if it's not a surrogate pair)
    return char.charCodeAt(0);
  }

  /**
   * Gets the Unicode code point at the specified offset in the text.
   * Handles surrogate pairs correctly.
   * @param text - The text to examine
   * @param offset - The offset position
   * @returns The Unicode code point at the offset
   * @throws RangeError if the offset is out of range
   */
  static codePointAt(text: string, offset: number): number {
    if (offset >= text.length) {
        throw new RangeError('Offset out of range');
    }
    let char = text[offset];

    // Check if it is a high surrogate (part of a surrogate pair)
    if (char >= '\uD800' && char <= '\uDBFF' && offset + 1 < text.length) {
        const nextChar = text[offset + 1];
        // Check if the previous character is a low surrogate
        if (nextChar >= '\uDC00' && nextChar <= '\uDFFF') {
          // If it is, combine the surrogate pair into a full Unicode code point
          return (char.charCodeAt(0) - 0xD800) * 0x400 + (nextChar.charCodeAt(0) - 0xDC00) + 0x10000;
        }
    }
    return char.charCodeAt(0);
  }

  /**
   * Gets the number of UTF-16 code units required to represent a Unicode code point.
   * @param codePoint - The Unicode code point
   * @returns 1 for BMP characters (0x0000-0xFFFF), 2 for supplementary characters (0x10000-0x10FFFF)
   */
  static charCount(codePoint: number): number {
    // If the code point is in the BMP range (0x0000 - 0xFFFF), it needs 1 UTF-16 code unit
    if (codePoint <= 0xFFFF) {
      return 1;
    }
    // If the code point is in the supplementary range (0x10000 - 0x10FFFF), it needs 2 UTF-16 code units
    return 2;
  }

  /**
   * Gets the offset before the current position, handling complex Unicode sequences
   * such as emojis, regional indicators, keycaps, and variation selectors.
   * @param text - The text to examine
   * @param offset - The current offset position
   * @returns The offset before the current position, accounting for Unicode sequences
   */
  static getOffsetBefore(text: string, offset: number): number {
    if (offset <= 1) {
      return 0;
    }

    let codePoint: number = FlutterTextUtils.codePointBefore(text, offset);
    let deleteCharCount: number = FlutterTextUtils.charCount(codePoint);
    let lastOffset: number = offset - deleteCharCount;

    if (lastOffset == 0) {
      return 0;
    }

    // Line Feed
    if (codePoint == LINE_FEED) {
      codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
      if (codePoint == CARRIAGE_RETURN) {
        ++deleteCharCount;
      }
      return offset - deleteCharCount;
    }

    // Flags
    if (FlutterTextUtils.isRegionalIndicatorSymbol(codePoint)) {
      codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
      lastOffset -= FlutterTextUtils.charCount(codePoint);
      let regionalIndicatorSymbolCount: number = 1;
      while (lastOffset > 0 && FlutterTextUtils.isRegionalIndicatorSymbol(codePoint)) {
        codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
        lastOffset -= FlutterTextUtils.charCount(codePoint);
        regionalIndicatorSymbolCount++;
      }
      if (FlutterTextUtils.isRegionalIndicatorSymbol(codePoint)) {
        regionalIndicatorSymbolCount++;
      }
      if (regionalIndicatorSymbolCount % 2 == 0) {
        deleteCharCount += 2;
      }
      return offset - deleteCharCount;
    }

    // Keycaps
    if (codePoint == COMBINING_ENCLOSING_KEYCAP) {
      codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
      lastOffset -= FlutterTextUtils.charCount(codePoint);
      if (lastOffset > 0 && FlutterTextUtils.isVariationSelector(codePoint)) {
        let tmpCodePoint: number = FlutterTextUtils.codePointBefore(text, lastOffset);
        if (FlutterTextUtils.isKeycapBase(tmpCodePoint)) {
          deleteCharCount += FlutterTextUtils.charCount(codePoint) + FlutterTextUtils.charCount(tmpCodePoint);
        }
      } else if (FlutterTextUtils.isKeycapBase(codePoint)) {
        deleteCharCount += FlutterTextUtils.charCount(codePoint);
      }
      return offset - deleteCharCount;
    }

    /**
     * Following if statements for Emoji tag sequence and Variation selector are skipping these
     * modifiers for going through the last statement that is for handling emojis. They return the
     * offset if they don't find proper base characters
     */
    // Emoji Tag Sequence
    if (codePoint == CANCEL_TAG) { // tag_end
      codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
      lastOffset -= FlutterTextUtils.charCount(codePoint);
      while (lastOffset > 0 && FlutterTextUtils.isTagSpecChar(codePoint)) { // tag_spec
        deleteCharCount += FlutterTextUtils.charCount(codePoint);
        codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
        lastOffset -= FlutterTextUtils.charCount(codePoint);
      }
      if (!FlutterTextUtils.isEmoji(codePoint)) { // tag_base not found. Just delete the end.
        return offset - 2;
      }
      deleteCharCount += FlutterTextUtils.charCount(codePoint);
    }

    if (FlutterTextUtils.isVariationSelector(codePoint)) {
      codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
      if (!FlutterTextUtils.isEmoji(codePoint)) {
        return offset - deleteCharCount;
      }
      deleteCharCount += FlutterTextUtils.charCount(codePoint);

      lastOffset -= FlutterTextUtils.charCount(codePoint);
    }

    if (FlutterTextUtils.isEmoji(codePoint)) {
      let isZwj: boolean = false;
      let lastSeenVariantSelectorCharCount: number = 0;
      do {
        if (isZwj) {
          deleteCharCount += FlutterTextUtils.charCount(codePoint) + lastSeenVariantSelectorCharCount + 1;
          isZwj = false;
        }
        lastSeenVariantSelectorCharCount = 0;
        if (FlutterTextUtils.isEmojiModifier(codePoint)) {
          codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
          lastOffset -= FlutterTextUtils.charCount(codePoint);
          if (lastOffset > 0 && FlutterTextUtils.isVariationSelector(codePoint)) {
            codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
            if (!FlutterTextUtils.isEmoji(codePoint)) {
              return offset - deleteCharCount;
            }
            lastSeenVariantSelectorCharCount = FlutterTextUtils.charCount(codePoint);
            lastOffset -= FlutterTextUtils.charCount(codePoint);
          }
          if (FlutterTextUtils.isEmojiModifierBase(codePoint)) {
            deleteCharCount += lastSeenVariantSelectorCharCount + FlutterTextUtils.charCount(codePoint);
          }
          break;
        }

        if (lastOffset > 0) {
          codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
          lastOffset -= FlutterTextUtils.charCount(codePoint);
          if (codePoint == ZERO_WIDTH_JOINER) {
            isZwj = true;
            codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
            lastOffset -= FlutterTextUtils.charCount(codePoint);
            if (lastOffset > 0 && FlutterTextUtils.isVariationSelector(codePoint)) {
              codePoint = FlutterTextUtils.codePointBefore(text, lastOffset);
              lastSeenVariantSelectorCharCount = FlutterTextUtils.charCount(codePoint);
              lastOffset -= FlutterTextUtils.charCount(codePoint);
            }
          }
        }

        if (lastOffset == 0) {
          break;
        }
      } while (isZwj && FlutterTextUtils.isEmoji(codePoint));

      if (isZwj && lastOffset == 0) {
        deleteCharCount += FlutterTextUtils.charCount(codePoint) + lastSeenVariantSelectorCharCount + 1;
        isZwj = false;
      }
    }

    return offset - deleteCharCount;
  }

  /**
   * In preview strings the IME often uses ASCII `'` as pinyin syllable boundaries; Backspace
   * must not treat a lone `'` as one user-visible character deletion.
   */
  private static isOnlyImePreviewApostropheRun(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    for (let i = 0; i < s.length; i++) {
      if (s.charAt(i) !== "'") {
        return false;
      }
    }
    return true;
  }

  /** Same segment-apostrophe set as `PreviewTextStringMerge.isImePreviewApostropheLikeChar` (no circular import). */
  private static isImePreviewApostropheLikeChar(ch: string): boolean {
    if (ch.length === 0) {
      return false;
    }
    const codeUnit = ch.charCodeAt(0);
    return ch === "'" || codeUnit === 0x2019 || codeUnit === 0x02bc || codeUnit === 0xff07;
  }

  private static previewSliceIsOnlyImeApostropheLikeRun(
    text: string,
    start: number,
    endExclusive: number,
  ): boolean {
    if (start < 0 || start >= endExclusive || endExclusive > text.length) {
      return false;
    }
    for (let i = start; i < endExclusive; i++) {
      if (!FlutterTextUtils.isImePreviewApostropheLikeChar(text.charAt(i))) {
        return false;
      }
    }
    return true;
  }

  /**
   * One preview Backspace step: delete `[delStart, delEnd)` so a lone IME `'` left of the caret
   * does not expand the removal to `[delStart, caret)` (which would swallow the previous letter too).
   * When `[plain, offset)` is apostrophe-only, deletes one grapheme cluster immediately before that run:
   * `[getOffsetBefore(text, plain), plain)` instead of `[…, offset)`.
   */
  static getImePreviewBackspaceDeleteRange(text: string, offset: number): ImePreviewBackspaceRange | null {
    if (offset <= 0 || offset > text.length) {
      return null;
    }
    const plain = FlutterTextUtils.getOffsetBefore(text, offset);
    if (plain < 0 || plain >= offset) {
      return null;
    }
    if (!FlutterTextUtils.previewSliceIsOnlyImeApostropheLikeRun(text, plain, offset)) {
      return new ImePreviewBackspaceRange(plain, offset);
    }
    if (plain === 0) {
      return new ImePreviewBackspaceRange(0, offset);
    }
    const userStart = FlutterTextUtils.getOffsetBefore(text, plain);
    if (userStart < 0 || userStart >= plain) {
      return new ImePreviewBackspaceRange(0, offset);
    }
    return new ImePreviewBackspaceRange(userStart, plain);
  }

  /**
   * Same as getOffsetAfter, but if `[offset, end)` is only consecutive `'` (IME separators),
   * extend once more so `'` is not counted alone as one forward-delete step.
   */
  static getOffsetAfterForImePreview(text: string, offset: number): number {
    const len = text.length;
    if (offset >= len) {
      return len;
    }
    let end = FlutterTextUtils.getOffsetAfter(text, offset);
    while (end <= len) {
      const slice = text.substring(offset, end);
      if (!FlutterTextUtils.isOnlyImePreviewApostropheRun(slice)) {
        break;
      }
      if (end >= len) {
        break;
      }
      end = FlutterTextUtils.getOffsetAfter(text, end);
    }
    return end;
  }

  /**
   * Gets the offset after the current position, handling complex Unicode sequences
   * such as emojis, regional indicators, keycaps, and variation selectors.
   * @param text - The text to examine
   * @param offset - The current offset position
   * @returns The offset after the current position, accounting for Unicode sequences
   */
  static getOffsetAfter(text: string, offset: number): number {
    const len = text.length;
    if (offset >= len - 1) {
      return len;
    }

    let codePoint: number = FlutterTextUtils.codePointAt(text, offset);
    let nextCharCount: number = FlutterTextUtils.charCount(codePoint);
    let nextOffset: number = offset + nextCharCount;

    if (nextOffset == 0) {
      return 0;
    }
    // Line Feed
    if (codePoint == LINE_FEED) {
      codePoint = FlutterTextUtils.codePointAt(text, nextOffset);
      if (codePoint == CARRIAGE_RETURN) {
        ++nextCharCount;
      }
      return offset + nextCharCount;
    }

    // Flags
    if (FlutterTextUtils.isRegionalIndicatorSymbol(codePoint)) {
      if (nextOffset >= len - 1
          || !FlutterTextUtils.isRegionalIndicatorSymbol(FlutterTextUtils.codePointAt(text, nextOffset))) {
        return offset + nextCharCount;
      }
      // In this case there are at least two regional indicator symbols ahead of
      // offset. If those two regional indicator symbols are a pair that
      // represent a region together, the next offset should be after both of
      // them.
      let regionalIndicatorSymbolCount: number = 0;
      let regionOffset: number = offset;
      while (regionOffset > 0
          && FlutterTextUtils.isRegionalIndicatorSymbol(FlutterTextUtils.codePointBefore(text, regionOffset))) {
        regionOffset -= FlutterTextUtils.charCount(FlutterTextUtils.codePointBefore(text, regionOffset));
        regionalIndicatorSymbolCount++;
      }
      if (regionalIndicatorSymbolCount % 2 == 0) {
        nextCharCount += 2;
      }
      return offset + nextCharCount;
    }

    // Keycaps
    if (FlutterTextUtils.isKeycapBase(codePoint)) {
      nextCharCount += FlutterTextUtils.charCount(codePoint);
    }
    if (codePoint == COMBINING_ENCLOSING_KEYCAP) {
      codePoint = FlutterTextUtils.codePointBefore(text, nextOffset);
      nextOffset += FlutterTextUtils.charCount(codePoint);
      if (nextOffset < len && FlutterTextUtils.isVariationSelector(codePoint)) {
        let tmpCodePoint: number = FlutterTextUtils.codePointAt(text, nextOffset);
        if (FlutterTextUtils.isKeycapBase(tmpCodePoint)) {
          nextCharCount += FlutterTextUtils.charCount(codePoint) + FlutterTextUtils.charCount(tmpCodePoint);
        }
      } else if (FlutterTextUtils.isKeycapBase(codePoint)) {
        nextCharCount += FlutterTextUtils.charCount(codePoint);
      }
      return offset + nextCharCount;
    }

    if (FlutterTextUtils.isEmoji(codePoint)) {
      let isZwj: boolean = false;
      let lastSeenVariantSelectorCharCount: number = 0;
      do {
        if (isZwj) {
          nextCharCount += FlutterTextUtils.charCount(codePoint) + lastSeenVariantSelectorCharCount + 1;
          isZwj = false;
        }
        lastSeenVariantSelectorCharCount = 0;
        if (FlutterTextUtils.isEmojiModifier(codePoint)) {
          break;
        }

        if (nextOffset < len) {
          codePoint = FlutterTextUtils.codePointAt(text, nextOffset);
          nextOffset += FlutterTextUtils.charCount(codePoint);
          if (codePoint == COMBINING_ENCLOSING_KEYCAP) {
            codePoint = FlutterTextUtils.codePointBefore(text, nextOffset);
            nextOffset += FlutterTextUtils.charCount(codePoint);
            if (nextOffset < len && FlutterTextUtils.isVariationSelector(codePoint)) {
              let tmpCodePoint: number = FlutterTextUtils.codePointAt(text, nextOffset);
              if (FlutterTextUtils.isKeycapBase(tmpCodePoint)) {
                nextCharCount += FlutterTextUtils.charCount(codePoint) + FlutterTextUtils.charCount(tmpCodePoint);
              }
            } else if (FlutterTextUtils.isKeycapBase(codePoint)) {
              nextCharCount += FlutterTextUtils.charCount(codePoint);
            }
            return offset + nextCharCount;
          }
          if (FlutterTextUtils.isEmojiModifier(codePoint)) {
            nextCharCount += lastSeenVariantSelectorCharCount + FlutterTextUtils.charCount(codePoint);
            break;
          }
          if (FlutterTextUtils.isVariationSelector(codePoint)) {
            nextCharCount += lastSeenVariantSelectorCharCount + FlutterTextUtils.charCount(codePoint);
            break;
          }
          if (codePoint == ZERO_WIDTH_JOINER) {
            isZwj = true;
            codePoint = FlutterTextUtils.codePointAt(text, nextOffset);
            nextOffset += FlutterTextUtils.charCount(codePoint);
            if (nextOffset < len && FlutterTextUtils.isVariationSelector(codePoint)) {
              codePoint = FlutterTextUtils.codePointAt(text, nextOffset);
              lastSeenVariantSelectorCharCount = FlutterTextUtils.charCount(codePoint);
              nextOffset += FlutterTextUtils.charCount(codePoint);
            }
          }
        }

        if (nextOffset >= len) {
          break;
        }
      } while (isZwj && FlutterTextUtils.isEmoji(codePoint));

      if (isZwj && nextOffset >= len) {
        nextCharCount += FlutterTextUtils.charCount(codePoint) + lastSeenVariantSelectorCharCount + 1;
        isZwj = false;
      }
    }

    return offset + nextCharCount;
  }
}
