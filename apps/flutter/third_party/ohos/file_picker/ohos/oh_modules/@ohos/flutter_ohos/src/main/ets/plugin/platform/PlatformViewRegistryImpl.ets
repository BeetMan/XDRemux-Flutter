/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on PlatformViewRegistryImpl.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import HashMap from '@ohos.util.HashMap';
import PlatformViewFactory from './PlatformViewFactory'
import PlatformViewRegistry from './PlatformViewRegistry'

/**
 * Implementation of PlatformViewRegistry for managing platform view factories.
 */
export default class PlatformViewRegistryImpl implements PlatformViewRegistry {
  /** Maps a platform view type id to its factory. */
  private viewFactories: HashMap<String, PlatformViewFactory>;

  /**
   * Constructs a new PlatformViewRegistryImpl instance.
   */
  constructor() {
    this.viewFactories = new HashMap();
  }

  /**
   * Registers a factory for a platform view.
   * @param viewTypeId - Unique identifier for the platform view's type
   * @param factory - Factory for creating platform views of the specified type
   * @returns True if succeeded, false if a factory is already registered for viewTypeId
   */
  registerViewFactory(viewTypeId: string, factory: PlatformViewFactory): boolean {
    if (this.viewFactories.hasKey(viewTypeId)) {
      return false;
    }

    this.viewFactories.set(viewTypeId, factory);
    return true;
  }

  /**
   * Gets the factory for a specific view type.
   * @param viewTypeId - The view type ID
   * @returns The PlatformViewFactory for the view type, or undefined if not found
   */
  getFactory(viewTypeId: string): PlatformViewFactory {
    return this.viewFactories.get(viewTypeId);
  }
}
