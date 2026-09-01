/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on ListenableEditingState.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import { TextEditState } from '../../embedding/engine/systemchannels/TextInputChannel';
import Log from '../../util/Log';
import inputMethod from '@ohos.inputMethod';
import ArrayList from '@ohos.util.ArrayList';
import { TextEditingDelta } from './TextEditingDelta';
import TextInputChannel from '../../embedding/engine/systemchannels/TextInputChannel';
import { FlutterTextUtils } from './TextUtils';
import { KeyCode } from '@kit.InputKit';
import KeyEventChannel, { SimulateKeyEvent } from '../../embedding/engine/systemchannels/KeyEventChannel';
import { PasteboardUtils } from '../../util/PasteboardUtils';
import { isPreviewTextSupported } from './PreviewTextSupport';
import { PreviewTextStringMerge } from './PreviewTextStringMerge';
import { PreviewTextMergeContext } from './PreviewTextMergeContext';
import { PreviewSpanCoalescing } from './PreviewSpanCoalescing';

const TAG = "ListenableEditingState";

/**
 * Enumeration of delete operation states.
 */
enum DeleteStates {
  /** Delete operation has started */
  START,
  /** Delete operation is in progress */
  MOVING,
  /** Delete operation has ended */
  END
}

/**
 * Snapshot of editing state; same role as Android ListenableEditingState for text / selection / composing diffs before notify.
 */
export interface EditingStateSnapshot {
  text: string;
  selectionStart: number;
  selectionEnd: number;
  composingStart: number;
  composingEnd: number;
}

/** Half-open [start, end) span in document coordinates (trailing Latin / IME apostrophe suffix). */
interface TrailingLatinImePreviewSuffixRange {
  start: number;
  end: number;
}

/** Text/selection/composing + OHOS preview span; mirrors Android ListenableEditingState. Flutter sync via `updateTextInputState` / `TextInputMethodHandlerImpl.setEditingState`. */
export class ListenableEditingState {
  private static findTrailingLatinImePreviewSuffixRange(full: string): TrailingLatinImePreviewSuffixRange | null {
    const fullLen = full.length;
    if (fullLen === 0) {
      return null;
    }
    let suffixStart = fullLen;
    while (suffixStart > 0) {
      const scanChar = full.charAt(suffixStart - 1);
      const isApo =
        scanChar === "'" || scanChar.charCodeAt(0) === 0x2019 || scanChar.charCodeAt(0) === 0x02bc || scanChar.charCodeAt(0) === 0xff07;
      const isLat = (scanChar >= 'a' && scanChar <= 'z') || (scanChar >= 'A' && scanChar <= 'Z');
      if (!(isApo || isLat)) {
        break;
      }
      suffixStart--;
    }
    if (suffixStart >= fullLen) {
      return null;
    }
    let hasLetter = false;
    for (let idx = suffixStart; idx < fullLen; idx++) {
      const suffixCh = full.charAt(idx);
      if ((suffixCh >= 'a' && suffixCh <= 'z') || (suffixCh >= 'A' && suffixCh <= 'Z')) {
        hasLetter = true;
        break;
      }
    }
    if (!hasLetter) {
      return null;
    }
    let hasCjkBefore = false;
    for (let idx = 0; idx < suffixStart; idx++) {
      const codeUnit = full.charCodeAt(idx);
      if (codeUnit >= 0x4e00 && codeUnit <= 0x9fff) {
        hasCjkBefore = true;
        break;
      }
    }
    if (!hasCjkBefore) {
      return null;
    }
    if (suffixStart > 0) {
      const charBeforeSuffix = full.charAt(suffixStart - 1);
      if ((charBeforeSuffix >= 'a' && charBeforeSuffix <= 'z') || (charBeforeSuffix >= 'A' && charBeforeSuffix <= 'Z')) {
        return null;
      }
    }
    const range: TrailingLatinImePreviewSuffixRange = { start: suffixStart, end: fullLen };
    return range;
  }

  private static isBmpCjkOnlyInsert(text: string): boolean {
    if (text.length < 1) {
      return false;
    }
    for (let idx = 0; idx < text.length; idx++) {
      const codeUnit = text.charCodeAt(idx);
      if (codeUnit < 0x4e00 || codeUnit > 0x9fff) {
        return false;
      }
    }
    return true;
  }

  /** Lowercase a–z only, length in [2,8] (pinyin tail after leading segment `'` in preview span). */
  private static isAsciiLowerLatinTailForPrefixCommit(asciiTail: string): boolean {
    const tailLen = asciiTail.length;
    if (tailLen < 2 || tailLen > 8) {
      return false;
    }
    for (let idx = 0; idx < tailLen; idx++) {
      const codeUnit = asciiTail.charCodeAt(idx);
      if (codeUnit < 0x61 || codeUnit > 0x7a) {
        return false;
      }
    }
    return true;
  }

  /**
   * When caret leaves [leftIdx,rightIdx) into strict prefix/suffix, OHOS may not send insertText for the first candidate.
   * Map a tiny set of tails (not IME dictionary); extend as needed.
   */
  private static latinTailToFirstHanOnCaretOutsidePreview(latinLower: string): string | null {
    if (latinLower === 'hao') {
      return '好';
    }
    return null;
  }

  /** IME-style syllable boundary: ASCII `'` and common Unicode apostrophe variants. */
  static isImeSegmentApostropheLikeChar(segmentChar: string): boolean {
    if (segmentChar === "'" || segmentChar.charCodeAt(0) === 0x2019 || segmentChar.charCodeAt(0) === 0x02bc || segmentChar.charCodeAt(0) === 0xff07) {
      return true;
    }
    return false;
  }

  private TextInputChannel: TextInputChannel | null = null;
  private keyEventChannel: KeyEventChannel | undefined;
  private client: number = 0
  private leftDeleteState: DeleteStates = DeleteStates.END
  private rightDeleteState: DeleteStates = DeleteStates.END
  private mStringCache: string;
  private mSelectionStartCache: number = 0;
  private mSelectionEndCache: number = 0;
  private mComposingStartCache: number = 0;
  private mComposingEndCache: number = 0;

  private mListeners: ArrayList<EditingStateWatcher> = new ArrayList<EditingStateWatcher>();
  private mPendingListeners: ArrayList<EditingStateWatcher> = new ArrayList<EditingStateWatcher>();
  private mBatchTextEditingDeltas: ArrayList<TextEditingDelta> = new ArrayList<TextEditingDelta>();
  private mChangeNotificationDepth: number = 0;
  private mBatchEditNestDepth: number = 0;
  private mTextWhenBeginBatchEdit: string;
  private mSelectionStartWhenBeginBatchEdit: number = 0;
  private mSelectionEndWhenBeginBatchEdit: number = 0;
  private mComposingStartWhenBeginBatchEdit: number = 0;
  private mComposingEndWhenBeginBatchEdit: number = 0;

  /** Document span [leftIdx,rightIdx) in `mStringCache`; IME preview string `mPreviewText` should match that slice when non-empty. */
  private mPreviewText: string = "";
  private mPreviewTextStart: number = 0;
  private mPreviewTextEnd: number = 0;
  private mLeftIdxOfPreviewTextRange: number = 0;
  private mRightIdxOfPreviewTextRange: number = 0;
  private mIsCursorIdxOutOfPreviewTextRange: boolean = false;
  /** Preview-relative selection (0..len of preview run); flushed to `mSelection*` in document coords. */
  private mPreviewSelectionStartRel: number = 0;
  private mPreviewSelectionEndRel: number = 0;
  /** Credits: skip applying Framework selection when it looks like a stale “caret at rightIdx” echo after a mid-preview edit. */
  private mSkipFlutterStaleEndEchoRemaining: number = 0;
  /** Countdown: after some merges, ignore noop IME preview callbacks that would overwrite caret from `imeRel`. */
  private mSkipNoopImeCaretForPreviewsRemaining: number = 0;
  /** After preview merge, handler should run `syncImcSelectionAfterEditableChange` once. */
  private mImcFullSyncAfterPreviewInsert: boolean = false;

  markSkipNextFlutterSelectionApplyOnce(): void {
    this.mSkipFlutterStaleEndEchoRemaining = Math.max(this.mSkipFlutterStaleEndEchoRemaining, 6);
  }

  getSkipFlutterStaleEndEchoRemaining(): number {
    return this.mSkipFlutterStaleEndEchoRemaining;
  }

  /** Call when a Framework selection echo pinned at preview end was skipped; decrements remaining skip budget. */
  consumeStaleEndEchoSkipCredit(): void {
    if (this.mSkipFlutterStaleEndEchoRemaining > 0) {
      this.mSkipFlutterStaleEndEchoRemaining--;
    }
  }

  consumeImcFullSyncAfterPreviewInsert(): boolean {
    if (!this.mImcFullSyncAfterPreviewInsert) {
      return false;
    }
    this.mImcFullSyncAfterPreviewInsert = false;
    return true;
  }

  /** True when document preview span leftIdx < rightIdx (independent of whether `mPreviewText` is temporarily empty). */
  isPreviewStagingActive(): boolean {
    return this.mLeftIdxOfPreviewTextRange !== this.mRightIdxOfPreviewTextRange;
  }

  /**
   * Max of IME preview string length and cache span (rightIdx−leftIdx). After in-preview deletes, `mPreviewText` can briefly lag
   * empty while [leftIdx,rightIdx) still holds the pinyin in `mStringCache`; relative caret clamping must use this, not preview text length alone.
   */
  private previewEffectiveSpanLength(): number {
    if (this.mLeftIdxOfPreviewTextRange === this.mRightIdxOfPreviewTextRange) {
      return 0;
    }
    const span = this.mRightIdxOfPreviewTextRange - this.mLeftIdxOfPreviewTextRange;
    const previewTextLen = this.getPreviewText().length;
    return previewTextLen > span ? previewTextLen : span;
  }

  /**
   * Current displayed full text (during preview this is the sole local string, including preview run).
   */
  getStagingComposedText(): string {
    return this.mStringCache;
  }

  /**
   * Replace preview span [left, right) in cache with newPreview; update mPreviewText and right bound.
   * Suffix must be taken from current mRightIdx (same as coalesce), not only leftIdx + mPreviewText.length:
   * when rightIdx lags preview text length briefly, the old formula mis-merges or drops trailing preview code units still in cache,
   * e.g. Backspace between b|c leaves a| while suggestions still show c.
   */
  private writePreviewSpanIntoCache(newPreview: string): void {
    const leftIdx = this.mLeftIdxOfPreviewTextRange;
    if (this.mPreviewText !== '' || this.mLeftIdxOfPreviewTextRange !== this.mRightIdxOfPreviewTextRange) {
      this.syncPreviewRightToPreviewLength();
      this.repairPreviewSpanInCacheIfDrifted();
    }
    const rightIdx = this.mRightIdxOfPreviewTextRange;
    const suffix = this.mStringCache.substring(rightIdx);
    this.mStringCache = this.mStringCache.substring(0, leftIdx) + newPreview + suffix;
    this.setPreviewText(newPreview);
    this.mRightIdxOfPreviewTextRange = leftIdx + newPreview.length;
  }

  /**
   * Align mRightIdx with mPreviewText length and remove stale code units [leftIdx+previewTextLen, leftIdx+oldRightIdx) from mStringCache when preview shrinks.
   * Otherwise shrinking rightIdx only leaves old preview tail in cache; mid-field preview after mid Backspace / IME tail trim shows extra pinyin or wrong suffix.
   */
  private syncPreviewRightToPreviewLength(): void {
    const leftIdx = this.mLeftIdxOfPreviewTextRange;
    const previewTextLen = this.mPreviewText.length;
    const oldRightIdx = this.mRightIdxOfPreviewTextRange;
    const syncResult = PreviewSpanCoalescing.syncCacheRightToPreviewLength(
      this.mStringCache,
      leftIdx,
      previewTextLen,
      oldRightIdx,
    );
    this.mStringCache = syncResult.cache;
    this.mRightIdxOfPreviewTextRange = syncResult.rightIdx;
  }

  /**
   * If cache preview span disagrees with mPreviewText, rewrite span from mPreviewText (IME preview is source of truth).
   */
  private repairPreviewSpanInCacheIfDrifted(): void {
    const leftIdx = this.mLeftIdxOfPreviewTextRange;
    const rightIdx = this.mRightIdxOfPreviewTextRange;
    const repairResult = PreviewSpanCoalescing.repairPreviewSpanIfDrifted(this.mStringCache, leftIdx, rightIdx, this.mPreviewText);
    this.mStringCache = repairResult.cache;
    this.mRightIdxOfPreviewTextRange = repairResult.rightIdx;
  }

  /**
   * Align mRightIdx with mPreviewText and rewrite [leftIdx,rightIdx) in cache from mPreviewText (metadata wins).
   * Call before IME setPreviewText / pushing display to Flutter so lagging rightIdx does not duplicate tail via substring(rightIdx)
   * (candidates OK but field gains chars / misaligns on second Backspace).
   */
  coalescePreviewSpanWithCache(): void {
    if (this.mPreviewText === '' || this.mLeftIdxOfPreviewTextRange === this.mRightIdxOfPreviewTextRange) {
      return;
    }
    const leftIdx = this.mLeftIdxOfPreviewTextRange;
    this.syncPreviewRightToPreviewLength();
    this.repairPreviewSpanInCacheIfDrifted();
  }

  /** True while [leftIdx,rightIdx) is the preview span — IME may clear mPreviewText briefly before insertText. */
  private previewCaretSessionActive(): boolean {
    return this.isPreviewStagingActive();
  }

  /**
   * Flush relative selection into document mSelection* (single outward display). Caller must ensure previewCaretSessionActive.
   */
  private flushPreviewRelativeToDocumentSelection(): void {
    if (!this.previewCaretSessionActive()) {
      return;
    }
    const leftIdx = this.mLeftIdxOfPreviewTextRange;
    const len = this.previewEffectiveSpanLength();
    let relStart = this.mPreviewSelectionStartRel;
    let relEnd = this.mPreviewSelectionEndRel;
    if (relStart < 0) {
      relStart = 0;
    }
    if (relEnd < 0) {
      relEnd = 0;
    }
    if (relStart > len) {
      relStart = len;
    }
    if (relEnd > len) {
      relEnd = len;
    }
    if (relStart > relEnd) {
      const swapHold = relStart;
      relStart = relEnd;
      relEnd = swapHold;
    }
    this.mPreviewSelectionStartRel = relStart;
    this.mPreviewSelectionEndRel = relEnd;
    this.mSelectionStartCache = leftIdx + relStart;
    this.mSelectionEndCache = leftIdx + relEnd;
  }

  /**
   * Preview-edit path only: set relative selection inside preview string and refresh document selection.
   */
  private setPreviewRelativeSelection(startRel: number, endRel: number): void {
    this.mPreviewSelectionStartRel = startRel;
    this.mPreviewSelectionEndRel = endRel;
    this.flushPreviewRelativeToDocumentSelection();
  }

  /**
   * After document selection is written directly (e.g. suffix delete), sync relative selection from mSelection* for later IME callbacks.
   */
  private syncPreviewRelativeFromDocumentAfterDirectSelectionChange(): void {
    if (!this.previewCaretSessionActive()) {
      return;
    }
    const leftIdx = this.mLeftIdxOfPreviewTextRange;
    const rightIdx = this.mRightIdxOfPreviewTextRange;
    const len = this.previewEffectiveSpanLength();
    let selMinDoc = Math.min(this.mSelectionStartCache, this.mSelectionEndCache);
    let selMaxDoc = Math.max(this.mSelectionStartCache, this.mSelectionEndCache);
    if (selMinDoc >= leftIdx && selMaxDoc <= rightIdx) {
      this.mPreviewSelectionStartRel = selMinDoc - leftIdx;
      this.mPreviewSelectionEndRel = selMaxDoc - leftIdx;
      return;
    }
    if (selMinDoc >= rightIdx) {
      this.mPreviewSelectionStartRel = len;
      this.mPreviewSelectionEndRel = len;
    } else if (selMaxDoc <= leftIdx) {
      this.mPreviewSelectionStartRel = 0;
      this.mPreviewSelectionEndRel = 0;
    } else {
      this.mPreviewSelectionStartRel = 0;
      this.mPreviewSelectionEndRel = len;
    }
  }

  /** IME setPreviewText entry: align relative selection from current document selection, then merge. */
  private syncPreviewRelativeFromDocumentAtImePreviewEntry(): void {
    if (!this.previewCaretSessionActive()) {
      return;
    }
    const leftIdx = this.mLeftIdxOfPreviewTextRange;
    const rightIdx = this.mRightIdxOfPreviewTextRange;
    const selMinDoc = Math.min(this.mSelectionStartCache, this.mSelectionEndCache);
    const selMaxDoc = Math.max(this.mSelectionStartCache, this.mSelectionEndCache);
    if (selMinDoc >= leftIdx && selMaxDoc <= rightIdx) {
      this.mPreviewSelectionStartRel = selMinDoc - leftIdx;
      this.mPreviewSelectionEndRel = selMaxDoc - leftIdx;
      return;
    }
    this.syncPreviewRelativeFromDocumentAfterDirectSelectionChange();
  }

  /**
   * Flutter/Framework writes selection while preview staging: update both document coords and internal relative pair.
   */
  applyExternalDocumentSelectionWhilePreviewStaging(docStart: number, docEnd: number): void {
    this.mSelectionStartCache = docStart;
    this.mSelectionEndCache = docEnd;
    if (!this.previewCaretSessionActive()) {
      return;
    }
    const leftIdx = this.mLeftIdxOfPreviewTextRange;
    const rightIdx = this.mRightIdxOfPreviewTextRange;
    let selMinDoc = Math.min(docStart, docEnd);
    let selMaxDoc = Math.max(docStart, docEnd);
    // Caret/selection entirely before [leftIdx,rightIdx) or after rightIdx: keep document coords; do not clamp+flush to leftIdx (would jump 你|好 → 你好|).
    if (selMaxDoc < leftIdx || selMinDoc > rightIdx) {
      this.syncPreviewRelativeFromDocumentAfterDirectSelectionChange();
      return;
    }
    if (selMinDoc < leftIdx) {
      selMinDoc = leftIdx;
    }
    if (selMaxDoc > rightIdx) {
      selMaxDoc = rightIdx;
    }
    if (selMinDoc > selMaxDoc) {
      selMaxDoc = selMinDoc;
    }
    this.mPreviewSelectionStartRel = selMinDoc - leftIdx;
    this.mPreviewSelectionEndRel = selMaxDoc - leftIdx;
    this.flushPreviewRelativeToDocumentSelection();
  }

  /**
   * Collapsed caret strictly before leftIdx or after rightIdx; span is ASCII `'` + lowercase latin tail [2,8];
   * char before leftIdx is BMP CJK; only supported tail today is `hao` → `好`. Caller should apply selection first.
   * @returns true if span was replaced (staging cleared via `handleInsertTextEvent`).
   */
  commitLeadingLatinPreviewWhenCaretOutsideSpan(): boolean {
    if (!this.isPreviewStagingActive()) {
      return false;
    }
    const leftIdx = this.mLeftIdxOfPreviewTextRange;
    const rightIdx = this.mRightIdxOfPreviewTextRange;
    if (!(leftIdx < rightIdx) || leftIdx < 1) {
      return false;
    }
    const sCol = Math.min(this.mSelectionStartCache, this.mSelectionEndCache);
    const eCol = Math.max(this.mSelectionStartCache, this.mSelectionEndCache);
    if (sCol !== eCol) {
      return false;
    }
    const strictPrefix = eCol < leftIdx;
    const strictSuffix = sCol > rightIdx;
    if (!strictPrefix && !strictSuffix) {
      return false;
    }
    const mid = this.mStringCache.substring(leftIdx, rightIdx);
    if (mid.length < 2 || mid.charCodeAt(0) !== 0x27) {
      return false;
    }
    const latin = mid.substring(1);
    if (!ListenableEditingState.isAsciiLowerLatinTailForPrefixCommit(latin)) {
      return false;
    }
    const han = ListenableEditingState.latinTailToFirstHanOnCaretOutsidePreview(latin.toLowerCase());
    if (han === null || !ListenableEditingState.isBmpCjkOnlyInsert(han)) {
      return false;
    }
    const prevCp = this.mStringCache.charCodeAt(leftIdx - 1);
    if (prevCp < 0x4e00 || prevCp > 0x9fff) {
      return false;
    }
    this.mSelectionStartCache = leftIdx;
    this.mSelectionEndCache = leftIdx;
    this.handleInsertTextEvent(han);
    return true;
  }

  /** For `handleInsertPreviewTextEvent`: document selection inside [leftIdx,rightIdx), else prefix/suffix uses raw coords, else leftIdx+rel. */
  private selectionStartForImeMerge(leftBound: number): number {
    if (this.previewCaretSessionActive()) {
      const leftIdx = this.mLeftIdxOfPreviewTextRange;
      const rightIdx = this.mRightIdxOfPreviewTextRange;
      const selMinDoc = Math.min(this.mSelectionStartCache, this.mSelectionEndCache);
      const selMaxDoc = Math.max(this.mSelectionStartCache, this.mSelectionEndCache);
      if (selMinDoc >= leftIdx && selMaxDoc <= rightIdx) {
        return selMinDoc;
      }
      // Rel uses 0 for "any caret strictly before leftIdx", which maps to document leftIdx — wrong for 你|好 + preview at leftIdx.
      if (selMaxDoc < leftIdx) {
        return selMinDoc;
      }
      if (selMinDoc >= rightIdx) {
        return selMinDoc;
      }
      return leftBound + this.mPreviewSelectionStartRel;
    }
    return this.mSelectionStartCache;
  }

  private selectionEndForImeMerge(leftBound: number): number {
    if (this.previewCaretSessionActive()) {
      const leftIdx = this.mLeftIdxOfPreviewTextRange;
      const rightIdx = this.mRightIdxOfPreviewTextRange;
      const selMinDoc = Math.min(this.mSelectionStartCache, this.mSelectionEndCache);
      const selMaxDoc = Math.max(this.mSelectionStartCache, this.mSelectionEndCache);
      if (selMinDoc >= leftIdx && selMaxDoc <= rightIdx) {
        return selMaxDoc;
      }
      if (selMaxDoc < leftIdx) {
        return selMaxDoc;
      }
      if (selMinDoc >= rightIdx) {
        return selMaxDoc;
      }
      return leftBound + this.mPreviewSelectionEndRel;
    }
    return this.mSelectionEndCache;
  }

  /**
   * Clear preview staging metadata only; do not change mStringCache (use when body was already written by caller).
   */
  clearPreviewStagingFieldsOnly(): void {
    this.mPreviewText = "";
    this.mPreviewTextStart = 0;
    this.mPreviewTextEnd = 0;
    this.mLeftIdxOfPreviewTextRange = 0;
    this.mRightIdxOfPreviewTextRange = 0;
    this.mPreviewSelectionStartRel = 0;
    this.mPreviewSelectionEndRel = 0;
  }

  /**
   * Drop preview session: clear staging metadata only; do not merge preview into mStringCache (Flutter updateTextInputState usually follows).
   */
  discardPreviewStagingMetadata(): void {
    this.clearPreviewStagingFieldsOnly();
  }

  /**
   * Constructs a new ListenableEditingState instance.
   * @param TextInputChannel - The TextInputChannel for communication, possibly null
   * @param client - The client ID
   * @param keyEventChannel - Optional KeyEventChannel for key event handling
   */
  constructor(TextInputChannel:TextInputChannel | null,client:number, keyEventChannel?: KeyEventChannel) {
    this.TextInputChannel = TextInputChannel;
    this.keyEventChannel = keyEventChannel;
    this.client = client
    this.mStringCache = "";
    this.mTextWhenBeginBatchEdit = "";
    this.mSelectionStartCache = 0;
    this.mSelectionEndCache = 0;
    this.mComposingStartCache = -1;
    this.mComposingEndCache = -1;
    this.mPreviewText = "";
  }

  /**
   * Extracts and clears the batch of text editing deltas.
   * @returns A list of TextEditingDelta objects representing the changes
   */
  extractBatchTextEditingDeltas(): ArrayList<TextEditingDelta> {
    let currentBatchDeltas = new ArrayList<TextEditingDelta>();
    this.mBatchTextEditingDeltas.forEach((data) => {
      currentBatchDeltas.add(data);
    })
    this.mBatchTextEditingDeltas.clear();
    return currentBatchDeltas;
  }

  /**
   * Clears all batched text editing deltas.
   */
  clearBatchDeltas(): void {
    this.mBatchTextEditingDeltas.clear();
  }

  /**
   * Replaces a range of text with new text.
   * @param start - The start position of the range to replace
   * @param end - The end position of the range to replace
   * @param tb - The replacement text
   * @param tbStart - The start position within the replacement text
   * @param tbEnd - The end position within the replacement text
   */
  replace(start: number, end: number, tb: String, tbStart: number, tbEnd: number): void {
    const placeIndex =
      this.mSelectionStartCache < this.mSelectionEndCache ? this.mSelectionStartCache : this.mSelectionEndCache;

    this.mBatchTextEditingDeltas.add(
      new TextEditingDelta(
        this.mStringCache.toString(),
        placeIndex + tbEnd,
        placeIndex + tbEnd,
        this.getComposingStart(),
        this.getComposingEnd(),
        start,
        end + tbStart,
        tb.toString()
      ));
  }

  /**
   * Gets the current selection start position.
   * @returns The selection start position
   */
  getSelectionStart(): number {
    return this.mSelectionStartCache;
  }

  /**
   * Gets the current selection end position.
   * @returns The selection end position
   */
  getSelectionEnd(): number {
    return this.mSelectionEndCache;
  }

  /**
   * Gets the current composing region start position.
   * @returns The composing start position, or -1 if no composing region
   */
  getComposingStart(): number {
    return this.mComposingStartCache;
  }

  /**
   * Gets the current composing region end position.
   * @returns The composing end position, or -1 if no composing region
   */
  getComposingEnd(): number {
    return this.mComposingEndCache;
  }

  /**
   * Gets the current text content.
   * @returns The text string
   */
  getStringCache(): string {
    return this.mStringCache;
  }

  /**
   * Gets the currently selected text.
   * @returns The selected text, or empty string if selection is invalid
   */
  getSelectionString(): string {
    if (this.mSelectionStartCache < 0 || this.mSelectionEndCache > this.mStringCache.length) {
      return "";
    }
    return this.mStringCache.substring(this.mSelectionStartCache, this.mSelectionEndCache);
  }

  /**
   * Gets the current preview text from the input method.
   * @returns The preview text
   */
  getPreviewText(): string {
    return this.mPreviewText;
  }

  /**
   * Gets the start position of the preview text in the original text.
   * @returns The preview text start position
   */
  getPreviewTextStart(): number {
    return this.mPreviewTextStart;
  }

  /**
   * Gets the end position of the preview text in the original text.
   * @returns The preview text end position
   */
  getPreviewTextEnd(): number {
    return this.mPreviewTextEnd;
  }

  /**
   * Gets the right index of the preview text range in the string cache.
   * @returns The right index of the preview text range
   */
  getRightIdxOfPreviewTextRange() : number {
    return this.mRightIdxOfPreviewTextRange;
  }

  /**
   * Gets the left index of the preview text range in the string cache.
   * @returns The left index of the preview text range
   */
  getLeftIdxOfPreviewTextRange() : number {
    return this.mLeftIdxOfPreviewTextRange;
  }

  /**
   * Sets the preview text.
   * @param previewText - The preview text to set
   */
  setPreviewText(previewText: string): void {
    this.mPreviewText = previewText;
  }

  /**
   * Sets the start position of the preview text.
   * @param previewTextStart - The start position
   */
  setPreviewTextStart(previewTextStart: number): void {
    this.mPreviewTextStart = previewTextStart;
  }

  /**
   * Sets the end position of the preview text.
   * @param previewTextEnd - The end position
   */
  setPreviewTextEnd(previewTextEnd: number): void {
    this.mPreviewTextEnd = previewTextEnd;
  }

  /**
   * Updates the preview text range indices.
   * @param leftIdx - The left index in the string cache
   * @param rightIdx - The right index in the string cache
   */
  updatePreviewTextRange(leftIdx: number, rightIdx: number): void {
    this.mLeftIdxOfPreviewTextRange = leftIdx;
    this.mRightIdxOfPreviewTextRange = rightIdx;
  }

  /**
   * Clears all preview text contents and resets related indices.
   */
  clearPreviewTextContents() : void {
    this.clearPreviewStagingFieldsOnly();
  }

  /**
   * Sets whether the cursor index is out of the preview text range.
   * @param hasChanged - True if the cursor is out of range, false otherwise
   */
  setIsCursorIdxOutOfPreviewTextRange(hasChanged: boolean): void {
    this.mIsCursorIdxOutOfPreviewTextRange = hasChanged;
  }

  /**
   * Gets whether the cursor index is out of the preview text range.
   * @returns True if the cursor is out of range, false otherwise
   */
  getIsCursorIdxOutOfPreviewTextRange(): boolean {
    return this.mIsCursorIdxOutOfPreviewTextRange;
  }

  /**
   * Sets the selection start position.
   * @param newSelectionStart - The new selection start position
   */
  setSelectionStart(newSelectionStart: number): void {
    this.mSelectionStartCache = newSelectionStart;
  }

  /**
   * Sets the selection end position.
   * @param newSelectionEnd - The new selection end position
   */
  setSelectionEnd(newSelectionEnd: number): void {
    this.mSelectionEndCache = newSelectionEnd;
  }

  /**
   * Sets the composing region start position.
   * @param newComposingStart - The new composing start position, or -1 to clear
   */
  setComposingStart(newComposingStart: number): void {
    this.mComposingStartCache = newComposingStart;
  }

  /**
   * Sets the composing region end position.
   * @param newComposingEnd - The new composing end position, or -1 to clear
   */
  setComposingEnd(newComposingEnd: number): void {
    this.mComposingEndCache = newComposingEnd;
  }

  /**
   * Sets the text content.
   * @param newStringCache - The new text content
   */
  setStringCache(newStringCache: string): void {
    this.mStringCache = newStringCache;
  }

  /**
   * Notifies a single listener of editing state changes.
   * @param listener - The listener to notify
   * @param textChanged - Whether the text has changed
   * @param selectionChanged - Whether the selection has changed
   * @param composingChanged - Whether the composing region has changed
   */
  notifyListener(listener: EditingStateWatcher,
    textChanged: boolean,
    selectionChanged: boolean,
    composingChanged: boolean): void {
    this.mChangeNotificationDepth++;
    listener.didChangeEditingState(textChanged, selectionChanged, composingChanged);
    this.mChangeNotificationDepth--;
  }

  /**
   * Notifies all listeners if any changes have occurred.
   * @param textChanged - Whether the text has changed
   * @param selectionChanged - Whether the selection has changed
   * @param composingChanged - Whether the composing region has changed
   */
  notifyListenersIfNeeded(textChanged: boolean, selectionChanged: boolean, composingChanged: boolean) {
    if (textChanged || selectionChanged || composingChanged) {
      for (const listener of this.mListeners) {
        this.notifyListener(listener, textChanged, selectionChanged, composingChanged);
      }
    }
  }

  /**
   * Capture current native editing state (single truth for Framework: full cache + selection + composing).
   */
  captureEditingSnapshot(): EditingStateSnapshot {
    return {
      text: this.getStringCache(),
      selectionStart: this.getSelectionStart(),
      selectionEnd: this.getSelectionEnd(),
      composingStart: this.getComposingStart(),
      composingEnd: this.getComposingEnd()
    };
  }

  /**
   * Diff vs snapshot for text / selection / composing, then notify (same idea as Android replace tail + endBatchEdit).
   */
  notifyListenersIfChangedSince(before: EditingStateSnapshot): void {
    const textChanged = before.text !== this.getStringCache();
    const selectionChanged =
      before.selectionStart !== this.getSelectionStart() || before.selectionEnd !== this.getSelectionEnd();
    const composingChanged =
      before.composingStart !== this.getComposingStart() || before.composingEnd !== this.getComposingEnd();
    this.notifyListenersIfNeeded(textChanged, selectionChanged, composingChanged);
  }

  /**
   * Clamp selection to [0, mStringCache.length]. When IME clears preview the session ends and flush must not write mSelection*
   * at stale lengths or later TextEditState from syncEditingState throws invalid selection.
   */
  private clampDocumentSelectionToCache(): void {
    const len = this.mStringCache.length;
    let docSelStart = this.mSelectionStartCache;
    let docSelEnd = this.mSelectionEndCache;
    if (docSelStart < 0) {
      docSelStart = 0;
    }
    if (docSelEnd < 0) {
      docSelEnd = 0;
    }
    if (docSelStart > len) {
      docSelStart = len;
    }
    if (docSelEnd > len) {
      docSelEnd = len;
    }
    
    this.mSelectionStartCache = docSelStart;
    this.mSelectionEndCache = docSelEnd;
  }

  /**
   * IME `setPreviewText`: merge into `mStringCache` span [leftIdx,rightIdx), fold apostrophes, map caret. Rules live in
   * `PreviewTextStringMerge` + `applyImePreviewCaretAfterMerge`; sets `mImcFullSyncAfterPreviewInsert` for handler sync.
   */
  handleInsertPreviewTextEvent(text: string, range: inputMethod.Range): void {
    const notifySnap = this.captureEditingSnapshot();
    const ctx = new PreviewTextMergeContext();
    this.coalescePreviewSpanWithCache();

    ctx.imeText = text;
    ctx.prevPreview = this.getPreviewText();
    ctx.prevLen = ctx.prevPreview.length;
    ctx.hadActivePreview = this.mLeftIdxOfPreviewTextRange !== this.mRightIdxOfPreviewTextRange;
    ctx.oldLeft = this.mLeftIdxOfPreviewTextRange;
    this.syncPreviewRelativeFromDocumentAtImePreviewEntry();
    ctx.selStart = this.selectionStartForImeMerge(ctx.oldLeft);
    ctx.selEnd = this.selectionEndForImeMerge(ctx.oldLeft);
    ctx.textForMerge = text;
    ctx.imeFullBodyMode = range.start < 0 || range.end < 0;

    PreviewTextStringMerge.initPreviewRangeSplice(ctx, range.start, range.end);
    PreviewTextStringMerge.correctDuplicativeOpeningTextSplice(ctx);
    PreviewTextStringMerge.dropMisleadingSpanEndSpliceForMidCaret(ctx);
    PreviewTextStringMerge.repairPreviewRangeSpliceWhenDisagreesWithLocalOneStepBackspace(ctx);
    PreviewTextStringMerge.applyFullBodySuffixStitch(ctx);
    PreviewTextStringMerge.applyLocalFullBodyPreviewMerge(ctx);
    PreviewTextStringMerge.fixBareApostropheInsertWithoutSegmentMarker(ctx);
    PreviewTextStringMerge.fixUtf16SuffixAppendAtMidCaret(ctx);
    PreviewTextStringMerge.computeEffectiveTextAfterShrinkRules(ctx);
    const merge0 = ctx.textForMerge;
    const eff0 = ctx.effectiveText;
    const caretRelBefore = ctx.selStart - ctx.oldLeft;
    const relForCollapse = caretRelBefore < 0 ? 0 : caretRelBefore;
    const collapsed = PreviewTextStringMerge.collapseConsecutiveImeApostrophesInPreviewAndCaret(eff0, relForCollapse);
    ctx.effectiveText = collapsed.text;
    if (caretRelBefore < 0) {
      // Prefix caret (…|好 + preview at leftIdx): do not map oldLeft+collapsed.rel — collapse clamps rel<0 to 0 and would
      // jump the document caret to leftIdx (你好|'…) while the user stayed in [0,leftIdx).
    } else {
      ctx.selStart = ctx.oldLeft + collapsed.rel;
      ctx.selEnd = ctx.selStart;
    }
    if (merge0 === eff0) {
      ctx.textForMerge = ctx.effectiveText;
    } else {
      ctx.textForMerge = PreviewTextStringMerge.collapseConsecutiveImeApostrophesInPreview(merge0);
    }

    this.mImcFullSyncAfterPreviewInsert = true;

    this.applyImePreviewStringCacheAndRange(ctx);

    this.setPreviewText(ctx.effectiveText);
    this.setPreviewTextStart(range.start);
    this.setPreviewTextEnd(range.end);

    this.applyImePreviewCaretAfterMerge(ctx, range);

    if (ctx.effectiveText === '' && ctx.hadActivePreview) {
      const gapLeft = this.mLeftIdxOfPreviewTextRange;
      this.mSelectionStartCache = gapLeft;
      this.mSelectionEndCache = gapLeft;
      this.mPreviewSelectionStartRel = 0;
      this.mPreviewSelectionEndRel = 0;
    }

    if (this.mListeners == null) {
      Log.e(TAG, "handleInsertPreviewTextEvent, mListeners is null");
      return;
    }

    this.coalescePreviewSpanWithCache();
    this.clampDocumentSelectionToCache();
    this.notifyListenersIfChangedSince(notifySnap);
  }

  /** If cache slice [oldLeft, oldRight) disagrees with prevPreview, rewrite span from ctx.prevPreview. */
  private repairPreviewSpanInCacheIfSpanDrifted(ctx: PreviewTextMergeContext): void {
    if (!(ctx.hadActivePreview && ctx.prevLen > 0)) {
      return;
    }
    const oldRight = this.mRightIdxOfPreviewTextRange;
    const oldLeft = ctx.oldLeft;
    const overwriteResult = PreviewSpanCoalescing.overwriteSpanIfTextMismatch(
      this.mStringCache,
      oldLeft,
      oldRight,
      ctx.prevPreview,
    );
    if (overwriteResult.changed) {
      this.mStringCache = overwriteResult.cache;
      this.mRightIdxOfPreviewTextRange = overwriteResult.rightIdx;
    }
  }

  /** Writes merged preview into mStringCache and [leftIdx,rightIdx); uses ctx.prevLen / prevPreview at entry for suffix math. */
  private applyImePreviewStringCacheAndRange(ctx: PreviewTextMergeContext): void {
    this.repairPreviewSpanInCacheIfSpanDrifted(ctx);
    const prevLen = ctx.prevLen;
    const effectiveText = ctx.effectiveText;
    if (!ctx.hadActivePreview) {
      const anchor = this.getSelectionStart();
      this.mStringCache =
        this.mStringCache.substring(0, anchor) + effectiveText + this.mStringCache.substring(anchor);
      this.updatePreviewTextRange(anchor, anchor + effectiveText.length);
    } else {
      const leftIdx = this.mLeftIdxOfPreviewTextRange;
      const lenCache = this.mStringCache.length;
      let suffixTail: string;
      if (prevLen > 0) {
        const suffixStart = Math.min(leftIdx + prevLen, lenCache);
        suffixTail = this.mStringCache.substring(suffixStart);
      } else {
        suffixTail = this.mStringCache.substring(
          Math.min(this.mRightIdxOfPreviewTextRange, lenCache),
        );
      }
      const leftCut = Math.min(Math.max(leftIdx, 0), lenCache);
      this.mStringCache =
        this.mStringCache.substring(0, leftCut) + effectiveText + suffixTail;
      this.updatePreviewTextRange(leftIdx, leftIdx + effectiveText.length);
    }
  }

  /** Clamps mPreviewSelection*Rel to [0, maxRel] and flushes document selection. */
  private clampPreviewRelativeSelectionToMax(maxRel: number): void {
    let relStart = this.mPreviewSelectionStartRel;
    let relEnd = this.mPreviewSelectionEndRel;
    if (relStart < 0) {
      relStart = 0;
    }
    if (relEnd < 0) {
      relEnd = 0;
    }
    if (relStart > maxRel) {
      relStart = maxRel;
    }
    if (relEnd > maxRel) {
      relEnd = maxRel;
    }
    this.setPreviewRelativeSelection(relStart, relEnd);
  }

  /** Clamps document selection to [leftIdx, rightIdx] on preview span, then syncs relative coords. */
  private clampDocumentSelectionToPreviewSpanThenSync(leftIdx: number, rightIdx: number): void {
    if (this.mSelectionStartCache < leftIdx) {
      this.mSelectionStartCache = leftIdx;
    } else if (this.mSelectionStartCache > rightIdx) {
      this.mSelectionStartCache = rightIdx;
    }
    if (this.mSelectionEndCache < leftIdx) {
      this.mSelectionEndCache = leftIdx;
    } else if (this.mSelectionEndCache > rightIdx) {
      this.mSelectionEndCache = rightIdx;
    }
    this.syncPreviewRelativeFromDocumentAtImePreviewEntry();
  }

  /**
   * When IME used in-preview range splice, map caret with splice geometry.
   * @returns true if caret was applied from range splice (skip IME-relativized path).
   */
  private tryApplyPreviewRangeSpliceCaret(
    ctx: PreviewTextMergeContext,
    leftIdx: number,
    newLen: number,
  ): boolean {
    if (!ctx.previewRangeSpliceUsed) {
      return false;
    }
    const prevLen = ctx.prevLen;
    const previewSpliceStart = ctx.previewRangeSpliceStart;
    const previewSpliceEnd = ctx.previewRangeSpliceEnd;
    const insLen = ctx.previewRangeSpliceInsLen;
    const expectedNewLen = prevLen - (previewSpliceEnd - previewSpliceStart) + insLen;
    const caretInPrevForSplice = ctx.selStart - leftIdx;
    if (
      expectedNewLen === newLen &&
      ctx.effectiveText === ctx.textForMerge &&
      caretInPrevForSplice >= 0 &&
      caretInPrevForSplice <= prevLen
    ) {
      let mappedRel = PreviewTextStringMerge.previewMapCaretAfterPreviewRangeReplace(
        prevLen,
        previewSpliceStart,
        previewSpliceEnd,
        insLen,
        caretInPrevForSplice,
      );
      if (mappedRel < 0) {
        mappedRel = 0;
      }
      if (mappedRel > newLen) {
        mappedRel = newLen;
      }
      this.setPreviewRelativeSelection(mappedRel, mappedRel);
      this.mSkipNoopImeCaretForPreviewsRemaining = 0;
      return true;
    }
    return false;
  }

  /** Collapsed IME range → preview-relative caret index, or -1. */
  private resolveImeRelativeCaretForCollapsedRange(
    range: inputMethod.Range,
    leftIdx: number,
    newLen: number,
  ): number {
    const rangeStart = range.start;
    const collapsed = rangeStart === range.end;
    let imeRel = -1;
    if (collapsed) {
      // Prefer document offset when rangeStart lies in [leftIdx, leftIdx+newLen] (e.g. rangeStart=leftIdx=2 for empty setPreview at preview start);
      // legacy preview-relative rangeStart is in [0, newLen] with rangeStart < leftIdx when leftIdx > 0.
      const docRel = rangeStart - leftIdx;
      if (docRel >= 0 && docRel <= newLen) {
        imeRel = docRel;
      } else if (rangeStart >= 0 && rangeStart <= newLen) {
        imeRel = rangeStart;
      }
    }
    return imeRel;
  }

  /** Collapsed selection + known imeRel: noop vs geometry caret in preview coordinates. */
  private applyPreviewCaretCollapsedWhenImeRelKnown(
    ctx: PreviewTextMergeContext,
    leftIdx: number,
    newLen: number,
    imeRel: number,
  ): void {
    const prevPreview = ctx.prevPreview;
    const prevLen = ctx.prevLen;
    const effectiveText = ctx.effectiveText;
    const selStart = ctx.selStart;
    const imePreviewNoop =
      effectiveText === prevPreview && newLen === prevLen;
    if (imePreviewNoop) {
      const localRel = this.mPreviewSelectionStartRel;
      if (this.mSkipNoopImeCaretForPreviewsRemaining > 0) {
        this.mSkipNoopImeCaretForPreviewsRemaining--;
        this.clampPreviewRelativeSelectionToMax(newLen);
      } else if (imeRel >= newLen && localRel < newLen) {
        this.clampPreviewRelativeSelectionToMax(newLen);
      } else if (localRel >= newLen && imeRel < newLen) {
        this.setPreviewRelativeSelection(imeRel, imeRel);
      } else {
        this.setPreviewRelativeSelection(imeRel, imeRel);
      }
      return;
    }
    this.mSkipNoopImeCaretForPreviewsRemaining = 0;
    let caretInPrevForGeo = selStart - leftIdx;
    if (caretInPrevForGeo > prevLen && caretInPrevForGeo <= prevLen + 1) {
      caretInPrevForGeo = prevLen;
    }
    let useRel = imeRel;
    if (caretInPrevForGeo >= 0 && caretInPrevForGeo <= prevLen) {
      if (newLen > prevLen) {
        let geo = PreviewTextStringMerge.previewCaretAfterSingleInsertion(prevPreview, effectiveText, caretInPrevForGeo);
        if (geo < 0) {
          geo = PreviewTextStringMerge.previewCaretAfterInsertionAtLocalCaret(prevPreview, effectiveText, caretInPrevForGeo);
        }
        if (geo >= 0) {
          useRel = geo > newLen ? newLen : geo;
        }
      } else if (newLen < prevLen) {
        let geo = PreviewTextStringMerge.previewCaretAfterSingleDeletion(prevPreview, effectiveText, caretInPrevForGeo);
        if (geo < 0) {
          geo = PreviewTextStringMerge.previewCaretAfterDeletionUsingBareStrings(prevPreview, effectiveText, caretInPrevForGeo);
        }
        if (geo >= 0) {
          useRel = geo > newLen ? newLen : geo;
        }
      }
    }
    if (useRel < 0) {
      this.clampPreviewRelativeSelectionToMax(newLen);
    } else {
      this.setPreviewRelativeSelection(useRel > newLen ? newLen : useRel, useRel > newLen ? newLen : useRel);
    }
  }

  /** Collapsed selection + no imeRel: geometry / insert-detect fallback. */
  private applyPreviewCaretCollapsedWhenImeRelUnknown(
    ctx: PreviewTextMergeContext,
    leftIdx: number,
    newLen: number,
  ): void {
    const prevPreview = ctx.prevPreview;
    const prevLen = ctx.prevLen;
    const effectiveText = ctx.effectiveText;
    const selStart = ctx.selStart;
    this.mSkipNoopImeCaretForPreviewsRemaining = 0;
    let caretInPrev = selStart - leftIdx;
    if (caretInPrev > prevLen && caretInPrev <= prevLen + 1) {
      caretInPrev = prevLen;
    }
    if (effectiveText === prevPreview && newLen === prevLen) {
      this.clampPreviewRelativeSelectionToMax(newLen);
    } else if (caretInPrev >= 0 && caretInPrev <= prevLen) {
      let newOff = -1;
      if (newLen < prevLen) {
        newOff = PreviewTextStringMerge.previewCaretAfterSingleDeletion(prevPreview, effectiveText, caretInPrev);
        if (newOff < 0) {
          newOff = PreviewTextStringMerge.previewCaretAfterDeletionUsingBareStrings(prevPreview, effectiveText, caretInPrev);
        }
      } else if (newLen > prevLen) {
        newOff = PreviewTextStringMerge.previewCaretAfterSingleInsertion(prevPreview, effectiveText, caretInPrev);
        if (newOff < 0) {
          newOff = PreviewTextStringMerge.previewCaretAfterInsertionAtLocalCaret(prevPreview, effectiveText, caretInPrev);
        }
      }
      if (newOff >= 0) {
        if (newOff > newLen) {
          newOff = newLen;
        }
        this.setPreviewRelativeSelection(newOff, newOff);
      } else if (newLen > prevLen) {
        const insStart = PreviewTextStringMerge.detectSingleInsertOffsetInPreview(prevPreview, effectiveText);
        if (insStart >= 0) {
          const delta = newLen - prevLen;
          let adj: number;
          if (caretInPrev < insStart) {
            adj = caretInPrev;
          } else if (caretInPrev === insStart) {
            adj = insStart + delta;
          } else {
            adj = caretInPrev + delta;
          }
          if (adj < 0) {
            adj = 0;
          }
          if (adj > newLen) {
            adj = newLen;
          }
          this.setPreviewRelativeSelection(adj, adj);
        } else {
          const cursorOff = caretInPrev;
          if (cursorOff >= 0 && cursorOff <= prevLen) {
            let adj = cursorOff + (newLen - prevLen);
            if (adj < 0) {
              adj = 0;
            }
            if (adj > newLen) {
              adj = newLen;
            }
            this.setPreviewRelativeSelection(adj, adj);
          } else {
            this.clampPreviewRelativeSelectionToMax(newLen);
          }
        }
      } else {
        this.clampPreviewRelativeSelectionToMax(newLen);
      }
    } else {
      this.clampPreviewRelativeSelectionToMax(newLen);
    }
  }

  /** Maps IME / geometry to mPreviewSelection* after merge (depends on document leftIdx/rightIdx after applyImePreviewStringCacheAndRange). */
  private applyImePreviewCaretAfterMerge(ctx: PreviewTextMergeContext, range: inputMethod.Range): void {
    const leftIdx = this.mLeftIdxOfPreviewTextRange;
    const rightIdx = this.mRightIdxOfPreviewTextRange;
    const newLen = ctx.effectiveText.length;

    if (!ctx.hadActivePreview) {
      this.setPreviewRelativeSelection(newLen, newLen);
      return;
    }
    if (ctx.selStart !== ctx.selEnd) {
      this.clampDocumentSelectionToPreviewSpanThenSync(leftIdx, rightIdx);
      return;
    }
    if (this.tryApplyPreviewRangeSpliceCaret(ctx, leftIdx, newLen)) {
      return;
    }
    const imeRel = this.resolveImeRelativeCaretForCollapsedRange(range, leftIdx, newLen);
    if (imeRel >= 0) {
      this.applyPreviewCaretCollapsedWhenImeRelKnown(ctx, leftIdx, newLen, imeRel);
    } else {
      this.applyPreviewCaretCollapsedWhenImeRelUnknown(ctx, leftIdx, newLen);
    }
  }

  /**
   * Handles insertion of final text from the input method.
   * @param text - The text to insert
   * @param options - Optional policy for preview commit (e.g. English preview range + suffix). Applied by caller.
   */
  handleInsertTextEvent(text: string, options?: PreviewInsertOptions): void {
    const notifySnap = this.captureEditingSnapshot();
    const selectionStartSnapshot = this.mSelectionStartCache;
    const selectionEndSnapshot = this.mSelectionEndCache;
    if (this.getPreviewText() !== "" || this.isPreviewStagingActive()) {
      this.repairPreviewSpanInCacheIfDrifted();
    }
    const previewLeftIdx = this.getLeftIdxOfPreviewTextRange();
    const previewRightIdx = this.getRightIdxOfPreviewTextRange();
    if (this.getPreviewText().length != 0) {
      this.setPreviewText("");
    }
    const usedExplicitPreviewRange =
      options?.usePreviewRange === true && options.previewStart != null && options.previewEnd != null;
    const retainSpan = options?.retainPreviewRangeAfterCommit === true;
    const selectionMin = Math.min(selectionStartSnapshot, selectionEndSnapshot);
    const selectionMax = Math.max(selectionStartSnapshot, selectionEndSnapshot);
    // Pinyin span [leftIdx,rightIdx) may follow one committed char (e.g. …了'hao). Caret at leftIdx-1 (…么|了) + CJK candidate must insert
    // before that char and keep it: …么 + 好 + 了 + drop 'hao — not replace [leftIdx,rightIdx) with 好 alone (…怎么了好).
    // Require cache[leftIdx]===''' (segment marker): 你|好ni'hao has leftIdx at 'n' — must replace [leftIdx,rightIdx) with 你好, not splice 好 as "bridge".
    const previewLeftIsSegmentApostrophe =
      previewLeftIdx < this.mStringCache.length &&
      this.mStringCache.charCodeAt(previewLeftIdx) === 0x27; // '\'' IME syllable boundary
    const candidateBridgeBeforePreview =
      !usedExplicitPreviewRange &&
      previewLeftIdx < previewRightIdx &&
      previewLeftIsSegmentApostrophe &&
      selectionMin === selectionMax &&
      selectionMin < previewLeftIdx &&
      previewLeftIdx === selectionMin + 1 &&
      ListenableEditingState.isBmpCjkOnlyInsert(text);
    const bridgeBeforePinyin = candidateBridgeBeforePreview
      ? this.mStringCache.substring(selectionMin, previewLeftIdx)
      : '';
    // When finishTextPreview commits with retainSpan, do not overwrite mSelection with [leftIdx,rightIdx): that was only needed
    // as replace bounds; forcing [2,6) makes post-replace caret jump to span end and breaks prefix caret + delete.
    if (usedExplicitPreviewRange) {
      if (options.appendSuffix != null && options.appendSuffix.length > 0) {
        text += options.appendSuffix;
      }
      if (!retainSpan) {
        this.mSelectionStartCache = options.previewStart as number;
        this.mSelectionEndCache = options.previewEnd as number;
      }
    } else if (previewLeftIdx < previewRightIdx && !candidateBridgeBeforePreview) {
      // IME insertText commit = replace full preview [leftIdx,rightIdx) with candidate. Do not rely on "leftIdx < selectionStart":
      // at preview left edge sel==leftIdx breaks old check → replace(leftIdx,leftIdx) zero-width, preview remains, suggestions jump to end.
      this.mSelectionStartCache = previewLeftIdx;
      this.mSelectionEndCache = previewRightIdx;
    }

    let start: number;
    let end: number;
    let insertPayload = text;
    if (usedExplicitPreviewRange) {
      const previewRangeStart = options.previewStart as number;
      const previewRangeEnd = options.previewEnd as number;
      start = previewRangeStart < previewRangeEnd ? previewRangeStart : previewRangeEnd;
      end = previewRangeStart < previewRangeEnd ? previewRangeEnd : previewRangeStart;
    } else if (candidateBridgeBeforePreview) {
      start = selectionMin;
      end = previewRightIdx;
      insertPayload = text + bridgeBeforePinyin;
    } else {
      start =
        this.mSelectionStartCache < this.mSelectionEndCache ? this.mSelectionStartCache : this.mSelectionEndCache;
      end = this.mSelectionStartCache > this.mSelectionEndCache ? this.mSelectionStartCache : this.mSelectionEndCache;
    }
    if (
      !usedExplicitPreviewRange &&
      start === end &&
      previewLeftIdx >= previewRightIdx &&
      ListenableEditingState.isBmpCjkOnlyInsert(text)
    ) {
      const tail = ListenableEditingState.findTrailingLatinImePreviewSuffixRange(this.mStringCache);
      if (tail !== null && start < tail.start) {
        start = tail.start;
        end = tail.end;
      }
    }
    const insertPayloadLength = insertPayload.length;
    this.replace(start, end, insertPayload, 0, insertPayloadLength);

    const cacheLenBeforeInsert = this.mStringCache.length;
    const selStartBeforeInsert =
      retainSpan && usedExplicitPreviewRange
        ? selectionMin
        : Math.min(this.mSelectionStartCache, this.mSelectionEndCache);
    const mergedStringCache =
      this.mStringCache.substring(0, start) + insertPayload + this.mStringCache.substring(end);
    this.mStringCache = mergedStringCache;
    if (candidateBridgeBeforePreview) {
      this.mSelectionStartCache = selectionMin + text.length;
      this.mSelectionEndCache = this.mSelectionStartCache;
    } else if (cacheLenBeforeInsert == selStartBeforeInsert) {
      this.setSelectionStart(this.mStringCache.length);
      this.setSelectionEnd(this.mStringCache.length);
    } else if (cacheLenBeforeInsert > selStartBeforeInsert) {
      if (retainSpan && usedExplicitPreviewRange && selectionMax <= start) {
        this.mSelectionStartCache = selectionMin;
        this.mSelectionEndCache = selectionMax;
        this.syncPreviewRelativeFromDocumentAfterDirectSelectionChange();
      } else {
        this.mSelectionStartCache = start + text.length;
        this.mSelectionEndCache = this.mSelectionStartCache;
      }
    }
    this.clampDocumentSelectionToCache();
    if (this.mListeners == null) {
      Log.e(TAG, "mListeners is null");
      return;
    }
    this.notifyListenersIfChangedSince(notifySnap);
    if (retainSpan) {
      this.updatePreviewTextRange(start, start + text.length);
    } else {
      this.clearPreviewStagingFieldsOnly();
      this.setPreviewTextStart(-1);
      this.setPreviewTextEnd(-1);
    }
  }

  /**
   * Updates the text input state from Flutter.
   * @param state - The new text edit state
   */
  updateTextInputState(state: TextEditState): void {
    if (this.leftDeleteState === DeleteStates.START) {
      this.leftDeleteState = DeleteStates.MOVING;
    }
    if (this.rightDeleteState === DeleteStates.START) {
      this.rightDeleteState = DeleteStates.MOVING;
    }
    this.beginBatchEdit();
    // Must not require non-empty mPreviewText: after in-preview edits IME may clear preview while [leftIdx,rightIdx) still holds pinyin in cache.
    // Falling through to setStringCache(state.text) replaces the whole cache and drops staging → 你|好hao with preview exited.
    if (isPreviewTextSupported() &&
      (this.isPreviewStagingActive() || this.getPreviewText() !== '')) {
      if (state.hasSelection()) {
        this.setSelectionStart(state.selectionStart);
        this.setSelectionEnd(state.selectionEnd);
      }
      const len = this.mStringCache.length;
      let docSelStart = this.mSelectionStartCache;
      let docSelEnd = this.mSelectionEndCache;
      if (docSelStart < 0) {
        docSelStart = 0;
      }
      if (docSelEnd < 0) {
        docSelEnd = 0;
      }
      if (docSelStart > len) {
        docSelStart = len;
      }
      if (docSelEnd > len) {
        docSelEnd = len;
      }
      this.setSelectionStart(docSelStart);
      this.setSelectionEnd(docSelEnd);
      this.syncPreviewRelativeFromDocumentAfterDirectSelectionChange();
      this.endBatchEdit();
      return;
    }
    this.setStringCache(state.text);
    if (state.hasSelection()) {
      this.setSelectionStart(state.selectionStart);
      this.setSelectionEnd(state.selectionEnd);
    } else {
      this.setSelectionStart(0);
      this.setSelectionEnd(0);
    }
    if (state.hasComposing()) {
      this.setComposingStart(state.composingStart);
      this.setComposingEnd(state.composingEnd);
    } else {
      this.setComposingStart(-1);
      this.setComposingEnd(-1);
    }
    this.endBatchEdit();
  }

  /**
   * Begins a batch edit operation.
   * Multiple edits can be batched together to reduce notifications.
   */
  beginBatchEdit(): void {
    this.mBatchEditNestDepth++;
    if (this.mChangeNotificationDepth > 0) {
      Log.e(TAG, "editing state should not be changed in a listener callback");
    }
    if (this.mBatchEditNestDepth == 1 && !this.mListeners.isEmpty()) {
      this.mTextWhenBeginBatchEdit = this.getStringCache();
      this.mSelectionStartWhenBeginBatchEdit = this.getSelectionStart();
      this.mSelectionEndWhenBeginBatchEdit = this.getSelectionEnd();
      this.mComposingStartWhenBeginBatchEdit = this.getComposingStart();
      this.mComposingEndWhenBeginBatchEdit = this.getComposingEnd();
    }
  }

  /**
   * Ends a batch edit operation and notifies listeners of all changes.
   */
  endBatchEdit(): void {
    if (this.mBatchEditNestDepth == 0) {
      Log.e(TAG, "endBatchEdit called without a matching beginBatchEdit");
      return;
    }
    if (this.mBatchEditNestDepth == 1) {
      for (const listener of this.mPendingListeners) {
        this.notifyListener(listener, true, true, true);
      }

      if (!this.mListeners.isEmpty()) {
        const textChanged = !(this.mStringCache == this.mTextWhenBeginBatchEdit);
        const selectionChanged = this.mSelectionStartWhenBeginBatchEdit != this.getSelectionStart()
          || this.mSelectionEndWhenBeginBatchEdit != this.getSelectionEnd();
        const composingRegionChanged = this.mComposingStartWhenBeginBatchEdit != this.getComposingStart()
          || this.mComposingEndWhenBeginBatchEdit != this.getComposingEnd();
        this.notifyListenersIfNeeded(textChanged, selectionChanged, composingRegionChanged);
      }
    }
    for (const listener of this.mPendingListeners) {
      this.mListeners.add(listener);
    }
    this.mPendingListeners.clear();
    this.mBatchEditNestDepth--;
  }

  /**
   * Adds a listener to be notified of editing state changes.
   * @param listener - The listener to add
   */
  addEditingStateListener(listener: EditingStateWatcher): void {
    if (this.mChangeNotificationDepth > 0) {
      Log.e(TAG, "adding a listener " + JSON.stringify(listener) + " in a listener callback");
    }
    if (this.mBatchEditNestDepth > 0) {
      this.mPendingListeners.add(listener);
    } else {
      this.mListeners.add(listener);
    }
  }

  /**
   * Removes an editing state listener.
   * @param listener - The listener to remove
   */
  removeEditingStateListener(listener: EditingStateWatcher): void {
    if (this.mChangeNotificationDepth > 0) {
      Log.e(TAG, "removing a listener " + JSON.stringify(listener) + " in a listener callback");
    }
    this.mListeners.remove(listener);
    if (this.mBatchEditNestDepth > 0) {
      this.mPendingListeners.remove(listener);
    }
  }

  /**
   * Marks the start of a deletion operation.
   * @param code - The key code that triggered the deletion
   */
  startDeleting(code: number) {
    if (code === KeyCode.KEYCODE_FORWARD_DEL) {
      this.rightDeleteState = DeleteStates.START
    } else {
      this.leftDeleteState = DeleteStates.START
    }
  }

  /**
   * Marks the end of a deletion operation.
   * @param code - The key code that triggered the deletion
   */
  endDeletion(code: number) {
    if (code === KeyCode.KEYCODE_FORWARD_DEL) {
      this.rightDeleteState = DeleteStates.END
    } else {
      this.leftDeleteState = DeleteStates.END
    }
  }

  /**
   * Handles a delete event from the input method.
   * @param leftOrRight - True for delete right (forward delete), false for delete left (backspace)
   * @param length - The number of characters to delete
   * @param enableDeltaModel - Whether delta model is enabled
   */
  handleDeleteEvent(leftOrRight: boolean, length: number, enableDeltaModel: boolean | undefined): void {
    if (length === 0) {
      return;
    }
    const notifySnap = this.captureEditingSnapshot();

    let leftIdx = this.mLeftIdxOfPreviewTextRange;
    // mRightIdx can lag preview length after edits; stale right makes pos look past preview and routes
    // backspace to the suffix branch (wrong layer). Cursor may also sit at previewEnd+1 until IMC sync.
    let rightIdx = this.mRightIdxOfPreviewTextRange;
    const hasPreviewRangeMeta = leftIdx !== rightIdx;
    if (this.getPreviewText().length > 0 || hasPreviewRangeMeta) {
      this.syncPreviewRightToPreviewLength();
      this.repairPreviewSpanInCacheIfDrifted();
      leftIdx = this.mLeftIdxOfPreviewTextRange;
      rightIdx = this.mRightIdxOfPreviewTextRange;
      // Do not force updatePreviewTextRange from previewLen here: sync already set rightIdx=leftIdx+len(mPreviewText);
      // shrinking rightIdx below real preview tail in cache (brief preview-length drift) kicks tail out of IN_PREVIEW or drops it on writeback.
    }
    if (rightIdx > leftIdx) {
      const start =
        this.mSelectionStartCache < this.mSelectionEndCache ? this.mSelectionStartCache : this.mSelectionEndCache;
      const end =
        this.mSelectionStartCache > this.mSelectionEndCache ? this.mSelectionStartCache : this.mSelectionEndCache;
      if (start === end) {
        let pos = start;
        const previewEnd = rightIdx;
        if (!leftOrRight && pos > previewEnd && pos <= previewEnd + 1) {
          pos = previewEnd;
        }
        if (!leftOrRight) {
          // Backspace: selection is in display coordinates (same as base for index < leftIdx).
          // At preview left edge with committed text before [leftIdx,rightIdx), delete prefix first (not first preview code unit).
          if (pos === leftIdx && leftIdx > 0) {
            let unicodeStart = leftIdx;
            for (let deleteStep = 0; deleteStep < length; deleteStep++) {
              unicodeStart = FlutterTextUtils.getOffsetBefore(this.mStringCache, unicodeStart);
              if (unicodeStart === 0) {
                break;
              }
            }
            this.replace(unicodeStart, leftIdx, "", 0, 0);
            this.mStringCache = this.mStringCache.substring(0, unicodeStart) + this.mStringCache.substring(leftIdx);
            const delta = leftIdx - unicodeStart;
            this.mLeftIdxOfPreviewTextRange -= delta;
            this.mRightIdxOfPreviewTextRange -= delta;
            if (this.previewCaretSessionActive()) {
              this.setPreviewRelativeSelection(0, 0);
            } else {
              this.mSelectionStartCache = this.mLeftIdxOfPreviewTextRange;
              this.mSelectionEndCache = this.mLeftIdxOfPreviewTextRange;
            }
            this.markSkipNextFlutterSelectionApplyOnce();
            this.notifyListenersIfChangedSince(notifySnap);
            return;
          }
          // Inside preview span [leftIdx,rightIdx] inclusive rightIdx for caret (includes leftIdx when preview starts at doc origin: leftIdx=0,pos=0).
          if (pos >= leftIdx && pos <= rightIdx) {
            let workingPreview = this.getPreviewText();
            if (workingPreview.length < 1 && rightIdx > leftIdx) {
              workingPreview = this.mStringCache.substring(leftIdx, rightIdx);
            }
            let curPos = pos;
            for (let deleteStep = 0; deleteStep < length; deleteStep++) {
              let offsetInPreview = curPos - leftIdx;
              if (offsetInPreview <= 0) {
                if (workingPreview.length < 1) {
                  break;
                }
                // Caret at preview start: getImePreviewBackspaceDeleteRange requires offset>0; delete one unit left of first cluster.
                offsetInPreview = FlutterTextUtils.getOffsetAfterForImePreview(workingPreview, 0);
                if (offsetInPreview <= 0) {
                  break;
                }
              }
              const backspaceDeleteRange =
                FlutterTextUtils.getImePreviewBackspaceDeleteRange(workingPreview, offsetInPreview);
              if (backspaceDeleteRange === null || backspaceDeleteRange.delStart >= backspaceDeleteRange.delEnd) {
                break;
              }
              workingPreview =
                workingPreview.substring(0, backspaceDeleteRange.delStart) +
                workingPreview.substring(backspaceDeleteRange.delEnd);
              curPos =
                leftIdx +
                (offsetInPreview - (backspaceDeleteRange.delEnd - backspaceDeleteRange.delStart));
            }
            const relAfterBk = curPos - leftIdx;
            const collapsedBk =
              PreviewTextStringMerge.collapseConsecutiveImeApostrophesInPreviewAndCaret(workingPreview, relAfterBk);
            workingPreview = collapsedBk.text;
            curPos = leftIdx + collapsedBk.rel;
            this.writePreviewSpanIntoCache(workingPreview);
            const leftIdxAfterWrite = this.mLeftIdxOfPreviewTextRange;
            if (this.previewCaretSessionActive()) {
              this.setPreviewRelativeSelection(curPos - leftIdxAfterWrite, curPos - leftIdxAfterWrite);
            } else {
              this.mSelectionStartCache = curPos;
              this.mSelectionEndCache = curPos;
            }
            this.mSkipNoopImeCaretForPreviewsRemaining = 3;
            this.markSkipNextFlutterSelectionApplyOnce();
            this.coalescePreviewSpanWithCache();
            this.notifyListenersIfChangedSince(notifySnap);
            return;
          }
          if (pos > rightIdx) {
            let unicodeStart = pos;
            for (let deleteStep = 0; deleteStep < length; deleteStep++) {
              unicodeStart = FlutterTextUtils.getOffsetBefore(this.mStringCache, unicodeStart);
              if (unicodeStart === 0) {
                break;
              }
            }
            this.replace(unicodeStart, pos, "", 0, 0);
            this.mStringCache = this.mStringCache.substring(0, unicodeStart) + this.mStringCache.substring(pos);
            const deleted = pos - unicodeStart;
            this.mSelectionStartCache = pos - deleted;
            this.mSelectionEndCache = pos - deleted;
            this.syncPreviewRelativeFromDocumentAfterDirectSelectionChange();
            this.markSkipNextFlutterSelectionApplyOnce();
            this.notifyListenersIfChangedSince(notifySnap);
            return;
          }
        } else {
          // Forward delete
          if (pos >= leftIdx && pos < rightIdx) {
            let workingPreview = this.getPreviewText();
            if (workingPreview.length < 1 && rightIdx > leftIdx) {
              workingPreview = this.mStringCache.substring(leftIdx, rightIdx);
            }
            let offsetInPreview = pos - leftIdx;
            for (let deleteStep = 0; deleteStep < length; deleteStep++) {
              if (offsetInPreview >= workingPreview.length) {
                break;
              }
              const delEnd = FlutterTextUtils.getOffsetAfterForImePreview(workingPreview, offsetInPreview);
              workingPreview = workingPreview.substring(0, offsetInPreview) + workingPreview.substring(delEnd);
            }
            this.writePreviewSpanIntoCache(workingPreview);
            const leftIdxAfterForwardDelete = this.mLeftIdxOfPreviewTextRange;
            if (this.previewCaretSessionActive()) {
              this.setPreviewRelativeSelection(pos - leftIdxAfterForwardDelete, pos - leftIdxAfterForwardDelete);
            } else {
              this.mSelectionStartCache = pos;
              this.mSelectionEndCache = pos;
            }
            this.mSkipNoopImeCaretForPreviewsRemaining = 3;
            this.markSkipNextFlutterSelectionApplyOnce();
            this.coalescePreviewSpanWithCache();
            this.notifyListenersIfChangedSince(notifySnap);
            return;
          }
          if (pos === rightIdx && pos < this.mStringCache.length) {
            let curAbs = pos;
            for (let deleteStep = 0; deleteStep < length; deleteStep++) {
              if (curAbs >= this.mStringCache.length) {
                break;
              }
              const delEnd = FlutterTextUtils.getOffsetAfter(this.mStringCache, curAbs);
              this.replace(curAbs, delEnd, "", 0, 0);
              this.mStringCache = this.mStringCache.substring(0, curAbs) + this.mStringCache.substring(delEnd);
            }
            this.mSelectionStartCache = pos;
            this.mSelectionEndCache = pos;
            this.syncPreviewRelativeFromDocumentAfterDirectSelectionChange();
            this.markSkipNextFlutterSelectionApplyOnce();
            this.notifyListenersIfChangedSince(notifySnap);
            return;
          }
        }
      } else {
        // Range selection with preview: clear preview and fall through to generic delete.
        this.clearPreviewTextContents();
      }
    }

    if (enableDeltaModel) {
      let selectionStart = this.getSelectionStart();
      let selectionEnd = this.getSelectionEnd();
      if(selectionStart === 0 && selectionEnd === 0){
        // When both selectionStart and selectionEnd are 0, the delete range is empty.
        return;
      }
      if (selectionStart === selectionEnd) {
        // Collapsed selection: ordinary delete; adjust offset by length.
        this.setSelectionStart(this.mSelectionStartCache - length);
      }
    }
    // Preview span / delta paths can leave mSelection* past mStringCache.length; getOffsetBefore throws RangeError.
    this.clampDocumentSelectionToCache();

    let start =
      this.mSelectionStartCache < this.mSelectionEndCache ? this.mSelectionStartCache : this.mSelectionEndCache;
    let end = this.mSelectionStartCache > this.mSelectionEndCache ? this.mSelectionStartCache : this.mSelectionEndCache;

    if (leftOrRight == false && this.leftDeleteState !== DeleteStates.MOVING) {
      //delete left
      if (start == 0 && end == 0) {
        return;
      }

      let unicodeStart = start;
      if (start == end) {
        for (let deleteStep = 0; deleteStep < length; deleteStep++) {
          unicodeStart = FlutterTextUtils.getOffsetBefore(this.mStringCache, unicodeStart);
          if (unicodeStart === 0) {
            break;
          }
        }
      }
      this.replace(unicodeStart, end, "", 0, 0);
      this.mSelectionStartCache = unicodeStart;
      let tempStr: string = this.mStringCache.slice(0, unicodeStart) + this.mStringCache.slice(end);
      this.mStringCache = tempStr;
      this.mSelectionEndCache = this.mSelectionStartCache;
    } else if (leftOrRight == true && this.rightDeleteState !== DeleteStates.MOVING) {
      //delete right
      if (start == this.mStringCache.length) {
        return;
      }
      let unicodeEnd = end;
      if (start == end) {
        for (let deleteStep = 0; deleteStep < length; deleteStep++) {
          unicodeEnd = FlutterTextUtils.getOffsetAfter(this.mStringCache, unicodeEnd);
          if (unicodeEnd === this.mStringCache.length) {
            break;
          }
        }
      }
      this.replace(start, unicodeEnd, "", 0, 0);
      this.mSelectionEndCache = start;
      let tempStr: string = this.mStringCache.slice(0, start) +
        (unicodeEnd >= this.mStringCache.length ? "" : this.mStringCache.slice(unicodeEnd));
      this.mStringCache = tempStr;
      this.mSelectionStartCache = this.mSelectionEndCache;
    }
    this.notifyListenersIfChangedSince(notifySnap);
  }

  /**
   * Handles a newline event from the input method.
   */
  handleNewlineEvent(): void {
    const notifySnap = this.captureEditingSnapshot();
    // Caret bounds: use the smaller of start/end as start.
    let start =
      this.mSelectionStartCache < this.mSelectionEndCache ? this.mSelectionStartCache : this.mSelectionEndCache;
    // Use the larger of start/end as end.
    let end = this.mSelectionStartCache > this.mSelectionEndCache ? this.mSelectionStartCache : this.mSelectionEndCache;

    this.replace(start, end, '\n', 0, 1);
    // Compare caret position vs string length to choose how to place the caret after insert.
    if (this.mStringCache.length == this.mSelectionStartCache) {
      //Insert newline one by one
      let tempStr: string = this.mStringCache.substring(0, start) + '\n' + this.mStringCache.substring(end);
      this.mStringCache = tempStr;
      this.setSelectionStart(this.mStringCache.length);
      this.setSelectionEnd(this.mStringCache.length);
    } else if (this.mStringCache.length > this.mSelectionStartCache) {
      //Insert newline in the middle of string
      let tempStr: string = this.mStringCache.substring(0, start) + '\n' + this.mStringCache.substring(end);
      this.mStringCache = tempStr;
      this.mSelectionStartCache = start + 1;
      this.mSelectionEndCache = this.mSelectionStartCache;
    }
    if (this.mListeners == null) {
      Log.e(TAG, "mListeners is null");
      return;
    }
    this.notifyListenersIfChangedSince(notifySnap);
  }

  /**
   * Handles a function key event from the input method.
   * @param functionKey - The function key that was pressed
   */
  handleFunctionKey(functionKey: inputMethod.FunctionKey): void {
    if (!this.TextInputChannel) {
      return
    }
    switch (functionKey.enterKeyType) {
      case inputMethod.EnterKeyType.PREVIOUS:
        this.TextInputChannel.previous(this.client);
        break;
      case inputMethod.EnterKeyType.UNSPECIFIED:
        this.TextInputChannel.unspecifiedAction(this.client);
        break;
      case inputMethod.EnterKeyType.NEWLINE:
        this.TextInputChannel.newline(this.client);
        break;
      case inputMethod.EnterKeyType.GO:
        this.TextInputChannel.go(this.client);
        break;
      case inputMethod.EnterKeyType.SEARCH:
        this.TextInputChannel.search(this.client);
        break;
      case inputMethod.EnterKeyType.SEND:
        this.TextInputChannel.send(this.client);
        break;
      case inputMethod.EnterKeyType.NEXT:
        this.TextInputChannel.next(this.client);
        break;
      case inputMethod.EnterKeyType.DONE:
        this.TextInputChannel.done(this.client);
        break;
    }
  }

  /**
   * Handles a text selection by range event.
   * @param range - The range to select
   */
  handleSelectByRangeEvent(range: inputMethod.Range): void {
    const notifySnap = this.captureEditingSnapshot();
    if (this.previewCaretSessionActive()) {
      const len = this.getStringCache().length;
      let selMinDoc = Math.min(range.start, range.end);
      let selMaxDoc = Math.max(range.start, range.end);
      if (selMinDoc < 0) {
        selMinDoc = 0;
      }
      if (selMaxDoc > len) {
        selMaxDoc = len;
      }
      if (selMinDoc > selMaxDoc) {
        selMaxDoc = selMinDoc;
      }
      this.applyExternalDocumentSelectionWhilePreviewStaging(selMinDoc, selMaxDoc);
      this.notifyListenersIfChangedSince(notifySnap);
      return;
    }
    if (range.start === 0) { // cursor index updated at the start pos of text
      this.setSelectionStart(0);
      this.setSelectionEnd(0);
    } else { // cursor index updated at the end pos of text
      this.setSelectionStart(this.getStringCache().length);
      this.setSelectionEnd(this.getStringCache().length);
    }
    this.notifyListenersIfChangedSince(notifySnap);
  }

  /**
   * cursor moved at 2D-text with 4 directions
   *  aaaaaa                   aaaaaa|
   *  bbbbbbb|b -(cursor_up)-> bbbbbbbb
   *  cccc                     cccc
   *
   *  aaaaaa                     aaaaaa
   *  bbbbbbb|b -(cursor_down)-> bbbbbbbb
   *  cccc                       cccc|
   *
   *  aaaaaa                      aaaaaa
   *  bbbbbbb|b -(cursor_right)-> bbbbbbbb|
   *  cccc                        cccc
   *
   *  aaaaaa                     aaaaaa
   *  bbbbbbb|b -(cursor_left)-> bbbbbb|bb
   *  cccc                       cccc
   */
  /**
   * Handles cursor movement events in 2D text.
   * @param direction - The direction to move the cursor
   */
  handleMoveCursorEvent(direction: inputMethod.Direction): void {
    switch (direction) {
      case inputMethod.Direction.CURSOR_LEFT:
        this.moveCursorLeftWithoutKeySimulation();
        break;
      case inputMethod.Direction.CURSOR_RIGHT:
      case inputMethod.Direction.CURSOR_UP:
      case inputMethod.Direction.CURSOR_DOWN:
        // simulate the hardware-keyboard arrow-key pressed with any directions,
        // and the cursor index in text cache will be moved
        this.simulateHardwareCursorMovement(direction, false);
        break;
      default:
        Log.w(TAG, `"Unknown cursor movement direction: ${direction}"`);
        break;
    }
  }

  /**
   * Moves the collapsed cursor one character left in mStringCache / selection cache.
   * Used when IME calls moveCursor(LEFT) after paired-symbol insertText; does not
   * simulate ArrowLeft (avoids Shift+Left expand-selection while Shift is held).
   */
  private moveCursorLeftWithoutKeySimulation(): void {
    const selStart = this.mSelectionStartCache;
    const selEnd = this.mSelectionEndCache;
    if (selStart == selEnd && selStart > 0) {
      const newOffset = FlutterTextUtils.getOffsetBefore(this.mStringCache, selStart);
      this.setSelectionStart(newOffset);
      this.setSelectionEnd(newOffset);
      this.notifyListenersIfNeeded(false, true, false);
    }
  }

  /**
   * text-selection changed with cursor moving at 2D-text
   * (...) -> denotes the selection range of text
   *  aaaaaa                   aaaa(aa
   *  bbbb|bbbb -(cursor_up)-> bbbb)bbbb
   *  cccc                     cccc
   *
   *  aaaaaa                     aaaaaa
   *  bbbbbbb|b -(cursor_down)-> bbbbbbb(b
   *  cccc                       cccc)
   *
   *  aaaaaa                      aaaaaa
   *  bb|bbbbbb -(cursor_right)-> bb(b)bbbbb
   *  cccc                        cccc
   *
   *  aaaaaa                     aaaaaa
   *  bbbbbbb|b -(cursor_left)-> bbbbbb(b)b
   *  cccc                       cccc
   */
  /**
   * Handles text selection changes with cursor movement.
   * @param movement - The movement that triggers the selection change
   */
  handleSelectByMovementEvent(movement: inputMethod.Movement) : void {
    switch (movement.direction) {
      case inputMethod.Direction.CURSOR_LEFT:
      case inputMethod.Direction.CURSOR_RIGHT:
      case inputMethod.Direction.CURSOR_UP:
      case inputMethod.Direction.CURSOR_DOWN:
        // simulate the hardware-keyboard shift-key combined with arrow-key simultaneously pressed,
        // and the text selection changed with cursor movement
        this.simulateHardwareCursorMovement(movement.direction, true);
        break;
      default:
        Log.w(TAG, `"Unknown cursor movement direction: ${movement.direction}"`);
        break;
    }
  }

  /**
   * Gets the text to the left of the cursor.
   * @param length - The maximum number of characters to return
   * @returns The text to the left of the cursor
   */
  getLeftTextOfCursor(length: number) : string {
    if (length <= 0) {
      return "";
    }
    const strCacheLen = this.getStringCache().length;
    if (!strCacheLen) {
      return "";
    }
    const cursorIdx = this.getSelectionStart();
    let startIdx = cursorIdx - length;
    if (startIdx < 0) {
      startIdx = 0;
    }
    return this.getStringCache().substring(startIdx, cursorIdx);
  }

  /**
   * Gets the text to the right of the cursor.
   * @param length - The maximum number of characters to return
   * @returns The text to the right of the cursor
   */
  getRightTextOfCursor(length: number) : string {
    if (length <= 0) {
      return "";
    }
    const strCacheLen = this.getStringCache().length;
    if (!strCacheLen) {
      return "";
    }
    const cursorIdx = this.getSelectionEnd();
    let endIdx = cursorIdx + length;
    if (endIdx >= strCacheLen) {
      endIdx = strCacheLen;
    }
    return this.getStringCache().substring(cursorIdx, endIdx);
  }

  /**
   * Handles extended actions like select all, cut, copy, and paste.
   * @param action - The action to perform
   */
  handleExtendActionEvent(action: inputMethod.ExtendAction) : void {
    switch (action) {
      case inputMethod.ExtendAction.SELECT_ALL:
        // select all text from the start to end, and notify cursor state updating
        {
          const notifySnap = this.captureEditingSnapshot();
        this.setSelectionStart(0);
        this.setSelectionEnd(this.getStringCache().length);
          this.notifyListenersIfChangedSince(notifySnap);
        }
        break;
      case inputMethod.ExtendAction.CUT:
        // set to copy text before cutting
        const cutText = this.getStringCache().substring(this.getSelectionStart(), this.getSelectionEnd());
        PasteboardUtils.setCopyData(cutText);
        // based on the text selection length (endIdx - startIdx) for cutting
        this.handleDeleteEvent(false, this.getSelectionEnd() - this.getSelectionStart(), false);
        break;
      case inputMethod.ExtendAction.COPY:
        // obtain the current selection range of text cache as the copy text
        const copyText = this.getStringCache().substring(this.getSelectionStart(), this.getSelectionEnd());
        PasteboardUtils.setCopyData(copyText);
        break;
      case inputMethod.ExtendAction.PASTE:
        // PasteboardUtils.getPasteDataAsync() is a async function, so must await the async paste operatopn 
        // in sync func, otherwise there can be a problem of timing inconsistency in the insertion of pasted text here.
        const handlePasteDataAsync = async () => {
          try {
            const pasteText = await PasteboardUtils.getPasteDataAsync(); 
            if (pasteText) { // insert the paste text into the editing box
              this.handleInsertTextEvent(pasteText);
            }
          } catch (err) {
            Log.e(TAG, "get PasteData error: " + err);
          }
        };
        handlePasteDataAsync();
        break;
      default:
        Log.w(TAG, `"Unknown ExtendAction: ${action}"`);
        break;
    }
  }

  /**
   * This method is used to simulate the hard-keyboard key event in soft-keyboard mode,
   * Case 1: cursor moving is simulated by sending arrow-key event to flutter SDK (Dart-side),
   * hence the cursor will move up/down/left/right in editing box.
   * Case 2: text-selection changed with cursor moving is simulated by sending shift-key combined with arrow-key events
   * to flutter SDK, hence the text-selection range will be updated by moving cursor up/down/left/right in editing box.
   * @param direction: cursor move direction from IMC callback
   * @param isShiftPressed: determine whether shift-key is pressed
   */
  /**
   * Simulates hardware keyboard cursor movement by sending key events to Flutter.
   * @param direction - The direction to move the cursor
   * @param isShiftPressed - Whether shift key is pressed (for text selection)
   * @private
   */
  private simulateHardwareCursorMovement(direction: inputMethod.Direction, isShiftPressed: boolean) : void {
    // Some IME soft keyboards expose a “select” / text-edit control that behaves like the hardware Shift key.
    // When that control is on, treat it the same as Shift held on a physical keyboard.
    enum SimulatedKeyText {
      KEY_SHIFT = 'KEYCODE_SHIFT_LEFT',
      KEY_ARROW_UP = 'KEYCODE_DPAD_UP',
      KEY_ARROW_DOWN = 'KEYCODE_DPAD_DOWN',
      KEY_ARROW_LEFT = 'KEYCODE_DPAD_LEFT',
      KEY_ARROW_RIGHT = 'KEYCODE_DPAD_RIGHT',
      KEY_UNKNOWN = 'KEYCODE_UNKNOWN'
    }
    if (isShiftPressed) { // simulate shift-key down
      this.sendSimulatedKeyEvent(new SimulateKeyEvent(KeyCode.KEYCODE_SHIFT_LEFT, SimulatedKeyText.KEY_SHIFT), false);
    }
    let arrowEvent: SimulateKeyEvent;
    switch (direction) {
      case inputMethod.Direction.CURSOR_UP: // simulate hardware arrow-up key event
        arrowEvent = new SimulateKeyEvent(KeyCode.KEYCODE_DPAD_UP, SimulatedKeyText.KEY_ARROW_UP);
        break;
      case inputMethod.Direction.CURSOR_DOWN: // simulate hardware arrow-down key event
        arrowEvent = new SimulateKeyEvent(KeyCode.KEYCODE_DPAD_DOWN, SimulatedKeyText.KEY_ARROW_DOWN);
        break;
      case inputMethod.Direction.CURSOR_LEFT: // simulate hardware arrow-left key event
        arrowEvent = new SimulateKeyEvent(KeyCode.KEYCODE_DPAD_LEFT, SimulatedKeyText.KEY_ARROW_LEFT);
        break;
      case inputMethod.Direction.CURSOR_RIGHT: // simulate hardware arrow-right key event
        arrowEvent = new SimulateKeyEvent(KeyCode.KEYCODE_DPAD_RIGHT, SimulatedKeyText.KEY_ARROW_RIGHT);
        break;
      default:
        arrowEvent = new SimulateKeyEvent(KeyCode.KEYCODE_UNKNOWN, SimulatedKeyText.KEY_UNKNOWN);
        break;
    }
    this.sendSimulatedKeyEvent(arrowEvent, false); // simulate arrow-key down
    this.sendSimulatedKeyEvent(arrowEvent, true);  // simulate arrow-key up
    if (isShiftPressed) { // simulate shift-key up
      this.sendSimulatedKeyEvent(new SimulateKeyEvent(KeyCode.KEYCODE_SHIFT_LEFT, SimulatedKeyText.KEY_SHIFT), true);
    }
  }

  /**
   * Sends a simulated key event to Flutter.
   * @param event - The key event to simulate
   * @param isKeyUp - True for key up event, false for key down event
   * @private
   */
  private sendSimulatedKeyEvent(event: SimulateKeyEvent, isKeyUp: boolean) : void {
    this.keyEventChannel?.simulateSendFlutterKeyEvent(
      event, isKeyUp, {
      onFrameworkResponse: (isEventHandled: boolean): void => {}
    });
  }
}

/**
 * Options for inserting text when committing preview (e.g. English preview add space).
 * Policy is applied by the caller (Handler/Coordinator), not by the state.
 */
export interface PreviewInsertOptions {
  usePreviewRange: boolean;
  previewStart?: number;
  previewEnd?: number;
  appendSuffix?: string;
  /**
   * When true, keep [leftIdx,rightIdx) preview span metadata after replace so a following IME insertText (e.g. CJK candidate)
   * can still replace the pinyin span. Used by finishTextPreview when committing a leading-segment-marker tail like `'hao`.
   */
  retainPreviewRangeAfterCommit?: boolean;
}

/**
 * Interface for objects that watch for editing state changes.
 * Changing the editing state in a didChangeEditingState callback may cause unexpected behavior.
 */
export interface EditingStateWatcher {
  /**
   * Called when the editing state changes.
   * @param textChanged - Whether the text has changed
   * @param selectionChanged - Whether the selection has changed
   * @param composingRegionChanged - Whether the composing region has changed
   */
  didChangeEditingState(textChanged: boolean, selectionChanged: boolean, composingRegionChanged: boolean): void;
}