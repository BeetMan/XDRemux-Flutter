/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on PlatformViewsController.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import PlatformViewsChannel, {
  PlatformViewBufferResized,
  PlatformViewCreationRequest,
  PlatformViewResizeRequest,
  PlatformViewsHandler,
  PlatformViewTouch,
  PlatformViewBufferSize
} from '../../../ets/embedding/engine/systemchannels/PlatformViewsChannel';
import PlatformView, { Params } from './PlatformView';
import { DVModelParameters, } from '../../view/DynamicView/dynamicView';
import { createDVModelFromJson } from '../../view/DynamicView/dynamicViewJson';
import display from '@ohos.display';
import { FlutterView } from '../../view/FlutterView';
import { TextureRegistry } from '../../view/TextureRegistry';
import TextInputPlugin from '../editing/TextInputPlugin';
import { PlatformViewWrapper } from './PlatformViewWrapper';
import { FlutterOverlaySurface } from '../../embedding/engine/FlutterOverlaySurface';
import HashSet from '@ohos.util.HashSet';
import PlatformViewRegistry from './PlatformViewRegistry';
import PlatformViewRegistryImpl from './PlatformViewRegistryImpl';
import DartExecutor from '../../embedding/engine/dart/DartExecutor';
import { FlutterMutatorView } from '../../embedding/engine/mutatorsstack/FlutterMutatorView';
import Log from '../../util/Log'
import PlatformViewFactory from './PlatformViewFactory'
import { ByteBuffer } from '../../util/ByteBuffer';
import Any from '../common/Any';
import { ArrayList, Stack } from '@kit.ArkTS';
import { CustomTouchEvent, CustomTouchObject } from './CustomTouchEvent';
import { NodeRenderType } from '@kit.ArkUI';
import { PlatformViewInfo } from '../../embedding/ohos/PlatformViewInfo';
import { EmbeddingNodeController } from '../../embedding/ohos/EmbeddingNodeController';

/**
 * JSON representation of a DynamicView model.
 */
class DVModelJson {
  /** The component type. */
  compType: string
  /** Array of child components. */
  children: Array<Any>
  /** Component attributes. */
  attributes: Any
  /** Component events. */
  events: Any
  /** Optional build function. */
  build: Any

  /**
   * Constructs a new DVModelJson instance.
   * @param compType - The component type
   * @param children - Array of child components
   * @param attributes - Component attributes
   * @param events - Component events
   * @param build - Optional build function
   */
  constructor(compType: string, children: Array<Any>, attributes: Any, events: Any, build?: Any) {
    this.compType = compType
    this.children = children
    this.attributes = attributes
    this.events = events;
    this.build = build;
  }
}
/**
 * Enumeration of touch event types.
 */
enum TouchEventType {
  /** Action code for when a primary pointer touched the screen. */
  ACTION_DOWN = 0,
  /** Action code for when a primary pointer stopped touching the screen. */
  ACTION_UP = 1,
  /** Action code for when the event only includes information about pointer movement. */
  ACTION_MOVE = 2,
  /** Action code for when a motion event has been canceled. */
  ACTION_CANCEL = 3,
  /** Action code for when a secondary pointer touched the screen. */
  ACTION_POINTER_DOWN = 5,
  /** Action code for when a secondary pointer stopped touching the screen. */
  ACTION_POINTER_UP = 6,
}

const TAG = "PlatformViewsController"
const PLATFORM_VIEW_ACTIVE_TOUCHES = 'platformViewActiveTouches';
const PLATFORM_VIEW_LAST_TOUCH_EVENT = 'platformViewLastTouchEvent';
const PLATFORM_VIEW_LAST_TOUCH_EVENT_IS_PX = 'platformViewLastTouchEventIsPx';
const PLATFORM_VIEW_CANCEL_DRAINING = 'platformViewCancelDraining';

/**
 * Controller for managing platform views in Flutter applications.
 * This class handles the creation, lifecycle, and interaction of native views embedded in Flutter.
 *
 * Implements {@code PlatformViewsHandler} (see {@code PlatformViewsChannel}): fulfills create, dispose, touch,
 * resize, and related commands sent from the Flutter framework over the platform-views channel, mapping them to
 * OpenHarmony {@code PlatformView} / {@code EmbeddingNodeController} instances attached to the host {@code FlutterView}.
 */
export default class PlatformViewsController implements PlatformViewsHandler {
  private registry: PlatformViewRegistryImpl;
  private context: Context | null = null;
  private flutterView: FlutterView | null = null;
  private textureRegistry: TextureRegistry | null = null;
  private textInputPlugin: TextInputPlugin | null = null;
  private platformViewsChannel: PlatformViewsChannel | null = null;
  private nextOverlayLayerId: number = 0;
  private focusViewId: number = -1;
  private platformViews: Map<number, PlatformView>;
  private platformViewParentInfo: Map<number, PlatformViewInfo>;
  private viewIdWithTextureId: Map<number, number>;
  private viewIdWithNodeController: Map<number, EmbeddingNodeController>;
  private viewWrappers: Map<number, PlatformViewWrapper>;
  private currentFrameUsedOverlayLayerIds: HashSet<number>;
  private currentFrameUsedPlatformViewIds: HashSet<number>;

  /**
   * Constructs a new PlatformViewsController instance.
   */
  constructor() {
    this.registry = new PlatformViewRegistryImpl();
    this.currentFrameUsedOverlayLayerIds = new HashSet();
    this.currentFrameUsedPlatformViewIds = new HashSet();
    this.viewWrappers = new Map();
    this.platformViews = new Map();
    this.platformViewParentInfo = new Map();
    this.viewIdWithTextureId = new Map();
    this.viewIdWithNodeController = new Map();
  }

  /**
   * Creates a platform view for hybrid composition mode.
   * @param request - The platform view creation request
   */
  createForPlatformViewLayer(request: PlatformViewCreationRequest): void {
    Log.i(TAG, "Enter createForPlatformViewLayer");
    this.ensureValidRequest(request);

    let platformView: PlatformView = this.createPlatformView(request);

    // OHOS currently relies on the texture composition path for the
    // multi-PlatformView direction fix below. The platform-view-layer / hybrid
    // branch remains a stub, so it is intentionally left outside the scope of
    // this change.
    this.configureForHybridComposition(platformView, request);
  }

  private isTerminalTouch(type: TouchType): boolean {
    return type === TouchType.Up || type === TouchType.Cancel;
  }

  private cloneTouchObjectWithType(touch: CustomTouchObject, type: TouchType): CustomTouchObject {
    return new CustomTouchObject(type, touch.id, touch.displayX, touch.displayY, touch.windowX, touch.windowY,
      touch.screenX, touch.screenY, touch.x, touch.y);
  }

  private getActiveTouches(params: Record<string, Any>, create: boolean = false): Map<number, CustomTouchObject> | undefined {
    let activeTouches = params[PLATFORM_VIEW_ACTIVE_TOUCHES] as Map<number, CustomTouchObject> | undefined;
    if (activeTouches === undefined && create) {
      activeTouches = new Map<number, CustomTouchObject>();
      params[PLATFORM_VIEW_ACTIVE_TOUCHES] = activeTouches;
    }
    return activeTouches;
  }

  private rememberPostedTouchEvent(params: Record<string, Any>, event: CustomTouchEvent, isPx: boolean = true): void {
    params[PLATFORM_VIEW_LAST_TOUCH_EVENT] = event;
    params[PLATFORM_VIEW_LAST_TOUCH_EVENT_IS_PX] = isPx;

    let activeTouches = this.getActiveTouches(params, true)!;
    if (event.type === TouchType.Cancel) {
      activeTouches.clear();
      return;
    }

    for (let touch of event.changedTouches) {
      if (this.isTerminalTouch(touch.type)) {
        activeTouches.delete(touch.id);
      } else {
        activeTouches.set(touch.id, this.cloneTouchObjectWithType(touch, touch.type));
      }
    }

    for (let touch of event.touches) {
      if (this.isTerminalTouch(touch.type)) {
        activeTouches.delete(touch.id);
      } else {
        activeTouches.set(touch.id, this.cloneTouchObjectWithType(touch, touch.type));
      }
    }
  }

  private clearTrackedTouchState(params: Record<string, Any>): void {
    params['down'] = false;
    params['touchEvent'] = undefined;
    params['mouseEvent'] = undefined;
    params[PLATFORM_VIEW_LAST_TOUCH_EVENT] = undefined;
    params[PLATFORM_VIEW_LAST_TOUCH_EVENT_IS_PX] = undefined;
    const activeTouches = this.getActiveTouches(params);
    activeTouches?.clear();
    params[PLATFORM_VIEW_ACTIVE_TOUCHES] = undefined;
  }

  private postTouchCancelEvent(nodeController: EmbeddingNodeController,
    lastTouchEvent: CustomTouchEvent | undefined,
    lastTouchEventIsPx: boolean,
    viewId: number,
    reason: string,
    source: string,
    cancelTouches: Array<CustomTouchObject>): boolean {
    const cancelEvent = new CustomTouchEvent(TouchType.Cancel, cancelTouches, cancelTouches,
      Date.now(),
      lastTouchEvent?.source ?? SourceType.TouchScreen, lastTouchEvent?.pressure ?? 1,
      lastTouchEvent?.tiltX ?? 0, lastTouchEvent?.tiltY ?? 0, lastTouchEvent?.sourceTool ?? SourceTool.Finger);
    let ret = false;
    try {
      ret = nodeController.postEvent(cancelEvent, lastTouchEventIsPx);
    } catch (err) {
      Log.e(TAG, "Sending platform view touch cancel threw an exception", err);
    }
    Log.i(TAG, "platform_view_touch_cancel sent viewId=" + viewId
      + " reason=" + reason + " source=" + source + " changedTouches=" + cancelTouches.length
      + " ret=" + ret);
    return ret;
  }

  private cancelActiveTouchIfNeeded(viewId: number, params: Record<string, Any>, reason: string): void {
    const nodeController = params['nodeController'] as EmbeddingNodeController | undefined;
    const activeTouches = this.getActiveTouches(params);
    const lastTouchEvent = params[PLATFORM_VIEW_LAST_TOUCH_EVENT] as CustomTouchEvent | undefined;
    const lastTouchEventIsPx = params[PLATFORM_VIEW_LAST_TOUCH_EVENT_IS_PX] as boolean ?? false;
    const pendingTouchEvents = params['touchEvent'] as Array<CustomTouchEvent> | undefined;
    const pendingCount = pendingTouchEvents === undefined ? 0 : pendingTouchEvents.length;

    if (nodeController === undefined) {
      Log.i(TAG, "platform_view_touch_cancel skip viewId=" + viewId
        + " reason=" + reason + " no_node pending=" + pendingCount);
      this.clearTrackedTouchState(params);
      return;
    }

    let cancelTouches: Array<CustomTouchObject> = [];
    let cancelSource: string = "none";
    if (activeTouches !== undefined && activeTouches.size > 0) {
      activeTouches.forEach((touch: CustomTouchObject) => {
        cancelTouches.push(this.cloneTouchObjectWithType(touch, TouchType.Cancel));
      });
      cancelSource = "active_map";
    } else if (lastTouchEvent !== undefined) {
      const sourceTouches = lastTouchEvent.touches.length > 0 ? lastTouchEvent.touches : lastTouchEvent.changedTouches;
      for (let touch of sourceTouches) {
        cancelTouches.push(this.cloneTouchObjectWithType(touch, TouchType.Cancel));
      }
      cancelSource = "last_event";
    }

    if (cancelTouches.length > 0) {
      if (cancelTouches.length > 1) {
        for (let i = 0; i < cancelTouches.length; i++) {
          this.postTouchCancelEvent(nodeController, lastTouchEvent, lastTouchEventIsPx,
            viewId, reason, cancelSource + "_single_" + i, [cancelTouches[i]]);
        }
      }
      this.postTouchCancelEvent(nodeController, lastTouchEvent, lastTouchEventIsPx,
        viewId, reason, cancelSource + "_combined", cancelTouches);
      params[PLATFORM_VIEW_CANCEL_DRAINING] = true;
    } else {
      Log.i(TAG, "platform_view_touch_cancel skip viewId=" + viewId
        + " reason=" + reason + " no_touch pending=" + pendingCount);
    }

    this.clearTrackedTouchState(params);
  }

  /**
   * Disposes a platform view and releases all associated resources.
   * @param viewId - The ID of the platform view to dispose
   */
  dispose(viewId: number): void {
    let platformView: PlatformView | null = this.platformViews.get(viewId) || null;
    if (platformView == null) {
      Log.e(TAG, "Disposing unknown platform view with id: " + viewId);
      return;
    }
    let viewWrapper: PlatformViewWrapper | null = this.viewWrappers.get(viewId) || null;
    if (viewWrapper != null) {
      let disposedParams = viewWrapper.getDvModel().getLayoutParams() as Record<string, Any>;
      this.cancelActiveTouchIfNeeded(viewId, disposedParams, "dispose");
    } else {
      Log.i(TAG, "platform_view_touch_cancel skip viewId=" + viewId
        + " reason=dispose no_wrapper");
    }

    if (this.focusViewId == viewId) {
      this.clearFocus(viewId);
      this.focusViewId = -1;
    }
    this.platformViews.delete(viewId);
    this.platformViewParentInfo.delete(viewId);
    let textureId = this.viewIdWithTextureId.get(viewId);

    if (textureId != undefined) {
      this.textureRegistry!.unregisterTexture(textureId);
    }

    this.viewIdWithNodeController.get(viewId)?.disposeFrameNode()
    this.viewIdWithNodeController.delete(viewId);

    if (viewWrapper != null && this.flutterView) {
      let index = this.flutterView.getDVModel().children.indexOf(viewWrapper.getDvModel()!);
      if (index > -1) {
        this.flutterView.getDVModel().children.splice(index, 1);
        platformView.onFlutterViewDetached();
      }
    }
    this.viewWrappers.delete(viewId);

    try {
      platformView.dispose();
    } catch (err) {
      Log.e(TAG, "Disposing platform view threw an exception", err);
    }
  }

  /**
   * Sets a parameter value in the DVModelParameters.
   * @param params - The parameters object to modify
   * @param key - The parameter key
   * @param element - The value to set
   */
  setParams: (params: DVModelParameters, key: string, element: Any) => void =
    (params: DVModelParameters, key: string, element: Any): void => {
      let params2 = params as Record<string, Any>;
      params2[key] = element;
    }

  /**
   * Gets a parameter value from the DVModelParameters.
   * @param params - The parameters object to read from
   * @param key - The parameter key
   * @returns The parameter value as a number
   */
  getParams: (params: DVModelParameters, key: string) => number = (params: DVModelParameters, key: string): number => {
    let params2 = params as Record<string, Any>;
    return params2[key];
  }

  /**
   * Resizes a platform view.
   * @param request - The resize request containing new dimensions
   * @param onComplete - Callback to invoke when resize is complete
   */
  resize(request: PlatformViewResizeRequest, onComplete: PlatformViewBufferResized): void {
    let physicalWidth: number = this.toPhysicalPixels(request.newLogicalWidth);
    let physicalHeight: number = this.toPhysicalPixels(request.newLogicalHeight);
    let viewId: number = request.viewId;
    Log.i(TAG,
      `Resize viewId ${viewId}, pw:${physicalWidth}, ph:${physicalHeight},lw:${request.newLogicalWidth}, lh:${request.newLogicalHeight}`);

    let viewWrapper = this.viewWrappers.get(request.viewId)
    let params: DVModelParameters | undefined = viewWrapper?.getDvModel()!.params

    this.setParams(params!, "width", physicalWidth);
    this.setParams(params!, "height", physicalHeight);

    let textureId = this.viewIdWithTextureId.get(viewId);
    if (textureId != undefined) {
      let density = this.getDisplayDensity();
      this.textureRegistry?.notifyTextureResizing(textureId, request.newLogicalWidth * density, request.newLogicalHeight * density);
    }

    onComplete.run(new PlatformViewBufferSize(physicalWidth, physicalHeight));
  }

  /**
   * Updates the offset position of a platform view.
   * @param viewId - The ID of the platform view
   * @param top - The top offset
   * @param left - The left offset
   */
  offset(viewId: number, top: number, left: number): void {
    Log.i(TAG, `Offset is id${viewId}, t:${top}, l:${left}`);

    let viewWrapper = this.viewWrappers.get(viewId)
    if (viewWrapper === undefined) {
      return;
    }

    let params: DVModelParameters | undefined = viewWrapper?.getDvModel()!.params;
    if (!params) {
      return;
    }
    // When the current value is NaN and the previous value is a normal value,
    // the platformView is considered to have transitioned from visible to invisible.
    // Use Number.isNaN; the page is considered invisible in the background
    // only when both top and left values equal NaN.
    if (Number.isNaN(top) && Number.isNaN(left)) {
      let leftPre: number | undefined = this.getParams(params!, "left");
      let topPre: number | undefined = this.getParams(params!, "top");
      let compType: string | undefined = viewWrapper?.getDvModel().compType;
      if ((leftPre !== undefined && !Number.isNaN(leftPre)) &&
        (topPre !== undefined && !Number.isNaN(topPre)) &&
        (compType === "NodeContainer")) {
        const nodeController = (params as Record<string, EmbeddingNodeController>)?.nodeController;
        if (nodeController instanceof EmbeddingNodeController) {
          nodeController.notifyPlatformViewInvisible();
        }
      }
    }
    this.setParams(params!, "left", left);
    this.setParams(params!, "top", top);
  }

  /**
   * Sets the hover state for platform views.
   * @param viewId - The ID of the platform view to set hover state for
   */
  hover(viewId: number) {
    for (let key of this.viewWrappers.keys()) {
      let viewWrapper: undefined | PlatformViewWrapper = this.viewWrappers.get(key);
      let dvModel = viewWrapper?.getDvModel();
      let params = dvModel?.getLayoutParams() as Record<string, Any>;
      if (key == viewId) {
        params["hover"] = true;
      } else {
        params["hover"] = false;
      }
    }
  }

  /**
   * Handles touch events for platform views.
   * @param touch - The touch event information
   */
  onTouch(touch: PlatformViewTouch): void {
    let viewWrapper: undefined | PlatformViewWrapper = this.viewWrappers.get(touch.viewId)
    this.focusViewId = touch.viewId;
    if (viewWrapper != undefined) {
      let dvModel = viewWrapper.getDvModel()
      let params = dvModel.getLayoutParams() as Record<string, Any>;
      // When receiving a DOWN action
      if (touch.action === TouchEventType.ACTION_DOWN) {
        // Set the current touch state to true
        params['down'] = true
        params[PLATFORM_VIEW_CANCEL_DRAINING] = false;
        // When first receiving a touch DOWN event, dispatch all events stored in the list
        let touchEventArray: Array<CustomTouchEvent> | undefined = params['touchEvent'] as Array<CustomTouchEvent>
        if (touchEventArray !== undefined) {
          let nodeController = params['nodeController'] as EmbeddingNodeController;
          for (let it of touchEventArray) {
            nodeController.postEvent(it)
            this.rememberPostedTouchEvent(params, it);
          }
          // Clear the list after first dispatch
          params['touchEvent'] = undefined
        }

        // When first receiving a mouse PRESS event, dispatch all events stored in the list
        let mouseEventArray: Array<MouseEvent> | undefined = params['mouseEvent'] as Array<MouseEvent>
        if (mouseEventArray !== undefined) {
          let nodeController = params['nodeController'] as EmbeddingNodeController;
          for (let it of mouseEventArray) {
            nodeController.postMouseEvent(it)
          }
          // Clear the list after first dispatch
          params['mouseEvent'] = undefined
        }
        // When receiving an UP action
      } else if (touch.action === TouchEventType.ACTION_UP || touch.action === TouchEventType.ACTION_CANCEL) {
        if (touch.action === TouchEventType.ACTION_CANCEL) {
          this.cancelActiveTouchIfNeeded(touch.viewId, params, "platform_cancel");
        }
        // Set the touch state to false after finger is lifted. When multiple fingers are lifted suddenly,
        // the final state returned is also ACTION_UP, so we use the UP state to indicate the user
        // is no longer touching the platform view
        params['down'] = false
      }
    }
  }

  /**
   * Sets the text direction for a platform view.
   * @param viewId - The ID of the platform view
   * @param direction - The text direction to set
   */
  setDirection(viewId: number, direction: Direction): void {
    let nodeController = this.viewIdWithNodeController.get(viewId)
    let platformViewInfo = this.platformViewParentInfo.get(viewId);
    if (nodeController != undefined && platformViewInfo != undefined) {
      platformViewInfo.direction = direction;
      // Rebuild the node with the PlatformView and surface that belong to this
      // specific viewId. Reusing the latest FlutterView-level references can
      // redirect updates to the wrong native node when multiple PlatformViews
      // are alive at the same time.
      nodeController?.setRenderOption(platformViewInfo.platformView, platformViewInfo.surfaceId,
        NodeRenderType.RENDER_TYPE_TEXTURE, direction)
      nodeController?.rebuild()
    }
  }

  /**
   * Validates if a direction value is valid.
   * @param direction - The direction value to validate
   * @returns True if the direction is valid, false otherwise
   */
  validateDirection(direction: number): boolean {
    return direction == Direction.Ltr || direction == Direction.Rtl || direction == Direction.Auto;
  }

  /**
   * Clears focus from a platform view.
   * @param viewId - The ID of the platform view
   */
  clearFocus(viewId: number): void {
    const platformView = this.platformViews.get(viewId);
    if (platformView == null) {
      Log.e(TAG, "Setting direction to an unknown view with id: " + viewId);
      return;
    }
    const embeddedView = platformView.getView();
    if (embeddedView == null) {
      Log.e(TAG, "Setting direction to a null view with id: " + viewId);
      return;
    }
    // Make the Xcomponent gain focus.
    focusControl.requestFocus("unfocus-xcomponent-node");
  }

  /**
   * Synchronizes the native view hierarchy.
   * @param yes - Whether to synchronize
   * @throws Error as this method is not implemented
   */
  synchronizeToNativeViewHierarchy(yes: boolean): void {
    throw new Error('Method not implemented.');
  }

  /**
   * Creates a platform view for texture layer composition mode.
   * @param request - The platform view creation request
   * @returns The texture ID for the created view
   */
  public createForTextureLayer(request: PlatformViewCreationRequest): number {
    Log.i(TAG, "Enter createForTextureLayer");
    this.ensureValidRequest(request);
    this.ensureFlutterViewAttached("create platform view");

    let platformView: PlatformView = this.createPlatformView(request);
    let textureId = this.configureForTextureLayerComposition(platformView, request);
    this.viewIdWithTextureId.set(request.viewId, textureId);
    return textureId;
  }

  /**
   * Ensures that a platform view creation request is valid.
   * @param request - The request to validate
   * @throws Error if the request is invalid
   * @private
   */
  private ensureValidRequest(request: PlatformViewCreationRequest): void {
    if (!this.validateDirection(request.direction)) {
      throw new Error("Trying to create a view with unknown direction value: "
        + request.direction
        + "(view id: "
        + request.viewId
        + ")")
    }
  }

  /**
   * Creates a platform view instance from a factory.
   * @param request - The platform view creation request
   * @returns The created PlatformView instance
   * @throws Error if the factory is not found or creation fails
   * @private
   */
  private createPlatformView(request: PlatformViewCreationRequest): PlatformView {
    Log.i(TAG, "begin createPlatformView");
    const viewFactory: PlatformViewFactory = this.registry.getFactory(request.viewType);
    if (viewFactory == null) {
      throw new Error("Trying to create a platform view of unregistered type: " + request.viewType)
    }

    let createParams: Any = null;
    if (request.params != null) {
      let byteParas: ByteBuffer = request.params as ByteBuffer;
      createParams = viewFactory.getCreateArgsCodec().decodeMessage(byteParas.buffer);
    }

    if (this.context == null) {
      throw new Error('PlatformView#context is null.');
    }
    let platformView = viewFactory.create(this.context, request.viewId, createParams);

    let embeddedView: WrappedBuilder<[Params]> = platformView.getView();
    if (embeddedView == null) {
      throw new Error("PlatformView#getView() returned null, but an WrappedBuilder reference was expected.");
    }

    this.platformViews.set(request.viewId, platformView);
    return platformView;
  }

  /**
   * Configures the view for Hybrid Composition mode.
   * @param platformView - The platform view to configure
   * @param request - The creation request
   * @private
   */
  private configureForHybridComposition(platformView: PlatformView, request: PlatformViewCreationRequest): void {
    // This path is not implemented yet on OHOS. Keep that behavior explicit so
    // future readers do not assume the texture-path fix also covers hybrid.
    Log.i(TAG, "Using hybrid composition for platform view: " + request.viewId);
  }

  /**
   * Configures the view for Texture Layer Composition mode.
   * @param platformView - The platform view to configure
   * @param request - The creation request
   * @returns The texture ID for the view
   * @private
   */
  private configureForTextureLayerComposition(platformView: PlatformView,
    request: PlatformViewCreationRequest): number {
    Log.i(TAG, "Hosting view in view hierarchy for platform view: " + request.viewId);
    let surfaceId: string = '0';
    let textureId: number = 0;
    if (this.textureRegistry != null) {
      textureId = this.textureRegistry!.getTextureId();
      surfaceId = this.textureRegistry!.registerTexture(textureId).getSurfaceId().toString();
      Log.i(TAG, "nodeController getSurfaceId: " + surfaceId);
      this.flutterView!.setSurfaceId(surfaceId);
    }

    let wrappedBuilder: WrappedBuilder<[Params]> = platformView.getView();
    this.flutterView?.setWrappedBuilder(wrappedBuilder);
    this.flutterView?.setPlatformView(platformView);
    let physicalWidth: number = this.toPhysicalPixels(request.logicalWidth);
    let physicalHeight: number = this.toPhysicalPixels(request.logicalHeight);

    let nodeController = new EmbeddingNodeController();
    nodeController.setRenderOption(platformView, surfaceId, NodeRenderType.RENDER_TYPE_TEXTURE, request.direction);
    // Persist the native view/surface pair per Flutter viewId so later updates
    // (for example setDirection) always target the correct embedded node.
    this.platformViewParentInfo.set(
      request.viewId,
      new PlatformViewInfo(
        platformView,
        surfaceId,
        physicalWidth,
        physicalHeight,
        request.logicalTop,
        request.logicalLeft,
        request.direction
      )
    );
    this.viewIdWithNodeController.set(request.viewId, nodeController);

    let dvModel = createDVModelFromJson(new DVModelJson("NodeContainer",
      [],
      {
        "width": physicalWidth,
        "height": physicalHeight,
        "nodeController": nodeController,
        "left": request.logicalLeft,
        "top": request.logicalTop
      },
      {},
      undefined));
    let viewWrapper: PlatformViewWrapper = new PlatformViewWrapper();
    viewWrapper.addDvModel(dvModel);
    this.viewWrappers.set(request.viewId, viewWrapper);
    this.flutterView?.getDVModel().children.push(viewWrapper.getDvModel())
    platformView.onFlutterViewAttached(this.flutterView!.getDVModel());
    Log.i(TAG, "Create platform view success");
    return textureId;
  }

  /**
   * Attaches the controller to a context, texture registry, and Dart executor.
   * @param context - The application context
   * @param textureRegistry - The texture registry for managing textures
   * @param dartExecutor - The Dart executor for communication
   */
  public attach(context: Context, textureRegistry: TextureRegistry | null, dartExecutor: DartExecutor): void {
    this.context = context;
    this.textureRegistry = textureRegistry;
    this.platformViewsChannel = new PlatformViewsChannel(dartExecutor);
    this.platformViewsChannel.setPlatformViewsHandler(this);
  }

  /**
   * Detaches the controller and cleans up resources.
   */
  public detach(): void {
    if (this.platformViewsChannel != null) {
      this.platformViewsChannel.setPlatformViewsHandler(null);
    }
    this.destroyOverlaySurfaces();
    this.platformViewsChannel = null;
    this.context = null;
    this.textureRegistry = null;
  }

  /**
   * Attaches the controller to a FlutterView.
   * @param newFlutterView - The FlutterView to attach to
   */
  public attachToView(newFlutterView: FlutterView) {
    // The same FlutterView can receive multiple XComponent surface generations
    // during fast ArkUI route changes. PlatformView attach/detach tracks the
    // FlutterView/DV tree, not each native surface, so same-view surface churn is
    // handled by FlutterView/XComponent native attach logic instead of notifying
    // plugins again here.
    if (this.flutterView == newFlutterView) {
      return;
    }

    if (this.flutterView != null) {
      this.detachFromView();
    }

    this.flutterView = newFlutterView;

    // A FlutterView surface can be destroyed and later recreated while the
    // engine and PlatformViewsController stay alive. Reattach existing wrapper
    // DVModels to the new FlutterView so embedded PlatformViews remain visible
    // after the surface is mounted again.
    for (let viewId of this.viewWrappers.keys()) {
      let viewWrapper: PlatformViewWrapper | undefined = this.viewWrappers.get(viewId);
      if (viewWrapper == undefined) {
        continue;
      }
      let dvModel = viewWrapper.getDvModel();
      if (this.flutterView.getDVModel().children.indexOf(dvModel) < 0) {
        this.flutterView.getDVModel().children.push(dvModel);
      }
    }

    // Match Android PlatformViewsController semantics: every created PlatformView
    // is notified when the owning FlutterView attaches, even though only wrapper
    // DVModels are physically re-added to the FlutterView tree above.
    for (let viewId of this.platformViews.keys()) {
      let platformView: PlatformView | undefined = this.platformViews.get(viewId);
      if (platformView != undefined) {
        platformView.onFlutterViewAttached(this.flutterView.getDVModel());
      }
    }
  }

  /**
   * Detaches the controller from the FlutterView.
   */
  public detachFromView(detachingFlutterView?: FlutterView): void {
    if (this.flutterView == null) {
      return;
    }
    if (detachingFlutterView != undefined && this.flutterView != detachingFlutterView) {
      return;
    }

    // Mirror Android's FlutterView detach semantics: remove wrapper DVModels
    // from the old FlutterView and notify every PlatformView so plugins do not
    // keep using a stale FlutterView/DynamicView tree after the surface is gone.
    for (let viewId of this.viewWrappers.keys()) {
      let viewWrapper: PlatformViewWrapper | undefined = this.viewWrappers.get(viewId);
      if (viewWrapper == undefined) {
        continue;
      }
      let index = this.flutterView.getDVModel().children.indexOf(viewWrapper.getDvModel());
      while (index > -1) {
        this.flutterView.getDVModel().children.splice(index, 1);
        index = this.flutterView.getDVModel().children.indexOf(viewWrapper.getDvModel());
      }
    }

    this.destroyOverlaySurfaces();
    this.removeOverlaySurfaces();
    this.flutterView = null;

    // Keep the notification scope symmetric with attachToView and Android:
    // PlatformView lifecycle callbacks are tied to FlutterView ownership, not to
    // whether the view currently has a wrapper DVModel.
    for (let viewId of this.platformViews.keys()) {
      let platformView: PlatformView | undefined = this.platformViews.get(viewId);
      if (platformView != undefined) {
        platformView.onFlutterViewDetached();
      }
    }
  }

  /**
   * Gets the current FlutterView.
   * @returns The FlutterView instance, or null if not attached
   */
  public getFlutterView(): FlutterView | null {
    return this.flutterView;
  }

  /**
   * Attaches a text input plugin to this controller.
   * @param textInputPlugin - The TextInputPlugin instance
   */
  public attachTextInputPlugin(textInputPlugin: TextInputPlugin): void {
    this.textInputPlugin = textInputPlugin;
  }

  /**
   * Detaches the text input plugin from this controller.
   */
  public detachTextInputPlugin(): void {
    this.textInputPlugin = null;
  }

  /**
   * Gets the platform view registry.
   * @returns The PlatformViewRegistry instance
   */
  public getRegistry(): PlatformViewRegistry {
    return this.registry;
  }

  /**
   * Called when the controller is detached from NAPI.
   * Disposes all platform views.
   */
  public onDetachedFromNapi(): void {
    this.diposeAllViews();
  }

  /**
   * Called before the Flutter engine restarts.
   * Disposes all platform views.
   */
  public onPreEngineRestart(): void {
    this.diposeAllViews();
  }

  /**
   * Gets the display density.
   * @returns The display density value
   * @private
   */
  private getDisplayDensity(): number {
    return display.getDefaultDisplaySync().densityPixels;
  }

  /**
   * Converts logical pixels to physical pixels.
   * @param logicalPixels - The logical pixel value
   * @returns The physical pixel value
   * @private
   */
  private toPhysicalPixels(logicalPixels: number): number {
    return Math.round(px2vp(logicalPixels * this.getDisplayDensity()));
  }

  /**
   * Converts physical pixels to logical pixels using a specific density.
   * @param physicalPixels - The physical pixel value
   * @param displayDensity - The display density to use
   * @returns The logical pixel value
   * @private
   */
  private toLogicalPixelsByDensity(physicalPixels: number, displayDensity: number): number {
    return Math.round(physicalPixels / displayDensity);
  }

  /**
   * Converts physical pixels to logical pixels using the current display density.
   * @param physicalPixels - The physical pixel value
   * @returns The logical pixel value
   * @private
   */
  private toLogicalPixels(physicalPixels: number): number {
    return this.toLogicalPixelsByDensity(physicalPixels, this.getDisplayDensity());
  }

  /**
   * Disposes all platform views.
   * @private
   */
  private diposeAllViews(): void {
    let viewKeys = this.platformViews.keys();
    for (let viewId of viewKeys) {
      this.dispose(viewId);
    }
  }

  /**
   * Initializes the root image view if needed.
   * @private
   */
  private initializeRootImageViewIfNeeded(): void {
  }

  /**
   * Called when an overlay surface should be displayed.
   * @param id - The overlay surface ID
   * @param x - The X position
   * @param y - The Y position
   * @param width - The width
   * @param height - The height
   */
  public onDisplayOverlaySurface(id: number, x: number, y: number, width: number, height: number): void {
  }

  /**
   * Called at the beginning of each frame.
   * Clears the sets of used overlay layers and platform views.
   */
  public onBeginFrame(): void {
    this.currentFrameUsedOverlayLayerIds.clear();
    this.currentFrameUsedPlatformViewIds.clear();
  }

  /**
   * Called at the end of each frame.
   */
  public onEndFrame(): void {
  }

  /**
   * Finishes frame rendering.
   * @param isFrameRenderedUsingImageReaders - Whether the frame was rendered using image readers
   * @private
   */
  private finishFrame(isFrameRenderedUsingImageReaders: boolean): void {
  }

  /**
   * Creates a new overlay surface.
   * @returns A new FlutterOverlaySurface instance
   */
  public createOverlaySurface(): FlutterOverlaySurface {
    return new FlutterOverlaySurface(this.nextOverlayLayerId++);
  }

  /**
   * Destroys all overlay surfaces.
   * @private
   */
  private destroyOverlaySurfaces(): void {
  }

  /**
   * Removes overlay surfaces from the view hierarchy.
   * @private
   */
  private removeOverlaySurfaces(): void {
    if (!(this.flutterView instanceof FlutterView)) {
      return;
    }
  }

  /**
   * Renders a platform view with the specified dimensions and position.
   * @param surfaceId - The surface ID
   * @param platformView - The platform view to render
   * @param width - The width in pixels
   * @param height - The height in pixels
   * @param left - The left position in pixels
   * @param top - The top position in pixels
   */
  public render(surfaceId: number, platformView: PlatformView,
    width: number, height: number, left: number, top: number) {

    let wrapper = this.viewWrappers.get(surfaceId);
    if (wrapper != null) {
      let params: DVModelParameters | undefined = wrapper?.getDvModel()!.params

      this.setParams(params!, "width", width);
      this.setParams(params!, "height", height);
      this.setParams(params!, "left", left);
      this.setParams(params!, "top", top);
      return;
    }

    if (this.flutterView == null) {
      Log.w(TAG, "render: FlutterView is detached, skipping render for surfaceId=" + surfaceId);
      return;
    }
    this.flutterView!.setSurfaceId(surfaceId.toString());
    let wrappedBuilder: WrappedBuilder<[Params]> = platformView.getView();
    this.flutterView?.setWrappedBuilder(wrappedBuilder);
    this.flutterView?.setPlatformView(platformView);

    let nodeController = new EmbeddingNodeController();

    nodeController.setRenderOption(platformView, surfaceId.toString(), NodeRenderType.RENDER_TYPE_TEXTURE,
      Direction.Auto);
    this.viewIdWithNodeController.set(surfaceId, nodeController);

    let dvModel = createDVModelFromJson(new DVModelJson("NodeContainer",
      [],
      {
        "width": width,
        "height": height,
        "nodeController": nodeController,
        "left": left,
        "top": top
      },
      {},
      undefined));

    let viewWrapper: PlatformViewWrapper = new PlatformViewWrapper();
    viewWrapper.addDvModel(dvModel);
    this.viewWrappers.set(surfaceId, viewWrapper);
    this.flutterView?.getDVModel().children.push(viewWrapper.getDvModel());
    platformView.onFlutterViewAttached(this.flutterView!.getDVModel());
    this.platformViews.set(surfaceId, platformView!);
  }
  private ensureFlutterViewAttached(action: string): void {
    if (this.flutterView == null) {
      throw new Error("Cannot " + action + " while FlutterView is detached from PlatformViewsController.");
    }
  }
}
