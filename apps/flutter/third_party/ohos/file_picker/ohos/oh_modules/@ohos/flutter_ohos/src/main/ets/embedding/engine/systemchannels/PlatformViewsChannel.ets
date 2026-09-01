/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on PlatformViewsChannel.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import Any from '../../../plugin/common/Any';

import MethodCall from '../../../plugin/common/MethodCall';
import MethodChannel, { MethodCallHandler, MethodResult } from '../../../plugin/common/MethodChannel';
import StandardMethodCodec from '../../../plugin/common/StandardMethodCodec';
import { ByteBuffer } from '../../../util/ByteBuffer';
import Log from '../../../util/Log';
import DartExecutor from '../dart/DartExecutor';

const TAG = "PlatformViewsChannel";
const NON_TEXTURE_FALLBACK = -2;

/**
 * System channel that sends 2-way communication between Flutter and OpenHarmony to facilitate
 * embedding of OpenHarmony Views within a Flutter application.
 *
 * Implement PlatformViewsHandler and register it via setPlatformViewsHandler() to implement
 * the OpenHarmony side of this channel.
 */
export default class PlatformViewsChannel {
  private channel: MethodChannel;
  private handler: PlatformViewsHandler | null = null;
  private parsingHandler = new ParsingCallback();

  /**
   * Constructs a PlatformViewsChannel that connects OpenHarmony to the Dart
   * code running in dartExecutor.
   *
   * The given dartExecutor is permitted to be idle or executing code.
   *
   * @param dartExecutor - The DartExecutor for sending messages to Dart
   */
  constructor(dartExecutor: DartExecutor) {
    this.channel = new MethodChannel(dartExecutor, "flutter/platform_views", StandardMethodCodec.INSTANCE);
    this.parsingHandler.platformChannel = this;
    this.channel.setMethodCallHandler(this.parsingHandler);
  }

  /**
   * Sets the PlatformViewsHandler which receives all events and requests that are parsed
   * from the underlying platform views channel.
   * @param handler - The PlatformViewsHandler instance, or null to remove
   */
  public setPlatformViewsHandler(handler: PlatformViewsHandler | null): void {
    this.handler = handler;
    this.parsingHandler.handler = handler;
  }

  /**
   * Notifies Flutter that a platform view has gained focus.
   * @param viewId - The ID of the platform view that gained focus
   */
  public invokeViewFocused(viewId: number): void {
    if (this.channel == null) {
      return;
    }
    this.channel.invokeMethod("viewFocused", viewId);
  }

  /**
   * Handles platform view creation requests.
   * @param call - The method call containing creation parameters
   * @param result - The result callback to send a response
   */
  create(call: MethodCall, result: MethodResult): void {
    const createArgs: Map<string, Any> = call.args;
    const usesPlatformViewLayer: boolean = createArgs.has("hybrid") && createArgs.get("hybrid") as boolean;
    const additionalParams: ByteBuffer = createArgs.has("params") ? createArgs.get("params") : null;

    let direction: Direction = Direction.Ltr;
    if (createArgs.get("direction") == 0) {
      direction = Direction.Ltr;
    } else if (createArgs.get("direction") == 1) {
      direction = Direction.Rtl;
    }

    try {
      if (usesPlatformViewLayer) {
        const request: PlatformViewCreationRequest = new PlatformViewCreationRequest(
          createArgs.get("id"),
          createArgs.get("viewType"),
          0,
          0,
          0,
          0,
          direction,
          additionalParams,
          RequestedDisplayMode.HYBRID_ONLY
        );
        this.handler?.createForPlatformViewLayer(request);
        result.success(null);
      } else {
        const hybridFallback: boolean = createArgs.has("hybridFallback") && createArgs.get("hybridFallback");
        const displayMode: RequestedDisplayMode =
          hybridFallback ? RequestedDisplayMode.TEXTURE_WITH_HYBRID_FALLBACK
            : RequestedDisplayMode.TEXTURE_WITH_VIRTUAL_FALLBACK;
        const request: PlatformViewCreationRequest = new PlatformViewCreationRequest(
          createArgs.get("id"),
          createArgs.get("viewType"),
          createArgs.has("top") ? createArgs.get("top") : 0.0,
          createArgs.has("left") ? createArgs.get("left") : 0.0,
          createArgs.get("width"),
          createArgs.get("height"),
          direction,
          additionalParams,
          displayMode
        );

        Log.i(TAG, `Create texture param id:${request.viewId},
          type:${request.viewType},
          w:${request.logicalWidth},
          h:${request.logicalHeight},
          l:${request.logicalLeft},
          t:${request.logicalTop},
          d:${request.direction}`);

        const textureId = this.handler?.createForTextureLayer(request);
        if (textureId == NON_TEXTURE_FALLBACK) {
          if (!hybridFallback) {
            throw new Error(
              "Platform view attempted to fall back to hybrid mode when not requested.");
          }

          // A fallback to hybrid mode is indicated with a null texture ID.
          result.success(null);
        } else {
          result.success(textureId);
        }
      }
    } catch (err) {
      Log.e(TAG, "create failed" + err);
      result.error("error", err, null);
    }
  }

  /**
   * Handles platform view disposal requests.
   * @param call - The method call containing the view ID to dispose
   * @param result - The result callback to send a response
   */
  dispose(call: MethodCall, result: MethodResult): void {
    const disposeArgs: Map<string, Any> = call.args;
    const viewId: number = disposeArgs.get("id");
    try {
      this.handler?.dispose(viewId);
      result.success(null);
    } catch (err) {
      Log.e(TAG, "dispose failed", err);
      result.error("error", err, null);
    }
  }

  /**
   * Handles platform view resize requests.
   * @param call - The method call containing resize parameters
   * @param result - The result callback to send a response
   */
  resize(call: MethodCall, result: MethodResult): void {
    const resizeArgs: Map<string, Any> = call.args;
    const resizeRequest: PlatformViewResizeRequest = new PlatformViewResizeRequest(
      resizeArgs.get("id"),
      resizeArgs.get("width"),
      resizeArgs.get("height")
    );
    try {
      let resizeCallback = new ResizeCallback();
      resizeCallback.result = result;
      this.handler?.resize(resizeRequest, resizeCallback);
    } catch (err) {
      Log.e(TAG, "resize failed", err);
      result.error("error", err, null);
    }
  }

  /**
   * Handles platform view offset change requests.
   * @param call - The method call containing offset parameters
   * @param result - The result callback to send a response
   */
  offset(call: MethodCall, result: MethodResult): void {
    const offsetArgs: Map<string, Any> = call.args;
    try {
      this.handler?.offset(
        offsetArgs.get("id"),
        offsetArgs.get("top"),
        offsetArgs.get("left"));
      result.success(null);
    } catch (err) {
      Log.e(TAG, "offset failed", err);
      result.error("error", err, null);
    }
  }

  /**
   * Handles touch events on platform views.
   * @param call - The method call containing touch event data
   * @param result - The result callback to send a response
   */
  touch(call: MethodCall, result: MethodResult): void {
    const args: Array<Any> = call.args;
    let index = 0;
    const touch: PlatformViewTouch = new PlatformViewTouch(
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index++],
      args[index]
    );

    try {
      this.handler?.onTouch(touch);
      result.success(null);
    } catch (err) {
      Log.e(TAG, "offset failed", err);
      result.error("error", err, null);
    }
  }

  /**
   * Handles platform view direction change requests.
   * @param call - The method call containing direction parameters
   * @param result - The result callback to send a response
   */
  setDirection(call: MethodCall, result: MethodResult): void {
    const setDirectionArgs: Map<string, Any> = call.args;
    const newDirectionViewId: number = setDirectionArgs.get("id");
    const directionValue: number = setDirectionArgs.get("direction");
    // The framework sends 0/1 for LTR/RTL. Convert them explicitly before
    // dispatching so the controller always receives a valid Direction enum.
    let direction: Direction = Direction.Ltr;
    if (directionValue == 0) {
      direction = Direction.Ltr;
    } else if (directionValue == 1) {
      direction = Direction.Rtl;
    } else {
      Log.w(
        TAG,
        "Received unsupported direction value " + directionValue +
        " for platform view " + newDirectionViewId +
        ". Falling back to Direction.Ltr."
      );
    }

    try {
      this.handler?.setDirection(newDirectionViewId, direction);
      result.success(null);
    } catch (err) {
      Log.e(TAG, "setDirection failed", err);
      result.error("error", err, null);
    }
  }

  /**
   * Handles platform view focus clearing requests.
   * @param call - The method call containing the view ID
   * @param result - The result callback to send a response
   */
  clearFocus(call: MethodCall, result: MethodResult): void {
    const viewId: number = call.args;
    try {
      this.handler?.clearFocus(viewId);
      result.success(null);
    } catch (err) {
      Log.e(TAG, "clearFocus failed", err);
      result.error("error", err, null);
    }
  }

  /**
   * Handles requests to synchronize to native view hierarchy.
   * @param call - The method call containing synchronization parameters
   * @param result - The result callback to send a response
   */
  synchronizeToNativeViewHierarchy(call: MethodCall, result: MethodResult): void {
    const yes: boolean = call.args;
    try {
      this.handler?.synchronizeToNativeViewHierarchy(yes);
      result.success(null);
    } catch (err) {
      Log.e(TAG, "synchronizeToNativeViewHierarchy failed", err);
      result.error("error", err, null);
    }
  }

  /**
   * Handles hover events on platform views.
   * @param call - The method call containing the view ID
   * @param result - The result callback to send a response
   */
  hover(call: MethodCall, result: MethodResult) {
    const viewId: number = call.args;
    try {
      this.handler?.hover(viewId);
      result.success(null);
    } catch (err) {
      Log.e(TAG, "hover failed", err);
      result.error("error", err, null);
    }
  }
}

/**
 * Handler that receives platform view messages sent from Flutter to OpenHarmony through a given
 * PlatformViewsChannel.
 *
 * To register a PlatformViewsHandler with a PlatformViewsChannel,
 * see PlatformViewsChannel.setPlatformViewsHandler.
 */
export interface PlatformViewsHandler {
  /**
   * The Flutter application would like to display a new OpenHarmony View, i.e., platform view.
   *
   * The OpenHarmony View is added to the view hierarchy. This view is rendered in the Flutter
   * framework by a PlatformViewLayer.
   *
   * @param request - The metadata sent from the framework
   */
  createForPlatformViewLayer(request: PlatformViewCreationRequest): void;

  /**
   * The Flutter application would like to display a new OpenHarmony View, i.e., platform view.
   *
   * The OpenHarmony View is added to the view hierarchy. This view is rendered in the Flutter
   * framework by a TextureLayer.
   *
   * The ID returned by createForTextureLayer to indicate that the requested texture mode
   * was not available and the view creation fell back to PlatformViewLayer mode.
   * This can only be returned if the PlatformViewCreationRequest sets
   * TEXTURE_WITH_HYBRID_FALLBACK as the requested display mode.
   *
   * @param request - The metadata sent from the framework
   * @returns The texture ID, or NON_TEXTURE_FALLBACK if falling back to hybrid mode
   */
  createForTextureLayer(request: PlatformViewCreationRequest): number;

  /**
   * The Flutter application would like to dispose of an existing OpenHarmony View.
   * @param viewId - The ID of the platform view to dispose
   */
  dispose(viewId: number): void;

  /**
   * The Flutter application would like to resize an existing OpenHarmony View.
   *
   * @param request - The request to resize the platform view
   * @param onComplete - Once the resize is completed, this is the handler to notify the size of the
   *     platform view buffer
   */
  resize(request: PlatformViewResizeRequest, onComplete: PlatformViewBufferResized): void;

  /**
   * The Flutter application would like to change the offset of an existing OpenHarmony View.
   * @param viewId - The ID of the platform view
   * @param top - The new top offset
   * @param left - The new left offset
   */
  offset(viewId: number, top: number, left: number): void;

  /**
   * The user touched a platform view within Flutter.
   *
   * Touch data is reported in the touch parameter.
   * @param touch - The touch event data
   */
  onTouch(touch: PlatformViewTouch): void;

  /**
   * The Flutter application would like to change the layout direction of an existing OpenHarmony
   * View, i.e., platform view.
   * @param viewId - The ID of the platform view
   * @param direction - The new layout direction
   */
  setDirection(viewId: number, direction: Direction): void;

  /**
   * Clears the focus from the platform view with a given id if it is currently focused.
   * @param viewId - The ID of the platform view
   */
  clearFocus(viewId: number): void;

  /**
   * Whether the render surface of FlutterView should be converted to a
   * FlutterImageView when a PlatformView is added.
   *
   * This is done to synchronize the rendering of the PlatformView and the FlutterView. Defaults
   * to true.
   * @param yes - Whether to synchronize to native view hierarchy
   */
  synchronizeToNativeViewHierarchy(yes: boolean): void;

  /**
   * Handles hover events on a platform view.
   * @param viewId - The ID of the platform view
   */
  hover(viewId: number): void;
}

/** Platform view display modes that can be requested at creation time. */
enum RequestedDisplayMode {
  /** Use Texture Layer if possible, falling back to Virtual Display if not. */
  TEXTURE_WITH_VIRTUAL_FALLBACK,
  /** Use Texture Layer if possible, falling back to Hybrid Composition if not. */
  TEXTURE_WITH_HYBRID_FALLBACK,
  /** Use Hybrid Composition in all cases. */
  HYBRID_ONLY,
}

/** Request sent from Flutter to create a new platform view. */
export class PlatformViewCreationRequest {
  /** The ID of the platform view as seen by the Flutter side. */
  public viewId: number;
  /** The type of view to create for this platform view. */
  public viewType: string;
  /** The density independent width to display the platform view. */
  public logicalWidth: number;
  /** The density independent height to display the platform view. */
  public logicalHeight: number;
  /** The density independent top position to display the platform view. */
  public logicalTop: number;
  /** The density independent left position to display the platform view. */
  public logicalLeft: number;
  /** The layout direction of the new platform view. */
  public direction: Direction;
  /** The requested display mode for the platform view. */
  public displayMode: RequestedDisplayMode;
  /** Custom parameters that are unique to the desired platform view. */
  public params: ByteBuffer;

  /**
   * Constructs a new PlatformViewCreationRequest instance.
   * @param viewId - The ID of the platform view
   * @param viewType - The type of view to create
   * @param logicalTop - The density-independent top position
   * @param logicalLeft - The density-independent left position
   * @param logicalWidth - The density-independent width
   * @param logicalHeight - The density-independent height
   * @param direction - The layout direction
   * @param params - Custom parameters for the view
   * @param displayMode - The requested display mode (optional)
   */
  constructor(viewId: number, viewType: string, logicalTop: number, logicalLeft: number, logicalWidth: number,
    logicalHeight: number, direction: Direction, params: ByteBuffer, displayMode?: RequestedDisplayMode) {
    this.viewId = viewId;
    this.viewType = viewType;
    this.logicalTop = logicalTop;
    this.logicalLeft = logicalLeft;
    this.logicalWidth = logicalWidth;
    this.logicalHeight = logicalHeight;
    this.direction = direction;
    this.displayMode = displayMode ? displayMode : RequestedDisplayMode.TEXTURE_WITH_VIRTUAL_FALLBACK;
    this.params = params;
  }
}

/** Request sent from Flutter to resize a platform view. */
export class PlatformViewResizeRequest {
  /** The ID of the platform view as seen by the Flutter side. */
  public viewId: number;
  /** The new density independent width to display the platform view. */
  public newLogicalWidth: number;
  /** The new density independent height to display the platform view. */
  public newLogicalHeight: number;

  /**
   * Constructs a new PlatformViewResizeRequest instance.
   * @param viewId - The ID of the platform view
   * @param newLogicalWidth - The new density-independent width
   * @param newLogicalHeight - The new density-independent height
   */
  constructor(viewId: number, newLogicalWidth: number, newLogicalHeight: number) {
    this.viewId = viewId;
    this.newLogicalWidth = newLogicalWidth;
    this.newLogicalHeight = newLogicalHeight;
  }
}

/** The platform view buffer size. */
export class PlatformViewBufferSize {
  /** The width of the screen buffer. */
  public width: number;
  /** The height of the screen buffer. */
  public height: number;

  /**
   * Constructs a new PlatformViewBufferSize instance.
   * @param width - The width of the buffer
   * @param height - The height of the buffer
   */
  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }
}

/** Allows to notify when a platform view buffer has been resized. */
export abstract class PlatformViewBufferResized {
  /**
   * Called when the platform view buffer has been resized.
   * @param bufferSize - The new buffer size
   */
  abstract run(bufferSize: PlatformViewBufferSize): void;
}

/** The state of a touch event in Flutter within a platform view. */
export class PlatformViewTouch {
  /** The ID of the platform view as seen by the Flutter side. */
  public viewId: number;
  /** The amount of time that the touch has been pressed. */
  public downTime: number;
  /** The time when the event occurred. */
  public eventTime: number;
  /** The touch action type. */
  public action: number;
  /** The number of pointers (e.g, fingers) involved in the touch event. */
  public pointerCount: number;
  /** Properties for each pointer, encoded in a raw format. */
  public rawPointerPropertiesList: Any;
  /** Coordinates for each pointer, encoded in a raw format. */
  public rawPointerCoords: Any;
  /** The meta state indicating modifier keys pressed. */
  public metaState: number;
  /** The button state indicating which buttons are pressed. */
  public buttonState: number;
  /** Coordinate precision along the x-axis. */
  public xPrecision: number;
  /** Coordinate precision along the y-axis. */
  public yPrecision: number;
  /** The ID of the input device that generated the event. */
  public deviceId: number;
  /** Edge flags indicating which screen edges were touched. */
  public edgeFlags: number;
  /** The event source indicating the type of input device. */
  public source: number;
  /** Event flags providing additional information about the event. */
  public flags: number;
  /** The motion event ID for tracking the event. */
  public motionEventId: number;

  /**
   * Constructs a new PlatformViewTouch instance.
   * @param viewId - The ID of the platform view
   * @param downTime - The time when the touch was pressed
   * @param eventTime - The time of the event
   * @param action - The touch action
   * @param pointerCount - The number of pointers
   * @param rawPointerPropertiesList - Raw pointer properties
   * @param rawPointerCoords - Raw pointer coordinates
   * @param metaState - The meta state
   * @param buttonState - The button state
   * @param xPrecision - X-axis coordinate precision
   * @param yPrecision - Y-axis coordinate precision
   * @param deviceId - The device ID
   * @param edgeFlags - Edge flags
   * @param source - The event source
   * @param flags - Event flags
   * @param motionEventId - The motion event ID
   */
  constructor(viewId: number,
    downTime: number,
    eventTime: number,
    action: number,
    pointerCount: number,
    rawPointerPropertiesList: Any,
    rawPointerCoords: Any,
    metaState: number,
    buttonState: number,
    xPrecision: number,
    yPrecision: number,
    deviceId: number,
    edgeFlags: number,
    source: number,
    flags: number,
    motionEventId: number) {
    this.viewId = viewId;
    this.downTime = downTime;
    this.eventTime = eventTime;
    this.action = action;
    this.pointerCount = pointerCount;
    this.rawPointerPropertiesList = rawPointerPropertiesList;
    this.rawPointerCoords = rawPointerCoords;
    this.metaState = metaState;
    this.buttonState = buttonState;
    this.xPrecision = xPrecision;
    this.yPrecision = yPrecision;
    this.deviceId = deviceId;
    this.edgeFlags = edgeFlags;
    this.source = source;
    this.flags = flags;
    this.motionEventId = motionEventId;
  }
}

/**
 * Method call handler for parsing platform view requests.
 */
class ParsingCallback implements MethodCallHandler {
  platformChannel: PlatformViewsChannel | null = null;
  handler: PlatformViewsHandler | null = null;

  /**
   * Handles method calls from Dart.
   * @param call - The method call from Dart
   * @param result - The result callback to send a response
   */
  onMethodCall(call: MethodCall, result: MethodResult) {
    if (this.handler == null) {
      return;
    }

    Log.i(TAG, "Received '" + call.method + "' message.");
    switch (call.method) {
      case "create": {
        this.platformChannel?.create(call, result);
        break;
      }
      case "dispose": {
        this.platformChannel?.dispose(call, result);
        break;
      }
      case "resize": {
        this.platformChannel?.resize(call, result);
        break;
      }
      case "offset": {
        this.platformChannel?.offset(call, result);
        break;
      }
      case "touch": {
        this.platformChannel?.touch(call, result);
        break;
      }
      case "setDirection": {
        this.platformChannel?.setDirection(call, result);
        break;
      }
      case "clearFocus": {
        this.platformChannel?.clearFocus(call, result);
        break;
      }
      case "synchronizeToNativeViewHierarchy": {
        this.platformChannel?.synchronizeToNativeViewHierarchy(call, result);
        break;
      }
      case "hover": {
        this.platformChannel?.hover(call, result);
        break;
      }
      default:
        result.notImplemented();
    }
  }
}

/**
 * Callback for handling platform view resize completion.
 */
class ResizeCallback extends PlatformViewBufferResized {
  result: MethodResult | null = null;

  /**
   * Called when the resize is complete.
   * @param bufferSize - The new buffer size
   */
  run(bufferSize: PlatformViewBufferSize) {
    if (bufferSize == null) {
      this.result?.error("error", "Failed to resize the platform view", null);
    } else {
      const response: Map<string, Any> = new Map();
      response.set("width", bufferSize.width);
      response.set("height", bufferSize.height);
      this.result?.success(response);
    }
  }
}
