/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 *
 * Pure string/caret geometry for IME preview merge paths. Kept separate from
 * ListenableEditingState to avoid circular imports with PreviewTextCoordinator.
 */

import { FlutterTextUtils } from './TextUtils';
import { PreviewTextMergeContext } from './PreviewTextMergeContext';

/** Result of collapsing consecutive IME apostrophes while preserving a preview-relative caret. */
export interface PreviewCollapseApostropheCaretResult {
  text: string;
  rel: number;
}

/**
 * Stateless helpers for preview text merging, tail-shrink picking, and caret mapping.
 */
export class PreviewTextStringMerge {
  /**
   * Strip IME pinyin segment markers `'` before deciding if only the preview tail was removed.
   * Otherwise abc'de'f'g → abc'de'f is not a strict UTF-16 prefix (trailing `'` vs none), and
   * mid-string caret correction would be missed.
   */
  static previewBareForTailShrinkCompare(text: string): string {
    let out = '';
    for (let idx = 0; idx < text.length; idx++) {
      const bareCh = text.charAt(idx);
      if (bareCh !== "'") {
        out += bareCh;
      }
    }
    return out;
  }

  /** Matches TextUtils.isOnlyImePreviewApostropheRun: common IME segment apostrophe code units (incl. non-ASCII). */
  static isImePreviewApostropheLikeChar(segmentChar: string): boolean {
    if (segmentChar.length === 0) {
      return false;
    }
    const codeUnit = segmentChar.charCodeAt(0);
    return segmentChar === "'" || codeUnit === 0x2019 || codeUnit === 0x02BC || codeUnit === 0xFF07;
  }

  /** Whether two adjacent apostrophe-like code units exist (mixing U+2019 with ASCII breaks indexOf("''")). */
  static previewHasConsecutiveImeApostropheRun(text: string): boolean {
    for (let idx = 0; idx < text.length - 1; idx++) {
      if (PreviewTextStringMerge.isImePreviewApostropheLikeChar(text.charAt(idx)) &&
        PreviewTextStringMerge.isImePreviewApostropheLikeChar(text.charAt(idx + 1))) {
        return true;
      }
    }
    return false;
  }

  /** Whether candidate introduces a new illegal consecutive-apostrophe run that prev did not have. */
  static previewIntroducesNewConsecutiveApostropheRun(prev: string, candidate: string): boolean {
    if (!PreviewTextStringMerge.previewHasConsecutiveImeApostropheRun(candidate)) {
      return false;
    }
    if (PreviewTextStringMerge.previewHasConsecutiveImeApostropheRun(prev)) {
      return false;
    }
    return true;
  }

  static previewIndexOfFirstConsecutiveImeApostropheRun(text: string): number {
    for (let idx = 0; idx < text.length - 1; idx++) {
      if (PreviewTextStringMerge.isImePreviewApostropheLikeChar(text.charAt(idx)) &&
        PreviewTextStringMerge.isImePreviewApostropheLikeChar(text.charAt(idx + 1))) {
        return idx;
      }
    }
    return -1;
  }

  /**
   * Mid-preview edits must not leave adjacent IME apostrophe-like code units (`''`, `'`+U+2019, …);
   * fold every consecutive pair to one ASCII `'` (e.g. letter delete at `h'|s` after skipping `'`).
   */
  static collapseConsecutiveImeApostrophesInPreview(text: string): string {
    return PreviewTextStringMerge.collapseConsecutiveImeApostrophesInPreviewAndCaret(text, text.length).text;
  }

  /**
   * Same as {@link collapseConsecutiveImeApostrophesInPreview}, but keeps a preview-relative caret
   * aligned when code units before it are removed (pairs at `runStart`,`runStart+1` → one `'` at `runStart`).
   */
  static collapseConsecutiveImeApostrophesInPreviewAndCaret(
    previewText: string,
    caretRel: number,
  ): PreviewCollapseApostropheCaretResult {
    let out = previewText;
    let relCaret = caretRel;
    if (relCaret < 0) {
      relCaret = 0;
    }
    if (relCaret > out.length) {
      relCaret = out.length;
    }
    for (;;) {
      const consecutiveApoRunStart = PreviewTextStringMerge.previewIndexOfFirstConsecutiveImeApostropheRun(out);
      if (consecutiveApoRunStart < 0) {
        return { text: out, rel: relCaret };
      }
      if (relCaret > consecutiveApoRunStart + 1) {
        relCaret--;
      } else if (relCaret > consecutiveApoRunStart) {
        relCaret = consecutiveApoRunStart + 1;
      }
      out = out.substring(0, consecutiveApoRunStart) + "'" + out.substring(consecutiveApoRunStart + 2);
    }
  }

  /**
   * When a new consecutive-apostrophe run appears vs prev, collapse the **first** pair in candidate
   * to a single ASCII `'` (common after deleting a letter: x''z → x'z). Returns candidate unchanged if none.
   */
  private static previewTryCollapseFirstNewDoubleApostrophe(prev: string, candidate: string): string {
    if (!PreviewTextStringMerge.previewIntroducesNewConsecutiveApostropheRun(prev, candidate)) {
      return candidate;
    }
    const consecutiveApoRunStart = PreviewTextStringMerge.previewIndexOfFirstConsecutiveImeApostropheRun(candidate);
    if (consecutiveApoRunStart < 0) {
      return candidate;
    }
    return candidate.substring(0, consecutiveApoRunStart) + "'" + candidate.substring(consecutiveApoRunStart + 2);
  }

  /** Map plainBk index back to prev before deletion (plainBk = prev[0:delPlain) + prev[offset:]). */
  private static mapPlainBkIndexToPrev(delPlain: number, offset: number, plainIdx: number): number {
    if (plainIdx < delPlain) {
      return plainIdx;
    }
    return offset + (plainIdx - delPlain);
  }

  /**
   * For the first adjacent-apostrophe pair in plainBk, whether a **letter** lies in prev between
   * the two mapped positions (the `''` squeezed by this delete). If so, do not collapse `''`→`'`
   * or syllables merge wrongly (e.g. x'j'|… delete j → x''… → wrongly x's…).
   */
  private static previewDoubleApostropheInPlainBkBridgesDeletedLetter(
    prev: string,
    delPlain: number,
    offset: number,
    plainBk: string,
    doubleStart: number,
  ): boolean {
    if (doubleStart < 0 || doubleStart + 1 >= plainBk.length) {
      return false;
    }
    const mappedPlainLow = PreviewTextStringMerge.mapPlainBkIndexToPrev(delPlain, offset, doubleStart);
    const mappedPlainHigh = PreviewTextStringMerge.mapPlainBkIndexToPrev(delPlain, offset, doubleStart + 1);
    const intervalLow = Math.min(mappedPlainLow, mappedPlainHigh);
    const intervalHigh = Math.max(mappedPlainLow, mappedPlainHigh);
    for (let midIdx = intervalLow + 1; midIdx < intervalHigh; midIdx++) {
      if (midIdx >= 0 && midIdx < prev.length) {
        const midChar = prev.charAt(midIdx);
        const isLatinLetter =
          (midChar >= 'a' && midChar <= 'z') || (midChar >= 'A' && midChar <= 'Z');
        if (isLatinLetter) {
          return true;
        }
      }
    }
    return false;
  }

  /** Whether `[delStart, offset)` is only IME segment apostrophes (same idea as `getImePreviewBackspaceDeleteRange`). */
  private static previewSliceIsOnlyImeApostropheLikeRun(prev: string, delStart: number, offset: number): boolean {
    if (delStart < 0 || delStart >= offset || offset > prev.length) {
      return false;
    }
    for (let idx = delStart; idx < offset; idx++) {
      if (!PreviewTextStringMerge.isImePreviewApostropheLikeChar(prev.charAt(idx))) {
        return false;
      }
    }
    return offset > delStart;
  }

  /**
   * In full-preview callbacks the IME sometimes sends only the UTF-16 suffix of the previous preview
   * (not a strict-prefix tail trim); splicing blindly drops the left syllables
   * (e.g. prev=a'h'x'j's, ime=x'j's). When both contain `'` segments and the folded caret is near
   * the suffix start, treat text as a suffix and restore full prev.
   */
  static previewStitchSuffixOnlyImeFullBodyIfNeeded(
    prevPreview: string,
    imeText: string,
    caretRelInPreview: number,
  ): string | null {
    const prevLen = prevPreview.length;
    if (
      prevLen <= 0 ||
      imeText.length <= 0 ||
      imeText.length >= prevLen ||
      prevPreview.indexOf("'") < 0 ||
      imeText.indexOf("'") < 0
    ) {
      return null;
    }
    const tailMatchStart = prevLen - imeText.length;
    if (tailMatchStart <= 0 || prevPreview.substring(tailMatchStart) !== imeText) {
      return null;
    }
    if (caretRelInPreview < tailMatchStart - 1 || caretRelInPreview > prevLen) {
      return null;
    }
    return prevPreview;
  }

  /**
   * When the caret is not at the preview end: enforce **preview invariant 1** (one Backspace step
   * left of the caret only), do not accept IME “tail shrink” substitutes.
   * - If `[delPlain,offset)` is apostrophes only: take plainBk if it does not introduce illegal `''`
   *   (x'|j→xj); else try ext so ext does not swallow the syllable’s first letter leaving only j.
   * - After plain deletes one char, if x''z appears: try collapsing first `''`→`'`, unless `''`
   *   bridged a letter in prev; then consider extended Backspace.
   */
  static pickCaretLeftDeleteForImePreviewTailShrink(prev: string, offset: number): string {
    if (offset <= 0 || offset > prev.length) {
      return prev;
    }
    const delPlain = FlutterTextUtils.getOffsetBefore(prev, offset);
    if (delPlain < 0 || delPlain >= offset) {
      return prev;
    }
    const plainBk = prev.substring(0, delPlain) + prev.substring(offset);
    const plainShrink = prev.length - plainBk.length;
    if (plainShrink < 1 || plainShrink > 4) {
      return prev;
    }
    const delExtR = FlutterTextUtils.getImePreviewBackspaceDeleteRange(prev, offset);
    let extBk = prev;
    if (delExtR !== null && delExtR.delStart < delExtR.delEnd) {
      extBk = prev.substring(0, delExtR.delStart) + prev.substring(delExtR.delEnd);
    }
    const plainDeletesOnlyApostropheRun = PreviewTextStringMerge.previewSliceIsOnlyImeApostropheLikeRun(
      prev,
      delPlain,
      offset,
    );
    const plainBad =
      PreviewTextStringMerge.previewIntroducesNewConsecutiveApostropheRun(prev, plainBk);
    const extBad = PreviewTextStringMerge.previewIntroducesNewConsecutiveApostropheRun(prev, extBk);
    const extOk = !extBad && extBk !== prev && extBk.length < prev.length;
    if (plainDeletesOnlyApostropheRun && !plainBad) {
      return plainBk;
    }
    if (!plainDeletesOnlyApostropheRun) {
      if (!plainBad) {
        return plainBk;
      }
      const plainCollapsed = PreviewTextStringMerge.previewTryCollapseFirstNewDoubleApostrophe(prev, plainBk);
      const plainBkDoubleApoIdx = PreviewTextStringMerge.previewIndexOfFirstConsecutiveImeApostropheRun(plainBk);
      const collapseBridgesLetter =
        plainBkDoubleApoIdx >= 0 &&
        PreviewTextStringMerge.previewDoubleApostropheInPlainBkBridgesDeletedLetter(
          prev,
          delPlain,
          offset,
          plainBk,
          plainBkDoubleApoIdx,
        );
      const plainCollapsedOk =
        !collapseBridgesLetter &&
        plainCollapsed !== plainBk &&
        !PreviewTextStringMerge.previewIntroducesNewConsecutiveApostropheRun(prev, plainCollapsed) &&
        plainCollapsed.length < prev.length &&
        prev.length - plainCollapsed.length >= 1 &&
        prev.length - plainCollapsed.length <= 4;
      if (plainCollapsedOk) {
        return plainCollapsed;
      }
      if (collapseBridgesLetter) {
        return plainBk;
      }
    }
    if (plainDeletesOnlyApostropheRun || plainBad) {
      if (extOk) {
        return extBk;
      }
      const consecutiveApoRunStart = PreviewTextStringMerge.previewIndexOfFirstConsecutiveImeApostropheRun(extBk);
      if (consecutiveApoRunStart >= 0) {
        const rep = extBk.substring(0, consecutiveApoRunStart) + "'" + extBk.substring(consecutiveApoRunStart + 2);
        if (
          !PreviewTextStringMerge.previewHasConsecutiveImeApostropheRun(rep) &&
          rep !== prev &&
          rep.length < prev.length
        ) {
          return rep;
        }
      }
      return prev;
    }
    return prev;
  }

  /**
   * Exactly `L'R` (three UTF-16 units: non-apostrophe, IME apostrophe-like, non-apostrophe) with the caret
   * immediately before `R`. One user unit left of the caret is `L'` (marker is not deleted alone); result is `R`
   * (`z'|a`→`a`, `x'|h`→`h`).
   */
  static shouldKeepSuffixForCaretLeftUnitInLApostropheRThreePreview(
    prevPreview: string,
    offsetInPreview: number,
  ): boolean {
    return (
      prevPreview.length === 3 &&
      offsetInPreview === prevPreview.length - 1 &&
      !PreviewTextStringMerge.isImePreviewApostropheLikeChar(prevPreview.charAt(0)) &&
      PreviewTextStringMerge.isImePreviewApostropheLikeChar(prevPreview.charAt(1)) &&
      !PreviewTextStringMerge.isImePreviewApostropheLikeChar(prevPreview.charAt(2))
    );
  }

  /** UTF-16 shared prefix length between prev and candidate (code-unit equality). */
  static previewSharedUtf16PrefixLen(prev: string, candidate: string): number {
    const minLen = Math.min(prev.length, candidate.length);
    let prefixEnd = 0;
    while (prefixEnd < minLen && prev.charAt(prefixEnd) === candidate.charAt(prefixEnd)) {
      prefixEnd++;
    }
    return prefixEnd;
  }

  /**
   * After IME replaces preview range [rangeStart, rangeEnd) with `insLen` UTF-16 code units (this callback’s text),
   * map the **old-string** folded caret into the new string. When rangeStart===rangeEnd it is pure insert
   * (delSpan=0): caret at and right of the insertion point shifts by insLen.
   */
  static previewMapCaretAfterPreviewRangeReplace(
    prevLen: number,
    rangeStart: number,
    rangeEnd: number,
    insLen: number,
    caretInPrev: number,
  ): number {
    let clampedCaret = caretInPrev;
    if (clampedCaret < 0) {
      clampedCaret = 0;
    }
    if (clampedCaret > prevLen) {
      clampedCaret = prevLen;
    }
    const delSpan = rangeEnd - rangeStart;
    if (delSpan === 0) {
      if (clampedCaret < rangeStart) {
        return clampedCaret;
      }
      return clampedCaret + insLen;
    }
    if (clampedCaret <= rangeStart) {
      return clampedCaret;
    }
    if (clampedCaret >= rangeEnd) {
      return clampedCaret - delSpan + insLen;
    }
    return rangeStart + insLen;
  }

  /**
   * Count of non-`'` code units strictly left of UTF-16 index caret; aligns pinyin preview with apostrophes to bare letters.
   */
  private static previewUtfOffsetToBareLeftCount(text: string, utfOffset: number): number {
    let scanEnd = utfOffset;
    if (scanEnd < 0) {
      scanEnd = 0;
    }
    if (scanEnd > text.length) {
      scanEnd = text.length;
    }
    let count = 0;
    for (let idx = 0; idx < scanEnd; idx++) {
      if (text.charAt(idx) !== "'") {
        count++;
      }
    }
    return count;
  }

  /**
   * UTF-16 caret offset in s (with `'` ) when bareLeftCount substantive chars are to the left (before next code unit).
   */
  private static previewBareLeftCountToUtfOffset(text: string, bareLeftCount: number): number {
    if (bareLeftCount <= 0) {
      return 0;
    }
    let seen = 0;
    for (let idx = 0; idx < text.length; idx++) {
      if (text.charAt(idx) !== "'") {
        seen++;
        if (seen === bareLeftCount) {
          return idx + 1;
        }
      }
    }
    return text.length;
  }

  /**
   * IME shortens preview once: assume one contiguous delete of delLen code units; returns folded caret
   * after the deleted block under **invariant 1**; -1 if geometry cannot be recognized.
   */
  static previewCaretAfterSingleDeletion(prev: string, next: string, caretInPrev: number): number {
    const delLen = prev.length - next.length;
    if (delLen <= 0) {
      return -1;
    }
    let delStart = 0;
    while (delStart < prev.length && delStart < next.length &&
      prev.charAt(delStart) === next.charAt(delStart)) {
      delStart++;
    }
    if (prev.substring(delStart + delLen) !== next.substring(delStart)) {
      return -1;
    }
    let foldedCaret = caretInPrev;
    if (foldedCaret < 0) {
      foldedCaret = 0;
    }
    if (foldedCaret > prev.length) {
      foldedCaret = prev.length;
    }
    if (foldedCaret <= delStart) {
      return foldedCaret;
    }
    if (foldedCaret >= delStart + delLen) {
      return foldedCaret - delLen;
    }
    return delStart;
  }

  /**
   * e.g. a'b'l'c → abc: non-contiguous UTF-16 deletes break previewCaretAfterSingleDeletion; post-Backspace
   * clamp pins mid-string caret to end. Recompute delete geometry on bare strings without `'` and map back to next UTF-16.
   */
  static previewCaretAfterDeletionUsingBareStrings(prev: string, next: string, caretInPrev: number): number {
    const prevBare = PreviewTextStringMerge.previewBareForTailShrinkCompare(prev);
    const nextBare = PreviewTextStringMerge.previewBareForTailShrinkCompare(next);
    if (prevBare === prev && nextBare === next) {
      return -1;
    }
    const bareCaret = PreviewTextStringMerge.previewUtfOffsetToBareLeftCount(prev, caretInPrev);
    const geoBare = PreviewTextStringMerge.previewCaretAfterSingleDeletion(prevBare, nextBare, bareCaret);
    if (geoBare < 0) {
      return -1;
    }
    if (nextBare !== next) {
      const bareAtCaret = PreviewTextStringMerge.previewUtfOffsetToBareLeftCount(nextBare, geoBare);
      return PreviewTextStringMerge.previewBareLeftCountToUtfOffset(next, bareAtCaret);
    }
    return geoBare;
  }

  /**
   * IME lengthens preview once: assume delta code units inserted at insStart; returns folded caret under
   * **invariant 2** (right of the new insertion); -1 if unrecognized.
   */
  static previewCaretAfterSingleInsertion(prev: string, next: string, caretInPrev: number): number {
    const delta = next.length - prev.length;
    if (delta <= 0) {
      return -1;
    }
    let insStart = 0;
    while (insStart < prev.length && insStart < next.length &&
      prev.charAt(insStart) === next.charAt(insStart)) {
      insStart++;
    }
    if (prev.substring(insStart) !== next.substring(insStart + delta)) {
      return -1;
    }
    let foldedCaret = caretInPrev;
    if (foldedCaret < 0) {
      foldedCaret = 0;
    }
    if (foldedCaret > prev.length) {
      foldedCaret = prev.length;
    }
    if (foldedCaret < insStart) {
      // Tail append (insStart===len): IME often reports “after last letter” as offset=len-1 (still before last code unit);
      // returning foldedCaret would leave sel stuck at 6,6 while the string grew (e.g. a'b'c'l then 'k).
      if (insStart === prev.length && foldedCaret === prev.length - 1) {
        const moved = prev.length + delta;
        return moved > next.length ? next.length : moved;
      }
      // Mid insert: folded selection often sits one left of insert (insStart-1); must cross this insertion by delta.
      if (insStart > 0 && insStart < prev.length && foldedCaret === insStart - 1) {
        const moved = foldedCaret + delta;
        return moved > next.length ? next.length : moved;
      }
      return foldedCaret;
    }
    const movedPast = foldedCaret + delta;
    return movedPast > next.length ? next.length : movedPast;
  }

  /**
   * When LCP-based insert detection fails, assume delta code units were inserted at local caret caretInPrev (common IME behavior).
   */
  static previewCaretAfterInsertionAtLocalCaret(prev: string, next: string, caretInPrev: number): number {
    const delta = next.length - prev.length;
    if (delta <= 0) {
      return -1;
    }
    let foldedCaret = caretInPrev;
    if (foldedCaret < 0) {
      foldedCaret = 0;
    }
    if (foldedCaret > prev.length) {
      foldedCaret = prev.length;
    }
    const prefix = prev.substring(0, foldedCaret);
    const suffix = prev.substring(foldedCaret);
    if (next.length !== prefix.length + delta + suffix.length) {
      return -1;
    }
    if (!next.startsWith(prefix) || !next.endsWith(suffix)) {
      return -1;
    }
    const mid = next.substring(prefix.length, prefix.length + delta);
    if (prefix + mid + suffix !== next) {
      return -1;
    }
    return foldedCaret + delta;
  }

  /**
   * If prev→next is one contiguous insert of delta code units at some offset, return that offset; else -1.
   */
  static detectSingleInsertOffsetInPreview(prev: string, next: string): number {
    const delta = next.length - prev.length;
    if (delta <= 0) {
      return -1;
    }
    let sharedPrefixEnd = 0;
    while (sharedPrefixEnd < prev.length && sharedPrefixEnd < next.length &&
      prev.charAt(sharedPrefixEnd) === next.charAt(sharedPrefixEnd)) {
      sharedPrefixEnd++;
    }
    if (prev.substring(sharedPrefixEnd) !== next.substring(sharedPrefixEnd + delta)) {
      return -1;
    }
    return sharedPrefixEnd;
  }

  /**
   * OHOS: range.start/end ≥ 0 → splice inside previous preview string.
   * When the preview span does not start at document 0 (`oldLeft > 0`), `range` is usually in **document** coordinates;
   * convert splice bounds by subtracting `oldLeft` when `rangeStart >= oldLeft` so mid-preview insert (e.g. doc 6..11 + ime) maps to
   * preview 0..5, not mistaken preview indices 6..11 (clamped) which yield `z'm'z'y`.
   */
  static initPreviewRangeSplice(ctx: PreviewTextMergeContext, rangeStart: number, rangeEnd: number): void {
    const prevPreview = ctx.prevPreview;
    const prevLen = ctx.prevLen;
    const hadActivePreview = ctx.hadActivePreview;
    if (!(hadActivePreview && prevLen > 0 && rangeStart >= 0 && rangeEnd >= 0)) {
      return;
    }
    let spliceStartInPreview = rangeStart;
    let spliceEndInPreview = rangeEnd;
    const oldLeft = ctx.oldLeft;
    if (oldLeft > 0 && rangeStart >= oldLeft) {
      spliceStartInPreview = rangeStart - oldLeft;
      spliceEndInPreview = rangeEnd - oldLeft;
    }
    if (spliceStartInPreview > spliceEndInPreview) {
      const swapHold = spliceStartInPreview;
      spliceStartInPreview = spliceEndInPreview;
      spliceEndInPreview = swapHold;
    }
    if (spliceStartInPreview < 0) {
      spliceStartInPreview = 0;
    }
    if (spliceEndInPreview < 0) {
      spliceEndInPreview = 0;
    }
    if (spliceStartInPreview > prevLen) {
      spliceStartInPreview = prevLen;
    }
    if (spliceEndInPreview > prevLen) {
      spliceEndInPreview = prevLen;
    }
    ctx.textForMerge =
      prevPreview.substring(0, spliceStartInPreview) + ctx.imeText + prevPreview.substring(spliceEndInPreview);
    ctx.previewRangeSpliceUsed = true;
    ctx.previewRangeSpliceStart = spliceStartInPreview;
    ctx.previewRangeSpliceEnd = spliceEndInPreview;
    ctx.previewRangeSpliceInsLen = ctx.imeText.length;
  }

  /**
   * Mid-preview Backspace: OHOS may deliver a range splice (start/end) + short `ime` that stitches garbage
   * (e.g. `z'm'h'z'y'a` + replace [4,9) with `z'm` → `z'm'z'm'a`) while the caret is inside the preview. One local
   * `getImePreviewBackspaceDeleteRange` step at the caret (e.g. delete `h` → `z'm'z'y'a`) matches product rules; if it
   * disagrees with the splice merge, drop the splice and use the local string (non–full-body so later steps do not
   * re-run tail-shrink on the wrong IME payload).
   */
  static repairPreviewRangeSpliceWhenDisagreesWithLocalOneStepBackspace(
    ctx: PreviewTextMergeContext,
  ): void {
    if (!ctx.previewRangeSpliceUsed || ctx.selStart !== ctx.selEnd) {
      return;
    }
    if (!ctx.hadActivePreview || ctx.prevLen <= 1) {
      return;
    }
    const prev = ctx.prevPreview;
    const prevLen = ctx.prevLen;
    const merged = ctx.textForMerge;

    // Empty IME: splice [spliceStart, spliceEnd)+"" can leave preview text unchanged (e.g. [0,0)+""). While spliceUsed,
    // applyLocalFullBodyPreviewMerge is skipped; one-step Backspace at the caret must still apply.
    // Caret at end (rel === prevLen) was excluded below and never reached merged.length < prevLen.
    if (ctx.imeText.length === 0 && merged === prev) {
      let rel = ctx.selStart - ctx.oldLeft;
      if (rel < 0) {
        rel = 0;
      }
      if (rel > prevLen) {
        rel = prevLen;
      }
      if (rel <= 0) {
        return;
      }
      const backspaceDeleteRange = FlutterTextUtils.getImePreviewBackspaceDeleteRange(prev, rel);
      if (backspaceDeleteRange === null || backspaceDeleteRange.delStart >= backspaceDeleteRange.delEnd) {
        return;
      }
      const local =
        prev.substring(0, backspaceDeleteRange.delStart) + prev.substring(backspaceDeleteRange.delEnd);
      if (local === prev) {
        return;
      }
      ctx.previewRangeSpliceUsed = false;
      ctx.previewRangeSpliceStart = 0;
      ctx.previewRangeSpliceEnd = 0;
      ctx.previewRangeSpliceInsLen = 0;
      ctx.textForMerge = local;
      ctx.imeFullBodyMode = false;
      return;
    }

    let rel = ctx.selStart - ctx.oldLeft;
    if (rel <= 0 || rel >= prevLen) {
      return;
    }
    if (merged.length >= prevLen) {
      return;
    }
    const backspaceDeleteRange = FlutterTextUtils.getImePreviewBackspaceDeleteRange(prev, rel);
    if (backspaceDeleteRange === null || backspaceDeleteRange.delStart >= backspaceDeleteRange.delEnd) {
      return;
    }
    const local =
      prev.substring(0, backspaceDeleteRange.delStart) + prev.substring(backspaceDeleteRange.delEnd);
    if (local === merged) {
      return;
    }
    ctx.previewRangeSpliceUsed = false;
    ctx.previewRangeSpliceStart = 0;
    ctx.previewRangeSpliceEnd = 0;
    ctx.previewRangeSpliceInsLen = 0;
    ctx.textForMerge = local;
    ctx.imeFullBodyMode = false;
  }

  /** Undo mistaken “duplicative opening” range splice for segmented pinyin. */
  static correctDuplicativeOpeningTextSplice(ctx: PreviewTextMergeContext): void {
    const prevPreview = ctx.prevPreview;
    const text = ctx.imeText;
    const spliceStartInPreview = ctx.previewRangeSpliceStart;
    const spliceEndInPreview = ctx.previewRangeSpliceEnd;
    const charBeforeRangeUtf =
      spliceStartInPreview > 0 ? prevPreview.charAt(spliceStartInPreview - 1) : '';
    const syllableApoBeforeSpliceStart = PreviewTextStringMerge.isImePreviewApostropheLikeChar(charBeforeRangeUtf);
    const multicharDuplicativeOpening =
      text.length >= 2 &&
      !syllableApoBeforeSpliceStart &&
      prevPreview.length >= text.length &&
      prevPreview.substring(0, text.length) === text &&
      (spliceStartInPreview >= text.length ||
        (spliceStartInPreview < text.length &&
          text.startsWith(prevPreview.substring(0, spliceStartInPreview))));
    const singlecharDuplicativeOpening =
      text.length === 1 &&
      prevPreview.length >= 1 &&
      prevPreview.charAt(0) === text &&
      spliceStartInPreview >= 1;
    const duplicativeOpeningTextSplice =
      ctx.previewRangeSpliceUsed &&
      prevPreview.indexOf("'") >= 0 &&
      spliceStartInPreview > 0 &&
      spliceEndInPreview > spliceStartInPreview &&
      prevPreview.length >= text.length &&
      (multicharDuplicativeOpening || singlecharDuplicativeOpening);
    if (!duplicativeOpeningTextSplice) {
      return;
    }
    ctx.previewRangeSpliceUsed = false;
    ctx.previewRangeSpliceInsLen = 0;
    ctx.textForMerge = prevPreview;
  }

  /** Drop misleading span-end range when caret is left of splice (tap mid-preview + Backspace). */
  static dropMisleadingSpanEndSpliceForMidCaret(ctx: PreviewTextMergeContext): void {
    if (!ctx.previewRangeSpliceUsed || ctx.selStart !== ctx.selEnd) {
      return;
    }
    const caretRelInPrev = ctx.selStart - ctx.oldLeft;
    if (
      caretRelInPrev >= 0 &&
      caretRelInPrev < ctx.previewRangeSpliceStart &&
      ctx.previewRangeSpliceEnd > ctx.previewRangeSpliceStart
    ) {
      ctx.previewRangeSpliceUsed = false;
      ctx.textForMerge = ctx.prevPreview;
      ctx.imeFullBodyMode = true;
    }
  }

  /** Stitch suffix-only IME full-body when caret inside preview. */
  static applyFullBodySuffixStitch(ctx: PreviewTextMergeContext): void {
    if (!(ctx.imeFullBodyMode && ctx.hadActivePreview && ctx.prevLen > 0 && ctx.selStart === ctx.selEnd)) {
      return;
    }
    const caretRelForStitch = ctx.selStart - ctx.oldLeft;
    const stitchedPrev = PreviewTextStringMerge.previewStitchSuffixOnlyImeFullBodyIfNeeded(
      ctx.prevPreview,
      ctx.textForMerge,
      caretRelForStitch,
    );
    if (stitchedPrev !== null) {
      ctx.textForMerge = stitchedPrev;
    }
  }

  /**
   * Full-body preview merge: shrink uses local one-step rules (`L'R`, `getImePreviewBackspaceDeleteRange`, `pick…`).
   * When the IME body is a **strict UTF-16 prefix** shorter than `prev` and the caret lies **in the removed suffix**
   * (`offset >= len(ime)`), use **`ime`** so pre-edit text matches candidates (e.g. `z'n'x'h` + `z'n'x` at tail — local
   * bk can wrongly yield `z'n'h`). If the caret is still **inside** the kept prefix (`offset < len(ime)`), keep local bk.
   * Growth / same-length updates use the IME callback string as the whole body. `ListenableEditingState` forces full IMC sync.
   */
  static applyLocalFullBodyPreviewMerge(ctx: PreviewTextMergeContext): void {
    if (ctx.previewRangeSpliceUsed) {
      return;
    }
    if (!ctx.imeFullBodyMode) {
      return;
    }
    if (!ctx.hadActivePreview || ctx.prevLen <= 0) {
      return;
    }
    if (ctx.selStart !== ctx.selEnd) {
      return;
    }
    const prevPreview = ctx.prevPreview;
    const prevLen = ctx.prevLen;
    const ime = ctx.imeText;
    let off = ctx.selStart - ctx.oldLeft;
    if (off < 0) {
      off = 0;
    }
    if (off > prevLen) {
      off = prevLen;
    }
    if (ime.length < prevLen) {
      if (off <= 0) {
        ctx.textForMerge = prevPreview;
        return;
      }
      if (
        PreviewTextStringMerge.shouldKeepSuffixForCaretLeftUnitInLApostropheRThreePreview(prevPreview, off)
      ) {
        ctx.textForMerge = prevPreview.substring(off);
        return;
      }
      const imeStrictUtf16PrefixShrink =
        ime.length < prevPreview.length && prevPreview.startsWith(ime);
      if (imeStrictUtf16PrefixShrink && off >= ime.length) {
        ctx.textForMerge = ime;
        return;
      }
      const backspaceDeleteRange = FlutterTextUtils.getImePreviewBackspaceDeleteRange(prevPreview, off);
      if (backspaceDeleteRange !== null && backspaceDeleteRange.delStart < backspaceDeleteRange.delEnd) {
        ctx.textForMerge =
          prevPreview.substring(0, backspaceDeleteRange.delStart) +
          prevPreview.substring(backspaceDeleteRange.delEnd);
        return;
      }
      const picked = PreviewTextStringMerge.pickCaretLeftDeleteForImePreviewTailShrink(prevPreview, off);
      if (picked !== prevPreview) {
        ctx.textForMerge = picked;
        return;
      }
      ctx.textForMerge = prevPreview;
      return;
    }
    ctx.textForMerge = ime;
  }

  /** prev has no `'` but IME full body adds segment apostrophes — rebare-append at caret. */
  static fixBareApostropheInsertWithoutSegmentMarker(ctx: PreviewTextMergeContext): void {
    const prevPreview = ctx.prevPreview;
    const prevLen = ctx.prevLen;
    if (
      !(
        ctx.hadActivePreview &&
        prevLen > 0 &&
        ctx.imeFullBodyMode &&
        ctx.selStart === ctx.selEnd &&
        prevPreview.indexOf("'") < 0 &&
        ctx.textForMerge.indexOf("'") >= 0
      )
    ) {
      return;
    }
    const caretRel = ctx.selStart - ctx.oldLeft;
    if (caretRel < 0 || caretRel >= prevLen) {
      return;
    }
    const barePrev = PreviewTextStringMerge.previewBareForTailShrinkCompare(prevPreview);
    const bareIme = PreviewTextStringMerge.previewBareForTailShrinkCompare(ctx.textForMerge);
    if (!(bareIme.length > barePrev.length && bareIme.startsWith(barePrev))) {
      return;
    }
    const appendedBare = bareIme.substring(barePrev.length);
    if (appendedBare.length < 1 || appendedBare.length > 4) {
      return;
    }
    const fixedBare = barePrev.substring(0, caretRel) + appendedBare + barePrev.substring(caretRel);
    if (fixedBare !== bareIme) {
      ctx.textForMerge = fixedBare;
    }
  }

  /**
   * Full-body: IME appends at UTF-16 end while caret is mid — rotate insertion to caret.
   * Aligns insert product rule (new text left of caret; caret after insert), not tail-only append.
   */
  static fixUtf16SuffixAppendAtMidCaret(ctx: PreviewTextMergeContext): void {
    const prevPreview = ctx.prevPreview;
    const prevLen = ctx.prevLen;
    if (
      !(
        ctx.hadActivePreview &&
        prevLen > 0 &&
        ctx.imeFullBodyMode &&
        ctx.selStart === ctx.selEnd &&
        prevPreview.indexOf("'") < 0
      )
    ) {
      return;
    }
    const caretRel = ctx.selStart - ctx.oldLeft;
    if (
      caretRel < 0 ||
      caretRel >= prevLen ||
      ctx.textForMerge.length <= prevLen ||
      !ctx.textForMerge.startsWith(prevPreview)
    ) {
      return;
    }
    const appended = ctx.textForMerge.substring(prevLen);
    if (
      ctx.textForMerge === prevPreview + appended &&
      appended.length >= 1 &&
      appended.length <= 3 &&
      appended.indexOf("'") < 0
    ) {
      ctx.textForMerge =
        prevPreview.substring(0, caretRel) + appended + prevPreview.substring(caretRel);
    }
  }

  /** Preview body after merge; no IME-vs-local effective override. */
  static computeEffectiveTextAfterShrinkRules(ctx: PreviewTextMergeContext): void {
    ctx.effectiveText = ctx.textForMerge;
  }
}
