export type MotionPhotoInspectionState = 'unidentified' | 'photo' | 'motion' | 'error';

export interface NativeMotionPhotoItem {
  mime: string;
  semantic: string;
  length: number;
  padding: number;
}

export interface NativeMotionPhotoReport {
  isMotionPhoto: boolean;
  sourceKind: string;
  stillStart: number;
  stillEnd: number;
  videoStart: number;
  videoEnd: number;
  isDualStream: boolean;
  items: Array<NativeMotionPhotoItem>;
  presentationTimestampUs?: number;
  presentationSource?: string;
  videoWidth?: number;
  videoHeight?: number;
  durationMs?: number;
  fps?: number;
  frameCount?: number;
  videoCodec?: string;
  hasAudio?: boolean;
  audioCodec?: string;
  audioChannels?: number;
  audioSampleRate?: number;
  audioDurationMs?: number;
  primaryBytes?: number;
  secondaryBytes?: number;
  secondaryWidth?: number;
  secondaryHeight?: number;
  secondaryFps?: number;
}

export interface MotionPhotoInspection {
  inputPath: string;
  state: MotionPhotoInspectionState;
  message: string;
  report?: NativeMotionPhotoReport;
}

interface MotionRawRecord {
  isMotionPhoto?: Object;
  errorMessage?: Object;
  sourceKind?: Object;
  stillStart?: Object;
  stillEnd?: Object;
  videoStart?: Object;
  videoEnd?: Object;
  isDualStream?: Object;
  items?: Object;
  presentationTimestampUs?: Object;
  presentationSource?: Object;
  videoWidth?: Object;
  videoHeight?: Object;
  durationMs?: Object;
  fps?: Object;
  frameCount?: Object;
  videoCodec?: Object;
  hasAudio?: Object;
  audioCodec?: Object;
  audioChannels?: Object;
  audioSampleRate?: Object;
  audioDurationMs?: Object;
  primaryBytes?: Object;
  secondaryBytes?: Object;
  secondaryWidth?: Object;
  secondaryHeight?: Object;
  secondaryFps?: Object;
}

interface MotionItemRawRecord {
  mime?: Object;
  semantic?: Object;
  length?: Object;
  padding?: Object;
}

function isRecord(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function requiredBoolean(value: Object | undefined, field: string): boolean {
  if (typeof value !== 'boolean') {
    throw new Error(field + ' 必须是布尔值');
  }
  return value as boolean;
}

function optionalBoolean(value: Object | undefined, field: string): boolean | undefined {
  if (value === undefined) {
    return undefined;
  }
  return requiredBoolean(value, field);
}

function requiredString(value: Object | undefined, field: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(field + ' 必须是非空字符串');
  }
  return value as string;
}

function optionalString(value: Object | undefined, field: string): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== 'string') {
    throw new Error(field + ' 必须是字符串');
  }
  return value as string;
}

function safeUnsigned(value: Object | undefined, field: string, maximum: number): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0 || value > maximum) {
    throw new Error(field + ' 不是安全的非负字节整数');
  }
  return value as number;
}

function optionalUnsigned(value: Object | undefined, field: string, maximum: number): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  return safeUnsigned(value, field, maximum);
}

function optionalSignedSafe(value: Object | undefined, field: string): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
    throw new Error(field + ' 不是安全整数');
  }
  return value as number;
}

function optionalFiniteNumber(value: Object | undefined, field: string): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    throw new Error(field + ' 不是有效的非负数字');
  }
  return value as number;
}

function parseItems(value: Object | undefined, fileSize: number): Array<NativeMotionPhotoItem> {
  if (!Array.isArray(value)) {
    throw new Error('items 必须是数组');
  }
  const rawItems: Array<Object> = value as Array<Object>;
  if (rawItems.length === 0) {
    throw new Error('items 不能为空');
  }
  const items: Array<NativeMotionPhotoItem> = [];
  for (let index = 0; index < rawItems.length; index += 1) {
    const raw: Object = rawItems[index];
    if (!isRecord(raw)) {
      throw new Error('items[' + String(index) + '] 必须是对象');
    }
    const item: MotionItemRawRecord = raw as MotionItemRawRecord;
    items.push({
      mime: requiredString(item.mime, 'items[' + String(index) + '].mime'),
      semantic: requiredString(item.semantic, 'items[' + String(index) + '].semantic'),
      length: safeUnsigned(item.length, 'items[' + String(index) + '].length', fileSize),
      padding: safeUnsigned(item.padding, 'items[' + String(index) + '].padding', fileSize)
    });
  }
  return items;
}

function parseReport(raw: Object, inputPath: string, fileSize: number): MotionPhotoInspection {
  if (!isRecord(raw)) {
    throw new Error('Motion Photo 返回值必须是对象');
  }
  if (!Number.isSafeInteger(fileSize) || fileSize < 0) {
    throw new Error('沙盒文件大小不是安全整数');
  }
  const value: MotionRawRecord = raw as MotionRawRecord;
  const isMotionPhoto: boolean = requiredBoolean(value.isMotionPhoto, 'isMotionPhoto');
  const errorMessage: string | undefined = optionalString(value.errorMessage, 'errorMessage');
  if (!isMotionPhoto) {
    if (errorMessage !== undefined && errorMessage.length > 0) {
      return { inputPath: inputPath, state: 'error', message: errorMessage };
    }
    return {
      inputPath: inputPath,
      state: 'photo',
      message: '普通照片或未识别出支持的 Motion Photo 结构'
    };
  }
  if (errorMessage !== undefined && errorMessage.length > 0) {
    throw new Error('实况识别报告同时包含成功标志和错误信息');
  }
  const stillStart: number = safeUnsigned(value.stillStart, 'stillStart', fileSize);
  const stillEnd: number = safeUnsigned(value.stillEnd, 'stillEnd', fileSize);
  const videoStart: number = safeUnsigned(value.videoStart, 'videoStart', fileSize);
  const videoEnd: number = safeUnsigned(value.videoEnd, 'videoEnd', fileSize);
  if (stillStart >= stillEnd || videoStart >= videoEnd) {
    throw new Error('Motion Photo 字节范围必须满足 start < end');
  }

  const videoLength: number = videoEnd - videoStart;
  const report: NativeMotionPhotoReport = {
    isMotionPhoto: true,
    sourceKind: requiredString(value.sourceKind, 'sourceKind'),
    stillStart: stillStart,
    stillEnd: stillEnd,
    videoStart: videoStart,
    videoEnd: videoEnd,
    isDualStream: requiredBoolean(value.isDualStream, 'isDualStream'),
    items: parseItems(value.items, fileSize),
    presentationTimestampUs: optionalSignedSafe(value.presentationTimestampUs, 'presentationTimestampUs'),
    presentationSource: optionalString(value.presentationSource, 'presentationSource'),
    videoWidth: optionalUnsigned(value.videoWidth, 'videoWidth', 4294967295),
    videoHeight: optionalUnsigned(value.videoHeight, 'videoHeight', 4294967295),
    durationMs: optionalUnsigned(value.durationMs, 'durationMs', Number.MAX_SAFE_INTEGER),
    fps: optionalFiniteNumber(value.fps, 'fps'),
    frameCount: optionalUnsigned(value.frameCount, 'frameCount', 4294967295),
    videoCodec: optionalString(value.videoCodec, 'videoCodec'),
    hasAudio: optionalBoolean(value.hasAudio, 'hasAudio'),
    audioCodec: optionalString(value.audioCodec, 'audioCodec'),
    audioChannels: optionalUnsigned(value.audioChannels, 'audioChannels', 65535),
    audioSampleRate: optionalUnsigned(value.audioSampleRate, 'audioSampleRate', 4294967295),
    audioDurationMs: optionalUnsigned(value.audioDurationMs, 'audioDurationMs', Number.MAX_SAFE_INTEGER),
    primaryBytes: optionalUnsigned(value.primaryBytes, 'primaryBytes', videoLength),
    secondaryBytes: optionalUnsigned(value.secondaryBytes, 'secondaryBytes', videoLength),
    secondaryWidth: optionalUnsigned(value.secondaryWidth, 'secondaryWidth', 4294967295),
    secondaryHeight: optionalUnsigned(value.secondaryHeight, 'secondaryHeight', 4294967295),
    secondaryFps: optionalFiniteNumber(value.secondaryFps, 'secondaryFps')
  };
  return { inputPath: inputPath, state: 'motion', message: '已识别 Motion Photo', report: report };
}

export function parseMotionPhotoJson(rawJson: string, inputPath: string, fileSize: number): MotionPhotoInspection {
  if (inputPath.length === 0) {
    return { inputPath: inputPath, state: 'error', message: '识别输入路径为空' };
  }
  try {
    const parsed: Object = JSON.parse(rawJson) as Object;
    return parseReport(parsed, inputPath, fileSize);
  } catch (error) {
    const message: string = error instanceof Error && error.message.length > 0
      ? error.message
      : 'Motion Photo 返回值无法解析';
    return { inputPath: inputPath, state: 'error', message: message };
  }
}

export function motionPhotoStateLabel(state: MotionPhotoInspectionState): string {
  if (state === 'motion') {
    return '实况照片信息';
  }
  if (state === 'photo') {
    return '普通照片 / 未识别结构';
  }
  if (state === 'error') {
    return '识别错误';
  }
  return '尚未识别';
}

export function emptyMotionPhotoInspection(): MotionPhotoInspection {
  return { inputPath: '', state: 'unidentified', message: '尚未识别当前输入' };
}
