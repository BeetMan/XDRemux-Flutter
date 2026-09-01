/*
 * Copyright 2013 The Flutter Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
*/

import UIAbility from '@ohos.app.ability.UIAbility'
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';

/**
 * Binding that provides plugins with access to UIAbility-related resources.
 * This interface allows plugins to access the ability and register for ability lifecycle events.
 */
export interface AbilityPluginBinding {
  /**
   * Gets the UIAbility instance.
   * @returns The UIAbility instance
   */
  getAbility(): UIAbility;

  /**
   * Adds a listener that is invoked whenever the associated UIAbility's onNewWant method is invoked.
   * @param listener - The NewWantListener to add
   */
  addOnNewWantListener(listener: NewWantListener): void;

  /**
   * Removes a listener that was added in addOnNewWantListener.
   * @param listener - The NewWantListener to remove
   */
  removeOnNewWantListener(listener: NewWantListener): void;

  /**
   * Adds a listener that is invoked whenever the associated UIAbility's windowStageEvent method is invoked.
   * @param listener - The WindowFocusChangedListener to add
   */
  addOnWindowFocusChangedListener(listener: WindowFocusChangedListener): void;

  /**
   * Removes a listener that was added in addOnWindowFocusChangedListener.
   * @param listener - The WindowFocusChangedListener to remove
   */
  removeOnWindowFocusChangedListener(listener: WindowFocusChangedListener): void;

  /**
   * Adds a listener that is invoked when the associated UIAbility saves and restores instance state.
   * @param listener - The OnSaveStateListener to add
   */
  addOnSaveStateListener(listener: OnSaveStateListener): void;

  /**
   * Removes a listener that was added in addOnSaveStateListener.
   * @param listener - The OnSaveStateListener to remove
   */
  removeOnSaveStateListener(listener: OnSaveStateListener): void;
}

/**
 * Delegate interface for handling new wants on behalf of the main UIAbility.
 */
export interface NewWantListener {
  /**
   * Called when a new want is started for the UIAbility.
   * @param want - The new want that was started for the UIAbility
   * @param launchParams - The launch parameters
   */
  onNewWant(want: Want, launchParams: AbilityConstant.LaunchParam): void;
}

/**
 * Delegate interface for handling window focus changes on behalf of the main UIAbility.
 */
export interface WindowFocusChangedListener {
  /**
   * Called when the window focus changes.
   * @param hasFocus - Whether the window has focus
   */
  onWindowFocusChanged(hasFocus: boolean): void;
}

/**
 * Delegate interface for handling save state events.
 */
export interface OnSaveStateListener {
  /**
   * Invoked when the associated UIAbility saves and restores instance state.
   * @param reason - The reason for saving state
   * @param wantParam - Parameters to save
   * @returns The result of the save state operation
   */
  onSaveState(reason: AbilityConstant.StateType, wantParam: Record<string, Object>): AbilityConstant.OnSaveResult;
}