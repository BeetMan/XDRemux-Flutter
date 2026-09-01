/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import {
  DVModel,
  DVModelChildren,
  DVModelContainer,
  DVModelEvents,
  DVModelParameters
} from '../../view/DynamicView/dynamicView';
import Log from '../../util/Log';

/**
 * Manager for the root DynamicView model container.
 * This class provides a singleton root container for all platform views.
 */
export class RootDvModeManager {
  private static model: DVModel =
    new DVModel("Stack", new DVModelParameters(), new DVModelEvents(), new DVModelChildren(), null);
  private static container: DVModelContainer = new DVModelContainer(RootDvModeManager.model);

  /**
   * Gets the root DynamicView model container.
   * @returns The root DVModelContainer instance
   */
  public static getRootDvMode(): DVModelContainer {
    return RootDvModeManager.container;
  }

  /**
   * Adds a DynamicView model to the root container.
   * @param model - The DVModel to add
   */
  public static addDvModel(model: DVModel): void {
    RootDvModeManager.container.model.children.push(model);
    Log.i("flutter RootDvModeManager", 'DVModel: %{public}s',
      JSON.stringify(RootDvModeManager.container.model.children) ?? '');
  }
}
