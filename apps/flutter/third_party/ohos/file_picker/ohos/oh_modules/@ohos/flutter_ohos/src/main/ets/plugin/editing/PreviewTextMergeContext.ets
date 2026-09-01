/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 *
 * Mutable working state for IME preview merge (handleInsertPreviewTextEvent).
 * Keeps ListenableEditingState orchestration thin; merge phases live in PreviewTextStringMerge.
 */

/**
 * Working state for one IME `setPreviewText` / preview merge pass.
 * Fields are updated in order by PreviewTextStringMerge pipeline steps.
 */
export class PreviewTextMergeContext {
  /** Raw IME callback text. */
  imeText: string = '';
  /** Preview string before this merge. */
  prevPreview: string = '';
  prevLen: number = 0;
  hadActivePreview: boolean = false;
  /** Document offset of preview left bound at merge entry. */
  oldLeft: number = 0;
  selStart: number = 0;
  selEnd: number = 0;
  /** Candidate full preview body after range-splice / corrections. */
  textForMerge: string = '';
  imeFullBodyMode: boolean = false;
  previewRangeSpliceUsed: boolean = false;
  /** Half-open [start, end) inside previous preview string for IME range splice. */
  previewRangeSpliceStart: number = 0;
  previewRangeSpliceEnd: number = 0;
  previewRangeSpliceInsLen: number = 0;
  /** Final preview body written to cache and mPreviewText. */
  effectiveText: string = '';
}
