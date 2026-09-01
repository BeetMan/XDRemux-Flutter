/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on NavigationChannel.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import { common } from '@kit.AbilityKit';
import hiTraceMeter from '@ohos.hiTraceMeter';

import JSONMethodCodec from '../../../plugin/common/JSONMethodCodec';
import MethodCall from '../../../plugin/common/MethodCall';
import MethodChannel, { MethodCallHandler, MethodResult } from '../../../plugin/common/MethodChannel';
import Log from '../../../util/Log';
import DartExecutor from '../dart/DartExecutor';
import FlutterManager from '../../ohos/FlutterManager';
import Any from '../../../plugin/common/Any';
import DisplayMetricsChannel from './DisplayMetricsChannel';

/**
 * Navigator activity types.
 */
export enum NavigatorActivity {
  PUSH = "push",
  POP = "pop",
}

/**
 * Navigator status types.
 */
export enum NavigatorStatus {
  START = "start",
  FINISH = "finish",
}

/**
 * Channel for handling navigation-related communication between Flutter and OpenHarmony.
 * This channel manages route navigation, including setting initial routes, pushing routes,
 * and popping routes.
 */
export default class NavigationChannel {
  private static TAG = "NavigationChannel";
  private channel: MethodChannel;

  /**
   * Constructs a new NavigationChannel instance.
   * @param dartExecutor - The DartExecutor for sending messages to Dart
   * @param displayMetricsChannel - The DisplayMetricsChannel for DPI state management
   * @param context - The application context
   */
  constructor(dartExecutor: DartExecutor, context?: common.Context, displayMetricsChannel?: DisplayMetricsChannel) {
    this.channel = new MethodChannel(dartExecutor, "flutter/navigation", JSONMethodCodec.INSTANCE);
    // Provide a default handler that returns an empty response to any messages
    // on this channel.
    this.channel.setMethodCallHandler(new NavigationCallback(dartExecutor, context, displayMetricsChannel));
  }

  /**
   * Sets the initial route for navigation.
   * @param initialRoute - The initial route string
   */
  setInitialRoute(initialRoute: string): void {
    Log.i(NavigationChannel.TAG, "Sending message to set initial route to '" + initialRoute + "'");
    this.channel.invokeMethod("setInitialRoute", initialRoute);
  }

  /**
   * Pushes a new route onto the navigation stack.
   * @param route - The route string to push
   */
  pushRoute(route: string): void {
    Log.i(NavigationChannel.TAG, "Sending message to push route '" + route + "'");
    this.channel.invokeMethod("pushRoute", route);
  }

  /**
   * Pushes route information onto the navigation stack.
   * @param route - The route information string to push
   */
  pushRouteInformation(route: string): void {
    Log.i(NavigationChannel.TAG, "Sending message to push route information '" + route + "'");
    this.channel.invokeMethod("pushRouteInformation", new Map().set("location", route));
  }

  /**
   * Pops the current route from the navigation stack.
   */
  popRoute(): void {
    Log.i(NavigationChannel.TAG, "Sending message to pop route.");
    this.channel.invokeMethod("popRoute", null);
  }

  /**
   * Sets a custom method call handler for navigation events.
   * @param handler - The MethodCallHandler to handle navigation method calls
   */
  setMethodCallHandler(handler: MethodCallHandler) {
    this.channel.setMethodCallHandler(handler);
  }
}

/**
 * Default callback handler for navigation channel that returns empty responses.
 */
class NavigationCallback implements MethodCallHandler {
  private static TAG = "NavigationChannel";
  private dartExecutor: DartExecutor;
  private context?: common.Context;
  private displayMetricsChannel?: DisplayMetricsChannel;

  constructor(dartExecutor: DartExecutor, context?: common.Context, displayMetricsChannel?: DisplayMetricsChannel) {
    this.dartExecutor = dartExecutor;
    this.context = context;
    this.displayMetricsChannel = displayMetricsChannel;
  }

  onMethodCall(call: MethodCall, result: MethodResult) {
    let method: string = call.method;
    let args: Any = call.args;
    Log.i(NavigationCallback.TAG, "method = " + method);
    switch (method) {
      case "reportNavigatorActivity": {
        if (args == null || !(args instanceof Map)) {
          Log.e(NavigationCallback.TAG, "reportNavigatorActivity, args is null or not a Map");
          result.success(null);
          break;
        }
        let activity: string = args.get("activity");
        if (activity === undefined) {
          Log.e(NavigationCallback.TAG, "reportNavigatorActivity, incorrect parameter activity");
          break;
        }

        let status: string = args.get("status");
        if (status === undefined) {
          Log.e(NavigationCallback.TAG, "reportNavigatorActivity, incorrect parameter status");
          break;
        }

        let routeName: string = args.get("routeName");
        if (status === 'start' && routeName !== this.displayMetricsChannel?.getCurrentUri()) {
 	        this.displayMetricsChannel?.setCurrentUri('');
 	        this.displayMetricsChannel?.setCustomDpiActive(false);
 	      }

        let navigatorStatus: NavigatorStatus = this.getNavigatorStatusFromValue(status);

        let navigatorActivity: NavigatorActivity = this.getNavigatorActivityFromValue(activity);
        switch(navigatorActivity) {
          case NavigatorActivity.PUSH:
            this.reportNavigatorPush(navigatorStatus);
            break;
          case NavigatorActivity.POP:
            this.reportNavigatorPop(navigatorStatus);
            break;
        }
        break;
      }
      case "routeInformationUpdated":
 	      this.notifyPageChanged(call);
 	      result.success(null);
 	      break;
 	    default:
 	      result.success(null);
 	      break;
    }
  }

  /**
   * Forwards the current route URI to the OS via {@code FlutterNapi.NotifyPageChanged} ({@code OH_AbilityRuntime_NotifyPageChanged}).
   * Uses {@code uri} from the method call, {@code uri.length} as {@code pageNameLen}, and {@code FlutterManager.getWindowId(context)}.
   */
  private notifyPageChanged(call: MethodCall) {
    if (this.dartExecutor == null || this.dartExecutor.flutterNapi == null) {
      Log.e(NavigationCallback.TAG, "dartExecutor or flutterNapi is null, cancel OHOS page change notification");
      return;
    }

    // Skip notification if context is not provided
    if (this.context == null) {
      Log.e(NavigationCallback.TAG, "context is not provided, skip OHOS page change notification");
      return;
    }

    // Skip notification if args is null or not a Map
    if (call.args == null || !(call.args instanceof Map)) {
      Log.e(NavigationCallback.TAG, "routeInformationUpdated args is null or not a Map, skip OHOS page change notification");
      return;
    }

    const argsMap = call.args as Map<string, string>;
    const currentUri: string = argsMap.get('uri') ?? '';
    const currentUriLen: number = currentUri.length;

    // Dynamically get windowId
    const windowId: number = FlutterManager.getInstance().getWindowId(this.context);
    if (windowId == 0) {
      Log.e(NavigationCallback.TAG, "Failed to get windowId, skip OHOS page change notification, uri: " + currentUri);
      return;
    }
    this.displayMetricsChannel?.setCurrentUri(currentUri);
    const notifyResult = this.dartExecutor.flutterNapi.NotifyPageChanged(currentUri, currentUriLen, windowId);
    // Return value: 0 means success, non-zero means error
    if (notifyResult == 0) {
      Log.i(NavigationCallback.TAG, "NotifyPageChanged success, uri: " + currentUri + ", windowId: " + windowId);
    } else {
      Log.e(NavigationCallback.TAG, "NotifyPageChanged failed, uri: " + currentUri + ", windowId: " + windowId + ", result: " + notifyResult);
    }
  }

  /**
   * Gets a NavigatorActivity from an encoded activity string.
   * @param activity - The encoded activity string
   * @returns The NavigatorActivity
   * @throws Error if the activity string is not recognized
   */
  private getNavigatorActivityFromValue(activity: string): NavigatorActivity {
    let activityTypes: string[] = [
      NavigatorActivity.PUSH,
      NavigatorActivity.POP
    ];
    if (activityTypes.includes(activity as NavigatorActivity)) {
      return activity as NavigatorActivity;
    }
    throw new Error("No such NavigatorActivity: " + activity);
  }

  /**
   * Gets a NavigatorStatus from an encoded status string.
   * @param status - The encoded status string
   * @returns The NavigatorStatus
   * @throws Error if the status string is not recognized
   */
  private getNavigatorStatusFromValue(status: string): NavigatorStatus {
    let statusTypes: string[] = [
      NavigatorStatus.START,
      NavigatorStatus.FINISH
    ];
    if (statusTypes.includes(status as NavigatorStatus)) {
      return status as NavigatorStatus;
    }
    throw new Error("No such NavigatorStatus: " + status);
  }

  private reportNavigatorPush(navigatorStatus: NavigatorStatus) {
    switch(navigatorStatus) {
      case NavigatorStatus.START:
        hiTraceMeter.startTrace("flutter::NAVIGATOR_PUSH", 0);
        break;
      case NavigatorStatus.FINISH:
        hiTraceMeter.finishTrace("flutter::NAVIGATOR_PUSH", 0);
        break;
    }
  }

  private reportNavigatorPop(navigatorStatus: NavigatorStatus) {
    switch(navigatorStatus) {
      case NavigatorStatus.START:
        hiTraceMeter.startTrace("flutter::NAVIGATOR_POP", 0);
        break;
      case NavigatorStatus.FINISH:
        hiTraceMeter.finishTrace("flutter::NAVIGATOR_POP", 0);
        break;
    }
  }
}
