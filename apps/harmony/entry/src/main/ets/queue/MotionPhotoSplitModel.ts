import { parseMotionPhotoJson } from './MotionPhotoModel.ts';
import type { MotionPhotoInspection, NativeMotionPhotoReport } from './MotionPhotoModel.ts';

export type MotionSplitPathState = 'file' | 'empty' | 'missing' | 'unsafe';
export type MotionSplitAssetKind = 'still' | 'video' | 'primary';

export interface MotionSplitFileStat {
  size: number;
  isFile: boolean;
  isDirectory: boolean;
  isSymbolicLink: boolean;
}

export interface MotionSplitPathPlan {
  itemId: string;
  sourceInputPath: string;
  scratchInputPath: string;
  outputDirectory: string;
  scratchStem: string;
  stillJpgPath: string;
  stillHeicPath: string;
  videoPath: string;
  primaryPath: string;
  ownedPaths: Array<string>;
}

export interface MotionPhotoSplitAsset {
  kind: MotionSplitAssetKind;
  path: string;
  fileName: string;
  suffix: string;
  mime: string;
  label: string;
  size: number;
}

export interface MotionPhotoSplitResult {
  itemId: string;
  inputPath: string;
  report: NativeMotionPhotoReport;
  assets: Array<MotionPhotoSplitAsset>;
  cleanupWarning: string;
}

export interface MotionSplitPipelineHooks {
  status(path: string): Promise<MotionSplitPathState>;
  stat(path: string): Promise<MotionSplitFileStat>;
  register(paths: Array<string>): void;
  persist(): Promise<void>;
  copy(sourcePath: string, destinationPath: string): Promise<void>;
  runSplit(inputPath: string, outputDirectory: string): Promise<string>;
  cleanup(paths: Array<string>): Promise<void>;
}

export interface MotionSplitPipelineOptions {
  plan: MotionSplitPathPlan;
  sourceInputPath: string;
  sourceBytes: number;
}

interface SplitRawRecord {
  success?: Object;
  errorMessage?: Object;
  stillPath?: Object;
  videoPath?: Object;
  primaryVideoPath?: Object;
}

function requiredString(value: Object | undefined, field: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(field + ' 必须是非空字符串');
  }
  return value as string;
}

function requiredBoolean(value: Object | undefined, field: string): boolean {
  if (typeof value !== 'boolean') {
    throw new Error(field + ' 必须是布尔值');
  }
  return value as boolean;
}

function safePlanPart(value: string, field: string): string {
  if (value.length === 0 || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error(field + ' 含有不安全字符');
  }
  return value;
}

function leaf(path: string): string {
  const slash: number = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

function join(root: string, child: string): string {
  const normalized: string = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  return normalized + '/' + child;
}

function requireRegularFile(stat: MotionSplitFileStat, path: string): void {
  if (stat.isSymbolicLink || stat.isDirectory || !stat.isFile) {
    throw new Error('拆分产物不是普通文件：' + path);
  }
  if (!Number.isSafeInteger(stat.size) || stat.size <= 0) {
    throw new Error('拆分产物为空或大小无效：' + path);
  }
}

function pathInPlan(path: string, plan: MotionSplitPathPlan): boolean {
  return path === plan.stillJpgPath || path === plan.stillHeicPath ||
    path === plan.videoPath || path === plan.primaryPath;
}

function expectedStillPath(path: string, plan: MotionSplitPathPlan): boolean {
  return path === plan.stillJpgPath || path === plan.stillHeicPath;
}

function expectedAssetPath(kind: MotionSplitAssetKind, path: string, plan: MotionSplitPathPlan): boolean {
  if (kind === 'still') return expectedStillPath(path, plan);
  if (kind === 'video') return path === plan.videoPath;
  return path === plan.primaryPath;
}

function makeAsset(
  kind: MotionSplitAssetKind,
  path: string,
  size: number
): MotionPhotoSplitAsset {
  const fileName: string = leaf(path);
  if (kind === 'still') {
    const heic: boolean = fileName.endsWith('.still.heic');
    return {
      kind: kind,
      path: path,
      fileName: fileName,
      suffix: heic ? '.heic' : '.jpg',
      mime: heic ? 'image/heic' : 'image/jpeg',
      label: heic ? '静态图（HEIC）' : '静态图（JPEG）',
      size: size
    };
  }
  return {
    kind: kind,
    path: path,
    fileName: fileName,
    suffix: '.mp4',
    mime: 'video/mp4',
    label: kind === 'primary' ? '主视频（可选）' : '完整视频',
    size: size
  };
}

function parseSplitObject(rawJson: string): SplitRawRecord {
  let parsed: Object;
  try {
    parsed = JSON.parse(rawJson) as Object;
  } catch (error) {
    throw new Error('Motion Photo 拆分返回值无法解析');
  }
  if (parsed === undefined || parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Motion Photo 拆分返回值必须是对象');
  }
  const value: SplitRawRecord = parsed as SplitRawRecord;
  if (!requiredBoolean(value.success, 'success')) {
    const message: Object | undefined = value.errorMessage;
    if (typeof message === 'string' && message.length > 0) {
      throw new Error(message);
    }
    throw new Error('Motion Photo 拆分失败');
  }
  if (typeof value.errorMessage === 'string' && value.errorMessage.length > 0) {
    throw new Error('拆分报告同时包含成功标志和错误信息');
  }
  return value;
}

function validatePlan(plan: MotionSplitPathPlan, sourceInputPath: string): void {
  if (plan.sourceInputPath !== sourceInputPath || sourceInputPath.length === 0) {
    throw new Error('拆分源输入路径不一致');
  }
  if (plan.scratchInputPath === sourceInputPath || plan.outputDirectory.length === 0) {
    throw new Error('拆分路径覆盖了原始输入');
  }
  safePlanPart(plan.scratchStem, '拆分文件名');
  const inputMarker: string = '/inputs/';
  const inputIndex: number = plan.scratchInputPath.lastIndexOf(inputMarker);
  if (inputIndex <= 0 || plan.outputDirectory !== plan.scratchInputPath.substring(0, inputIndex) + '/outputs') {
    throw new Error('拆分目录必须是 flat inputs/outputs');
  }
  const root: string = plan.scratchInputPath.substring(0, inputIndex);
  const expected: Array<string> = [
    root + '/inputs/' + plan.scratchStem + '.photo',
    root + '/outputs/' + plan.scratchStem + '.still.jpg',
    root + '/outputs/' + plan.scratchStem + '.still.heic',
    root + '/outputs/' + plan.scratchStem + '.video.mp4',
    root + '/outputs/' + plan.scratchStem + '.primary.mp4'
  ];
  const fields: Array<string> = [plan.scratchInputPath, plan.stillJpgPath, plan.stillHeicPath,
    plan.videoPath, plan.primaryPath];
  for (let index = 0; index < fields.length; index += 1) {
    if (fields[index] !== expected[index]) {
      throw new Error('拆分路径不符合预登记命名');
    }
  }
  if (plan.ownedPaths.length !== expected.length) {
    throw new Error('拆分归属列表必须完整登记五个路径');
  }
  const owned: Set<string> = new Set<string>();
  for (const path of plan.ownedPaths) {
    if (path.length === 0 || path.includes('\u0000') || path.includes('..') || path.includes('\\') ||
      path.includes('://') || owned.has(path)) {
      throw new Error('拆分归属路径无效或重复');
    }
    owned.add(path);
  }
  for (const path of expected) {
    if (!owned.has(path)) {
      throw new Error('拆分归属列表缺少预登记路径');
    }
  }
  if (owned.size !== expected.length || plan.stillJpgPath === plan.stillHeicPath ||
    plan.stillJpgPath === plan.videoPath || plan.stillJpgPath === plan.primaryPath ||
    plan.stillHeicPath === plan.videoPath || plan.stillHeicPath === plan.primaryPath ||
    plan.videoPath === plan.primaryPath) {
    throw new Error('拆分候选路径重复');
  }
}

/** Create flat, attempt-unique paths. Rust derives output names from the
 * scratch input stem, so the plan intentionally controls that stem. */
export function buildMotionSplitPathPlan(
  root: string,
  itemId: string,
  timestamp: number,
  serial: number,
  sourceInputPath: string
): MotionSplitPathPlan {
  if (root.length === 0 || root.includes('\u0000') || root.includes('\\') || root.includes('://') || root.includes('..')) {
    throw new Error('拆分沙盒根目录无效');
  }
  safePlanPart(itemId, '任务 ID');
  if (!Number.isSafeInteger(timestamp) || timestamp <= 0 || !Number.isSafeInteger(serial) || serial <= 0) {
    throw new Error('拆分尝试序号无效');
  }
  const scratchStem: string = 'input-' + itemId + '-motion-' + String(timestamp) + '-' + String(serial);
  const scratchInputPath: string = join(join(root, 'inputs'), scratchStem + '.photo');
  const outputDirectory: string = join(root, 'outputs');
  const stillJpgPath: string = join(outputDirectory, scratchStem + '.still.jpg');
  const stillHeicPath: string = join(outputDirectory, scratchStem + '.still.heic');
  const videoPath: string = join(outputDirectory, scratchStem + '.video.mp4');
  const primaryPath: string = join(outputDirectory, scratchStem + '.primary.mp4');
  const plan: MotionSplitPathPlan = {
    itemId: itemId,
    sourceInputPath: sourceInputPath,
    scratchInputPath: scratchInputPath,
    outputDirectory: outputDirectory,
    scratchStem: scratchStem,
    stillJpgPath: stillJpgPath,
    stillHeicPath: stillHeicPath,
    videoPath: videoPath,
    primaryPath: primaryPath,
    ownedPaths: [scratchInputPath, stillJpgPath, stillHeicPath, videoPath, primaryPath]
  };
  validatePlan(plan, sourceInputPath);
  return plan;
}

/** Parse and validate the Rust split report and the actual files produced by it. */
export function parseMotionSplitJson(
  rawJson: string,
  plan: MotionSplitPathPlan,
  sourceInputPath: string,
  sourceBytes: number,
  stats: Map<string, MotionSplitFileStat>
): MotionPhotoSplitResult {
  validatePlan(plan, sourceInputPath);
  if (!Number.isSafeInteger(sourceBytes) || sourceBytes <= 0) {
    throw new Error('Motion Photo 原始输入大小无效');
  }
  const raw: SplitRawRecord = parseSplitObject(rawJson);
  const inspection: MotionPhotoInspection = parseMotionPhotoJson(rawJson, sourceInputPath, sourceBytes);
  if (inspection.state !== 'motion' || inspection.report === undefined) {
    throw new Error(inspection.message);
  }
  const stillPath: string = requiredString(raw.stillPath, 'stillPath');
  const videoPath: string = requiredString(raw.videoPath, 'videoPath');
  const primaryPath: string | undefined = raw.primaryVideoPath === undefined
    ? undefined
    : requiredString(raw.primaryVideoPath, 'primaryVideoPath');
  if (!expectedStillPath(stillPath, plan)) {
    throw new Error('拆分报告静态图路径不在预登记候选内');
  }
  const reportMime: string = inspection.report.items[0].mime.toLowerCase();
  const mimeHeic: boolean = reportMime.includes('heic') || reportMime.includes('heif');
  const mimeStillPath: string = mimeHeic ? plan.stillHeicPath : plan.stillJpgPath;
  if (stillPath !== mimeStillPath) {
    throw new Error('拆分静态图扩展名与报告类型不符');
  }
  if (videoPath !== plan.videoPath) {
    throw new Error('拆分报告视频路径不符合预登记命名');
  }
  if (primaryPath !== undefined && primaryPath !== plan.primaryPath) {
    throw new Error('拆分报告主视频路径不符合预登记命名');
  }

  const actualPaths: Array<string> = [plan.stillJpgPath, plan.stillHeicPath, plan.videoPath, plan.primaryPath];
  for (const path of actualPaths) {
    const stat: MotionSplitFileStat | undefined = stats.get(path);
    if (stat !== undefined && (!pathInPlan(path, plan) || stat.isSymbolicLink || stat.isDirectory)) {
      throw new Error('拆分产物路径不安全：' + path);
    }
  }
  const stillJpg: MotionSplitFileStat | undefined = stats.get(plan.stillJpgPath);
  const stillHeic: MotionSplitFileStat | undefined = stats.get(plan.stillHeicPath);
  if ((stillJpg === undefined) === (stillHeic === undefined)) {
    throw new Error('拆分必须且只能写出一个静态图候选');
  }
  if (stats.get(stillPath) === undefined || stats.get(stillPath === plan.stillJpgPath
    ? plan.stillHeicPath : plan.stillJpgPath) !== undefined) {
    throw new Error('拆分报告静态图路径与实际写出文件不一致');
  }
  if (stats.get(plan.videoPath) === undefined) {
    throw new Error('拆分缺少完整视频');
  }
  if (primaryPath === undefined && stats.get(plan.primaryPath) !== undefined) {
    throw new Error('拆分写出了未在报告中声明的主视频');
  }
  if (primaryPath !== undefined && stats.get(plan.primaryPath) === undefined) {
    throw new Error('拆分报告声明的主视频不存在');
  }

  const stillStat: MotionSplitFileStat = stillJpg === undefined ? stillHeic as MotionSplitFileStat : stillJpg;
  const videoStat: MotionSplitFileStat = stats.get(plan.videoPath) as MotionSplitFileStat;
  requireRegularFile(stillStat, stillPath);
  requireRegularFile(videoStat, videoPath);
  const expectedStillBytes: number = inspection.report.stillEnd - inspection.report.stillStart;
  const expectedVideoBytes: number = inspection.report.videoEnd - inspection.report.videoStart;
  if (stillStat.size !== expectedStillBytes || videoStat.size !== expectedVideoBytes) {
    throw new Error('拆分静态图或完整视频大小与报告范围不符');
  }
  const assets: Array<MotionPhotoSplitAsset> = [makeAsset('still', stillPath, stillStat.size),
    makeAsset('video', videoPath, videoStat.size)];
  if (primaryPath !== undefined) {
    const primaryStat: MotionSplitFileStat = stats.get(plan.primaryPath) as MotionSplitFileStat;
    requireRegularFile(primaryStat, primaryPath);
    if (primaryStat.size > videoStat.size) {
      throw new Error('主视频大小超过完整视频范围');
    }
    if (inspection.report.primaryBytes !== undefined && primaryStat.size !== inspection.report.primaryBytes) {
      throw new Error('主视频大小与报告不符');
    }
    assets.push(makeAsset('primary', primaryPath, primaryStat.size));
  }
  return {
    itemId: plan.itemId,
    inputPath: sourceInputPath,
    report: inspection.report,
    assets: assets,
    cleanupWarning: ''
  };
}

async function preflightPaths(plan: MotionSplitPathPlan, hooks: MotionSplitPipelineHooks): Promise<void> {
  for (const path of plan.ownedPaths) {
    const state: MotionSplitPathState = await hooks.status(path);
    if (state !== 'missing') {
      throw new Error('拆分预留路径必须不存在：' + path + '（' + state + '）');
    }
  }
}

async function collectStats(
  plan: MotionSplitPathPlan,
  hooks: MotionSplitPipelineHooks
): Promise<Map<string, MotionSplitFileStat>> {
  const stats: Map<string, MotionSplitFileStat> = new Map<string, MotionSplitFileStat>();
  for (const path of [plan.stillJpgPath, plan.stillHeicPath, plan.videoPath, plan.primaryPath]) {
    const state: MotionSplitPathState = await hooks.status(path);
    if (state === 'unsafe') {
      throw new Error('拆分产物路径不安全：' + path);
    }
    if (state === 'file' || state === 'empty') {
      stats.set(path, await hooks.stat(path));
    }
  }
  return stats;
}

/** Execute the production split sequence with injected IO and queue hooks. */
export async function runMotionSplitPipeline(
  options: MotionSplitPipelineOptions,
  hooks: MotionSplitPipelineHooks
): Promise<MotionPhotoSplitResult> {
  const plan: MotionSplitPathPlan = options.plan;
  validatePlan(plan, options.sourceInputPath);
  if (plan.sourceInputPath !== options.sourceInputPath) {
    throw new Error('拆分源输入路径不一致');
  }
  await preflightPaths(plan, hooks);
  // This is the last phase that may fail without touching any file. Do not
  // cleanup here: an existing/unsafe path must never be deleted by a failed
  // preflight, and a persistence failure has not started ownership writes.
  hooks.register(plan.ownedPaths);
  await hooks.persist();

  let writeStarted: boolean = false;
  try {
    const sourceStat: MotionSplitFileStat = await hooks.stat(options.sourceInputPath);
    requireRegularFile(sourceStat, options.sourceInputPath);
    if (sourceStat.size !== options.sourceBytes) {
      throw new Error('原始输入在拆分前发生变化');
    }
    writeStarted = true;
    await hooks.copy(options.sourceInputPath, plan.scratchInputPath);
    const sourceAfter: MotionSplitFileStat = await hooks.stat(options.sourceInputPath);
    const scratchStat: MotionSplitFileStat = await hooks.stat(plan.scratchInputPath);
    requireRegularFile(sourceAfter, options.sourceInputPath);
    requireRegularFile(scratchStat, plan.scratchInputPath);
    if (sourceAfter.size !== options.sourceBytes || scratchStat.size !== sourceAfter.size) {
      throw new Error('拆分 scratch 输入与原始输入大小不一致');
    }
    const rawJson: string = await hooks.runSplit(plan.scratchInputPath, plan.outputDirectory);
    const stats: Map<string, MotionSplitFileStat> = await collectStats(plan, hooks);
    const result: MotionPhotoSplitResult = parseMotionSplitJson(
      rawJson,
      plan,
      options.sourceInputPath,
      sourceAfter.size,
      stats
    );
    try {
      await hooks.cleanup([plan.scratchInputPath]);
    } catch (cleanupError) {
      result.cleanupWarning = cleanupError instanceof Error
        ? cleanupError.message
        : String(cleanupError);
    }
    return result;
  } catch (error) {
    if (writeStarted) {
      try {
        await hooks.cleanup(plan.ownedPaths.slice());
      } catch (cleanupError) {
        const original: string = error instanceof Error ? error.message : String(error);
        const cleanupMessage: string = cleanupError instanceof Error ? cleanupError.message : String(cleanupError);
        throw new Error(original + '；本次拆分产物清理失败：' + cleanupMessage);
      }
    }
    throw error;
  }
}
