/*
* Copyright (c) 2024 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

/** Handle the motion events received by the FlutterNapi. */
// import PlainArray from '@ohos.util.PlainArray';
// import { TouchEvent } from '@ohos.multimodalInput.touchEvent';
// import Queue from '@ohos.util.Queue';

import { CustomTouchEvent, CustomTouchObject } from '../../plugin/platform/CustomTouchEvent';
import display from '@ohos.display';
import FlutterManager from './FlutterManager';
import { EmbeddingNodeController } from './EmbeddingNodeController';
import Any from '../../plugin/common/Any';


const OH_NATIVEXCOMPONENT_UNKNOWN = 4;
const OH_NATIVEXCOMPONENT_TOOL_TYPE_UNKNOWN = 0;
const PLATFORM_VIEW_ACTIVE_TOUCHES = 'platformViewActiveTouches';
const PLATFORM_VIEW_LAST_TOUCH_EVENT = 'platformViewLastTouchEvent';
const PLATFORM_VIEW_LAST_TOUCH_EVENT_IS_PX = 'platformViewLastTouchEventIsPx';
const PLATFORM_VIEW_CANCEL_DRAINING = 'platformViewCancelDraining';

/**
 * Represents a touch point in a native XComponent touch event.
 */
class OH_NativeXComponent_TouchPoint {
  id: number = 0;
  screenX: number = 0.0;
  screenY: number = 0.0;
  x: number = 0.0;
  y: number = 0.0;
  type: number = OH_NATIVEXCOMPONENT_UNKNOWN;
  size: number = 0;
  force: number = 0;
  timeStamp: number = 0;
  isPressed: boolean = false;

  /**
   * Constructs a new OH_NativeXComponent_TouchPoint instance.
   * @param id - The touch point ID
   * @param screenX - The screen X coordinate
   * @param screenY - The screen Y coordinate
   * @param x - The local X coordinate
   * @param y - The local Y coordinate
   * @param type - The touch type
   * @param size - The touch size
   * @param force - The touch force
   * @param timeStamp - The timestamp
   * @param isPressed - Whether the touch is pressed
   */
  constructor(id: number,
    screenX: number,
    screenY: number,
    x: number,
    y: number,
    type: number,
    size: number,
    force: number,
    timeStamp: number,
    isPressed: boolean) {
    this.id = id;
    this.screenX = screenX;
    this.screenY = screenY;
    this.x = x;
    this.y = y;
    this.type = type;
    this.size = size;
    this.force = force;
    this.timeStamp = timeStamp;
    this.isPressed = isPressed;
  }
}

/**
 * Represents a native XComponent touch event.
 */
class OH_NativeXComponent_TouchEvent {
  id: number = 0;
  screenX: number = 0.0;
  screenY: number = 0.0;
  x: number = 0.0;
  y: number = 0.0;
  type: number = OH_NATIVEXCOMPONENT_UNKNOWN;
  size: number = 0;
  force: number = 0;
  deviceId: number = 0;
  timeStamp: number = 0;
  touchPoints: OH_NativeXComponent_TouchPoint[] = [];
  numPoints: number = 0;

  /**
   * Constructs a new OH_NativeXComponent_TouchEvent instance.
   * @param id - The event ID
   * @param screenX - The screen X coordinate
   * @param screenY - The screen Y coordinate
   * @param x - The local X coordinate
   * @param y - The local Y coordinate
   * @param type - The touch type
   * @param size - The touch size
   * @param force - The touch force
   * @param deviceId - The device ID
   * @param timeStamp - The timestamp
   * @param touchPoints - Array of touch points
   * @param numPoints - Number of touch points
   */
  constructor(id: number,
    screenX: number,
    screenY: number,
    x: number,
    y: number,
    type: number,
    size: number,
    force: number,
    deviceId: number,
    timeStamp: number,
    touchPoints: OH_NativeXComponent_TouchPoint[],
    numPoints: number) {
    this.id = id;
    this.screenX = screenX;
    this.screenY = screenY;
    this.x = x;
    this.y = y;
    this.type = type;
    this.size = size;
    this.force = force;
    this.deviceId = deviceId;
    this.timeStamp = timeStamp;
    this.touchPoints = touchPoints;
    this.numPoints = numPoints;
  }
}

/**
 * Packet containing touch event data and tool information.
 */
class TouchPacket {
  touchEvent: OH_NativeXComponent_TouchEvent;
  toolType: number = OH_NATIVEXCOMPONENT_TOOL_TYPE_UNKNOWN;
  tiltX: number = 0;
  tiltY: number = 0;

  /**
   * Constructs a new TouchPacket instance.
   * @param touchEvent - The touch event
   * @param toolType - The tool type
   * @param tiltX - The X-axis tilt
   * @param tiltY - The Y-axis tilt
   */
  constructor(touchEvent: OH_NativeXComponent_TouchEvent,
    toolType: number,
    tiltX: number,
    tiltY: number) {
    this.touchEvent = touchEvent;
    this.toolType = toolType;
    this.tiltX = tiltX;
    this.tiltY = tiltY;
  }
}

/**
 * Packet containing mouse event data.
 */
class MousePacket {
  offset: number;
  x: number;
  y: number;
  screenX: number;
  screenY: number;
  timestamp: number;
  action: number;
  button: number;

  /**
   * Constructs a new MousePacket instance.
   * @param offset - The offset value
   * @param x - The local X coordinate
   * @param y - The local Y coordinate
   * @param screenX - The screen X coordinate
   * @param screenY - The screen Y coordinate
   * @param timestamp - The timestamp
   * @param action - The mouse action
   * @param button - The mouse button
   */
  constructor(  offset: number,
    x: number,
    y: number,
    screenX: number,
    screenY: number,
    timestamp: number,
    action: number,
    button: number) {
    this.offset = offset;
    this.x = x;
    this.y = y;
    this.screenX = screenX;
    this.screenY = screenY;
    this.timestamp = timestamp;
    this.action = action;
    this.button = button;
  }
}

/**
 * Processor for handling touch events received by FlutterNapi.
 * This class processes and converts touch events from native format to Flutter format.
 */
export default class TouchEventProcessor {
  private static instance: TouchEventProcessor;

  /**
   * Gets the singleton instance of TouchEventProcessor.
   * @returns The singleton TouchEventProcessor instance
   */
  static getInstance(): TouchEventProcessor {
    if (TouchEventProcessor.instance == null) {
      TouchEventProcessor.instance = new TouchEventProcessor();
    }
    return TouchEventProcessor.instance;
  }

  private decodeTouchPacket(strings: Array<string>, densityPixels: number, top: number, left: number): TouchPacket {
    let offset: number = 0;
    let numPoint: number = parseInt(strings[offset++]);
    let changesId: number = parseInt(strings[offset++]);
    let changesscreenX: number = (parseFloat(strings[offset++]) / densityPixels);
    let changesscreenY: number = (parseFloat(strings[offset++]) / densityPixels);
    let changesX: number = ((parseFloat(strings[offset++]) / densityPixels) - left);
    let changesY: number = ((parseFloat(strings[offset++]) / densityPixels) - top);
    let changesType: number = parseInt(strings[offset++]);
    let changesSize: number = parseFloat(strings[offset++]);
    let changesForce: number = parseFloat(strings[offset++]);
    let changesDeviceId: number = parseInt(strings[offset++]);
    let changesTimeStamp: number = parseInt(strings[offset++]);

    const touchPoints: OH_NativeXComponent_TouchPoint[] = [];
    for (let i = 0; i < numPoint; i++) {
      const touchPoint: OH_NativeXComponent_TouchPoint = new OH_NativeXComponent_TouchPoint(
        parseInt(strings[offset++]),
        (parseFloat(strings[offset++]) / densityPixels),
        (parseFloat(strings[offset++]) / densityPixels),
        ((parseFloat(strings[offset++]) / densityPixels) - left),
        ((parseFloat(strings[offset++]) / densityPixels) - top),
        parseInt(strings[offset++]),
        parseFloat(strings[offset++]),
        parseFloat(strings[offset++]),
        parseInt(strings[offset++]),
        parseInt(strings[offset++]) === 1 ? true : false
      );
      touchPoints.push(touchPoint);
    }

    const touchEventInput: OH_NativeXComponent_TouchEvent = new OH_NativeXComponent_TouchEvent(
      changesId,
      changesscreenX,
      changesscreenY,
      changesX,
      changesY,
      changesType,
      changesSize,
      changesForce,
      changesDeviceId,
      changesTimeStamp,
      touchPoints,
      numPoint
    );

    let toolTypeInput: number = parseInt(strings[offset++]);
    let tiltXTouch: number = parseInt(strings[offset++]);
    let tiltYTouch: number = parseInt(strings[offset++]);

    const touchPointEventPacket: TouchPacket = new TouchPacket(
      touchEventInput,
      toolTypeInput,
      tiltXTouch,
      tiltYTouch
    );
    return touchPointEventPacket;
  }

  private constructCustomTouchEventImpl(touchPacket: TouchPacket): CustomTouchEvent {
    let changes1: CustomTouchObject = new CustomTouchObject(
      touchPacket.touchEvent.type,
      touchPacket.touchEvent.id,
      touchPacket.touchEvent.screenX,
      touchPacket.touchEvent.screenY,
      touchPacket.touchEvent.screenX,
      touchPacket.touchEvent.screenY,
      touchPacket.touchEvent.screenX,
      touchPacket.touchEvent.screenY,
      touchPacket.touchEvent.x,
      touchPacket.touchEvent.y
    );

    let touches: CustomTouchObject[] = [];
    let touchPointer: number = touchPacket.touchEvent.numPoints;
    for (let i = 0; i < touchPointer; i++) {
      let touchesItem: CustomTouchObject = new CustomTouchObject(
        touchPacket.touchEvent.touchPoints[i].type,
        touchPacket.touchEvent.touchPoints[i].id,
        touchPacket.touchEvent.touchPoints[i].screenX,
        touchPacket.touchEvent.touchPoints[i].screenY,
        touchPacket.touchEvent.touchPoints[i].screenX,
        touchPacket.touchEvent.touchPoints[i].screenY,
        touchPacket.touchEvent.touchPoints[i].screenX,
        touchPacket.touchEvent.touchPoints[i].screenY,
        touchPacket.touchEvent.touchPoints[i].x,
        touchPacket.touchEvent.touchPoints[i].y
      );
      touches.push(touchesItem);
    }

    let customTouchEvent1: CustomTouchEvent = new CustomTouchEvent(
      touchPacket.touchEvent.type,
      touches,
      [changes1],
      touchPacket.touchEvent.timeStamp,
      SourceType.TouchScreen,
      touchPacket.touchEvent.force,
      touchPacket.tiltX,
      touchPacket.tiltY,
      touchPacket.toolType
    );

    return customTouchEvent1;
  }

  /**
   * Constructs a CustomTouchEvent from string array data.
   * @param strings - Array of string values representing touch data
   * @param top - The top offset
   * @param left - The left offset
   * @returns A CustomTouchEvent instance
   */
  public constructCustomTouchEvent(strings: Array<string>, top: number, left: number): CustomTouchEvent {
    let densityPixels: number = display.getDefaultDisplaySync().densityPixels;

    let touchPacket: TouchPacket = this.decodeTouchPacket(strings, densityPixels, top, left);
    let customTouchEvent: CustomTouchEvent = this.constructCustomTouchEventImpl(touchPacket);
    return customTouchEvent;
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

  private rememberPostedTouchEvent(params: Record<string, Any>, event: CustomTouchEvent): void {
    params[PLATFORM_VIEW_LAST_TOUCH_EVENT] = event;
    params[PLATFORM_VIEW_LAST_TOUCH_EVENT_IS_PX] = true;

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

  /**
   * Posts an axis/scroll event to platform views.
   * Axis/wheel coordinates are passed to nodes through this method.
   * @param strings - Array of string values representing axis event data
   */
  public postAxisEvent(strings: Array<string>) {
    FlutterManager.getInstance().getFlutterViewList().forEach((value) => {
      if (!value.getActive()) {
        return
      }
      let length = value.getDVModel().children.length
      for (let index = length - 1; index >= 0; index--) {
        const dvModel = value.getDVModel().children[index]
        const params = dvModel.getLayoutParams() as Record<string, ESObject>;
        if (!params["hover"]) {
          continue;
        }
        const left = params['left'] as number ?? 0;
        const top = params['top'] as number ?? 0;
        const densityPixels: number = display.getDefaultDisplaySync().densityPixels;

        let offset: number = 0;
        const action: number = parseFloat(strings[offset++]);
        const x: number = vp2px((parseInt(strings[offset++])) / densityPixels - left);
        const y: number = vp2px((parseInt(strings[offset++])) / densityPixels - top);
        const windowX: number = vp2px(parseFloat(strings[offset++]) / densityPixels);
        const windowY: number = vp2px(parseFloat(strings[offset++]) / densityPixels);
        const displayX: number = vp2px(parseFloat(strings[offset++]) / densityPixels);
        const displayY: number = vp2px(parseFloat(strings[offset++]) / densityPixels);
        const scroll: number = parseFloat(strings[offset++]);

        // 构造AxisEvent数据
        const axisEvent: AxisEvent = {
          action: action,
          x: x,
          y: y,
          windowX: x,
          windowY: y,
          displayX: displayX,
          displayY: displayY,
          scrollStep: scroll,
          axisVertical: scroll
        } as AxisEvent;

        let nodeController = params['nodeController'] as EmbeddingNodeController;
        nodeController.postAxisEvent(axisEvent)
      }      
    });
  }
  
  /**
   * Posts a touch event to platform views.
   * @param strings - Array of string values representing touch event data
   */
  public postTouchEvent(strings: Array<string>) {
    FlutterManager.getInstance().getFlutterViewList().forEach((value) => {
      if (!value.getActive()) {
        return
      }
      let length = value.getDVModel().children.length
      for (let index = length - 1; index >= 0; index--) {
        let dvModel = value.getDVModel().children[index]
        let params = dvModel.getLayoutParams() as Record<string, ESObject>;
        let left = params['left'] as number ?? 0;
        let top = params['top'] as number ?? 0;
        let down = params['down'] as boolean ?? false;
        if (down) {
          //如果flutter端判断当前platformView是可点击的，则将事件分发出去
          let touchEvent: CustomTouchEvent = TouchEventProcessor.getInstance().constructCustomTouchEvent(strings, top, left);
          let nodeController = params['nodeController'] as EmbeddingNodeController;
          nodeController.postEvent(touchEvent);
          this.rememberPostedTouchEvent(params, touchEvent);
        } else {
          //如果触摸事件为OH_NATIVEXCOMPONENT_DOWN=0，且只有一个手指，说明是下一次点击了，这时候需要清空上一次的数据
          if (strings[6] == '0' && strings[0] == '1') {
            params['touchEvent'] = undefined
            params[PLATFORM_VIEW_CANCEL_DRAINING] = false;
          }
          //如果触摸事件为OH_NATIVEXCOMPONENT_DOWN=0类型，且在flutter端还没判断当前view是否处于点击区域内，则
          //将点击事件存储在list列表中。
          let touchEvent: CustomTouchEvent = TouchEventProcessor.getInstance().constructCustomTouchEvent(strings, top, left);
          const cancelDraining = params[PLATFORM_VIEW_CANCEL_DRAINING] as boolean ?? false;
          if (cancelDraining && touchEvent.type !== TouchType.Down) {
            continue;
          }
          let array: Array<CustomTouchEvent> | undefined = params['touchEvent'] as Array<CustomTouchEvent>
          if (array == undefined) {
            array = []
            params['touchEvent'] = array
          }
          array.push(touchEvent)
        }
      }
    });
  }

  private decodeMousePacket(strings: Array<string>, densityPixels: number, top: number, left: number): MousePacket {
    let offset: number = 0;
    let x: number = vp2px((parseInt(strings[offset++])) / densityPixels - left);
    let y: number = vp2px((parseInt(strings[offset++])) / densityPixels - top);
    let screenX: number = vp2px(parseFloat(strings[offset++]) / densityPixels);
    let screenY: number = vp2px(parseFloat(strings[offset++]) / densityPixels);
    let timestamp: number = parseFloat(strings[offset++]);
    let action: number = parseFloat(strings[offset++]);
    let button: number = parseFloat(strings[offset++]);

    const mouseEventPacket: MousePacket = new MousePacket(
      offset,
      x,
      y,
      screenX,
      screenY,
      timestamp,
      action,
      button
    );
    return mouseEventPacket;
  }

  private constructMouseEventImpl(mousePacket: MousePacket): MouseEvent {
    // 构造MouseEvent数据
    const mouseEvent: MouseEvent = {
      button: mousePacket.button,
      action: mousePacket.action,
      displayX: mousePacket.x,
      displayY: mousePacket.y,
      windowX: mousePacket.x,
      windowY: mousePacket.y,
      screenX: mousePacket.screenX,
      screenY: mousePacket.screenY,
      x: mousePacket.x,
      y: mousePacket.y,
      stopPropagation: () => {},
      timestamp: mousePacket.timestamp,
      pressure: 0,
      tiltX: mousePacket.x,
      tiltY: mousePacket.y,
    } as MouseEvent;

    return mouseEvent;
  }

  /** Construct the MouseEvent and return. */
  public constructMouseEvent(strings: Array<string>, top: number, left: number): MouseEvent {
    let densityPixels: number = display.getDefaultDisplaySync().densityPixels;

    let mousePacket: MousePacket = this.decodeMousePacket(strings, densityPixels, top, left);
    let mouseEvent: MouseEvent = this.constructMouseEventImpl(mousePacket);
    return mouseEvent;
  }

  // 鼠标坐标通过postInputEvent传入到节点
  /**
   * Posts a mouse event to platform views.
   * @param strings - Array of string values representing mouse event data
   */
  public postMouseEvent(strings: Array<string>) {
    FlutterManager.getInstance().getFlutterViewList().forEach((value) => {
      if (!value.getActive()) {
        return
      }
      let length = value.getDVModel().children.length
      for (let index = length - 1; index >= 0; index--) {
        const dvModel = value.getDVModel().children[index]
        const params = dvModel.getLayoutParams() as Record<string, ESObject>;
        const left = params['left'] as number ?? 0;
        const top = params['top'] as number ?? 0;
        let down = params['down'] as boolean ?? false;
        let mouseEvent: MouseEvent = TouchEventProcessor.getInstance().constructMouseEvent(strings, top, left);

        if (mouseEvent.action != MouseAction.Press && mouseEvent.action != MouseAction.Release && params["hover"]) {
          // 如果鼠标事件不是OH_NATIVEXCOMPONENT_MOUSE_PRESS类型或OH_NATIVEXCOMPONENT_MOUSE_RELEASE类型，则
          // 直接分发出去
          let nodeController = params['nodeController'] as EmbeddingNodeController;
          nodeController.postMouseEvent(mouseEvent)
        } else if (down) {
          // 如果flutter端判断当前platformView是可点击的，则将事件分发出去,并结束分发
          let nodeController = params['nodeController'] as EmbeddingNodeController;
          nodeController.postMouseEvent(mouseEvent)
          break;
        } else {
          // 如果鼠标事件为OH_NATIVEXCOMPONENT_MOUSE_PRESS，说明是下一次点击了，这时候需要清空上一次的数据
          if (strings[5] == '1') {
            params['mouseEvent'] = undefined
          }
          // 如果鼠标事件为OH_NATIVEXCOMPONENT_MOUSE_PRESS类型，且在flutter端还没判断当前view是否处于点击区域内，则将点击事件存储在list列表中。
          let array: Array<MouseEvent> | undefined = params['mouseEvent'] as Array<MouseEvent>
          if (array == undefined) {
            array = []
            params['mouseEvent'] = array
          }
          array.push(mouseEvent)
        }
      }
    });
  }

  public checkHitPlatformView(left: number, top: number, width: number, height: number, x: number, y: number): boolean {
    if (x >= left && x <= (left + width) && y >= top && y <= (top + height)) {
      return true;
    } else {
      return false;
    }
  }
}
