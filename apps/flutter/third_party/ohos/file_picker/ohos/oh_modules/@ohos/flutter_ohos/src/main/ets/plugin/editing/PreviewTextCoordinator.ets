/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 *
 * String merge / caret math: `PreviewTextStringMerge.ets` (keeps this file free of LES↔Coordinator cycles).
 */

import { Configuration, TextEditState } from '../../embedding/engine/systemchannels/TextInputChannel';
import { ListenableEditingState } from './ListenableEditingState';
import { TextEditingDelta } from './TextEditingDelta';
import { isPreviewTextSupported } from './PreviewTextSupport';
import ArrayList from '@ohos.util.ArrayList';

/**
 * Display state for text field: composed from base text + preview text when in preview mode.
 */
export interface DisplayState {
  text: string;
  selectionStart: number;
  selectionEnd: number;
  composingStart: number;
  composingEnd: number;
}

/** Callback to update Flutter editing state (full replace). */
export type UpdateChannelState = (
  inputClientId: number,
  text: string,
  selectionStart: number,
  selectionEnd: number,
  composingStart: number,
  composingEnd: number
) => void;

/** Callback to update Flutter with deltas. */
export type UpdateChannelWithDeltas = (
  inputClientId: number,
  batchDeltas: ArrayList<TextEditingDelta>
) => void;

/** Callback to notify IMC of current selection (e.g. after composing display text). */
export type NotifySelectionToImc = (text: string, selectionStart: number, selectionEnd: number) => void;

/** Mirrors Android TextInputPlugin: compare lastKnown vs current editable to skip redundant updateEditingState. */
export interface FrameworkOutgoingSyncMeta {
  lastOutgoing: TextEditState | null;
  onOutgoingCommitted: (state: TextEditState) => void;
}

/** Preview display + channel sync; caret-outside merge uses Flutter `TextEditState` vs native doc. */
export class PreviewTextCoordinator {
  /** Clamp selection/composing to `text.length` for a safe `TextEditState`. */
  static safeTextEditStateForNativeDocument(
    text: string,
    selectionStart: number,
    selectionEnd: number,
    composingStart: number,
    composingEnd: number
  ): TextEditState {
    const len = text.length;
    let clampedComposingStart = composingStart;
    let clampedComposingEnd = composingEnd;
    if (clampedComposingStart >= 0 && clampedComposingEnd > clampedComposingStart) {
      if (clampedComposingStart > len) {
        clampedComposingStart = len;
      }
      if (clampedComposingEnd > len) {
        clampedComposingEnd = len;
      }
      if (clampedComposingStart >= clampedComposingEnd) {
        clampedComposingStart = -1;
        clampedComposingEnd = -1;
      }
    } else {
      clampedComposingStart = -1;
      clampedComposingEnd = -1;
    }
    if (selectionStart === -1 && selectionEnd === -1) {
      return new TextEditState(text, -1, -1, clampedComposingStart, clampedComposingEnd);
    }
    const clampedSelection = PreviewTextCoordinator.clampSelection(selectionStart, selectionEnd, len);
    return new TextEditState(
      text,
      clampedSelection[0],
      clampedSelection[1],
      clampedComposingStart,
      clampedComposingEnd,
    );
  }

  static displayStateToTextEditState(display: DisplayState): TextEditState {
    return PreviewTextCoordinator.safeTextEditStateForNativeDocument(
      display.text,
      display.selectionStart,
      display.selectionEnd,
      display.composingStart,
      display.composingEnd
    );
  }

  static editingStatesEqualForChannel(a: TextEditState, b: TextEditState): boolean {
    return a.text === b.text &&
      a.selectionStart === b.selectionStart &&
      a.selectionEnd === b.selectionEnd &&
      a.composingStart === b.composingStart &&
      a.composingEnd === b.composingEnd;
  }

  /**
   * Composes the display string and selection when preview text is active:
   * displayText = leftOfPreview + previewText + rightOfPreview.
   * Selection follows editable (display coordinates).
   * Use composingStart/End = -1: OHOS preview is not the same as Flutter's IME composing span; marking
   * the preview as composing with a cursor in the middle can hide text after the caret on the Flutter side.
   */
  static composeDisplayState(editable: ListenableEditingState): DisplayState {
    if (isPreviewTextSupported() && editable.isPreviewStagingActive()) {
      editable.coalescePreviewSpanWithCache();
      const text = editable.getStagingComposedText();
      const len = text.length;
      let selStart = editable.getSelectionStart();
      let selEnd = editable.getSelectionEnd();
      if (selStart < 0) {
        selStart = 0;
      }
      if (selEnd < 0) {
        selEnd = 0;
      }
      if (selStart > len) {
        selStart = len;
      }
      if (selEnd > len) {
        selEnd = len;
      }
      return {
        text,
        selectionStart: selStart,
        selectionEnd: selEnd,
        composingStart: -1,
        composingEnd: -1
      };
    }
    const stringCache = editable.getStringCache();
    const startIdx = editable.getLeftIdxOfPreviewTextRange();
    const previewText = editable.getPreviewText();
    const left = stringCache.substring(0, startIdx);
    // Flutter may echo composed text into mStringCache while IME still owns previewText. Then
    // substring(startIdx) can be "abcde" or "abcdde" while preview is already "abcd" — appending
    // preview + right duplicates tail (e.g. abcd|de).
    const rawTail = stringCache.substring(startIdx, stringCache.length);
    let right = rawTail;
    if (previewText.length > 0 && right.startsWith(previewText)) {
      right = stringCache.substring(startIdx + previewText.length, stringCache.length);
    }
    // Drop repeated boundary code unit (echo kept an extra copy of preview's last char).
    while (previewText.length > 0 && right.length > 0 &&
      right.charAt(0) === previewText.charAt(previewText.length - 1)) {
      right = right.substring(1);
    }
    const purePreviewAnchor = startIdx === 0 && left === '';
    // Echo remainder after "preview" in rawTail: strip dup boundary chars, then drop only if no new
    // character appears (e.g. abcde/e, abcdde/de→e). Keep "lo" after "hel" because 'o' ∉ preview.
    if (purePreviewAnchor && previewText.length > 0 && rawTail.startsWith(previewText)) {
      let echoRemainderAfterPreview = rawTail.substring(previewText.length);
      while (echoRemainderAfterPreview.length > 0 && previewText.length > 0 &&
        echoRemainderAfterPreview.charAt(0) === previewText.charAt(previewText.length - 1)) {
        echoRemainderAfterPreview = echoRemainderAfterPreview.substring(1);
      }
      if (echoRemainderAfterPreview.length === 0) {
        right = '';
      } else {
        let hasCharNotInPreview = false;
        for (let charIdx = 0; charIdx < echoRemainderAfterPreview.length; charIdx++) {
          if (previewText.indexOf(echoRemainderAfterPreview.charAt(charIdx)) < 0) {
            hasCharNotInPreview = true;
            break;
          }
        }
        if (!hasCharNotInPreview) {
          right = '';
        } else {
          // Use normalized remainder from rawTail (not the earlier `right` from substring), so we do
          // not keep a stale code unit when IME shortened preview but cache still has abcde vs abcd.
          right = echoRemainderAfterPreview;
          // Single orphan after preview when cache is exactly one unit longer: Flutter echo of the
          // deleted character (e.g. preview abcd, cache abcde).
          if (
            echoRemainderAfterPreview.length === 1 &&
            previewText.indexOf(echoRemainderAfterPreview.charAt(0)) < 0 &&
            rawTail.length === previewText.length + 1
          ) {
            right = '';
          }
        }
      }
    }
    // Cache is only a short orphan tail (e.g. "de") while preview does not contain it as substring.
    if (purePreviewAnchor && previewText.length > 0 && rawTail.length > 0 && rawTail.length <= 4 &&
      !rawTail.startsWith(previewText) && previewText.indexOf(rawTail) < 0) {
      right = '';
    }
    const text = left + previewText + right;
    const len = text.length;
    let selStart = editable.getSelectionStart();
    let selEnd = editable.getSelectionEnd();
    if (selStart < 0) {
      selStart = 0;
    }
    if (selEnd < 0) {
      selEnd = 0;
    }
    if (selStart > len) {
      selStart = len;
    }
    if (selEnd > len) {
      selEnd = len;
    }
    return {
      text,
      selectionStart: selStart,
      selectionEnd: selEnd,
      composingStart: -1,
      composingEnd: -1
    };
  }

  /** True when preview text is supported and the document still has an active preview span [leftIdx, rightIdx). */
  static shouldSyncWithPreview(editable: ListenableEditingState): boolean {
    return isPreviewTextSupported() && editable.isPreviewStagingActive();
  }

  /**
   * Chooses update path (delta / preview / normal) and performs channel update + IMC notify.
   * Call this from EditingStateWatcher.didChangeEditingState to keep the listener thin.
   */
  static syncEditingState(
    editable: ListenableEditingState,
    inputTargetId: number,
    configuration: Configuration | null,
    updateChannel: UpdateChannelState,
    updateChannelWithDeltas: UpdateChannelWithDeltas,
    notifySelectionToImc: NotifySelectionToImc,
    frameworkSyncMeta?: FrameworkOutgoingSyncMeta | null
  ): void {
    const previewPath = PreviewTextCoordinator.shouldSyncWithPreview(editable);
    let committed: TextEditState;
    let previewDisplay: DisplayState | null = null;
    if (previewPath) {
      previewDisplay = PreviewTextCoordinator.composeDisplayState(editable);
      committed = PreviewTextCoordinator.displayStateToTextEditState(previewDisplay);
    } else {
      committed = PreviewTextCoordinator.safeTextEditStateForNativeDocument(
        editable.getStringCache(),
        editable.getSelectionStart(),
        editable.getSelectionEnd(),
        editable.getComposingStart(),
        editable.getComposingEnd()
      );
    }

    // During preview, do not skip when equal to lastOutgoing: after repeated Backspace / mid deletes,
    // compose vs Framework echo vs IMC selection can drift; treating them equal stops further updateEditingState,
    // so IME suggestions stay correct but the Flutter field stalls. Non-preview path keeps dedupe to reduce echo.
    if (frameworkSyncMeta != null && frameworkSyncMeta.lastOutgoing != null && !previewPath &&
      PreviewTextCoordinator.editingStatesEqualForChannel(frameworkSyncMeta.lastOutgoing, committed)) {
      editable.clearBatchDeltas();
      return;
    }

    // Preview edits do not go through delta batches; delta-first would skip UI updates.
    if (previewPath && previewDisplay != null) {
      const display = previewDisplay;
      updateChannel(
        inputTargetId,
        display.text,
        display.selectionStart,
        display.selectionEnd,
        display.composingStart,
        display.composingEnd
      );
      notifySelectionToImc(display.text, display.selectionStart, display.selectionEnd);
      editable.clearBatchDeltas();
      frameworkSyncMeta?.onOutgoingCommitted(committed);
      return;
    }
    if (configuration != null && configuration.enableDeltaModel) {
      updateChannelWithDeltas(inputTargetId, editable.extractBatchTextEditingDeltas());
      editable.clearBatchDeltas();
      frameworkSyncMeta?.onOutgoingCommitted(committed);
      return;
    }
    const out = PreviewTextCoordinator.safeTextEditStateForNativeDocument(
      editable.getStringCache(),
      editable.getSelectionStart(),
      editable.getSelectionEnd(),
      editable.getComposingStart(),
      editable.getComposingEnd()
    );
    updateChannel(
      inputTargetId,
      out.text,
      out.selectionStart,
      out.selectionEnd,
      out.composingStart,
      out.composingEnd
    );
    frameworkSyncMeta?.onOutgoingCommitted(out);
  }

  /** Build committed document by taking mid [leftIdx, rightIdx) from Flutter `text` / composing when it differs from `nativeDoc`. */
  private static mergePreviewMidFromFlutterState(
    nativeDoc: string,
    leftIdx: number,
    rightIdx: number,
    flutter: TextEditState
  ): string {
    const left = nativeDoc.substring(0, leftIdx);
    const right = nativeDoc.substring(rightIdx);
    const oldMid = nativeDoc.substring(leftIdx, rightIdx);
    const flutterText = flutter.text;
    if (flutterText.length === nativeDoc.length) {
      const flutterMidSlice = flutterText.substring(leftIdx, rightIdx);
      if (flutterMidSlice !== oldMid) {
        return left + flutterMidSlice + right;
      }
      return nativeDoc;
    }
    if (flutterText.startsWith(left) && flutterText.endsWith(right) &&
      flutterText.length >= left.length + right.length) {
      return flutterText;
    }
    if (flutter.hasComposing() &&
      flutter.composingStart === leftIdx &&
      flutter.composingEnd === rightIdx &&
      flutter.composingEnd <= flutterText.length) {
      const composingMidSlice =
        flutterText.substring(flutter.composingStart, flutter.composingEnd);
      if (composingMidSlice !== oldMid) {
        return left + composingMidSlice + right;
      }
    }
    if (flutter.hasComposing() && flutterText.length >= rightIdx) {
      const flutterComposingStart = flutter.composingStart;
      const flutterComposingEnd = flutter.composingEnd;
      if (flutterComposingStart >= 0 && flutterComposingEnd > flutterComposingStart &&
        flutterComposingStart <= leftIdx && flutterComposingEnd >= rightIdx &&
        flutterComposingEnd <= flutterText.length) {
        const flutterSpanMidSlice = flutterText.substring(leftIdx, rightIdx);
        if (flutterSpanMidSlice !== oldMid) {
          return left + flutterSpanMidSlice + right;
        }
      }
    }
    return nativeDoc;
  }

  private static mapSelectionAfterPreviewMidReplace(
    selStart: number,
    selEnd: number,
    leftIdx: number,
    rightIdx: number,
    oldPreviewLen: number,
    newMidLen: number
  ): [number, number] {
    const delta = newMidLen - oldPreviewLen;
    const mapOne = (pos: number): number => {
      if (pos <= leftIdx) {
        return pos;
      }
      if (pos >= rightIdx) {
        return pos + delta;
      }
      return leftIdx + newMidLen;
    };

    return [mapOne(selStart), mapOne(selEnd)];
  }

  private static clampSelection(selStart: number, selEnd: number, len: number): [number, number] {
    let clampedSelStart = selStart;
    let clampedSelEnd = selEnd;
    if (clampedSelStart < 0) {
      clampedSelStart = 0;
    }
    if (clampedSelEnd < 0) {
      clampedSelEnd = 0;
    }
    if (clampedSelStart > len) {
      clampedSelStart = len;
    }
    if (clampedSelEnd > len) {
      clampedSelEnd = len;
    }

    return [clampedSelStart, clampedSelEnd];
  }

  /** True if some `'`/`’`/… appears immediately after a letter inside `mid` (syllable boundary inside span). */
  private static previewMidHasInternalSegmentApostrophe(mid: string): boolean {
    for (let idx = 0; idx < mid.length; idx++) {
      if (!ListenableEditingState.isImeSegmentApostropheLikeChar(mid.charAt(idx))) {
        continue;
      }
      if (idx > 0) {
        const prev = mid.charAt(idx - 1);
        if ((prev >= 'a' && prev <= 'z') || (prev >= 'A' && prev <= 'Z')) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * Flutter selection strictly after rightIdx: replace [leftIdx, rightIdx) when `editingState` carries a different mid than native.
   * EOF stale-echo shortcut does not apply if `docMid` has letter+apostrophe syllable boundaries.
   */
  static commitPreviewWhenCursorOutOfRange(
    editable: ListenableEditingState,
    editingState: TextEditState,
    notifySelectionToImc: NotifySelectionToImc
  ): boolean {
    const leftIdx = editable.getLeftIdxOfPreviewTextRange();
    const rightIdx = editable.getRightIdxOfPreviewTextRange();
    const currStart = editingState.selectionStart;
    const currEnd = editingState.selectionEnd;
    const hasPreviewRange = leftIdx !== rightIdx;
    const selMin = Math.min(currStart, currEnd);
    const selMax = Math.max(currStart, currEnd);
    if (hasPreviewRange && selMax < leftIdx) {
      return false;
    }
    const isCursorOutOfPreviewToTheRight = hasPreviewRange && selMin > rightIdx;

    if (!isCursorOutOfPreviewToTheRight) {
      return false;
    }

    const nativeDoc = editable.getStagingComposedText();
    const docLen = nativeDoc.length;
    const docMid = nativeDoc.substring(leftIdx, rightIdx);
    // EOF + same text as native: usually wait for IME insertText; do not skip when mid has letter+`'` syllable marks.
    if (selMin > rightIdx &&
      editingState.text === nativeDoc &&
      editingState.selectionStart === docLen &&
      editingState.selectionEnd === docLen &&
      !PreviewTextCoordinator.previewMidHasInternalSegmentApostrophe(docMid)) {
      return false;
    }

    const oldPreviewLen = rightIdx - leftIdx;
    let committedText = PreviewTextCoordinator.mergePreviewMidFromFlutterState(
      nativeDoc,
      leftIdx,
      rightIdx,
      editingState
    );
    if (committedText === nativeDoc && editingState.text.length === nativeDoc.length) {
      const flutterMidSlice = editingState.text.substring(leftIdx, rightIdx);
      const nativeMidSlice = nativeDoc.substring(leftIdx, rightIdx);
      if (flutterMidSlice !== nativeMidSlice) {
        committedText =
          nativeDoc.substring(0, leftIdx) + flutterMidSlice + nativeDoc.substring(rightIdx);
      }
    }
    if (committedText === nativeDoc) {
      return false;
    }

    const newMidLen = committedText.length - nativeDoc.length + oldPreviewLen;
    const caretAfterCandidate = leftIdx + newMidLen;
    const clampedPair = PreviewTextCoordinator.clampSelection(
      caretAfterCandidate,
      caretAfterCandidate,
      committedText.length
    );
    const clampedCaretStart = clampedPair[0];
    const clampedCaretEnd = clampedPair[1];

    editable.setStringCache(committedText);
    editable.clearPreviewStagingFieldsOnly();
    editable.setPreviewTextStart(-1);
    editable.setPreviewTextEnd(-1);

    editingState.text = committedText;
    editingState.selectionStart = clampedCaretStart;
    editingState.selectionEnd = clampedCaretEnd;
    editingState.composingStart = -1;
    editingState.composingEnd = -1;
    editable.updateTextInputState(editingState);

    notifySelectionToImc(committedText, clampedCaretStart, clampedCaretEnd);
    return true;
  }
}
