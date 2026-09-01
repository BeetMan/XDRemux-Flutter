/*
* Copyright (c) 2026 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import window from '@ohos.window';
import Log from '../../util/Log';

const TAG = "PiPVisibilityBridge";
const POLL_INTERVAL_MS = 120;
const START_GRACE_MS = 2000;

type PiPVisibilityListener = (visible: boolean) => void;

/**
 * Process-global PiP visibility bridge.
 *
 * `window.getGlobalWindowMode()` is a process-level API whose result is
 * identical regardless of which UIAbility calls it, so a single polling
 * timer and a single `pipVisible` flag are sufficient.
 *
 * Multiple UIAbilities are handled via a `shownCount` reference counter:
 * polling only runs when *all* abilities are hidden (shownCount == 0).
 */
export default class PiPVisibilityBridge {
  private static instance: PiPVisibilityBridge;

  static getInstance(): PiPVisibilityBridge {
    if (PiPVisibilityBridge.instance == null) {
      PiPVisibilityBridge.instance = new PiPVisibilityBridge();
    }
    return PiPVisibilityBridge.instance;
  }

  private listeners = new Set<PiPVisibilityListener>();
  private shownCount = 0;
  private pipVisible = false;
  private lastHiddenAt = 0;
  private pollTimerId?: number;
  private refreshInFlight = false;

  register(listener: PiPVisibilityListener): void {
    this.listeners.add(listener);
    listener(this.pipVisible);
  }

  unregister(listener: PiPVisibilityListener): void {
    this.listeners.delete(listener);
    if (this.listeners.size == 0) {
      this.stopPolling();
    }
  }

  updateAbilityShown(shown: boolean): void {
    if (shown) {
      this.shownCount++;
      if (this.shownCount == 1) {
        this.lastHiddenAt = 0;
        this.stopPolling();
        this.updateVisibility(false);
      }
      return;
    }

    this.shownCount = Math.max(0, this.shownCount - 1);
    if (this.shownCount == 0) {
      this.lastHiddenAt = Date.now();
      this.stopPolling();
      this.refreshVisibility();
    }
  }

  private scheduleNextPoll(): void {
    if (this.pollTimerId != null || this.shownCount > 0 || this.pipVisible ||
        !this.isWithinGraceWindow()) {
      return;
    }
    this.pollTimerId = setTimeout((): void => {
      this.pollTimerId = undefined;
      this.refreshVisibility();
    }, POLL_INTERVAL_MS) as number;
  }

  private stopPolling(): void {
    if (this.pollTimerId == null) {
      return;
    }
    clearTimeout(this.pollTimerId);
    this.pollTimerId = undefined;
  }

  private refreshVisibility(): void {
    if (this.refreshInFlight) {
      this.scheduleNextPoll();
      return;
    }
    this.refreshInFlight = true;
    this.queryPipMode().then((visible: boolean) => {
      this.updateVisibility(this.shownCount == 0 && visible);
    }).catch((error: Object) => {
      Log.w(TAG, "queryPipMode error: " + JSON.stringify(error));
    }).finally(() => {
      this.refreshInFlight = false;
      if (this.shouldStopPolling()) {
        this.stopPolling();
      } else {
        this.scheduleNextPoll();
      }
    });
  }

  private async queryPipMode(): Promise<boolean> {
    if (this.shownCount > 0) {
      return false;
    }

    try {
      const mode = await window.getGlobalWindowMode();
      return (mode & window.GlobalWindowMode.PIP) !== 0;
    } catch (error) {
      Log.w(TAG, "getGlobalWindowMode failed: " + JSON.stringify(error));
      return false;
    }
  }

  private isWithinGraceWindow(): boolean {
    return this.lastHiddenAt > 0 && (Date.now() - this.lastHiddenAt) <= START_GRACE_MS;
  }

  private shouldStopPolling(): boolean {
    return this.shownCount > 0 || this.pipVisible || !this.isWithinGraceWindow();
  }

  private updateVisibility(visible: boolean): void {
    if (this.pipVisible === visible) {
      return;
    }

    this.pipVisible = visible;
    const snapshot = Array.from(this.listeners);
    snapshot.forEach((listener: PiPVisibilityListener): void => {
      listener(visible);
    });
  }
}
