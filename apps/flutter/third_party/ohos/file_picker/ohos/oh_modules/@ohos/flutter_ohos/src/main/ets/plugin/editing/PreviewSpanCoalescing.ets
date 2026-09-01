/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 *
 * Pure string/cache operations for IME preview span [leftIdx, rightIdx) inside mStringCache.
 * Keeps ListenableEditingState focused on lifecycle + field wiring.
 */

/** Result of applying preview span coalescing to a document buffer. */
export interface PreviewSpanSyncResult {
  cache: string;
  rightIdx: number;
}

/** Result of drift repair; cache may be unchanged while rightIdx moves. */
export interface PreviewSpanRepairResult {
  cache: string;
  rightIdx: number;
}

export interface PreviewSpanOverwriteResult {
  cache: string;
  rightIdx: number;
  changed: boolean;
}

export class PreviewSpanCoalescing {
  /**
   * Align right index with preview length; remove stale UTF-16 units [computedRightIdx, oldRightIdx) when preview shrinks.
   */
  static syncCacheRightToPreviewLength(
    stringCache: string,
    leftIdx: number,
    previewTextLen: number,
    oldRightIdx: number,
  ): PreviewSpanSyncResult {
    const computedRightIdx = leftIdx + previewTextLen;
    let cache = stringCache;
    if (computedRightIdx < oldRightIdx) {
      const sliceEnd = Math.min(oldRightIdx, cache.length);
      const sliceStart = Math.min(computedRightIdx, sliceEnd);
      if (sliceEnd > sliceStart) {
        cache = cache.substring(0, sliceStart) + cache.substring(sliceEnd);
      }
    }
    const maxLen = cache.length;
    let clampedRight = computedRightIdx;
    if (clampedRight > maxLen) {
      clampedRight = maxLen;
    }
    if (clampedRight < leftIdx) {
      clampedRight = leftIdx;
    }
    return { cache: cache, rightIdx: clampedRight };
  }

  /**
   * If cache[leftIdx, rightIdx) disagrees with preview text, rewrite span; if already equal but rightIdx lags, fix right only.
   */
  static repairPreviewSpanIfDrifted(
    stringCache: string,
    leftIdx: number,
    rightIdx: number,
    previewText: string,
  ): PreviewSpanRepairResult {
    if (leftIdx === rightIdx && previewText === '') {
      return { cache: stringCache, rightIdx: rightIdx };
    }
    if (previewText === '') {
      return { cache: stringCache, rightIdx: rightIdx };
    }
    const span = stringCache.substring(leftIdx, rightIdx);
    if (span === previewText) {
      const wantRightIdx = leftIdx + previewText.length;
      if (rightIdx !== wantRightIdx) {
        return { cache: stringCache, rightIdx: wantRightIdx };
      }
      return { cache: stringCache, rightIdx: rightIdx };
    }
    let suffix: string;
    const tailFromLeft = stringCache.substring(leftIdx);
    const usePrefixSuffix = tailFromLeft.startsWith(previewText);
    if (usePrefixSuffix) {
      suffix = stringCache.substring(leftIdx + previewText.length);
    } else {
      suffix = stringCache.substring(rightIdx);
    }
    const cache = stringCache.substring(0, leftIdx) + previewText + suffix;
    return { cache: cache, rightIdx: leftIdx + previewText.length };
  }

  /**
   * When [leftIdx, rightIdx) substring differs from expected preview text, replace that span with `expected`.
   */
  static overwriteSpanIfTextMismatch(
    stringCache: string,
    leftIdx: number,
    rightIdx: number,
    expected: string,
  ): PreviewSpanOverwriteResult {
    const span = stringCache.substring(leftIdx, rightIdx);
    if (span === expected) {
      return { cache: stringCache, rightIdx: rightIdx, changed: false };
    }
    return {
      cache: stringCache.substring(0, leftIdx) + expected + stringCache.substring(rightIdx),
      rightIdx: leftIdx + expected.length,
      changed: true,
    };
  }
}
