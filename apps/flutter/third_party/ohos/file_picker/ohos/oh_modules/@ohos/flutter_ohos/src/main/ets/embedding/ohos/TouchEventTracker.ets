/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/
/** Tracks the motion events received by the FlutterView. */
import PlainArray from '@ohos.util.PlainArray';
import { TouchEvent } from '@ohos.multimodalInput.touchEvent';
import Queue from '@ohos.util.Queue';

/**
 * Tracks touch events and provides unique identifiers for them.
 * This class maintains a singleton instance for managing touch event tracking.
 */
export class TouchEventTracker {
  private eventById: PlainArray<TouchEvent>;
  private unusedEvents: Queue<number>;
  private static INSTANCE: TouchEventTracker;

  /**
   * Gets the singleton instance of TouchEventTracker.
   * @returns The singleton TouchEventTracker instance
   */
  public static getInstance(): TouchEventTracker {
    if (TouchEventTracker.INSTANCE == null) {
      TouchEventTracker.INSTANCE = new TouchEventTracker();
    }
    return TouchEventTracker.INSTANCE;
  }

  /**
   * Constructs a new TouchEventTracker instance.
   */
  constructor() {
    this.eventById = new PlainArray();
    this.unusedEvents = new Queue();
  }

  /**
   * Tracks the event and returns a unique TouchEventId identifying the event.
   * @param event - The touch event to track
   * @returns A unique TouchEventId for the event
   */
  public track(event: TouchEvent): TouchEventId {
    const eventId: TouchEventId = TouchEventId.createUnique();
    this.eventById.add(eventId.getId(), event);
    this.unusedEvents.add(eventId.getId());
    return eventId;
  }

  /**
   * Returns the TouchEvent corresponding to the eventId while discarding all the motion events
   * that occurred prior to the event represented by the eventId.
   * @param eventId - The TouchEventId to retrieve
   * @returns The TouchEvent corresponding to the eventId
   */
  public pop(eventId: TouchEventId): TouchEvent {
    // remove all the older events.
    while (this.unusedEvents.length != 0 && this.unusedEvents.getFirst() < eventId.getId()) {
      this.eventById.remove(this.unusedEvents.pop());
    }

    // remove the current event from the heap if it exists.
    if (this.unusedEvents.length != 0 && this.unusedEvents.getFirst() == eventId.getId()) {
      this.unusedEvents.pop();
    }

    const event: TouchEvent = this.eventById.get(eventId.getId());
    this.eventById.remove(eventId.getId());
    return event;
  }
}

/**
 * Represents a unique identifier corresponding to a touch event.
 */
export class TouchEventId {
  private static ID_COUNTER: number = 0;
  private id: number;

  /**
   * Constructs a new TouchEventId instance.
   * @param id - The ID value
   */
  constructor(id: number) {
    this.id = id;
  }

  /**
   * Creates a TouchEventId from a given ID.
   * @param id - The ID value
   * @returns A new TouchEventId instance
   */
  public static from(id: number): TouchEventId {
    return new TouchEventId(id);
  }

  /**
   * Creates a unique TouchEventId with an auto-incremented ID.
   * @returns A new unique TouchEventId instance
   */
  public static createUnique(): TouchEventId {
    return new TouchEventId(TouchEventId.ID_COUNTER++);
  }

  /**
   * Gets the ID value.
   * @returns The ID value
   */
  public getId(): number {
    return this.id;
  }
}