/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on DartMessenger.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import { ErrorEvent, Queue, taskpool, worker, MessageEvents, JSON } from '@kit.ArkTS';

import Log from '../../../util/Log';
import {
  BinaryMessageHandler,
  BinaryMessenger,
  BinaryReply,
  TaskPriority,
  TaskQueue,
  TaskQueueOptions
} from '../../../plugin/common/BinaryMessenger';
import FlutterNapi from '../FlutterNapi';
import { PlatformMessageHandler } from './PlatformMessageHandler';
import { TraceSection } from '../../../util/TraceSection';
import SendableBinaryMessageHandler from '../../../plugin/common/SendableBinaryMessageHandler'

/**
 * Message conduit for 2-way communication between OpenHarmony and Dart.
 *
 * See {@link BinaryMessenger}, which sends messages from OpenHarmony to Dart
 *
 * See {@link PlatformMessageHandler}, which handles messages to OpenHarmony from Dart
 */

const TAG = "DartMessenger";

export class DartMessenger implements BinaryMessenger, PlatformMessageHandler {
  /** The FlutterNapi instance for native communication. */
  flutterNapi: FlutterNapi;
  /** Map of channel names to their message handlers. */
  messageHandlers: Map<String, HandlerInfo> = new Map();
  /** Map of reply IDs to their callback functions waiting for responses. */
  pendingReplies: Map<number, BinaryReply> = new Map();
  /** The next reply ID to use for message callbacks. */
  nextReplyId: number = 1;
  /** Factory for creating task queues for background message processing. */
  taskQueueFactory: TaskQueueFactory;
  /** Map of TaskQueue tokens to their actual task queue implementations. */
  createdTaskQueues: Map<TaskQueue, DartMessengerTaskQueue> = new Map();

  /**
   * Constructs a new DartMessenger instance.
   * @param flutterNapi - The FlutterNapi instance for native communication
   */
  constructor(flutterNapi: FlutterNapi) {
    this.flutterNapi = flutterNapi;
    this.taskQueueFactory = new DefaultTaskQueueFactory();
  }

  /**
   * Creates a background task queue for handling messages asynchronously.
   * @param options - Optional task queue configuration options
   * @returns A TaskQueue instance for background message processing
   */
  makeBackgroundTaskQueue(options?: TaskQueueOptions): TaskQueue {
    let taskQueue: DartMessengerTaskQueue =
      this.taskQueueFactory.makeBackgroundTaskQueue(options ?? new TaskQueueOptions());
    let token: TaskQueueToken = new TaskQueueToken();
    this.createdTaskQueues.set(token, taskQueue);
    return token;
  }

  /**
   * Sets a message handler for incoming messages from Dart on the specified channel.
   * @param channel - The channel name to listen on
   * @param handler - The message handler, or null to remove the handler
   * @param taskQueue - Optional task queue for processing messages
   * @param args - Additional arguments to pass to the handler
   */
  setMessageHandler(channel: String, handler: BinaryMessageHandler | SendableBinaryMessageHandler | null,
    taskQueue?: TaskQueue, ...args: Object[]): void {
    if (handler == null) {
      Log.d(TAG, "Removing handler for channel '" + channel + "'");
      this.messageHandlers.delete(channel);
      return;
    }
    let dartMessengerTaskQueue: DartMessengerTaskQueue | null = null;
    if (taskQueue !== null && taskQueue !== undefined) {
      dartMessengerTaskQueue = this.createdTaskQueues.get(taskQueue) ?? null;
      if (dartMessengerTaskQueue == null) {
        throw new Error(
          "Unrecognized TaskQueue, use BinaryMessenger to create your TaskQueue (ex makeBackgroundTaskQueue)."
        );
      }
    }
    Log.d(TAG, "Setting handler for channel '" + channel + "'");

    this.messageHandlers.set(channel, new HandlerInfo(handler, dartMessengerTaskQueue, ...args));
  }

  /**
   * Sends a binary message to Dart over the specified channel.
   * @param channel - The channel name for the message
   * @param message - The message data as an ArrayBuffer, or null for an empty message
   * @param callback - Optional callback to receive the reply from Dart
   */
  send(channel: String, message: ArrayBuffer | null, callback?: BinaryReply): void {
    Log.d(TAG, "Sending message over channel '" + channel + "'");
    let traceId: number = TraceSection.begin("DartMessenger#send on " + channel);
    try {
      Log.d(TAG, "Sending message with callback over channel '" + channel + "'");
      let replyId: number = this.nextReplyId++;
      if (callback != null) {
        this.pendingReplies.set(replyId, callback);
      }
      if (message == null) {
        this.flutterNapi.dispatchEmptyPlatformMessage(channel, replyId);
      } else {
        this.flutterNapi.dispatchPlatformMessage(channel, message, message.byteLength, replyId);
      }
    } finally {
      TraceSection.endWithId("DartMessenger#send on " + channel, traceId);
    }
    this.IsFlutterNavigationExecuted(channel);
  }

  /**
   * Dispatches a message to a task queue for asynchronous processing.
   * @param handlerInfo - The handler information containing the handler and task queue
   * @param message - The message data as an ArrayBuffer
   * @param replyId - The reply ID for responding to the message
   */
  dispatchMessageToQueue(handlerInfo: HandlerInfo, message: ArrayBuffer, replyId: number): void {
    let taskState: TaskState = new TaskState(handlerInfo.handler as ESObject, message, ...handlerInfo.args);
    handlerInfo.taskQueue?.dispatch(taskState, new Reply(this.flutterNapi, replyId));
  }

  /**
   * Invokes a message handler synchronously.
   * @param handler - The message handler to invoke, or null if no handler is registered
   * @param message - The message data as an ArrayBuffer
   * @param replyId - The reply ID for responding to the message
   */
  invokeHandler(handler: BinaryMessageHandler | null, message: ArrayBuffer, replyId: number): void {
    if (handler != null) {
      try {
        Log.d(TAG, "Deferring to registered handler to process message.");
        handler.onMessage(message, new Reply(this.flutterNapi, replyId));
      } catch (ex) {
        Log.e(TAG, "Uncaught exception in binary message listener", ex);
        this.flutterNapi.invokePlatformMessageEmptyResponseCallback(replyId);
      }
    } else {
      Log.d(TAG, "No registered handler for message. Responding to Dart with empty reply message.");
      this.flutterNapi.invokePlatformMessageEmptyResponseCallback(replyId);
    }
  }

  /**
   * Handles a message received from Dart over a specific channel.
   * @param channel - The channel name for the message
   * @param message - The message data as an ArrayBuffer
   * @param replyId - The reply ID for responding to the message
   * @param messageData - Additional message data
   */
  handleMessageFromDart(channel: String, message: ArrayBuffer, replyId: number, messageData: number): void {
    Log.d(TAG, "Received message from Dart over channel '" + channel + "'");
    let handlerInfo: HandlerInfo | null = this.messageHandlers.get(channel) ?? null;
    if (handlerInfo?.taskQueue != null) {
      this.dispatchMessageToQueue(handlerInfo, message, replyId);
    } else {
      this.invokeHandler(handlerInfo?.handler as BinaryMessageHandler, message, replyId);
    }
    this.IsFlutterNavigationExecuted(channel);
  }

  /**
   * Handles a platform message response from Dart.
   * @param replyId - The reply ID that was sent with the original message
   * @param reply - The reply data as an ArrayBuffer
   */
  handlePlatformMessageResponse(replyId: number, reply: ArrayBuffer): void {
    Log.d(TAG, "Received message reply from Dart.");
    let callback: BinaryReply | null = this.pendingReplies.get(replyId) ?? null;
    this.pendingReplies.delete(replyId);
    if (callback != null) {
      try {
        Log.d(TAG, "Invoking registered callback for reply from Dart.");
        callback.reply(reply);
      } catch (e) {
        Log.e(TAG, "Uncaught exception in binary message reply handler", e);
      }
    }
  }

  /**
   * Returns the number of pending channel callback replies.
   *
   * When sending messages to the Flutter application using BinaryMessenger.send,
   * developers can optionally specify a reply callback if they expect a reply from the Flutter application.
   *
   * This method tracks all the pending callbacks that are waiting for response, and is supposed
   * to be called from the main thread (as other methods). Calling from a different thread could
   * possibly capture an indeterministic internal state, so don't do it.
   * @returns The number of pending channel callback replies
   */
  getPendingChannelResponseCount(): number {
    return this.pendingReplies.size;
  }

  /**
   * Checks if the current Flutter page is performing navigation and notifies the native side.
   * @param channel - The channel name to check
   */
  IsFlutterNavigationExecuted(channel: String): void {
    if (channel == "flutter/navigation") {
      this.flutterNapi.setFlutterNavigationAction(this.flutterNapi.nativeShellHolderId!, true);
      Log.d(TAG, "setFlutterNavigationAction -> '" + channel + "'");
    }
  }
}

/**
 * Holds information about a platform handler, such as the task queue that processes messages from
 * Dart.
 */
class HandlerInfo {
  handler: BinaryMessageHandler | SendableBinaryMessageHandler;
  taskQueue: DartMessengerTaskQueue | null;
  args: Object[];

  /**
   * Constructs a new HandlerInfo instance.
   * @param handler - The message handler
   * @param taskQueue - The task queue for processing messages, or null for synchronous processing
   * @param args - Additional arguments to pass to the handler
   */
  constructor(handler: BinaryMessageHandler | SendableBinaryMessageHandler,
    taskQueue: DartMessengerTaskQueue | null,
    ...args: Object[]) {
    this.handler = handler;
    this.taskQueue = taskQueue;
    this.args = args;
  }
}

/**
 * Implementation of BinaryReply that sends replies back to Dart.
 */
class Reply implements BinaryReply {
  flutterNapi: FlutterNapi;
  replyId: number;
  done: boolean = false;

  /**
   * Constructs a new Reply instance.
   * @param flutterNapi - The FlutterNapi instance for sending replies
   * @param replyId - The reply ID for this reply
   */
  constructor(flutterNapi: FlutterNapi, replyId: number) {
    this.flutterNapi = flutterNapi;
    this.replyId = replyId;
  }

  /**
   * Sends a reply back to Dart.
   * @param reply - The reply data as an ArrayBuffer, or null for an empty reply
   * @throws Error if reply has already been submitted
   */
  reply(reply: ArrayBuffer | null) {
    if (this.done) {
      throw new Error("Reply already submitted");
    }

    if (reply == null) {
      this.flutterNapi.invokePlatformMessageEmptyResponseCallback(this.replyId);
    } else {
      this.flutterNapi.invokePlatformMessageResponseCallback(this.replyId, reply, reply.byteLength);
    }
  }
}

/**
 * Represents the state of a task to be executed in a background task queue.
 */
export class TaskState {
  /** The message handler to execute. */
  handler: SendableBinaryMessageHandler;
  /** The message data as an ArrayBuffer. */
  message: ArrayBuffer;
  /** Additional arguments to pass to the handler. */
  args: Object[];

  /**
   * Constructs a new TaskState instance.
   * @param handler - The message handler to execute
   * @param message - The message data as an ArrayBuffer
   * @param args - Additional arguments to pass to the handler
   */
  constructor(handler: SendableBinaryMessageHandler, message: ArrayBuffer, ...args: Object[]) {
    this.handler = handler;
    this.message = message;
    this.args = args;
  }
}

/**
 * Interface for task queues that process messages asynchronously.
 */
interface DartMessengerTaskQueue {
  /**
   * Dispatches a task to be executed in the task queue.
   * @param taskState - The task state containing the handler and message
   * @param callback - The reply callback for sending responses
   */
  dispatch(taskState: TaskState, callback: Reply): void;
}

/**
 * Interface for serial task queues that process messages sequentially.
 */
interface SerialTaskQueue extends DartMessengerTaskQueue {
}

/**
 * Factory interface for creating task queues.
 */
interface TaskQueueFactory {
  /**
   * Creates a background task queue with the specified options.
   * @param options - Task queue configuration options
   * @returns A DartMessengerTaskQueue instance
   */
  makeBackgroundTaskQueue(options: TaskQueueOptions): DartMessengerTaskQueue;
}

/**
 * Task queue that processes messages concurrently.
 */
class ConcurrentTaskQueue implements DartMessengerTaskQueue {
  private priority: TaskPriority;

  /**
   * Constructs a new ConcurrentTaskQueue instance.
   * @param priority - The priority level for task execution
   */
  constructor(priority: TaskPriority) {
    this.priority = priority;
  }

  /**
   * Dispatches a task to be executed concurrently.
   * @param taskState - The task state containing the handler and message
   * @param callback - The reply callback for sending responses
   */
  dispatch(taskState: TaskState, callback: Reply): void {
    let task: taskpool.Task = new taskpool.Task(handleMessageInBackground,
                                                taskState.handler,
                                                taskState.message,
                                                ...taskState.args);
    taskpool.execute(task, this.priority as number).then((result: Object) => {
      callback.reply(result as ArrayBuffer);
    }).catch((err: string) => {
      callback.reply(null);
      Log.e(TAG, "Oops! Failed to execute task: ", err);
    });
  }
}

const scriptURL: string = '../workers/PlatformChannelWorker.ets';
/**
 * Task queue that processes messages serially using a worker thread.
 */
class SerialTaskQueueWithWorker implements SerialTaskQueue {
  private static workerInstance: worker.ThreadWorker | null = null;

  /**
   * Constructs a new SerialTaskQueueWithWorker instance.
   * Creates a singleton worker instance if one doesn't exist.
   */
  constructor () {
    if (!SerialTaskQueueWithWorker.workerInstance) {
      SerialTaskQueueWithWorker.workerInstance =
        new worker.ThreadWorker(scriptURL, {name: 'PlatformChannelWorker'});
    }
  }

  /**
   * Dispatches a task to be executed serially in the worker thread.
   * @param taskState - The task state containing the handler and message
   * @param callback - The reply callback for sending responses
   */
  dispatch(taskState: TaskState, callback: Reply): void {
    SerialTaskQueueWithWorker.workerInstance!.onmessage = (e: MessageEvents): void => {
      callback.reply(e.data as ArrayBuffer);
    }

    SerialTaskQueueWithWorker.workerInstance!.onerror = (err: ErrorEvent) => {
      callback.reply(null);
      Log.e(TAG, "Oops! Failed to execute task in worker thread: ", err.message);
    }

    SerialTaskQueueWithWorker.workerInstance!.postMessageWithSharedSendable(taskState, [taskState.message]);
  }
}

type Runnable = () => Promise<void>;
/**
 * Task queue that processes messages serially using a task pool.
 */
class SerialTaskQueueWithTaskPool implements SerialTaskQueue {
  private priority: TaskPriority;
  private queue: Queue<Runnable> = new Queue();
  private isRunning: boolean = false;

  /**
   * Constructs a new SerialTaskQueueWithTaskPool instance.
   * @param priority - The priority level for task execution
   */
  constructor(priority: TaskPriority) {
    this.priority = priority;
  }

  /**
   * Dispatches a task to be executed serially in the task pool.
   * @param taskState - The task state containing the handler and message
   * @param callback - The reply callback for sending responses
   */
  dispatch(taskState: TaskState, callback: Reply): void {
    let task: taskpool.Task = new taskpool.Task(handleMessageInBackground,
                                                taskState.handler,
                                                taskState.message,
                                                ...taskState.args);
    const runnable: Runnable = async () => {
      try {
        const result = await taskpool.execute(task, this.priority as number);
        callback.reply(result as ArrayBuffer);
      } catch (err) {
        callback.reply(null);
        Log.e(TAG, "Oops! Failed to execute task: ", err);
      }
    };

    this.queue.add(runnable);

    if (!this.isRunning) {
      this.runNext();
    }
  }

  private async runNext(): Promise<void> {
    if (this.queue.length > 0) {
      this.isRunning = true;
      const task = this.queue.pop();
      try {
        await task();
      } finally {
        this.isRunning = false;
        this.runNext(); // 执行下一个任务
      }
    }
  }
}

/**
 * Default implementation of TaskQueueFactory.
 */
class DefaultTaskQueueFactory implements TaskQueueFactory {
  /**
   * Creates a background task queue based on the provided options.
   * @param options - Task queue configuration options
   * @returns A DartMessengerTaskQueue instance (serial or concurrent)
   */
  makeBackgroundTaskQueue(options: TaskQueueOptions): DartMessengerTaskQueue {
    if (options.isSingleThreadMode()) {
      return new SerialTaskQueueWithWorker();
    } else {
      if (options.getIsSerial()) {
        return new SerialTaskQueueWithTaskPool(options.getPriority());
      }
      return new ConcurrentTaskQueue(options.getPriority());
    }
  }
}

/**
 * Token implementation of TaskQueue used to identify task queues.
 */
class TaskQueueToken implements TaskQueue {
}

/**
 * Handles a message in the background thread.
 * This function is executed concurrently and processes messages asynchronously.
 * @param handler - The message handler to execute
 * @param message - The message data as an ArrayBuffer
 * @param args - Additional arguments to pass to the handler
 * @returns A promise that resolves to the reply ArrayBuffer, or null if no reply
 */
@Concurrent
async function handleMessageInBackground(handler: SendableBinaryMessageHandler,
  message: ArrayBuffer,
  ...args: Object[]): Promise<ArrayBuffer | null> {
  const result = await new Promise<ArrayBuffer | null>((resolve, reject) => {
    try {
      handler.onMessage(message, {
        reply: (reply: ArrayBuffer | null): void => {
          resolve(reply);
        }
      }, ...args);
    } catch (e) {
      reject(null);
      Log.e('WARNING', "Oops! Failed to handle message in the background: ", e);
    }
  });
  return result;
}
