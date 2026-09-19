import type { QueueItem } from './QueueController';

/** A batch export only runs in the foreground page session. */
export type BatchExportStatus = 'waiting' | 'copying' | 'succeeded' | 'failed' | 'journal-failed' | 'canceled';

export interface BatchExportEntry {
  id: string;
  displayName: string;
  sourceUri: string;
  outputPath: string;
  ownedPaths: Array<string>;
  fileName: string;
  targetUri: string;
  status: BatchExportStatus;
  /** Physical FD copy completed and the destination FD was closed. */
  copySucceeded: boolean;
  /** The destination is known to contain the copied output, even if the
   * subsequent queue journal checkpoint failed. */
  exported: boolean;
  errorMessage: string;
}

export interface BatchExportSummary {
  total: number;
  waiting: number;
  copying: number;
  succeeded: number;
  failed: number;
  journalFailed: number;
  canceled: number;
  exported: number;
}

export interface BatchExportRunOptions {
  copy: (entry: BatchExportEntry) => Promise<void>;
  checkpoint: (entry: BatchExportEntry) => Promise<void>;
  shouldStop?: () => boolean;
  onStatus?: (entries: Array<BatchExportEntry>) => void;
  errorMessage?: (error: Object) => string;
}

function safeToken(value: string, fallback: string): string {
  const sanitized: string = value.replace(/[^A-Za-z0-9_-]/g, '_');
  return sanitized.length === 0 ? fallback : sanitized;
}

function copyEntry(entry: BatchExportEntry): BatchExportEntry {
  return {
    id: entry.id,
    displayName: entry.displayName,
    sourceUri: entry.sourceUri,
    outputPath: entry.outputPath,
    ownedPaths: entry.ownedPaths.slice(),
    fileName: entry.fileName,
    targetUri: entry.targetUri,
    status: entry.status,
    copySucceeded: entry.copySucceeded,
    exported: entry.exported,
    errorMessage: entry.errorMessage
  };
}

function formatError(error: Object, formatter?: (error: Object) => string): string {
  if (formatter !== undefined) {
    const formatted: string = formatter(error);
    if (formatted.length > 0) {
      return formatted;
    }
  }
  if (error instanceof Error && error.message.length > 0) {
    return error.message;
  }
  return String(error);
}

function appendAlias(aliases: Array<string>, value: string): void {
  if (value.length > 0 && !aliases.includes(value)) {
    aliases.push(value);
  }
}

/** Add a local path alias for the file URI forms returned by a picker. */
function appendFileUriPathAlias(aliases: Array<string>, value: string): void {
  if (value.startsWith('file:///')) {
    appendAlias(aliases, value.substring('file://'.length));
  } else if (value.startsWith('file://localhost/')) {
    appendAlias(aliases, value.substring('file://localhost'.length));
  }
}

function uriAliases(value: string): Array<string> {
  const aliases: Array<string> = [];
  appendAlias(aliases, value);
  appendFileUriPathAlias(aliases, value);
  try {
    const decoded: string = decodeURIComponent(value);
    appendAlias(aliases, decoded);
    appendFileUriPathAlias(aliases, decoded);
  } catch (error) {
    // A malformed percent escape is rejected by the leaf check below. Keep
    // the raw alias only so the error remains about the picker result.
  }
  return aliases;
}

/** Return the decoded final path segment of a picker URI. */
export function batchExportUriLeaf(uri: string): string {
  if (typeof uri !== 'string' || uri.length === 0 || uri.trim() !== uri) {
    return '';
  }
  const slash: number = uri.lastIndexOf('/');
  if (slash < 0 || slash === uri.length - 1) {
    return '';
  }
  const rawLeaf: string = uri.substring(slash + 1);
  try {
    const leaf: string = decodeURIComponent(rawLeaf);
    return leaf.length === 0 || leaf.includes('/') || leaf.includes('\\') ? '' : leaf;
  } catch (error) {
    return '';
  }
}

/**
 * Snapshot only currently usable successful outputs. A failed reconversion
 * may still expose its prior result, so status alone is deliberately not a
 * filter. The default action excludes already-exported results.
 */
export function buildBatchExportPlan(items: Array<QueueItem>, batchToken: string): Array<BatchExportEntry> {
  const token: string = safeToken(batchToken, '1');
  const plan: Array<BatchExportEntry> = [];
  let ordinal: number = 0;
  for (const item of items) {
    if (item.result === undefined || item.exportedUri.length > 0 || item.status === 'running' ||
      item.externalBusy || item.cleanupStatus !== 'none') {
      continue;
    }
    ordinal += 1;
    const modeKey: string = safeToken(item.result.modeKey, 'result');
    const id: string = safeToken(item.id, 'job');
    plan.push({
      id: item.id,
      displayName: item.displayName,
      sourceUri: item.sourceUri,
      outputPath: item.result.outputPath,
      ownedPaths: item.ownedPaths.slice(),
      fileName: 'xdremux-batch-' + id + '-' + modeKey + '-' + token + '-' + String(ordinal) + '.heic',
      targetUri: '',
      status: 'waiting',
      copySucceeded: false,
      exported: false,
      errorMessage: ''
    });
  }
  return plan;
}

/**
 * Validate and map one multi-file picker response before opening any target
 * FD. The platform documents an Array return but not its ordering, therefore
 * every URI must carry an exact requested filename in its final URI segment.
 * protectedPaths may include every queue source/owned path, including items
 * excluded from this batch, to prevent a target from replacing another task's
 * input or sandbox artifact.
 */
export function attachBatchExportTargets(
  entries: Array<BatchExportEntry>,
  savedUris: Array<string>,
  protectedPaths: Array<string> = []
): Array<BatchExportEntry> {
  if (savedUris.length !== entries.length) {
    throw new Error('系统保存选择器返回数量与批量文件数不符；未写入任何图片');
  }

  const byFileName: Map<string, BatchExportEntry> = new Map<string, BatchExportEntry>();
  const forbidden: Set<string> = new Set<string>();
  for (const entry of entries) {
    if (byFileName.has(entry.fileName)) {
      throw new Error('批量导出文件名重复；未写入任何图片');
    }
    byFileName.set(entry.fileName, entry);
    for (const alias of uriAliases(entry.sourceUri)) {
      forbidden.add(alias);
    }
    for (const path of entry.ownedPaths) {
      for (const alias of uriAliases(path)) {
        forbidden.add(alias);
      }
    }
  }
  for (const path of protectedPaths) {
    for (const alias of uriAliases(path)) {
      forbidden.add(alias);
    }
  }

  const matched: Map<string, string> = new Map<string, string>();
  const seenUri: Set<string> = new Set<string>();
  const seenAlias: Set<string> = new Set<string>();
  for (const candidate of savedUris) {
    if (typeof candidate !== 'string' || candidate.length === 0 || candidate.trim() !== candidate) {
      throw new Error('系统保存选择器返回空或无效 URI；未写入任何图片');
    }
    if (seenUri.has(candidate)) {
      throw new Error('系统保存选择器返回重复 URI；未写入任何图片');
    }
    seenUri.add(candidate);
    const aliases: Array<string> = uriAliases(candidate);
    for (const alias of aliases) {
      if (seenAlias.has(alias)) {
        throw new Error('系统保存选择器返回重复 URI；未写入任何图片');
      }
      seenAlias.add(alias);
      if (forbidden.has(alias)) {
        throw new Error('导出目标不能是输入或应用沙盒路径；未写入任何图片');
      }
    }
    const leaf: string = batchExportUriLeaf(candidate);
    const entry: BatchExportEntry | undefined = byFileName.get(leaf);
    if (entry === undefined) {
      throw new Error('系统返回 URI 无法与批量文件名可靠对应；未写入任何图片，请改用单项导出');
    }
    if (matched.has(entry.id)) {
      throw new Error('系统保存选择器返回重复文件映射；未写入任何图片');
    }
    matched.set(entry.id, candidate);
  }

  if (matched.size !== entries.length) {
    throw new Error('系统返回 URI 映射不完整；未写入任何图片，请改用单项导出');
  }
  return entries.map((entry: BatchExportEntry): BatchExportEntry => {
    const targetUri: string | undefined = matched.get(entry.id);
    if (targetUri === undefined) {
      throw new Error('批量导出目标映射不完整；未写入任何图片');
    }
    const copy: BatchExportEntry = copyEntry(entry);
    copy.targetUri = targetUri;
    return copy;
  });
}

export function summarizeBatchExport(entries: Array<BatchExportEntry>): BatchExportSummary {
  const summary: BatchExportSummary = {
    total: entries.length,
    waiting: 0,
    copying: 0,
    succeeded: 0,
    failed: 0,
    journalFailed: 0,
    canceled: 0,
    exported: 0
  };
  for (const entry of entries) {
    if (entry.status === 'waiting') summary.waiting += 1;
    else if (entry.status === 'copying') summary.copying += 1;
    else if (entry.status === 'succeeded') summary.succeeded += 1;
    else if (entry.status === 'failed') summary.failed += 1;
    else if (entry.status === 'journal-failed') summary.journalFailed += 1;
    else if (entry.status === 'canceled') summary.canceled += 1;
    if (entry.exported) summary.exported += 1;
  }
  return summary;
}

/** Mark a batch that could not enter FD copy (picker cancel or URI mapping
 * validation failure) without claiming that any destination was written. */
export function markBatchExportNotStarted(
  entries: Array<BatchExportEntry>,
  status: 'failed' | 'canceled',
  message: string
): Array<BatchExportEntry> {
  return entries.map((entry: BatchExportEntry): BatchExportEntry => {
    const copy: BatchExportEntry = copyEntry(entry);
    copy.status = status;
    copy.errorMessage = message;
    return copy;
  });
}

/** Mark only entries that have not reached the copy loop. Completed physical
 * writes and journal-failed facts must remain visible when a later setup step
 * fails or the page is torn down. */
export function markBatchExportWaiting(
  entries: Array<BatchExportEntry>,
  status: 'failed' | 'canceled',
  message: string
): Array<BatchExportEntry> {
  return entries.map((entry: BatchExportEntry): BatchExportEntry => {
    const copy: BatchExportEntry = copyEntry(entry);
    if (copy.status === 'waiting') {
      copy.status = status;
      copy.errorMessage = message;
    }
    return copy;
  });
}

function notify(entries: Array<BatchExportEntry>, callback?: (entries: Array<BatchExportEntry>) => void): void {
  if (callback !== undefined) {
    try {
      callback(entries.map((entry: BatchExportEntry): BatchExportEntry => copyEntry(entry)));
    } catch (error) {
      // A detached/rebuilding ArkUI view must not turn a completed FD copy
      // into a failed export or skip its journal checkpoint.
    }
  }
}

/** Run target copies strictly serially, isolating copy errors per item. */
export async function runBatchExport(
  initialEntries: Array<BatchExportEntry>,
  options: BatchExportRunOptions
): Promise<Array<BatchExportEntry>> {
  const entries: Array<BatchExportEntry> = initialEntries.map(
    (entry: BatchExportEntry): BatchExportEntry => copyEntry(entry)
  );
  const shouldStop: () => boolean = options.shouldStop === undefined
    ? (): boolean => false
    : options.shouldStop;
  notify(entries, options.onStatus);

  for (let index: number = 0; index < entries.length; index += 1) {
    const entry: BatchExportEntry = entries[index];
    if (entry.status !== 'waiting') {
      continue;
    }
    if (shouldStop()) {
      for (let cancelIndex: number = index; cancelIndex < entries.length; cancelIndex += 1) {
        if (entries[cancelIndex].status === 'waiting') {
          entries[cancelIndex].status = 'canceled';
          entries[cancelIndex].errorMessage = '已停止后续导出';
        }
      }
      notify(entries, options.onStatus);
      break;
    }

    entry.status = 'copying';
    entry.errorMessage = '';
    notify(entries, options.onStatus);
    try {
      await options.copy(entry);
      entry.copySucceeded = true;
      entry.exported = true;
      notify(entries, options.onStatus);
    } catch (error) {
      entry.status = 'failed';
      entry.errorMessage = formatError(error as Object, options.errorMessage);
      notify(entries, options.onStatus);
      continue;
    }

    try {
      await options.checkpoint(entry);
    } catch (error) {
      entry.status = 'journal-failed';
      entry.errorMessage = formatError(error as Object, options.errorMessage);
      for (let cancelIndex: number = index + 1; cancelIndex < entries.length; cancelIndex += 1) {
        if (entries[cancelIndex].status === 'waiting') {
          entries[cancelIndex].status = 'canceled';
          entries[cancelIndex].errorMessage = '队列记录保存失败，已停止后续导出';
        }
      }
      notify(entries, options.onStatus);
      break;
    }
    entry.status = 'succeeded';
    entry.errorMessage = '';
    notify(entries, options.onStatus);
  }
  return entries.map((entry: BatchExportEntry): BatchExportEntry => copyEntry(entry));
}
