export type LivePhotoPathState = 'file' | 'empty' | 'missing' | 'unsafe';

export interface LivePhotoFileStat {
  size: number;
  isFile: boolean;
  isDirectory: boolean;
  isSymbolicLink: boolean;
}

export interface LivePhotoPairPathPlan {
  itemId: string;
  sourceInputPath: string;
  convertedStillPath: string;
  scratchInputPath: string;
  outputDirectory: string;
  scratchStem: string;
  stillPath: string;
  movPath: string;
  ownedPaths: Array<string>;
}

export interface LivePhotoPairResult {
  itemId: string;
  inputPath: string;
  convertedStillPath: string;
  stillPath: string;
  movPath: string;
  contentIdentifier: string;
  stillSize: number;
  movSize: number;
  cleanupWarning: string;
}

export interface LivePhotoPairPipelineHooks {
  status(path: string): Promise<LivePhotoPathState>;
  stat(path: string): Promise<LivePhotoFileStat>;
  register(paths: Array<string>): void;
  persist(): Promise<void>;
  copy(sourcePath: string, destinationPath: string): Promise<void>;
  makeLivePhoto(sourcePath: string, stillPath: string, outputDirectory: string): Promise<string>;
  pairValid(stillPath: string, movPath: string): Promise<boolean>;
  cleanup(paths: Array<string>): Promise<void>;
}

export interface LivePhotoPairPipelineOptions {
  plan: LivePhotoPairPathPlan;
  sourceInputPath: string;
  convertedStillPath: string;
}

interface LivePhotoRawReport {
  success?: Object;
  errorMessage?: Object;
  stillPath?: Object;
  videoPath?: Object;
  contentIdentifier?: Object;
}

function joinPath(root: string, leaf: string): string {
  const normalized: string = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  return normalized + '/' + leaf;
}

function pathLeaf(path: string): string {
  const slash: number = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

function safePart(value: string, field: string): void {
  if (value.length === 0 || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error(field + ' 含有不安全字符');
  }
}

function validateSandboxPath(path: string, directory: string, field: string): void {
  if (path.length === 0 || path.includes('\u0000') || path.includes('\\') || path.includes('://') ||
    path.includes('..') || !path.startsWith(directory + '/')) {
    throw new Error(field + ' 不在预期沙盒目录');
  }
  const leaf: string = path.substring(directory.length + 1);
  if (leaf.length === 0 || leaf.includes('/')) {
    throw new Error(field + ' 必须是 flat 沙盒路径');
  }
}

function validatePlan(plan: LivePhotoPairPathPlan, sourceInputPath: string, convertedStillPath: string): void {
  if (plan.itemId.length === 0 || !/^job-[1-9][0-9]*$/.test(plan.itemId)) {
    throw new Error('Live Photo 任务 ID 无效');
  }
  if (plan.sourceInputPath !== sourceInputPath || plan.convertedStillPath !== convertedStillPath ||
    sourceInputPath === convertedStillPath || sourceInputPath.length === 0 || convertedStillPath.length === 0) {
    throw new Error('Live Photo 配对来源路径不一致');
  }
  if (plan.outputDirectory.length === 0 || plan.outputDirectory.includes('\u0000') ||
    plan.outputDirectory.includes('\\') || plan.outputDirectory.includes('://') || plan.outputDirectory.includes('..')) {
    throw new Error('Live Photo 输出目录无效');
  }
  safePart(plan.scratchStem, 'Live Photo 文件名');
  const inputMarker: string = '/inputs/';
  const outputMarker: string = '/outputs';
  const inputIndex: number = plan.scratchInputPath.lastIndexOf(inputMarker);
  if (inputIndex <= 0 || plan.outputDirectory !== plan.scratchInputPath.substring(0, inputIndex) + outputMarker) {
    throw new Error('Live Photo 路径必须位于 flat inputs/outputs 目录');
  }
  const root: string = plan.scratchInputPath.substring(0, inputIndex);
  const inputsDirectory: string = root + '/inputs';
  const outputsDirectory: string = root + '/outputs';
  validateSandboxPath(sourceInputPath, inputsDirectory, 'Motion Photo 原图');
  validateSandboxPath(convertedStillPath, outputsDirectory, 'Apple 转换静态图');
  const expectedScratch: string = root + '/inputs/' + plan.scratchStem + '.photo';
  const expectedStill: string = root + '/outputs/' + plan.scratchStem + '.heic';
  const expectedMov: string = root + '/outputs/' + plan.scratchStem + '.mov';
  if (plan.scratchInputPath !== expectedScratch || plan.stillPath !== expectedStill || plan.movPath !== expectedMov ||
    pathLeaf(plan.stillPath) !== plan.scratchStem + '.heic' || pathLeaf(plan.movPath) !== plan.scratchStem + '.mov') {
    throw new Error('Live Photo 候选路径与预登记命名不符');
  }
  const expectedOwned: Array<string> = [expectedScratch, expectedStill, expectedMov];
  if (plan.ownedPaths.length !== expectedOwned.length || new Set<string>(plan.ownedPaths).size !== expectedOwned.length) {
    throw new Error('Live Photo 必须完整登记三个唯一沙盒路径');
  }
  for (const path of expectedOwned) {
    if (!plan.ownedPaths.includes(path)) throw new Error('Live Photo 归属列表缺少候选路径');
  }
  for (const path of plan.ownedPaths) {
    if (path.includes('\u0000') || path.includes('\\') || path.includes('://') || path.includes('..')) {
      throw new Error('Live Photo 归属路径无效');
    }
  }
  if (plan.ownedPaths.includes(sourceInputPath) || plan.ownedPaths.includes(convertedStillPath)) {
    throw new Error('Live Photo 归属路径不能包含输入或转换静态图');
  }
}

export function buildLivePhotoPairPathPlan(
  root: string,
  itemId: string,
  timestamp: number,
  serial: number,
  sourceInputPath: string,
  convertedStillPath: string
): LivePhotoPairPathPlan {
  if (root.length === 0 || root.includes('\u0000') || root.includes('\\') || root.includes('://') || root.includes('..')) {
    throw new Error('Live Photo 沙盒根目录无效');
  }
  safePart(itemId, 'Live Photo 任务 ID');
  if (!/^job-[1-9][0-9]*$/.test(itemId) || !Number.isSafeInteger(timestamp) || timestamp <= 0 ||
    !Number.isSafeInteger(serial) || serial <= 0) {
    throw new Error('Live Photo 尝试序号无效');
  }
  const stem: string = 'input-' + itemId + '-live-' + String(timestamp) + '-' + String(serial);
  const inputDirectory: string = joinPath(root, 'inputs');
  const outputDirectory: string = joinPath(root, 'outputs');
  const plan: LivePhotoPairPathPlan = {
    itemId: itemId,
    sourceInputPath: sourceInputPath,
    convertedStillPath: convertedStillPath,
    scratchInputPath: joinPath(inputDirectory, stem + '.photo'),
    outputDirectory: outputDirectory,
    scratchStem: stem,
    stillPath: joinPath(outputDirectory, stem + '.heic'),
    movPath: joinPath(outputDirectory, stem + '.mov'),
    ownedPaths: [
      joinPath(inputDirectory, stem + '.photo'),
      joinPath(outputDirectory, stem + '.heic'),
      joinPath(outputDirectory, stem + '.mov')
    ]
  };
  validatePlan(plan, sourceInputPath, convertedStillPath);
  return plan;
}

function parseReport(rawJson: string, plan: LivePhotoPairPathPlan): string {
  let parsed: Object;
  try {
    parsed = JSON.parse(rawJson) as Object;
  } catch (error) {
    throw new Error('Live Photo 原生报告无法解析');
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Live Photo 原生报告必须是对象');
  }
  const report: LivePhotoRawReport = parsed as LivePhotoRawReport;
  if (report.success !== true) {
    if (typeof report.errorMessage === 'string' && report.errorMessage.length > 0) {
      throw new Error(report.errorMessage as string);
    }
    throw new Error('Live Photo 原生生成失败');
  }
  if (report.errorMessage !== undefined && report.errorMessage !== null && report.errorMessage !== '') {
    throw new Error('Live Photo 报告同时包含成功标志和错误信息');
  }
  if (report.stillPath !== plan.stillPath || report.videoPath !== plan.movPath) {
    throw new Error('Live Photo 报告路径与预登记候选不一致');
  }
  if (typeof report.contentIdentifier !== 'string' ||
    !/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$/.test(report.contentIdentifier as string)) {
    throw new Error('Live Photo contentIdentifier 格式无效');
  }
  return report.contentIdentifier as string;
}

function requireNonEmptyRegular(stat: LivePhotoFileStat, path: string): void {
  if (stat.isSymbolicLink || stat.isDirectory || !stat.isFile || !Number.isSafeInteger(stat.size) || stat.size <= 0) {
    throw new Error('Live Photo 文件不是非空普通文件：' + path);
  }
}

async function preflight(plan: LivePhotoPairPathPlan, hooks: LivePhotoPairPipelineHooks): Promise<void> {
  for (const path of plan.ownedPaths) {
    const state: LivePhotoPathState = await hooks.status(path);
    if (state !== 'missing') {
      throw new Error('Live Photo 预留路径必须不存在：' + path + '（' + state + '）');
    }
  }
}

async function validateOutput(path: string, hooks: LivePhotoPairPipelineHooks): Promise<LivePhotoFileStat> {
  const state: LivePhotoPathState = await hooks.status(path);
  if (state !== 'file' && state !== 'empty') {
    throw new Error('Live Photo 输出缺失或不安全：' + path + '（' + state + '）');
  }
  const stat: LivePhotoFileStat = await hooks.stat(path);
  requireNonEmptyRegular(stat, path);
  return stat;
}

/** Register and persist the complete attempt before copying the source or invoking Rust. */
export async function runLivePhotoPairPipeline(
  options: LivePhotoPairPipelineOptions,
  hooks: LivePhotoPairPipelineHooks
): Promise<LivePhotoPairResult> {
  const plan: LivePhotoPairPathPlan = options.plan;
  validatePlan(plan, options.sourceInputPath, options.convertedStillPath);
  await preflight(plan, hooks);
  const sourceBefore: LivePhotoFileStat = await hooks.stat(options.sourceInputPath);
  const stillBefore: LivePhotoFileStat = await hooks.stat(options.convertedStillPath);
  requireNonEmptyRegular(sourceBefore, options.sourceInputPath);
  requireNonEmptyRegular(stillBefore, options.convertedStillPath);
  hooks.register(plan.ownedPaths.slice());
  await hooks.persist();

  let writeStarted: boolean = false;
  try {
    const sourceCheck: LivePhotoFileStat = await hooks.stat(options.sourceInputPath);
    const stillCheck: LivePhotoFileStat = await hooks.stat(options.convertedStillPath);
    requireNonEmptyRegular(sourceCheck, options.sourceInputPath);
    requireNonEmptyRegular(stillCheck, options.convertedStillPath);
    if (sourceCheck.size !== sourceBefore.size || stillCheck.size !== stillBefore.size) {
      throw new Error('Live Photo 配对输入在生成前发生变化');
    }
    writeStarted = true;
    await hooks.copy(options.sourceInputPath, plan.scratchInputPath);
    const scratch: LivePhotoFileStat = await hooks.stat(plan.scratchInputPath);
    const sourceAfterCopy: LivePhotoFileStat = await hooks.stat(options.sourceInputPath);
    requireNonEmptyRegular(scratch, plan.scratchInputPath);
    requireNonEmptyRegular(sourceAfterCopy, options.sourceInputPath);
    if (scratch.size !== sourceAfterCopy.size || sourceAfterCopy.size !== sourceBefore.size) {
      throw new Error('Live Photo scratch 输入与当前原图不一致');
    }
    const rawJson: string = await hooks.makeLivePhoto(
      plan.scratchInputPath,
      options.convertedStillPath,
      plan.outputDirectory
    );
    const contentIdentifier: string = parseReport(rawJson, plan);
    const stillStat: LivePhotoFileStat = await validateOutput(plan.stillPath, hooks);
    const movStat: LivePhotoFileStat = await validateOutput(plan.movPath, hooks);
    const stillAfter: LivePhotoFileStat = await hooks.stat(options.convertedStillPath);
    requireNonEmptyRegular(stillAfter, options.convertedStillPath);
    if (stillAfter.size !== stillBefore.size) {
      throw new Error('Apple 转换静态图在配对期间发生变化');
    }
    if (await hooks.pairValid(plan.stillPath, plan.movPath) !== true) {
      throw new Error('Rust 未确认 Live Photo 两个文件的标识匹配');
    }
    const result: LivePhotoPairResult = {
      itemId: plan.itemId,
      inputPath: options.sourceInputPath,
      convertedStillPath: options.convertedStillPath,
      stillPath: plan.stillPath,
      movPath: plan.movPath,
      contentIdentifier: contentIdentifier,
      stillSize: stillStat.size,
      movSize: movStat.size,
      cleanupWarning: ''
    };
    try {
      await hooks.cleanup([plan.scratchInputPath]);
    } catch (cleanupError) {
      result.cleanupWarning = cleanupError instanceof Error ? cleanupError.message : String(cleanupError);
    }
    return result;
  } catch (error) {
    if (writeStarted) {
      try {
        await hooks.cleanup(plan.ownedPaths.slice());
      } catch (cleanupError) {
        const original: string = error instanceof Error ? error.message : String(error);
        const cleanupMessage: string = cleanupError instanceof Error ? cleanupError.message : String(cleanupError);
        throw new Error(original + '；本次 Live Photo 配对产物清理失败：' + cleanupMessage);
      }
    }
    throw error;
  }
}
