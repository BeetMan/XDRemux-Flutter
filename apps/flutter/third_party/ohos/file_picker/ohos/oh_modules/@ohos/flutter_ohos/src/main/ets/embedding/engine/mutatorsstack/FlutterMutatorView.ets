/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterMutatorView.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import ArrayList from '@ohos.util.ArrayList';
import matrix4 from '@ohos.matrix4';
import { DVModel, DVModelEvents, DVModelParameters } from '../../../view/DynamicView/dynamicView';
import { createDVModelFromJson } from '../../../view/DynamicView/dynamicViewJson';
import OhosTouchProcessor from '../../ohos/OhosTouchProcessor';
import { FlutterMutator, FlutterMutatorsStack } from './FlutterMutatorsStack'
import Any from '../../../plugin/common/Any';

/**
 * View that applies Flutter mutators (transforms, clips) to a dynamic view model.
 * This class manages the layout and mutator application for platform views.
 */
export class FlutterMutatorView {
  private mutatorsStack: FlutterMutatorsStack | null = null;
  private screenDensity: number = 0;
  private left: number = 0;
  private top: number = 0;
  private prevLeft: number = 0;
  private prevTop: number = 0;
  private onTouch = (touchEvent: Any) => {
    let params = this.model.params as Record<string, number>;
    switch (touchEvent.type) {
      case TouchType.Down:
        this.prevLeft = this.left;
        this.prevTop = this.top;
        params.translateX = this.left;
        params.translateY = this.top;
        break;
      case TouchType.Move:
        params.translateX = this.prevLeft;
        params.translateY = this.prevTop;
        this.prevLeft = this.left;
        this.prevTop = this.top;
        break;
      case TouchType.Up:
      case TouchType.Cancel:
      default:
        break;
    }
  }
  private model: DVModel = createDVModelFromJson(
    new DVModelParam("Column", [], { backgroundColor: Color.Red }, { onTouch: this.onTouch })
  );

  /**
   * Sets listeners for descendant focus change events.
   * @param onFocus - Callback invoked when a descendant gains focus
   * @param onBlur - Callback invoked when a descendant loses focus
   */
  setOnDescendantFocusChangeListener(onFocus: () => void, onBlur: () => void) {
    // this.model.events["onFocus"] = onFocus;
    // this.model.events["onBlur"] = onBlur;
    let events2 = this.model.events as Record<string, DVModelEvents>;
    events2.onFocus = onFocus;
    events2.onBlur = onBlur;
  }

  /**
   * Sets the layout parameters for this view.
   * @param parameters - The layout parameters including margin, width, and height
   */
  public setLayoutParams(parameters: DVModelParameters): void {
    if (this.model.params == null) {
      this.model.params = new DVModelParameters();
    }
    let params = this.model.params as Record<string, string | number | Array<string | number> | matrix4.Matrix4Transit>;
    let parametersRecord =
      parameters as Record<string, string | number | Array<string | number> | matrix4.Matrix4Transit>;
    params.marginLeft = parametersRecord['marginLeft'];
    params.marginTop = parametersRecord['marginTop'];
    params.width = parametersRecord['width'];
    params.height = parametersRecord['height'];
    this.left = parametersRecord.marginLeft as number;
    this.top = parametersRecord.marginTop as number;
  }

  /**
   * Adds a child dynamic view model to this view.
   * @param model - The DVModel to add as a child
   */
  public addDvModel(model: DVModel): void {
    this.model?.children.push(model);
  }

  /**
   * Prepares this view for display by applying mutators and setting layout parameters.
   * @param mutatorsStack - The stack of mutators to apply
   * @param left - The left position of the view
   * @param top - The top position of the view
   * @param width - The width of the view
   * @param height - The height of the view
   */
  public readyToDisplay(mutatorsStack: FlutterMutatorsStack, left: number, top: number, width: number, height: number) {
    this.mutatorsStack = mutatorsStack;
    this.left = left;
    this.top = top;
    let parameters =
      new DVModelParameters() as Record<string, string | number | Array<string | number> | matrix4.Matrix4Transit>;
    parameters['marginLeft'] = left;
    parameters['marginTop'] = top;
    parameters['width'] = width;
    parameters['height'] = height;
    this.setLayoutParams(parameters);
    this.dealMutators();
  }

  private dealMutators() {
    if (this.mutatorsStack == null) {
      return;
    }
    let paths = this.mutatorsStack.getFinalClippingPaths();
    let rects = this.mutatorsStack.getFinalClippingRects();
    let matrix = this.mutatorsStack.getFinalMatrix();
    let params = this.model.params as Record<string, string | number | Array<string | number> | matrix4.Matrix4Transit>;
    if (!paths.isEmpty()) {
      let path = paths.getLast();
      params.pathWidth = path.width;
      params.pathHeight = path.height;
      params.pathCommands = path.commands;
    }
    if (!rects.isEmpty()) {
      let rect = rects.getLast();
      params.rectWidth = rect.width;
      params.rectHeight = rect.height;
      params.rectRadius = rect.radius;
    }
    params.matrix = matrix;
  }

  /**
   * Gets the dynamic view model for this view.
   * @returns The DVModel instance, or undefined if not set
   */
  public getDvModel(): DVModel | undefined {
    return this.model;
  }
}

/**
 * Parameters for creating a dynamic view model.
 */
class DVModelParam {
  compType: string
  children: []
  attributes: Any
  events: Any

  /**
   * Constructs a new DVModelParam instance.
   * @param compType - The component type
   * @param children - Array of child components
   * @param attributes - Component attributes
   * @param events - Component event handlers
   */
  constructor(compType: string, children: [], attributes: Any, events: Any) {
    this.compType = compType;
    this.children = children;
    this.attributes = attributes;
    this.events = events;
  }
}