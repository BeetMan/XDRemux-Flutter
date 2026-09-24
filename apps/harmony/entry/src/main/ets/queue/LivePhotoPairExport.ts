import { batchExportUriLeaf, uriAliases } from './BatchExport.ts';
import type { LivePhotoPairResult } from './LivePhotoPairModel.ts';

export type LivePhotoExportKind = 'still' | 'video';
export type LivePhotoExportStatus = 'waiting' | 'succeeded' | 'failed';

export interface LivePhotoExportEntry {
  kind: LivePhotoExportKind;
  label: string;
  sourcePath: string;
  fileName: string;
  targetUri: string;
  status: LivePhotoExportStatus;
  errorMessage: string;
}

export interface LivePhotoExportSummary {
  total: number;
  succeeded: number;
  failed: number;
  waiting: number;
}

function leaf(path: string): string {
  const slash: number = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

function copyEntry(entry: LivePhotoExportEntry): LivePhotoExportEntry {
  return { ...entry };
}

function safeToken(value: string): boolean {
  return value.length > 0 && /^[A-Za-z0-9_-]+$/.test(value);
}

export function buildLivePhotoExportPlan(pair: LivePhotoPairResult): Array<LivePhotoExportEntry> {
  const stillLeaf: string = leaf(pair.stillPath);
  const movLeaf: string = leaf(pair.movPath);
  if (!stillLeaf.endsWith('.heic') || !movLeaf.endsWith('.mov')) {
    throw new Error('Live Photo 沙盒产物扩展名无效');
  }
  const stillStem: string = stillLeaf.substring(0, stillLeaf.length - '.heic'.length);
  const movStem: string = movLeaf.substring(0, movLeaf.length - '.mov'.length);
  if (stillStem !== movStem || !safeToken(stillStem)) {
    throw new Error('Live Photo 导出文件必须使用同一安全文件名');
  }
  return [
    {
      kind: 'still',
      label: 'HEIC 静态图',
      sourcePath: pair.stillPath,
      fileName: stillStem + '.heic',
      targetUri: '',
      status: 'waiting',
      errorMessage: ''
    },
    {
      kind: 'video',
      label: 'MOV 视频',
      sourcePath: pair.movPath,
      fileName: movStem + '.mov',
      targetUri: '',
      status: 'waiting',
      errorMessage: ''
    }
  ];
}

/** Match both picker URIs by exact requested filename before opening either FD. */
export function attachLivePhotoExportTargets(
  entries: Array<LivePhotoExportEntry>,
  savedUris: Array<string>,
  protectedPaths: Array<string>
): Array<LivePhotoExportEntry> {
  if (entries.length !== 2 || savedUris.length !== 2) {
    throw new Error('Live Photo 保存选择器必须返回两个目标；未写入任何文件');
  }
  const byName: Map<string, LivePhotoExportEntry> = new Map<string, LivePhotoExportEntry>();
  const forbidden: Set<string> = new Set<string>();
  for (const entry of entries) {
    if (byName.has(entry.fileName) || entry.fileName.length === 0 || entry.sourcePath.length === 0) {
      throw new Error('Live Photo 预期文件名重复或来源无效；未写入任何文件');
    }
    byName.set(entry.fileName, entry);
    for (const alias of uriAliases(entry.sourcePath)) forbidden.add(alias);
  }
  for (const path of protectedPaths) {
    for (const alias of uriAliases(path)) forbidden.add(alias);
  }

  const targetByName: Map<string, string> = new Map<string, string>();
  const seenUri: Set<string> = new Set<string>();
  const seenAlias: Set<string> = new Set<string>();
  for (const uri of savedUris) {
    if (typeof uri !== 'string' || uri.length === 0 || uri.trim() !== uri) {
      throw new Error('Live Photo 保存选择器返回无效 URI；未写入任何文件');
    }
    if (seenUri.has(uri)) throw new Error('Live Photo 保存选择器返回重复 URI；未写入任何文件');
    seenUri.add(uri);
    const aliases: Array<string> = uriAliases(uri);
    for (const alias of aliases) {
      if (seenAlias.has(alias)) throw new Error('Live Photo 保存选择器返回重复目标；未写入任何文件');
      seenAlias.add(alias);
      if (forbidden.has(alias)) throw new Error('Live Photo 导出目标不能覆盖输入或沙盒文件；未写入任何文件');
    }
    const requested: LivePhotoExportEntry | undefined = byName.get(batchExportUriLeaf(uri));
    if (requested === undefined) {
      throw new Error('Live Photo 保存 URI 无法按文件名对应；未写入任何文件');
    }
    if (targetByName.has(requested.fileName)) {
      throw new Error('Live Photo 保存 URI 文件名重复；未写入任何文件');
    }
    targetByName.set(requested.fileName, uri);
  }
  if (targetByName.size !== entries.length) {
    throw new Error('Live Photo 保存目标不完整；未写入任何文件');
  }
  return entries.map((entry: LivePhotoExportEntry): LivePhotoExportEntry => {
    const targetUri: string | undefined = targetByName.get(entry.fileName);
    if (targetUri === undefined) throw new Error('Live Photo 导出目标映射不完整；未写入任何文件');
    const copy: LivePhotoExportEntry = copyEntry(entry);
    copy.targetUri = targetUri;
    return copy;
  });
}

/** Complete each independently; the HEIC and MOV copies are intentionally serial and non-atomic. */
export async function runLivePhotoPairExport(
  initialEntries: Array<LivePhotoExportEntry>,
  copy: (entry: LivePhotoExportEntry) => Promise<void>
): Promise<Array<LivePhotoExportEntry>> {
  if (initialEntries.length !== 2 || initialEntries.some((entry: LivePhotoExportEntry): boolean =>
    entry.targetUri.length === 0 || entry.status !== 'waiting')) {
    throw new Error('Live Photo 导出计划尚未完整映射');
  }
  const entries: Array<LivePhotoExportEntry> = initialEntries.map(copyEntry);
  for (const entry of entries) {
    try {
      await copy(entry);
      entry.status = 'succeeded';
      entry.errorMessage = '';
    } catch (error) {
      entry.status = 'failed';
      entry.errorMessage = error instanceof Error ? error.message : String(error);
    }
  }
  return entries.map(copyEntry);
}

export function summarizeLivePhotoExport(entries: Array<LivePhotoExportEntry>): LivePhotoExportSummary {
  const summary: LivePhotoExportSummary = { total: entries.length, succeeded: 0, failed: 0, waiting: 0 };
  for (const entry of entries) {
    if (entry.status === 'succeeded') summary.succeeded += 1;
    else if (entry.status === 'failed') summary.failed += 1;
    else summary.waiting += 1;
  }
  return summary;
}
