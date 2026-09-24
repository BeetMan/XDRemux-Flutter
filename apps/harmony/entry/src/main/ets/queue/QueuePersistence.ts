import type {
  NativeClassificationResult,
  NativeConversionResult,
  NativePhotoDetails,
  NativeProgress
} from './NativeTypes';
import type {
  QueueAttemptStatus,
  QueueItem,
  QueueItemStatus,
  QueueResult
} from './QueueController';

export const QUEUE_SCHEMA_VERSION: number = 1;
export const QUEUE_FILE_NAME: string = 'queue.json';
export const QUEUE_TEMP_SUFFIX: string = '.tmp';

const MAX_SAFE_INTEGER: number = 9007199254740991;
const MAX_U64: bigint = 18446744073709551615n;

export type QueueCleanupStatus = 'none' | 'pending' | 'failed';
export type QueuePathStatus = 'file' | 'empty' | 'missing' | 'unsafe';

export interface QueuePersistenceSnapshot {
  nextId: number;
  items: Array<QueueItem>;
}

export interface PersistedClassification {
  modeKey: string | null;
  folderName: string | null;
  status: string | null;
  rawUserComment: string | null;
  hasTagFlags: boolean;
  tagFlags: string;
  unknownFlags: string;
  hdrKind: string | null;
  family: string | null;
}

export interface PersistedConversion {
  success: boolean;
  mode: string | null;
  family: string | null;
  edrScale: number;
  gainMapMax: number;
  errorMessage: string | null;
}

export interface PersistedResult {
  outputPath: string;
  modeKey: string;
  modeLabel: string;
  sourceInputPath?: string;
  conversion: PersistedConversion;
}

export interface PersistedQueueItem {
  id: string;
  displayName: string;
  sourceUri: string;
  sourceKind?: 'share';
  sourceToken?: string;
  inputPath: string;
  status: QueueItemStatus;
  attemptStatus: QueueAttemptStatus;
  externalBusy: boolean;
  details?: NativePhotoDetails;
  classification?: PersistedClassification;
  progress: NativeProgress;
  result?: PersistedResult;
  exportedUri: string;
  errorMessage: string;
  lastAttemptModeKey: string;
  lastAttemptModeLabel: string;
  cleanupStatus: QueueCleanupStatus;
  cleanupErrorMessage: string;
  ownedPaths: Array<string>;
}

export interface PersistedQueueRecord {
  schema: number;
  nextId: number;
  items: Array<PersistedQueueItem>;
}

export interface QueueDecodeResult {
  snapshot?: QueuePersistenceSnapshot;
  warning: string;
  corrupt: boolean;
}

export interface QueueRestoreResult {
  snapshot: QueuePersistenceSnapshot;
  warnings: Array<string>;
}

export interface QueuePathProbe {
  status(path: string): QueuePathStatus;
}

export interface QueueStorageAdapter {
  exists(path: string): Promise<boolean>;
  readText(path: string): Promise<string>;
  writeAtomic(path: string, content: string): Promise<void>;
  rename(oldPath: string, newPath: string): Promise<void>;
}

export interface QueueStoreLoadResult {
  snapshot?: QueuePersistenceSnapshot;
  warning: string;
  corrupt: boolean;
  tempPresent: boolean;
}

export class QueuePersistenceError extends Error {
  public readonly cause: Object | undefined;

  constructor(message: string, cause?: Object) {
    super(message);
    this.name = 'QueuePersistenceError';
    this.cause = cause;
  }
}

function isRecord(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isFiniteNumber(value: Object | undefined): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

function isNonNegativeInteger(value: Object | undefined): value is number {
  return isFiniteNumber(value) && Math.floor(value) === value && value >= 0 && value <= MAX_SAFE_INTEGER;
}

function requiredString(value: Object | undefined, field: string, allowEmpty: boolean = false): string {
  if (typeof value !== 'string' || (!allowEmpty && value.length === 0)) {
    throw new Error(field + ' 必须是非空字符串');
  }
  return value;
}

function nullableString(value: Object | undefined, field: string): string | null {
  if (value === null) {
    return null;
  }
  return requiredString(value, field, true);
}

function requiredBoolean(value: Object | undefined, field: string): boolean {
  if (typeof value !== 'boolean') {
    throw new Error(field + ' 必须是布尔值');
  }
  return value;
}

function requiredNumber(value: Object | undefined, field: string): number {
  if (!isFiniteNumber(value)) {
    throw new Error(field + ' 必须是有限数字');
  }
  return value;
}

function requiredCounter(value: Object | undefined, field: string): number {
  if (!isNonNegativeInteger(value)) {
    throw new Error(field + ' 必须是非负整数');
  }
  return value;
}

function encodeU64(value: bigint, field: string): string {
  if (typeof value !== 'bigint' || value < 0n || value > MAX_U64) {
    throw new Error(field + ' 超出 u64 范围');
  }
  return value.toString(10);
}

function decodeU64(value: Object | undefined, field: string): bigint {
  const encoded: string = requiredString(value, field);
  if (!/^(0|[1-9][0-9]*)$/.test(encoded)) {
    throw new Error(field + ' 不是安全的十进制字符串');
  }
  try {
    const decoded: bigint = BigInt(encoded);
    if (decoded < 0n || decoded > MAX_U64) {
      throw new Error(field + ' 超出 u64 范围');
    }
    return decoded;
  } catch (error) {
    throw new Error(field + ' 解析失败');
  }
}

function cloneDetails(details: NativePhotoDetails): NativePhotoDetails {
  const copy: NativePhotoDetails = { success: details.success };
  if (details.errorMessage !== undefined) copy.errorMessage = details.errorMessage;
  if (details.make !== undefined) copy.make = details.make;
  if (details.model !== undefined) copy.model = details.model;
  if (details.dateTime !== undefined) copy.dateTime = details.dateTime;
  if (details.exposureTime !== undefined) copy.exposureTime = details.exposureTime;
  if (details.fNumber !== undefined) copy.fNumber = details.fNumber;
  if (details.iso !== undefined) copy.iso = details.iso;
  if (details.focalLength !== undefined) copy.focalLength = details.focalLength;
  if (details.focalLength35mm !== undefined) copy.focalLength35mm = details.focalLength35mm;
  if (details.exposureBias !== undefined) copy.exposureBias = details.exposureBias;
  if (details.width !== undefined) copy.width = details.width;
  if (details.height !== undefined) copy.height = details.height;
  if (details.hdrKind !== undefined) copy.hdrKind = details.hdrKind;
  if (details.edrScale !== undefined) copy.edrScale = details.edrScale;
  if (details.gainMapMax !== undefined) copy.gainMapMax = details.gainMapMax;
  return copy;
}

function encodeClassification(classification: NativeClassificationResult): PersistedClassification {
  return {
    modeKey: classification.modeKey,
    folderName: classification.folderName,
    status: classification.status,
    rawUserComment: classification.rawUserComment,
    hasTagFlags: classification.hasTagFlags,
    tagFlags: encodeU64(classification.tagFlags, 'tagFlags'),
    unknownFlags: encodeU64(classification.unknownFlags, 'unknownFlags'),
    hdrKind: classification.hdrKind,
    family: classification.family
  };
}

function decodeDetails(value: Object | undefined): NativePhotoDetails {
  if (!isRecord(value)) {
    throw new Error('details 必须是对象');
  }
  const raw = value as { success?: Object; errorMessage?: Object; make?: Object; model?: Object; dateTime?: Object;
    exposureTime?: Object; fNumber?: Object; iso?: Object; focalLength?: Object; focalLength35mm?: Object;
    exposureBias?: Object; width?: Object; height?: Object; hdrKind?: Object; edrScale?: Object; gainMapMax?: Object };
  const details: NativePhotoDetails = { success: requiredBoolean(raw.success, 'details.success') };
  if (raw.errorMessage !== undefined) details.errorMessage = requiredString(raw.errorMessage, 'details.errorMessage', true);
  if (raw.make !== undefined) details.make = requiredString(raw.make, 'details.make', true);
  if (raw.model !== undefined) details.model = requiredString(raw.model, 'details.model', true);
  if (raw.dateTime !== undefined) details.dateTime = requiredString(raw.dateTime, 'details.dateTime', true);
  if (raw.exposureTime !== undefined) details.exposureTime = requiredString(raw.exposureTime, 'details.exposureTime', true);
  if (raw.fNumber !== undefined) details.fNumber = requiredString(raw.fNumber, 'details.fNumber', true);
  if (raw.iso !== undefined) details.iso = requiredString(raw.iso, 'details.iso', true);
  if (raw.focalLength !== undefined) details.focalLength = requiredString(raw.focalLength, 'details.focalLength', true);
  if (raw.focalLength35mm !== undefined) details.focalLength35mm = requiredString(raw.focalLength35mm, 'details.focalLength35mm', true);
  if (raw.exposureBias !== undefined) details.exposureBias = requiredString(raw.exposureBias, 'details.exposureBias', true);
  if (raw.hdrKind !== undefined) details.hdrKind = requiredString(raw.hdrKind, 'details.hdrKind', true);
  if (raw.width !== undefined) details.width = requiredNumber(raw.width, 'details.width');
  if (raw.height !== undefined) details.height = requiredNumber(raw.height, 'details.height');
  if (raw.edrScale !== undefined) details.edrScale = requiredNumber(raw.edrScale, 'details.edrScale');
  if (raw.gainMapMax !== undefined) details.gainMapMax = requiredNumber(raw.gainMapMax, 'details.gainMapMax');
  return details;
}

function decodeClassification(value: Object | undefined): NativeClassificationResult {
  if (!isRecord(value)) throw new Error('classification 必须是对象');
  const raw = value as { modeKey?: Object; folderName?: Object; status?: Object; rawUserComment?: Object;
    hasTagFlags?: Object; tagFlags?: Object; unknownFlags?: Object; hdrKind?: Object; family?: Object };
  return {
    modeKey: nullableString(raw.modeKey, 'classification.modeKey'),
    folderName: nullableString(raw.folderName, 'classification.folderName'),
    status: nullableString(raw.status, 'classification.status'),
    rawUserComment: nullableString(raw.rawUserComment, 'classification.rawUserComment'),
    hasTagFlags: requiredBoolean(raw.hasTagFlags, 'classification.hasTagFlags'),
    tagFlags: decodeU64(raw.tagFlags, 'classification.tagFlags'),
    unknownFlags: decodeU64(raw.unknownFlags, 'classification.unknownFlags'),
    hdrKind: nullableString(raw.hdrKind, 'classification.hdrKind'),
    family: nullableString(raw.family, 'classification.family')
  };
}

function encodeConversion(conversion: NativeConversionResult): PersistedConversion {
  if (conversion.success !== true) {
    throw new Error('result.conversion.success 必须为 true');
  }
  if (!isFiniteNumber(conversion.edrScale) || !isFiniteNumber(conversion.gainMapMax)) {
    throw new Error('result.conversion 数值无效');
  }
  return {
    success: true,
    mode: conversion.mode,
    family: conversion.family,
    edrScale: conversion.edrScale,
    gainMapMax: conversion.gainMapMax,
    errorMessage: conversion.errorMessage
  };
}

function decodeConversion(value: Object | undefined): NativeConversionResult {
  if (!isRecord(value)) throw new Error('result.conversion 必须是对象');
  const raw = value as { success?: Object; mode?: Object; family?: Object; edrScale?: Object; gainMapMax?: Object;
    errorMessage?: Object };
  const success: boolean = requiredBoolean(raw.success, 'result.conversion.success');
  if (!success) {
    throw new Error('result.conversion.success 必须为 true');
  }
  return {
    success: true,
    mode: nullableString(raw.mode, 'result.conversion.mode'),
    family: nullableString(raw.family, 'result.conversion.family'),
    edrScale: requiredNumber(raw.edrScale, 'result.conversion.edrScale'),
    gainMapMax: requiredNumber(raw.gainMapMax, 'result.conversion.gainMapMax'),
    errorMessage: nullableString(raw.errorMessage, 'result.conversion.errorMessage')
  };
}

function encodeResult(result: QueueResult): PersistedResult {
  if (result.modeKey !== 'oppo' && result.modeKey !== 'apple') {
    throw new Error('result.modeKey 无效');
  }
  if (result.outputPath.length === 0 || result.outputPath.endsWith('.tmp') ||
    result.outputPath.includes('.apple-features-base-')) {
    throw new Error('result.outputPath 不能是临时输出路径');
  }
  const encoded: PersistedResult = {
    outputPath: result.outputPath,
    modeKey: result.modeKey,
    modeLabel: result.modeLabel,
    conversion: encodeConversion(result.conversion)
  };
  if (result.sourceInputPath !== undefined) {
    if (result.sourceInputPath.length === 0 || result.sourceInputPath.includes('\u0000')) {
      throw new Error('result.sourceInputPath 无效');
    }
    encoded.sourceInputPath = result.sourceInputPath;
  }
  return encoded;
}

function decodeResult(value: Object | undefined): QueueResult {
  if (!isRecord(value)) throw new Error('result 必须是对象');
  const raw = value as { outputPath?: Object; modeKey?: Object; modeLabel?: Object; sourceInputPath?: Object;
    conversion?: Object };
  const outputPath: string = requiredString(raw.outputPath, 'result.outputPath');
  const modeKey: string = requiredString(raw.modeKey, 'result.modeKey');
  if (modeKey !== 'oppo' && modeKey !== 'apple') {
    throw new Error('result.modeKey 无效');
  }
  if (outputPath.endsWith('.tmp') || outputPath.includes('.apple-features-base-')) {
    throw new Error('result.outputPath 不能是临时输出路径');
  }
  const decoded: QueueResult = {
    outputPath: outputPath,
    modeKey: modeKey,
    modeLabel: requiredString(raw.modeLabel, 'result.modeLabel', true),
    conversion: decodeConversion(raw.conversion)
  };
  if (raw.sourceInputPath !== undefined) {
    decoded.sourceInputPath = requiredString(raw.sourceInputPath, 'result.sourceInputPath');
  }
  return decoded;
}

function statusValue(value: Object | undefined, field: string): QueueItemStatus {
  if (value !== 'pending' && value !== 'running' && value !== 'succeeded' && value !== 'failed') {
    throw new Error(field + ' 无效');
  }
  return value as QueueItemStatus;
}

function attemptStatusValue(value: Object | undefined): QueueAttemptStatus {
  if (value !== 'idle' && value !== 'pending' && value !== 'running' && value !== 'succeeded' && value !== 'failed') {
    throw new Error('attemptStatus 无效');
  }
  return value as QueueAttemptStatus;
}

function cleanupStatusValue(value: Object | undefined): QueueCleanupStatus {
  if (value !== 'none' && value !== 'pending' && value !== 'failed') {
    throw new Error('cleanupStatus 无效');
  }
  return value as QueueCleanupStatus;
}

function encodeItem(item: QueueItem): PersistedQueueItem {
  const idMatch: RegExpMatchArray | null = item.id.match(/^job-[1-9][0-9]*$/);
  if (idMatch === null) throw new Error('任务 ID 无效');
  if (item.sourceUri.length === 0) throw new Error('任务 sourceUri 为空');
  const ownedPaths: Array<string> = item.ownedPaths.slice();
  const pathSet: Set<string> = new Set<string>();
  for (const path of ownedPaths) {
    if (path.length === 0 || path.includes('\u0000')) throw new Error('任务归属路径无效');
    if (pathSet.has(path)) throw new Error('任务归属路径重复');
    pathSet.add(path);
  }
  if (item.inputPath.length > 0 && !pathSet.has(item.inputPath)) {
    throw new Error('输入路径不在任务归属列表');
  }
  if (item.result !== undefined) {
    if (!pathSet.has(item.result.outputPath)) {
      throw new Error('结果路径不在任务归属列表');
    }
    if (item.inputPath.length > 0 && item.result.outputPath === item.inputPath) {
      throw new Error('结果路径不能与输入路径相同');
    }
    if (item.result.sourceInputPath !== undefined && !pathSet.has(item.result.sourceInputPath)) {
      throw new Error('结果来源路径不在任务归属列表');
    }
  }
  const encoded: PersistedQueueItem = {
    id: item.id,
    displayName: item.displayName,
    sourceUri: item.sourceUri,
    inputPath: item.inputPath,
    status: item.status,
    attemptStatus: item.attemptStatus,
    externalBusy: item.externalBusy,
    progress: {
      stage: item.progress.stage,
      current: item.progress.current,
      total: item.progress.total
    },
    exportedUri: item.exportedUri,
    errorMessage: item.errorMessage,
    lastAttemptModeKey: item.lastAttemptModeKey,
    lastAttemptModeLabel: item.lastAttemptModeLabel,
    cleanupStatus: item.cleanupStatus,
    cleanupErrorMessage: item.cleanupErrorMessage,
    ownedPaths: ownedPaths
  };
  if (item.sourceKind === 'share') encoded.sourceKind = 'share';
  if (item.sourceToken !== undefined) {
    if (item.sourceKind !== 'share' || !/^share-[1-9][0-9]*$/.test(item.sourceToken)) {
      throw new Error('sourceToken 无效');
    }
    encoded.sourceToken = item.sourceToken;
  }
  if (item.details !== undefined) encoded.details = cloneDetails(item.details);
  if (item.classification !== undefined) encoded.classification = encodeClassification(item.classification);
  if (item.result !== undefined) encoded.result = encodeResult(item.result);
  return encoded;
}

function decodeItem(value: Object | undefined, index: number): QueueItem {
  if (!isRecord(value)) throw new Error('items[' + String(index) + '] 必须是对象');
  const raw = value as { id?: Object; displayName?: Object; sourceUri?: Object; sourceKind?: Object;
    sourceToken?: Object;
    inputPath?: Object; status?: Object;
    attemptStatus?: Object; externalBusy?: Object; details?: Object; classification?: Object; progress?: Object;
    result?: Object; exportedUri?: Object; errorMessage?: Object; lastAttemptModeKey?: Object;
    lastAttemptModeLabel?: Object; cleanupStatus?: Object; cleanupErrorMessage?: Object; ownedPaths?: Object };
  const id: string = requiredString(raw.id, 'items[' + String(index) + '].id');
  if (!/^job-[1-9][0-9]*$/.test(id)) throw new Error('任务 ID 无效');
  const pathsValue: Object | undefined = raw.ownedPaths;
  if (!Array.isArray(pathsValue)) throw new Error('ownedPaths 必须是数组');
  const ownedPaths: Array<string> = [];
  const ownSet: Set<string> = new Set<string>();
  for (const pathValue of pathsValue as Array<Object>) {
    const path: string = requiredString(pathValue, 'ownedPaths 路径');
    if (path.includes('\u0000') || ownSet.has(path)) throw new Error('ownedPaths 存在重复或非法路径');
    ownSet.add(path);
    ownedPaths.push(path);
  }
  const inputPath: string = requiredString(raw.inputPath, 'inputPath', true);
  if (raw.sourceKind !== undefined && raw.sourceKind !== 'share') throw new Error('sourceKind 无效');
  if (raw.sourceToken !== undefined && (raw.sourceKind !== 'share' || typeof raw.sourceToken !== 'string' ||
    !/^share-[1-9][0-9]*$/.test(raw.sourceToken))) throw new Error('sourceToken 无效');
  if (inputPath.length > 0 && !ownSet.has(inputPath)) throw new Error('输入路径不在 ownedPaths');
  const progressValue: Object | undefined = raw.progress;
  if (!isRecord(progressValue)) throw new Error('progress 必须是对象');
  const progressRaw = progressValue as { stage?: Object; current?: Object; total?: Object };
  const result: QueueResult | undefined = raw.result === undefined ? undefined : decodeResult(raw.result);
  if (result !== undefined) {
    if (!ownSet.has(result.outputPath)) throw new Error('结果路径不在 ownedPaths');
    if (inputPath.length > 0 && result.outputPath === inputPath) {
      throw new Error('结果路径不能与输入路径相同');
    }
    if (result.sourceInputPath !== undefined && !ownSet.has(result.sourceInputPath)) {
      throw new Error('结果来源路径不在 ownedPaths');
    }
  }
  const item: QueueItem = {
    id: id,
    revision: 0,
    displayName: requiredString(raw.displayName, 'displayName', true),
    sourceUri: requiredString(raw.sourceUri, 'sourceUri'),
    sourceKind: raw.sourceKind === 'share' ? 'share' : undefined,
    sourceToken: raw.sourceToken as string | undefined,
    inputPath: inputPath,
    status: statusValue(raw.status, 'status'),
    attemptStatus: attemptStatusValue(raw.attemptStatus),
    externalBusy: requiredBoolean(raw.externalBusy, 'externalBusy'),
    details: raw.details === undefined ? undefined : decodeDetails(raw.details),
    classification: raw.classification === undefined ? undefined : decodeClassification(raw.classification),
    progress: {
      stage: requiredCounter(progressRaw.stage, 'progress.stage'),
      current: requiredCounter(progressRaw.current, 'progress.current'),
      total: requiredCounter(progressRaw.total, 'progress.total')
    },
    result: result,
    exportedUri: requiredString(raw.exportedUri, 'exportedUri', true),
    errorMessage: requiredString(raw.errorMessage, 'errorMessage', true),
    lastAttemptModeKey: requiredString(raw.lastAttemptModeKey, 'lastAttemptModeKey', true),
    lastAttemptModeLabel: requiredString(raw.lastAttemptModeLabel, 'lastAttemptModeLabel', true),
    cleanupStatus: cleanupStatusValue(raw.cleanupStatus),
    cleanupErrorMessage: requiredString(raw.cleanupErrorMessage, 'cleanupErrorMessage', true),
    ownedPaths: ownedPaths
  };
  return item;
}

function invalidQueue(warning: string): QueueDecodeResult {
  return { warning: '队列记录无效（' + warning + '），原文件未覆盖；请使用安全恢复入口备份后新建队列。', corrupt: true };
}

export function emptyQueueSnapshot(): QueuePersistenceSnapshot {
  return { nextId: 1, items: [] };
}

export function serializeQueueSnapshot(snapshot: QueuePersistenceSnapshot): string {
  if (!isNonNegativeInteger(snapshot.nextId) || snapshot.nextId < 1) {
    throw new QueuePersistenceError('队列 nextId 无效');
  }
  const ids: Set<string> = new Set<string>();
  const paths: Set<string> = new Set<string>();
  let highestId: number = 0;
  const items: Array<PersistedQueueItem> = [];
  try {
    for (const item of snapshot.items) {
      if (ids.has(item.id)) throw new Error('队列存在重复任务 ID');
      ids.add(item.id);
      const match: RegExpMatchArray | null = item.id.match(/^job-([1-9][0-9]*)$/);
      if (match === null) throw new Error('队列任务 ID 无效');
      const numericId: number = Number(match[1]);
      if (!Number.isSafeInteger(numericId)) throw new Error('队列任务 ID 超出安全范围');
      highestId = Math.max(highestId, numericId);
      const encoded: PersistedQueueItem = encodeItem(item);
      for (const path of encoded.ownedPaths) {
        if (paths.has(path)) throw new Error('ownedPaths 跨任务重复');
        paths.add(path);
      }
      items.push(encoded);
    }
    if (snapshot.nextId <= highestId) throw new Error('nextId 会造成任务 ID 冲突');
    const record: PersistedQueueRecord = { schema: QUEUE_SCHEMA_VERSION, nextId: snapshot.nextId, items: items };
    return JSON.stringify(record);
  } catch (error) {
    if (error instanceof QueuePersistenceError) throw error;
    if (error instanceof Error) {
      throw new QueuePersistenceError('队列记录校验失败：' + error.message, error);
    }
    throw new QueuePersistenceError('队列记录序列化失败', error as Object);
  }
}

export function decodeQueueSnapshot(rawText: string): QueueDecodeResult {
  if (rawText.length === 0) return invalidQueue('记录为空');
  try {
    const parsed: Object = JSON.parse(rawText) as Object;
    if (!isRecord(parsed)) return invalidQueue('顶层结构错误');
    const root = parsed as { schema?: Object; nextId?: Object; items?: Object };
    if (root.schema !== QUEUE_SCHEMA_VERSION) return invalidQueue('schema 不受支持');
    if (!isNonNegativeInteger(root.nextId) || root.nextId < 1) return invalidQueue('nextId 无效');
    if (!Array.isArray(root.items)) return invalidQueue('items 必须是数组');
    const items: Array<QueueItem> = [];
    const ids: Set<string> = new Set<string>();
    const paths: Set<string> = new Set<string>();
    let highestId: number = 0;
    for (let index: number = 0; index < (root.items as Array<Object>).length; index += 1) {
      const item: QueueItem = decodeItem((root.items as Array<Object>)[index], index);
      if (ids.has(item.id)) return invalidQueue('任务 ID 重复');
      ids.add(item.id);
      const match: RegExpMatchArray | null = item.id.match(/^job-([1-9][0-9]*)$/);
      if (match === null) return invalidQueue('任务 ID 无效');
      highestId = Math.max(highestId, Number(match[1]));
      for (const path of item.ownedPaths) {
        if (paths.has(path)) return invalidQueue('ownedPaths 跨任务重复');
        paths.add(path);
      }
      items.push(item);
    }
    if (!Number.isSafeInteger(highestId) || root.nextId <= highestId) return invalidQueue('nextId 会造成任务 ID 冲突');
    return { snapshot: { nextId: root.nextId, items: items }, warning: '', corrupt: false };
  } catch (error) {
    const message: string = error instanceof Error ? error.message : 'JSON 记录解析失败';
    return invalidQueue(message);
  }
}

function appendRecoveryMessage(item: QueueItem, message: string): void {
  if (item.errorMessage.length === 0) {
    item.errorMessage = message;
  } else if (!item.errorMessage.includes(message)) {
    item.errorMessage += '；' + message;
  }
}

function restoreItem(item: QueueItem, probe: QueuePathProbe, warnings: Array<string>): QueueItem {
  const restored: QueueItem = {
    ...item,
    revision: 0,
    externalBusy: false,
    progress: { stage: item.progress.stage, current: item.progress.current, total: item.progress.total },
    ownedPaths: item.ownedPaths.slice()
  };
  if (item.details !== undefined) restored.details = cloneDetails(item.details);
  if (item.classification !== undefined) restored.classification = { ...item.classification };
  if (item.result !== undefined) {
    restored.result = {
      outputPath: item.result.outputPath,
      modeKey: item.result.modeKey,
      modeLabel: item.result.modeLabel,
      sourceInputPath: item.result.sourceInputPath,
      conversion: { ...item.result.conversion }
    };
  }

  for (const path of restored.ownedPaths) {
    const state: QueuePathStatus = probe.status(path);
    if (state === 'unsafe') throw new QueuePersistenceError('任务路径不安全：' + path);
  }
  // A batch export marks every selected item externalBusy before opening the
  // picker. If the process exits during that external operation, a completed
  // conversion still has a valid sandbox result and must remain exportable.
  // Native conversion/cleanup interruptions continue to become manual-failure
  // records; only this exact succeeded+result case gets the softer warning.
  const interruptedExternalSuccess: boolean = item.externalBusy &&
    item.cleanupStatus === 'none' && item.status === 'succeeded' &&
    item.attemptStatus === 'succeeded' && item.result !== undefined;
  if (restored.status === 'running' || restored.attemptStatus === 'running' ||
    (item.externalBusy && !interruptedExternalSuccess)) {
    restored.status = 'failed';
    restored.attemptStatus = 'failed';
    appendRecoveryMessage(restored, '上次操作在应用退出时中断，请手动重试');
  } else if (interruptedExternalSuccess) {
    appendRecoveryMessage(restored, '上次文件操作可能在应用退出时中断，转换结果仍保留，可重新导出');
  }
  if (restored.cleanupStatus === 'pending') {
    restored.cleanupStatus = 'failed';
    restored.cleanupErrorMessage = '上次删除清理被中断，请重试删除';
    restored.status = 'failed';
    restored.attemptStatus = 'failed';
    appendRecoveryMessage(restored, '上次删除清理被中断，请重试删除');
  }
  if (restored.inputPath.length > 0) {
    const inputState: QueuePathStatus = probe.status(restored.inputPath);
    if (inputState === 'missing' || inputState === 'empty') {
      restored.inputPath = '';
      if (restored.status === 'pending' || restored.attemptStatus === 'pending') {
        restored.status = 'failed';
        restored.attemptStatus = 'failed';
      }
      appendRecoveryMessage(restored, '沙盒输入缺失或为空，重试时将重新导入');
    }
  }
  if (restored.result !== undefined) {
    const resultState: QueuePathStatus = probe.status(restored.result.outputPath);
    if (resultState === 'missing' || resultState === 'empty') {
      restored.result = undefined;
      restored.status = 'failed';
      restored.attemptStatus = 'failed';
      appendRecoveryMessage(restored, '转换结果缺失或为空，无法显示或导出，请重试转换');
    }
  }
  if (restored.status === 'succeeded' && restored.result === undefined) {
    restored.status = 'failed';
    restored.attemptStatus = 'failed';
    appendRecoveryMessage(restored, '队列记录缺少可用转换结果，请重试转换');
  }
  return restored;
}

export function restoreQueueSnapshot(snapshot: QueuePersistenceSnapshot, probe: QueuePathProbe): QueueRestoreResult {
  const warnings: Array<string> = [];
  const restoredItems: Array<QueueItem> = [];
  for (const item of snapshot.items) {
    restoredItems.push(restoreItem(item, probe, warnings));
  }
  return { snapshot: { nextId: snapshot.nextId, items: restoredItems }, warnings: warnings };
}

function joinPath(root: string, leaf: string): string {
  const trimmed: string = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  return trimmed + '/' + leaf;
}

export class QueueStateStore {
  private readonly adapter: QueueStorageAdapter;
  private readonly queuePath: string;
  private readonly temporaryPath: string;

  constructor(root: string, adapter: QueueStorageAdapter) {
    if (root.length === 0 || root.includes('\u0000')) throw new Error('队列沙盒根目录无效');
    this.adapter = adapter;
    this.queuePath = joinPath(root, QUEUE_FILE_NAME);
    this.temporaryPath = this.queuePath + QUEUE_TEMP_SUFFIX;
  }

  public get path(): string {
    return this.queuePath;
  }

  public get tempPath(): string {
    return this.temporaryPath;
  }

  public async load(): Promise<QueueStoreLoadResult> {
    const mainExists: boolean = await this.adapter.exists(this.queuePath);
    const tempExists: boolean = await this.adapter.exists(this.temporaryPath);
    if (!mainExists) {
      if (tempExists) {
        return {
          warning: '发现没有主记录的未提交队列临时文件；已停止自动恢复，请使用安全恢复入口备份后新建队列。',
          corrupt: true,
          tempPresent: true
        };
      }
      return { snapshot: emptyQueueSnapshot(), warning: '', corrupt: false, tempPresent: false };
    }
    let raw: string;
    try {
      raw = await this.adapter.readText(this.queuePath);
    } catch (error) {
      return {
        warning: '队列主记录读取失败；未执行清理，请重试读取或使用安全恢复入口。',
        corrupt: true,
        tempPresent: tempExists
      };
    }
    const decoded: QueueDecodeResult = decodeQueueSnapshot(raw);
    if (decoded.corrupt || decoded.snapshot === undefined) {
      return { warning: decoded.warning, corrupt: true, tempPresent: tempExists };
    }
    const warning: string = tempExists
      ? '发现未提交临时快照；已忽略临时内容并使用完整主记录。'
      : decoded.warning;
    return { snapshot: decoded.snapshot, warning: warning, corrupt: false, tempPresent: tempExists };
  }

  public async save(snapshot: QueuePersistenceSnapshot): Promise<void> {
    let encoded: string;
    try {
      encoded = serializeQueueSnapshot(snapshot);
      await this.adapter.writeAtomic(this.queuePath, encoded);
    } catch (error) {
      if (error instanceof QueuePersistenceError) throw error;
      throw new QueuePersistenceError('队列记录保存失败；未继续排程', error as Object);
    }
  }

  /**
   * Move a corrupt main record and any uncommitted temp beside it. This is
   * intentionally explicit: loading a corrupt record never deletes or
   * overwrites it, and this method is called only by the user's recovery UI.
   */
  public async quarantine(): Promise<Array<string>> {
    const mainExists: boolean = await this.adapter.exists(this.queuePath);
    const tempExists: boolean = await this.adapter.exists(this.temporaryPath);
    if (!mainExists && !tempExists) throw new Error('没有需要备份的队列记录');
    const suffix: string = '.corrupt-' + String(Date.now());
    const backups: Array<string> = [];
    if (mainExists) {
      const backup: string = this.queuePath + suffix;
      await this.adapter.rename(this.queuePath, backup);
      backups.push(backup);
    }
    if (tempExists) {
      const backup: string = this.temporaryPath + suffix;
      await this.adapter.rename(this.temporaryPath, backup);
      backups.push(backup);
    }
    return backups;
  }
}
