/*
 * Copyright 2013 The Flutter Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
*/

import { AbilityPluginBinding } from './AbilityPluginBinding';

/**
 * FlutterPlugin that is interested in UIAbility lifecycle events related to a FlutterEngine
 * running within the given UIAbility.
 */
export default interface AbilityAware {
  /**
   * This AbilityAware FlutterPlugin is now associated with a UIAbility.
   *
   * This method can be invoked in 1 of 2 situations:
   *
   * This AbilityAware FlutterPlugin was just added to a FlutterEngine that was already
   * connected to a running UIAbility.
   * This AbilityAware FlutterPlugin was already added to a FlutterEngine and that
   * FlutterEngine was just connected to a UIAbility.
   *
   * The given AbilityPluginBinding contains UIAbility-related references that an AbilityAware
   * FlutterPlugin may require, such as a reference to the actual UIAbility in question.
   * The AbilityPluginBinding may be referenced until either onDetachedFromAbilityForConfigChanges
   * or onDetachedFromAbility is invoked. At the conclusion of either of those methods, the
   * binding is no longer valid. Clear any references to the binding or its resources, and do not
   * invoke any further methods on the binding or its resources.
   * @param binding - The AbilityPluginBinding providing access to UIAbility resources
   */
  onAttachedToAbility(binding: AbilityPluginBinding): void;

  /**
   * This plugin has been detached from a UIAbility.
   *
   * Detachment can occur for a number of reasons:
   *
   * The app is no longer visible and the UIAbility instance has been destroyed.
   * The FlutterEngine that this plugin is connected to has been detached from its FlutterView.
   * This AbilityAware plugin has been removed from its FlutterEngine.
   *
   * By the end of this method, the UIAbility that was made available in
   * onAttachedToAbility is no longer valid. Any references to the
   * associated UIAbility or AbilityPluginBinding should be cleared.
   *
   * Any Lifecycle listeners that were registered in onAttachedToAbility or
   * onReattachedToAbilityForConfigChanges should be deregistered here to
   * avoid a possible memory leak and other side effects.
   */
  onDetachedFromAbility(): void;
}
