/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import FlutterEngineGroup from './FlutterEngineGroup';

/**
 * Static singleton cache that holds FlutterEngineGroup instances identified by Strings.
 *
 * The ID of a given FlutterEngineGroup can be whatever String is desired.
 *
 * FlutterEngineGroupCache is useful for storing pre-warmed FlutterEngineGroup instances. FlutterAbility
 * and FlutterEntry can use cached FlutterEngineGroup instances by implementing getCachedEngineGroupId()
 * to return a cached engine group ID. The FlutterAbilityAndEntryDelegate will then retrieve the
 * engine group from this cache and create new engines within that group. See FlutterAbility.getCachedEngineGroupId()
 * and FlutterEntry.getCachedEngineGroupId() for related APIs.
 */
export default class FlutterEngineGroupCache {
  static readonly instance = new FlutterEngineGroupCache();
  private cachedEngineGroups = new Map<String, FlutterEngineGroup>();

  /**
   * Checks if an engine group with the given ID exists in the cache.
   * @param engineGroupId - The ID of the engine group to check
   * @returns true if the engine group exists, false otherwise
   */
  contains(engineGroupId: string): boolean {
    return this.cachedEngineGroups.has(engineGroupId);
  }

  /**
   * Gets an engine group from the cache by ID.
   * @param engineGroupId - The ID of the engine group to retrieve
   * @returns The FlutterEngineGroup instance, or null if not found
   */
  get(engineGroupId: string): FlutterEngineGroup | null {
    return this.cachedEngineGroups.get(engineGroupId) ?? null;
  }

  /**
   * Puts an engine group into the cache or removes it if null is provided.
   * @param engineGroupId - The ID of the engine group
   * @param engineGroup - The FlutterEngineGroup instance to cache, or undefined to remove
   */
  put(engineGroupId: string, engineGroup?: FlutterEngineGroup) {
    if (engineGroup != null) {
      this.cachedEngineGroups.set(engineGroupId, engineGroup);
    } else {
      this.cachedEngineGroups.delete(engineGroupId);
    }
  }

  /**
   * Clears all engine groups from the cache.
   */
  clear(): void {
    this.cachedEngineGroups.clear();
  }
}