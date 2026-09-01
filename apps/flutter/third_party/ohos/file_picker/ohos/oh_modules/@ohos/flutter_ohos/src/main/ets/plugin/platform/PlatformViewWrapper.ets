/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import OhosTouchProcessor from '../../embedding/ohos/OhosTouchProcessor';
import { DVModel, DVModelParameters } from '../../view/DynamicView/dynamicView';
import { createDVModelFromJson } from '../../view/DynamicView/dynamicViewJson';
import { RootDvModeManager } from './RootDvModelManager';
import matrix4 from '@ohos.matrix4'
import Log from '../../util/Log';
import Any from '../common/Any';

const TAG: string = "PlatformViewWrapper";

/**
 * Wraps a platform view to intercept gestures and project this view onto a rendering target.
 *
 * An OpenHarmony platform view is composed by the engine using a TextureLayer. The view is embedded
 * in the OpenHarmony view hierarchy like a normal DynamicView, but it's projected onto a rendering
 * target, so it can be efficiently composed by the engine.
 *
 * Since the view is in the OpenHarmony view hierarchy, keyboard and accessibility interactions
 * behave normally.
 */
export class PlatformViewWrapper {
  private prevLeft: number = 0;
  private prevTop: number = 0;
  private left: number = 0;
  private top: number = 0;
  private bufferWidth: number = 0;
  private bufferHeight: number = 0;
  private touchProcessor: OhosTouchProcessor | null = null;
  private model: DVModel | undefined;

  /**
   * Sets the touch processor for handling touch events.
   * @param newTouchProcessor - The OhosTouchProcessor instance
   */
  public setTouchProcessor(newTouchProcessor: OhosTouchProcessor): void {
    this.touchProcessor = newTouchProcessor;
  }

  /**
   * Constructs a new PlatformViewWrapper instance.
   */
  constructor() {
  }

  /**
   * Gets the DynamicView model associated with this wrapper.
   * @returns The DVModel instance
   */
  public getDvModel(): DVModel {
    return this.model!;
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
   * @param element - The parameter key
   * @returns The parameter value, or undefined if not found
   */
  getParams: (params: DVModelParameters, element: string) => string | Any =
    (params: DVModelParameters, element: string): string | Any => {
      let params2 = params as Record<string, Any>;
      return params2[element];
    }

  /**
   * Sets the layout parameters for the platform view.
   * @param parameters - The layout parameters to apply
   */
  public setLayoutParams(parameters: DVModelParameters): void {
    if (!this.model) {
      return;
    }
    if (this.model.params == null) {
      this.model.params = new DVModelParameters();
    }
    this.setParams(this.model.params, "marginLeft", this.getParams(parameters, "marginLeft"));
    this.setParams(this.model.params, "marginTop", this.getParams(parameters, "marginTop"));
    this.left = this.getParams(parameters, "marginLeft");
    this.top = this.getParams(parameters, "marginTop");

    this.setParams(this.model.params, "width", this.getParams(parameters, "width"));
    this.setParams(this.model.params, "height", this.getParams(parameters, "height"));
  }

  /**
   * Adds a DynamicView model to this wrapper.
   * @param model - The DVModel to add
   */
  public addDvModel(model: DVModel): void {
    this.model = model
  }
}

/**
 * Parameters for DynamicView model creation.
 * This class holds the basic structure for creating a DynamicView model.
 */
class DVModelParam {
  /** The component type */
  compType: string
  /** Array of child components */
  children: []

  /**
   * Constructs a new DVModelParam instance.
   * @param compType - The component type
   * @param children - Array of child components
   */
  constructor(compType: string, children: []) {
    this.compType = compType;
    this.children = children;
  }
}