/*
* Copyright (c) 2024 Hunan OpenValley Digital Industry Development Co., Ltd.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import Log from '../../../util/Log';
import DartExecutor from '../dart/DartExecutor';
import HashMap from '@ohos.util.HashMap';
import StringUtils from '../../../util/StringUtils';
import Any from '../../../plugin/common/Any';
import FlutterNapi from '../FlutterNapi';
import MethodChannel, { MethodCallHandler, MethodResult } from '../../../plugin/common/MethodChannel';
import MethodCall from '../../../plugin/common/MethodCall';
import StandardMethodCodec from '../../../plugin/common/StandardMethodCodec';

/**
 * Types of animation voting.
 */
enum AnimationVotingType {
  TRANSLATE = 0,
  SCALE,
  ROTATION,
}

/**
 * Channel for handling native VSync functionality.
 * This channel manages VSync switching, animation velocity voting, and LTPO switch state checking.
 */
export default class NativeVsyncChannel implements MethodCallHandler {
    private static TAG = "NativeVsyncChannel";
    private static CHANNEL_NAME = "flutter/nativevsync";
    /** The MethodChannel for native VSync communication with Flutter. */
    public channel: MethodChannel;
    private flutterNapi: FlutterNapi;

    /**
     * Handles method calls from Dart.
     * @param call - The method call from Dart
     * @param result - The result callback to send a response
     */
    onMethodCall(call: MethodCall, result: MethodResult): void {
        let method: string = call.method;
        try {
            switch (method) {
                case "isEnable":
                    // Whether to enable DVsync
                    let isEnable: boolean = call.argument('isEnable');
                    this.flutterNapi.SetDVsyncSwitch(isEnable);
                    break;
                case "sendVelocity":
                    // Send animation velocity
                    let type: string = call.argument('type');
                    let velocity: number = call.argument('velocity');
                    if (type == "translate") {
                    FlutterNapi.animationVoting(AnimationVotingType.TRANSLATE, velocity);
                    }
                    break;
                case "checkLTPOSwitchStatus":
                    // Check LTPO switch state
                    result.success(FlutterNapi.checkLTPOSwitchState());
                    break;
                default:
                    result.notImplemented();
                    break;
            }
        } catch (error) {
            result.error("error", "UnHandled error: " + JSON.stringify(error), null)
        }
    }

    /**
     * Constructs a new NativeVsyncChannel instance.
     * @param dartExecutor - The DartExecutor for sending messages to Dart
     * @param flutterNapi - The FlutterNapi instance for native communication
     */
    constructor(dartExecutor: DartExecutor, flutterNapi: FlutterNapi) {
        this.channel = new MethodChannel(dartExecutor, NativeVsyncChannel.CHANNEL_NAME, StandardMethodCodec.INSTANCE);
        this.channel.setMethodCallHandler(this);
        this.flutterNapi = flutterNapi;
    }
}