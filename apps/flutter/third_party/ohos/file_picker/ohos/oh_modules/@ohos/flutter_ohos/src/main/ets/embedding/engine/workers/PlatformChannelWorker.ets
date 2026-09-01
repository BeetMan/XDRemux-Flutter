/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';

import Log from '../../../util/Log';
import SendableBinaryMessageHandler from '../../../plugin/common/SendableBinaryMessageHandler';
import { TaskState } from '../dart/DartMessenger';


const TAG: string = 'PlatformChannelWorker';
const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

/**
 * Defines the event handler to be called when the worker thread receives a message sent by the host thread.
 * The event handler is executed in the worker thread.
 *
 * @param e - The message event data
 */
workerPort.onmessage = async (e: MessageEvents) => {
  let data: TaskState = e.data;
  let result: ArrayBuffer | null = await handleMessage(data.handler, data.message, data.args);
  workerPort.postMessage(result, [result]);
}

/**
 * Defines the event handler to be called when the worker receives a message that cannot be deserialized.
 * The event handler is executed in the worker thread.
 *
 * @param e - The message event data
 */
workerPort.onmessageerror = (e: MessageEvents) => {
  Log.e(TAG, '#onmessageerror = ' + e.data);
}

/**
 * Defines the event handler to be called when an exception occurs during worker execution.
 * The event handler is executed in the worker thread.
 *
 * @param e - The error event
 */
workerPort.onerror = (e: ErrorEvent) => {
  Log.e(TAG, '#onerror = ' + e.message);
}

/**
 * Handles a message in the worker thread.
 * @param handler - The message handler to execute
 * @param message - The message data as an ArrayBuffer
 * @param args - Additional arguments to pass to the handler
 * @returns A promise that resolves to the reply ArrayBuffer, or null if no reply
 */
async function handleMessage(handler: SendableBinaryMessageHandler,
                             message: ArrayBuffer,
                             args: Object[]): Promise<ArrayBuffer | null> {
  const result = await new Promise<ArrayBuffer | null>((resolve, reject) => {
    try {
      handler.onMessage(message, {
        reply: (reply: ArrayBuffer | null): void => {
          resolve(reply);
        }
      }, ...args);
    } catch (e) {
      reject(null);
      Log.e(TAG, "Oops! Failed to handle message in the background: ", e);
    }
  });
  return result;
}