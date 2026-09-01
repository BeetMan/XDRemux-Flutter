/*
 * Copyright (c) 2021-2024 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */
import Any from '../../plugin/common/Any';

import { DVModel, DVModelParameters, DVModelEvents, DVModelChildren } from "./dynamicView";
import Log from '../../util/Log';
const TAG = "dynamicViewJson";

/**
 * Creates a DVModel instance from a JSON object.
 * This function recursively parses the JSON structure to build a complete DVModel tree.
 * @param json - The JSON object representing the view structure
 * @returns A DVModel instance created from the JSON
 */
export function createDVModelFromJson(json: Object): DVModel {

  /**
   * Helper function to create children from a JSON array.
   * @param children - Array of child JSON objects
   * @returns A DVModelChildren instance containing parsed child models
   * @private
   */
  let createChildrenFrom: (children: Array<Object>) => DVModelChildren = (children: Array<Object>): DVModelChildren => {
    let result = new DVModelChildren();
    if (Array.isArray(children)) {
      (children as Array<Object>).forEach(child => {
        const childView = createDVModelFromJson(child);
        if (childView != undefined) {
          result.push(childView);
        }
      });
    }
    return result;
  }

  /**
   * Helper function to set a parameter or event value.
   * @param result - The parameters or events object to modify
   * @param key - The key to set
   * @param element - The source object containing the value
   * @private
   */
  let setParams: (result: DVModelParameters | DVModelEvents, key: Any, element: Object) => void =
    (result: DVModelParameters, key: Any, element: Any): void => {
      let newResult = result as Record<string, Any>;
      newResult[key] = element[key];
    }

  /**
   * Helper function to create parameters from a JSON attributes object.
   * @param attributes - The attributes JSON object
   * @returns A DVModelParameters instance
   * @private
   */
  let createAttributesFrom: (attributes: Object) => DVModelParameters = (attributes: Object): DVModelParameters => {
    let result = new DVModelParameters();
    if ((typeof attributes == "object") && (!Array.isArray(attributes))) {
      Object.keys(attributes).forEach(k => {
        setParams(result, k, attributes)
      });
    }
    return result;
  }

  /**
   * Helper function to create events from a JSON events object.
   * @param events - The events JSON object
   * @returns A DVModelEvents instance
   * @private
   */
  let createEventsFrom: (events: Object) => DVModelEvents = (events: Object): DVModelEvents => {
    let result = new DVModelEvents();
    if ((typeof events == "object") && (!Array.isArray(events))) {
      Object.keys(events).forEach(k => {
        setParams(result, k, events)
      });
    }
    return result;
  }

  if (typeof json !== 'object') {
    Log.e(TAG, "createDVModelFromJson: input is not JSON");
    return new DVModel("", "", "", createChildrenFrom([]));
  }

  let jsonObject = json as Record<string, string | Any>;
  return new DVModel(
    jsonObject["compType"],
    createAttributesFrom(jsonObject["attributes"]),
    createEventsFrom(jsonObject["events"]),
    createChildrenFrom(jsonObject["children"]),
    jsonObject["build"]
  );
}
