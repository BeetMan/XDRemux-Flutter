/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on TraceSection.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import hiTraceMeter from '@ohos.hiTraceMeter'

/**
 * Utility class for tracing code sections using hiTraceMeter.
 * Provides methods to begin and end trace sections with automatic name cropping.
 */
export class TraceSection {
  /** The current task ID for trace sections. */
  static taskId: number = 0;

  /**
   * Crops a section name to ensure it stays below 124 characters.
   * @param sectionName - The section name to crop
   * @returns The cropped section name.
   * @private
   */
  private static cropSectionName(sectionName: string): string {
    return sectionName.length < 124 ? sectionName : sectionName.substring(0, 124) + "...";
  }

  /**
   * Wraps Trace.beginSection to ensure that the line length stays below 127 code units.
   *
   * @param sectionName - The string to display as the section name in the trace
   * @returns The task ID for this trace section
   */
  public static begin(sectionName: string): number {
    TraceSection.taskId++;
    hiTraceMeter.startTrace(TraceSection.cropSectionName(sectionName), TraceSection.taskId);
    return TraceSection.taskId;
  }

  /**
   * Ends a trace section.
   * @param sectionName - The section name to end.
   */
  public static end(sectionName: string): void {
    hiTraceMeter.finishTrace(TraceSection.cropSectionName(sectionName), TraceSection.taskId);
  }

  /**
   * Ends a trace section with a specific task ID.
   * @param sectionName - The section name to end.
   * @param id - The task ID to use.
   */
  public static endWithId(sectionName: string, id: number): void {
    hiTraceMeter.finishTrace(TraceSection.cropSectionName(sectionName), id);
  }
}
