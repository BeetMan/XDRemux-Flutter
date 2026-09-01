/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on SystemChannel.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import BasicMessageChannel from '../../../plugin/common/BasicMessageChannel';
import Any from '../../../plugin/common/Any';
import JSONMessageCodec from '../../../plugin/common/JSONMessageCodec';
import Log from '../../../util/Log';
import DartExecutor from '../dart/DartExecutor';

const TAG: string = "SystemChannel";

/**
 * System channel for communicating system-level events between OpenHarmony and Flutter.
 * This channel handles events such as memory pressure warnings.
 */
export default class SystemChannel {
  /** The BasicMessageChannel for sending system-level messages to Flutter. */
  public channel: BasicMessageChannel<object>;

  /**
   * Constructs a new SystemChannel instance.
   * @param dartExecutor - The DartExecutor for sending messages to Dart
   */
  constructor(dartExecutor: DartExecutor) {
    this.channel = new BasicMessageChannel<Any>(dartExecutor, "flutter/system", JSONMessageCodec.INSTANCE);
  }

  /**
   * Sends a memory pressure warning to the Flutter framework.
   */
  public sendMemoryPressureWarning(): void {
    Log.i(TAG, "Sending memory pressure warning to Flutter");
    let message: Map<string, string> = new Map().set("type", "memoryPressure");
    this.channel.send(message);
  }
}