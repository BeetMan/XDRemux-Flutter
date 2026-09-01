/*
 * Copyright 2013 The Flutter Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
*/

import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import UIAbility from '@ohos.app.ability.UIAbility';
import ExclusiveAppComponent from '../../../ohos/ExclusiveAppComponent';

/**
 * Interface for controlling ability-related operations in Flutter engines.
 * This interface provides methods to attach/detach from abilities and handle ability lifecycle events.
 */
export default interface ActivityControlSurface {
  /**
   * Attaches this surface to an exclusive app component (UIAbility).
   * @param exclusiveActivity - The exclusive app component to attach to
   */
  attachToAbility(exclusiveActivity: ExclusiveAppComponent<UIAbility>): void;

  /**
   * Detaches this surface from the current ability.
   */
  detachFromAbility(): void;

  /**
   * Handles a new Want event from the ability.
   * @param want - The Want object containing the intent
   * @param launchParams - The launch parameters
   */
  onNewWant(want: Want, launchParams: AbilityConstant.LaunchParam): void;

  /**
   * Handles window focus change events from the ability.
   * @param hasFocus - Whether the window has focus
   */
  onWindowFocusChanged(hasFocus: boolean): void;

  /**
   * Handles save state requests from the ability.
   * @param reason - The reason for saving state
   * @param wantParam - Parameters to save
   * @returns The result of the save state operation
   */
  onSaveState(reason: AbilityConstant.StateType, wantParam: Record<string, Object>): AbilityConstant.OnSaveResult;
}