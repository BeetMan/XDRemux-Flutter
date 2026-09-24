export const SHARE_IMPORT_ACTION: string = 'ohos.want.action.sendData';
export const MAX_SHARED_IMAGES: number = 15;

export interface SharedImageCandidate {
  utd?: string;
  uri?: string;
  title?: string;
}

export interface SupportedSharedImage {
  uri: string;
  displayName: string;
  extension: string;
}

export type ShareInboxItemStatus = 'copying' | 'ready' | 'failed';

export interface ShareInboxItem {
  id: string;
  status: ShareInboxItemStatus;
  sourceUri: string;
  displayName: string;
  inputPath: string;
  errorMessage: string;
}

export interface ShareInboxSnapshot {
  nextId: number;
  notice: string;
  items: Array<ShareInboxItem>;
}

export interface SharedImageFilterResult {
  images: Array<SupportedSharedImage>;
  ignored: number;
  truncated: number;
}

const SUPPORTED_EXTENSIONS: Array<string> = ['.heic', '.heif', '.jpg', '.jpeg'];

export function emptyShareInboxSnapshot(): ShareInboxSnapshot {
  return { nextId: 1, notice: '', items: [] };
}

function safeExtension(uri: string): string {
  const end: number = Math.min(
    uri.indexOf('?') < 0 ? uri.length : uri.indexOf('?'),
    uri.indexOf('#') < 0 ? uri.length : uri.indexOf('#')
  );
  const plain: string = uri.substring(0, end).toLowerCase();
  const slash: number = plain.lastIndexOf('/');
  const dot: number = plain.lastIndexOf('.');
  if (dot <= slash) return '';
  const extension: string = plain.substring(dot);
  return SUPPORTED_EXTENSIONS.includes(extension) ? extension : '';
}

function extensionForUtd(utd: string): string {
  if (utd === 'general.heic') return '.heic';
  if (utd === 'general.heif') return '.heif';
  if (utd === 'general.jpeg') return '.jpg';
  return '';
}

function nameFromUri(uri: string): string {
  const end: number = Math.min(
    uri.indexOf('?') < 0 ? uri.length : uri.indexOf('?'),
    uri.indexOf('#') < 0 ? uri.length : uri.indexOf('#')
  );
  const plain: string = uri.substring(0, end);
  const slash: number = plain.lastIndexOf('/');
  let name: string = plain.substring(slash + 1);
  try {
    name = decodeURIComponent(name);
  } catch (error) {
    // Keep the original name when a provider returns a malformed escape.
  }
  return name.length > 0 ? name : '分享图片';
}

/** Accept only file-backed HEIF/JPEG records. Text, links, records without a
 * URI, ambiguous general.image records, and unsupported image formats are
 * deliberately ignored. Duplicate URIs within one Share Kit batch are kept
 * once, while a separate user share remains a separate import. */
export function filterSharedImages(records: Array<SharedImageCandidate>): SharedImageFilterResult {
  const images: Array<SupportedSharedImage> = [];
  const seenUris: Set<string> = new Set<string>();
  let ignored: number = 0;
  let truncated: number = 0;
  for (const record of records) {
    const uri: string | undefined = record.uri;
    const utd: string | undefined = record.utd;
    if (uri === undefined || uri.length === 0 || uri.includes('\u0000') || utd === undefined) {
      ignored += 1;
      continue;
    }
    const uriExtension: string = safeExtension(uri);
    const utdExtension: string = extensionForUtd(utd);
    let extension: string = '';
    if (utd === 'general.image') {
      extension = uriExtension;
    } else if (utdExtension.length > 0 && (uriExtension.length === 0 || uriExtension === utdExtension ||
      (utdExtension === '.jpg' && uriExtension === '.jpeg') ||
      (utdExtension === '.heic' && uriExtension === '.heif') ||
      (utdExtension === '.heif' && uriExtension === '.heic'))) {
      extension = uriExtension.length > 0 ? uriExtension : utdExtension;
    }
    if (extension.length === 0) {
      ignored += 1;
      continue;
    }
    if (seenUris.has(uri)) {
      ignored += 1;
      continue;
    }
    seenUris.add(uri);
    if (images.length >= MAX_SHARED_IMAGES) {
      truncated += 1;
      continue;
    }
    const title: string | undefined = record.title;
    const displayName: string = title !== undefined && title.trim().length > 0
      ? title.trim()
      : nameFromUri(uri);
    images.push({ uri: uri, displayName: displayName, extension: extension });
  }
  return { images: images, ignored: ignored, truncated: truncated };
}

export function shareInboxInputPath(root: string, id: string, extension: string): string {
  if (root.length === 0 || root.includes('\u0000') || root.includes('://') || root.includes('..') ||
    root.includes('\\')) {
    throw new Error('分享导入沙盒根目录无效');
  }
  if (!/^share-[1-9][0-9]*$/.test(id) || !SUPPORTED_EXTENSIONS.includes(extension)) {
    throw new Error('分享导入路径参数无效');
  }
  const normalizedRoot: string = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  // This file lives in inputs/ but has a share-* leaf until ownership is
  // transferred to the durable queue. QueueSandbox ignores it as an orphan
  // candidate, so maintenance cannot remove an unconsumed share.
  return normalizedRoot + '/inputs/' + id + extension;
}

export function addShareInboxItem(
  snapshot: ShareInboxSnapshot,
  image: SupportedSharedImage,
  root: string
): { snapshot: ShareInboxSnapshot; item: ShareInboxItem } {
  if (!Number.isSafeInteger(snapshot.nextId) || snapshot.nextId < 1) {
    throw new Error('分享收件箱 nextId 无效');
  }
  const id: string = 'share-' + String(snapshot.nextId);
  const item: ShareInboxItem = {
    id: id,
    status: 'copying',
    sourceUri: image.uri,
    displayName: image.displayName,
    inputPath: shareInboxInputPath(root, id, image.extension),
    errorMessage: ''
  };
  return {
    snapshot: { nextId: snapshot.nextId + 1, notice: snapshot.notice, items: [...snapshot.items, item] },
    item: { ...item }
  };
}

export function updateShareInboxItem(
  snapshot: ShareInboxSnapshot,
  id: string,
  status: ShareInboxItemStatus,
  inputPath: string,
  errorMessage: string
): ShareInboxSnapshot {
  let found: boolean = false;
  const items: Array<ShareInboxItem> = snapshot.items.map((item: ShareInboxItem): ShareInboxItem => {
    if (item.id !== id) return { ...item };
    found = true;
    return { ...item, status: status, inputPath: inputPath, errorMessage: errorMessage };
  });
  if (!found) throw new Error('分享收件箱项目不存在：' + id);
  return { nextId: snapshot.nextId, notice: snapshot.notice, items: items };
}

export function removeShareInboxItem(snapshot: ShareInboxSnapshot, id: string): ShareInboxSnapshot {
  return {
    nextId: snapshot.nextId,
    notice: snapshot.notice,
    items: snapshot.items.filter((item: ShareInboxItem): boolean => item.id !== id).map(
      (item: ShareInboxItem): ShareInboxItem => ({ ...item })
    )
  };
}

/** The inbox remains the recovery owner until the queue journal commits. */
export async function persistQueueBeforeInboxRemoval(
  persistQueue: () => Promise<void>,
  removeInboxItem: () => Promise<void>
): Promise<void> {
  await persistQueue();
  await removeInboxItem();
}

export function validateShareInboxSnapshot(value: Object, root: string): ShareInboxSnapshot {
  const raw = value as { schema?: Object; nextId?: Object; notice?: Object; items?: Object };
  if (raw.schema !== 1 || !Number.isSafeInteger(raw.nextId) || (raw.nextId as number) < 1 ||
    typeof raw.notice !== 'string' || !Array.isArray(raw.items)) {
    throw new Error('分享收件箱记录结构无效');
  }
  const items: Array<ShareInboxItem> = [];
  const ids: Set<string> = new Set<string>();
  const paths: Set<string> = new Set<string>();
  let highestId: number = 0;
  for (const candidate of raw.items as Array<Object>) {
    if (typeof candidate !== 'object' || candidate === null) throw new Error('分享收件箱项目无效');
    const item = candidate as { id?: Object; status?: Object; sourceUri?: Object; displayName?: Object;
      inputPath?: Object; errorMessage?: Object };
    if (typeof item.id !== 'string' || !/^share-[1-9][0-9]*$/.test(item.id) || ids.has(item.id) ||
      (item.status !== 'copying' && item.status !== 'ready' && item.status !== 'failed') ||
      typeof item.sourceUri !== 'string' || item.sourceUri.length === 0 || item.sourceUri.includes('\u0000') ||
      typeof item.displayName !== 'string' || item.displayName.includes('\u0000') ||
      typeof item.inputPath !== 'string' || item.inputPath.includes('\u0000') ||
      typeof item.errorMessage !== 'string' || item.errorMessage.includes('\u0000')) {
      throw new Error('分享收件箱项目字段无效');
    }
    if ((item.status === 'ready' && item.inputPath.length === 0) ||
      (item.status === 'copying' && item.inputPath.length === 0)) {
      throw new Error('分享收件箱项目状态与路径不匹配');
    }
    if (item.inputPath.length > 0) {
      const allowedPrefix: string = (root.endsWith('/') ? root.substring(0, root.length - 1) : root) + '/inputs/share-';
      const leaf: string = item.inputPath.substring(allowedPrefix.length);
      const leafDot: number = leaf.lastIndexOf('.');
      if (!item.inputPath.startsWith(allowedPrefix) || leaf.includes('/') || leaf.includes('\\') ||
        !/^([1-9][0-9]*)(\.heic|\.heif|\.jpg|\.jpeg)$/.test(leaf) ||
        item.id.substring('share-'.length) !== leaf.substring(0, leafDot) || paths.has(item.inputPath)) {
        throw new Error('分享收件箱路径无效或重复');
      }
      paths.add(item.inputPath);
    }
    ids.add(item.id);
    highestId = Math.max(highestId, Number(item.id.substring('share-'.length)));
    items.push({
      id: item.id,
      status: item.status as ShareInboxItemStatus,
      sourceUri: item.sourceUri,
      displayName: item.displayName,
      inputPath: item.inputPath,
      errorMessage: item.errorMessage
    });
  }
  if (!Number.isSafeInteger(highestId) || (raw.nextId as number) <= highestId) {
    throw new Error('分享收件箱 nextId 会造成 ID 冲突');
  }
  return { nextId: raw.nextId as number, notice: raw.notice, items: items };
}

export function serializeShareInboxSnapshot(snapshot: ShareInboxSnapshot, root: string): string {
  const validated: ShareInboxSnapshot = validateShareInboxSnapshot({
    schema: 1,
    nextId: snapshot.nextId,
    notice: snapshot.notice,
    items: snapshot.items
  } as Object, root);
  let highestId: number = 0;
  for (const item of validated.items) {
    const numeric: number = Number(item.id.substring('share-'.length));
    if (!Number.isSafeInteger(numeric)) throw new Error('分享收件箱 ID 超出安全范围');
    highestId = Math.max(highestId, numeric);
  }
  if (validated.nextId <= highestId) throw new Error('分享收件箱 nextId 会造成 ID 冲突');
  return JSON.stringify({ schema: 1, nextId: validated.nextId, notice: validated.notice, items: validated.items });
}

/** A single Want object delivered through duplicate lifecycle callbacks is
 * accepted only once. Distinct Want objects remain distinct user actions. */
export class WantReferenceGuard<T extends Object> {
  private readonly handled: Array<T> = [];

  public claim(want: T): boolean {
    if (this.handled.includes(want)) return false;
    this.handled.push(want);
    if (this.handled.length > 16) this.handled.shift();
    return true;
  }
}
