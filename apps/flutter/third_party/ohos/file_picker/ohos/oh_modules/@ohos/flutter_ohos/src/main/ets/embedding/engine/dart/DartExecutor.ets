/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on DartExecutor.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import resourceManager from '@ohos.resourceManager';
import FlutterInjector from '../../../FlutterInjector';
import { BinaryMessageHandler, BinaryReply, TaskQueue, TaskQueueOptions } from '../../../plugin/common/BinaryMessenger';
import { BinaryMessenger } from '../../../plugin/common/BinaryMessenger';
import StringCodec from '../../../plugin/common/StringCodec';
import Log from '../../../util/Log';
import { TraceSection } from '../../../util/TraceSection';
import { FlutterCallbackInformation } from '../../../view/FlutterCallbackInformation';
import FlutterNapi from '../FlutterNapi';
import { DartMessenger } from './DartMessenger';
import SendableBinaryMessageHandler from '../../../plugin/common/SendableBinaryMessageHandler'


const TAG = "DartExecutor";

/**
 * Configures, bootstraps, and starts executing Dart code.
 *
 * To specify a top-level Dart function to execute, use a {@link DartEntrypoint} to tell
 * DartExecutor where to find the Dart code to execute, and which Dart function to use as the
 * entrypoint. To execute the entrypoint, pass the {@link DartEntrypoint} to
 * {@link executeDartEntrypoint}.
 *
 * To specify a Dart callback to execute, use a {@link DartCallback}. A given Dart callback must
 * be registered with the Dart VM to be invoked by a DartExecutor. To execute the callback,
 * pass the {@link DartCallback} to {@link executeDartCallback}.
 *
 * Once started, a DartExecutor cannot be stopped. The associated Dart code will execute
 * until it completes, or until the {@link FlutterEngine} that owns this
 * DartExecutor is destroyed.
 */
export default class DartExecutor implements BinaryMessenger {
  /** The FlutterNapi instance for native communication. */
  flutterNapi: FlutterNapi;
  /** The resource manager for accessing application assets. */
  assetManager: resourceManager.ResourceManager;
  private dartMessenger: DartMessenger;
  private binaryMessenger: BinaryMessenger;
  private isApplicationRunning: boolean = false;
  private isolateServiceId: String = "";
  private isolateServiceIdListener: IsolateServiceIdListener | null = null;
  private isolateChannelMessageHandler: BinaryMessageHandler =
    new IsolateChannelMessageHandler(this.isolateServiceId, this.isolateServiceIdListener);

  /**
   * Constructs a new DartExecutor instance.
   * @param flutterNapi - The FlutterNapi instance for native communication
   * @param assetManager - The resource manager for accessing assets
   */
  constructor(flutterNapi: FlutterNapi, assetManager: resourceManager.ResourceManager) {
    this.flutterNapi = flutterNapi;
    this.assetManager = assetManager;
    this.dartMessenger = new DartMessenger(flutterNapi);
    this.dartMessenger.setMessageHandler("flutter/isolate", this.isolateChannelMessageHandler);
    this.binaryMessenger = new DefaultBinaryMessenger(this.dartMessenger);
    // The NAPI might already be attached if coming from a spawned engine. If so, correctly report
    // that this DartExecutor is already running.
    if (flutterNapi.isRunningDart) {
      this.isApplicationRunning = true;
    }
  }

  /**
   * Invoked when the FlutterEngine that owns this DartExecutor attaches to NAPI.
   *
   * When attached to NAPI, this DartExecutor begins handling 2-way communication to/from
   * the Dart execution context. This communication is facilitated via 2 APIs:
   * BinaryMessenger, which sends messages to Dart
   * PlatformMessageHandler, which receives messages from Dart
   */
  onAttachedToNAPI(): void {
    Log.d(TAG, "Attached to NAPI. Registering the platform message handler for this Dart execution context.");
    this.flutterNapi.setPlatformMessageHandler(this.dartMessenger);
  }

  /**
   * Invoked when the FlutterEngine that owns this DartExecutor detaches from NAPI.
   *
   * When detached from NAPI, this DartExecutor stops handling 2-way communication to/from
   * the Dart execution context.
   */
  onDetachedFromNAPI(): void {
    Log.d(TAG, "Detached from NAPI. De-registering the platform message handler for this Dart execution context.");
    this.flutterNapi.setPlatformMessageHandler(null);
  }

  /**
   * Checks if this DartExecutor is currently executing Dart code.
   *
   * @returns True if Dart code is being executed, false otherwise
   */
  isExecutingDart(): boolean {
    return this.isApplicationRunning;
  }

  /**
   * Starts executing Dart code based on the given dartEntrypoint and the dartEntrypointArgs.
   *
   * See DartEntrypoint for configuration options.
   *
   * @param dartEntrypoint - Specifies which Dart function to run, and where to find it
   * @param dartEntrypointArgs - Arguments passed as a list of strings to Dart's entrypoint function
   */
  executeDartEntrypoint(dartEntrypoint: DartEntrypoint, dartEntrypointArgs?: string[]): void {
    if (this.isApplicationRunning) {
      Log.w(TAG, "Attempted to run a DartExecutor that is already running.");
      return;
    }

    let traceId: number = TraceSection.begin("DartExecutor#executeDartEntrypoint");
    try {
      Log.d(TAG, "Executing Dart entrypoint: " + dartEntrypoint);
      this.flutterNapi.runBundleAndSnapshotFromLibrary(
        dartEntrypoint.pathToBundle,
        dartEntrypoint.dartEntrypointFunctionName,
        dartEntrypoint.dartEntrypointLibrary,
        this.assetManager,
        dartEntrypointArgs ?? []);

      this.isApplicationRunning = true;
    } finally {
      TraceSection.endWithId("DartExecutor#executeDartEntrypoint", traceId);
    }
  }

  /**
   * Starts executing Dart code based on the given dartCallback.
   *
   * See DartCallback for configuration options.
   *
   * @param dartCallback - Specifies which Dart callback to run, and where to find it
   */
  executeDartCallback(dartCallback: DartCallback): void {
    if (this.isApplicationRunning) {
      Log.w(TAG, "Attempted to run a DartExecutor that is already running.");
      return;
    }

    let traceId: number = TraceSection.begin("DartExecutor#executeDartCallback");
    try {
      Log.d(TAG, "Executing Dart callback: " + dartCallback);
      this.flutterNapi.runBundleAndSnapshotFromLibrary(
        dartCallback.pathToBundle,
        dartCallback.callbackHandle.callbackName,
        dartCallback.callbackHandle.callbackLibraryPath,
        dartCallback.resourceManager,
        []);

      this.isApplicationRunning = true;
    } finally {
      TraceSection.endWithId("DartExecutor#executeDartCallback", traceId);
    }
  }

  /**
   * Gets a BinaryMessenger that can be used to send messages to, and receive messages
   * from, Dart code that this DartExecutor is executing.
   * @returns The BinaryMessenger instance
   */
  getBinaryMessenger(): BinaryMessenger {
    return this.binaryMessenger;
  }

  /**
   * Creates a background task queue for handling messages asynchronously.
   * @param options - Optional task queue configuration options
   * @returns A TaskQueue instance for background message processing
   */
  makeBackgroundTaskQueue(options?: TaskQueueOptions): TaskQueue {
    return this.getBinaryMessenger().makeBackgroundTaskQueue(options);
  }


  /**
   * Sends a binary message to Dart over the specified channel.
   * @param channel - The channel name for the message
   * @param message - The message data as an ArrayBuffer
   * @param callback - Optional callback to receive the reply from Dart
   */
  send(channel: String, message: ArrayBuffer, callback?: BinaryReply): void {
    this.getBinaryMessenger().send(channel, message, callback);
  }

  /**
   * Sets a message handler for incoming messages from Dart on the specified channel.
   * @param channel - The channel name to listen on
   * @param handler - The message handler, or null to remove the handler
   * @param taskQueue - Optional task queue for processing messages
   * @param args - Additional arguments to pass to the handler
   */
  setMessageHandler(channel: String, handler: BinaryMessageHandler | SendableBinaryMessageHandler | null,
    taskQueue?: TaskQueue, ...args: Object[]): void {
    this.getBinaryMessenger().setMessageHandler(channel, handler, taskQueue, ...args);
  }

  /**
   * Gets the number of pending channel callback replies.
   * When sending messages with reply callbacks, this tracks how many are still waiting for responses.
   * Must be called from the main thread.
   * Mainly useful for testing frameworks to determine if the app is idle.
   * @returns The number of pending channel callback replies
   */
  getPendingChannelResponseCount(): number {
    return this.dartMessenger.getPendingChannelResponseCount();
  }

  /**
   * Gets an identifier for this executor's primary isolate. This identifier can be used in
   * queries to the Dart service protocol.
   * @returns The isolate service ID
   */
  getIsolateServiceId(): String {
    return this.isolateServiceId;
  }


  /**
   * Sets a listener that will be notified when an isolate identifier is available for this
   * executor's primary isolate.
   * @param listener - The listener to be notified when the isolate service ID is available
   */
  setIsolateServiceIdListener(listener: IsolateServiceIdListener): void {
    this.isolateServiceIdListener = listener;
    if (this.isolateServiceIdListener != null && this.isolateServiceId != null) {
      this.isolateServiceIdListener.onIsolateServiceIdAvailable(this.isolateServiceId);
    }
  }

  /**
   * Notifies the Dart VM of a low memory event.
   * This allows the Dart VM to free resources, but does not notify the Flutter application.
   * To notify the Flutter application, use SystemChannel.sendMemoryPressureWarning().
   *
   * Note: Calling this method may cause performance issues. Avoid calling during startup or animations.
   */
  notifyLowMemoryWarning(): void {
    if (this.flutterNapi.isAttached()) {
      this.flutterNapi.notifyLowMemoryWarning();
    }
  }
}


/**
 * Configuration options that specify which Dart entrypoint function is executed and where to find
 * that entrypoint and other assets required for Dart execution.
 */
export class DartEntrypoint {
  /** The path within the ResourceManager where the app will look for assets. */
  pathToBundle: string;
  /** The library or file location that contains the Dart entrypoint function. */
  dartEntrypointLibrary: string;
  /** The name of a Dart function to execute. */
  dartEntrypointFunctionName: string;

  /**
   * Constructs a new DartEntrypoint instance.
   * @param pathToBundle - The path within the AssetManager where the app will look for assets
   * @param dartEntrypointLibrary - The library or file location that contains the Dart entrypoint function
   * @param dartEntrypointFunctionName - The name of a Dart function to execute
   */
  constructor(pathToBundle: string,
    dartEntrypointLibrary: string,
    dartEntrypointFunctionName: string) {
    this.pathToBundle = pathToBundle;
    this.dartEntrypointLibrary = dartEntrypointLibrary;
    this.dartEntrypointFunctionName = dartEntrypointFunctionName;
  }

  /**
   * Creates a default DartEntrypoint using the main function.
   * @returns A DartEntrypoint configured with the default main entrypoint
   * @throws Error if FlutterLoader is not initialized
   */
  static createDefault() {
    const flutterLoader = FlutterInjector.getInstance().getFlutterLoader();
    if (!flutterLoader.initialized) {
      throw new Error(
        "DartEntrypoints can only be created once a FlutterEngine is created.");
    }
    return new DartEntrypoint(flutterLoader.findAppBundlePath(), "", "main");
  }
}


/**
 * Callback interface invoked when the isolate identifier becomes available.
 */
interface IsolateServiceIdListener {
  /**
   * Called when the isolate service ID becomes available.
   * @param isolateServiceId - The isolate service ID
   */
  onIsolateServiceIdAvailable(isolateServiceId: String): void;
}


/**
 * Configuration options that specify which Dart callback function is executed and where to find
 * that callback and other assets required for Dart execution.
 */
export class DartCallback {
  /** Standard OpenHarmony ResourceManager for accessing assets. */
  public resourceManager: resourceManager.ResourceManager;
  /** The path within the ResourceManager where the app will look for assets. */
  public pathToBundle: string;
  /** A Dart callback that was previously registered with the Dart VM. */
  public callbackHandle: FlutterCallbackInformation;

  /**
   * Constructs a new DartCallback instance.
   * @param resourceManager - Standard OpenHarmony ResourceManager
   * @param pathToBundle - The path within the ResourceManager where the app will look for assets
   * @param callbackHandle - A Dart callback that was previously registered with the Dart VM
   */
  constructor(resourceManager: resourceManager.ResourceManager,
    pathToBundle: string,
    callbackHandle: FlutterCallbackInformation) {
    this.resourceManager = resourceManager;
    this.pathToBundle = pathToBundle;
    this.callbackHandle = callbackHandle;
  }

  /**
   * Returns a string representation of this DartCallback.
   * @returns A string describing the callback's bundle path, library path, and function name
   */
  toString(): String {
    return "DartCallback( bundle path: "
      + this.pathToBundle
      + ", library path: "
      + this.callbackHandle.callbackLibraryPath
      + ", function: "
      + this.callbackHandle.callbackName
      + " )";
  }
}

/**
 * Default implementation of BinaryMessenger that delegates to DartMessenger.
 */
export class DefaultBinaryMessenger implements BinaryMessenger {
  private messenger: DartMessenger;

  /**
   * Constructs a new DefaultBinaryMessenger instance.
   * @param messenger - The DartMessenger instance to delegate to
   */
  constructor(messenger: DartMessenger) {
    this.messenger = messenger;
  }

  /**
   * Creates a background task queue for handling messages asynchronously.
   * @param options - Optional task queue configuration options
   * @returns A TaskQueue instance for background message processing
   */
  makeBackgroundTaskQueue(options?: TaskQueueOptions): TaskQueue {
    return this.messenger.makeBackgroundTaskQueue(options);
  }

  /**
   * Sends a message from OpenHarmony to Dart over the given channel and then
   * has the provided callback invoked when the Dart side responds.
   *
   * @param channel - The name of the logical channel used for the message
   * @param message - The message payload as an ArrayBuffer, or null for an empty message
   * @param callback - A callback invoked when the Dart application responds to the message
   */
  send(channel: String, message: ArrayBuffer, callback?: BinaryReply): void {
    this.messenger.send(channel, message, callback);
  }

  /**
   * Sets the given BinaryMessageHandler as the singular handler for all incoming messages
   * received from the Dart side of this Dart execution context.
   *
   * @param channel - The name of the channel
   * @param handler - A BinaryMessageHandler to be invoked on incoming messages, or null
   * @param taskQueue - Optional task queue for processing messages
   * @param args - Additional arguments to pass to the handler
   */
  setMessageHandler(channel: String, handler: BinaryMessageHandler | SendableBinaryMessageHandler | null,
    taskQueue?: TaskQueue, ...args: Object[]): void {
    this.messenger.setMessageHandler(channel, handler, taskQueue, ...args);
  }
}

/**
 * Message handler for the isolate channel that receives isolate service IDs.
 */
class IsolateChannelMessageHandler implements BinaryMessageHandler {
  private isolateServiceId: String;
  private isolateServiceIdListener: IsolateServiceIdListener | null = null;

  /**
   * Constructs a new IsolateChannelMessageHandler instance.
   * @param isolateServiceId - The isolate service ID
   * @param isolateServiceIdListener - Optional listener to be notified when the ID is available
   */
  constructor(isolateServiceId: String, isolateServiceIdListener: IsolateServiceIdListener | null) {
    this.isolateServiceId = isolateServiceId;
    this.isolateServiceIdListener = isolateServiceIdListener;
  }

  /**
   * Handles a message received on the isolate channel.
   * @param message - The message containing the isolate service ID
   * @param callback - The reply callback
   */
  onMessage(message: ArrayBuffer, callback: BinaryReply): void {
    this.isolateServiceId = StringCodec.INSTANCE.decodeMessage(message);
    if (this.isolateServiceIdListener != null) {
      this.isolateServiceIdListener.onIsolateServiceIdAvailable(this.isolateServiceId);
    }
  }
}