export const GALLERY_LIBRARY_SCHEMA: number = 1;
export const GALLERY_LIBRARY_DIRECTORY: string = 'xdremux-gallery';
export const GALLERY_LIBRARY_MANIFEST: string = 'library.json';

export interface GalleryLibraryItem {
  id: string;
  displayName: string;
  extension: string;
  mimeType: string;
  size: number;
  importedAt: number;
}

export interface GalleryLibraryRecord {
  schema: number;
  items: Array<GalleryLibraryItem>;
}

const UUID_PATTERN: RegExp = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const EXTENSION_PATTERN: RegExp = /^\.[a-z0-9]{1,12}$/;

export function galleryMimeTypeForExtension(extension: string): string {
  const normalized: string = extension.toLowerCase();
  if (normalized === '.heic' || normalized === '.heif') return 'image/heic';
  if (normalized === '.jpg' || normalized === '.jpeg') return 'image/jpeg';
  if (normalized === '.png') return 'image/png';
  if (normalized === '.webp') return 'image/webp';
  if (normalized === '.gif') return 'image/gif';
  if (normalized === '.tif' || normalized === '.tiff') return 'image/tiff';
  if (normalized === '.bmp') return 'image/bmp';
  return 'application/octet-stream';
}

export function galleryExtensionFromName(name: string): string {
  const withoutQuery: string = name.split('?')[0].split('#')[0];
  const slash: number = Math.max(withoutQuery.lastIndexOf('/'), withoutQuery.lastIndexOf('\\'));
  const baseName: string = withoutQuery.substring(slash + 1);
  const dot: number = baseName.lastIndexOf('.');
  if (dot <= 0 || dot === baseName.length - 1) return '.img';
  const extension: string = baseName.substring(dot).toLowerCase();
  return EXTENSION_PATTERN.test(extension) ? extension : '.img';
}

export function galleryItemPath(root: string, item: GalleryLibraryItem): string {
  return root + '/items/' + item.id + item.extension;
}

export function emptyGalleryLibrary(): GalleryLibraryRecord {
  return { schema: GALLERY_LIBRARY_SCHEMA, items: [] };
}

export function encodeGalleryLibrary(items: Array<GalleryLibraryItem>): string {
  const normalized: Array<GalleryLibraryItem> = validateGalleryItems(items);
  const record: GalleryLibraryRecord = { schema: GALLERY_LIBRARY_SCHEMA, items: normalized };
  return JSON.stringify(record);
}

export function decodeGalleryLibrary(raw: string): GalleryLibraryRecord {
  const parsed: Object = JSON.parse(raw) as Object;
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('图库索引不是有效对象');
  }
  const record: Record<string, Object> = parsed as Record<string, Object>;
  if (record.schema !== GALLERY_LIBRARY_SCHEMA || !Array.isArray(record.items)) {
    throw new Error('图库索引版本或项目列表无效');
  }
  return { schema: GALLERY_LIBRARY_SCHEMA, items: validateGalleryItems(record.items as Array<GalleryLibraryItem>) };
}

function validateGalleryItems(items: Array<GalleryLibraryItem>): Array<GalleryLibraryItem> {
  if (!Array.isArray(items) || items.length > 10000) {
    throw new Error('图库项目数量无效');
  }
  const seen: Set<string> = new Set<string>();
  const validated: Array<GalleryLibraryItem> = [];
  for (const item of items) {
    if (item === null || typeof item !== 'object') throw new Error('图库项目格式无效');
    if (typeof item.id !== 'string' || !UUID_PATTERN.test(item.id) || seen.has(item.id)) {
      throw new Error('图库项目标识无效或重复');
    }
    if (typeof item.displayName !== 'string' || item.displayName.length === 0 || item.displayName.length > 512) {
      throw new Error('图库项目名称无效');
    }
    if (typeof item.extension !== 'string' || !EXTENSION_PATTERN.test(item.extension) ||
      item.extension !== item.extension.toLowerCase()) {
      throw new Error('图库项目扩展名无效');
    }
    if (typeof item.mimeType !== 'string' || item.mimeType.length === 0 || item.mimeType.length > 128) {
      throw new Error('图库项目媒体类型无效');
    }
    if (typeof item.size !== 'number' || !Number.isSafeInteger(item.size) || item.size <= 0) {
      throw new Error('图库项目文件大小无效');
    }
    if (typeof item.importedAt !== 'number' || !Number.isSafeInteger(item.importedAt) || item.importedAt < 0) {
      throw new Error('图库项目导入时间无效');
    }
    seen.add(item.id);
    validated.push({
      id: item.id,
      displayName: item.displayName,
      extension: item.extension,
      mimeType: item.mimeType,
      size: item.size,
      importedAt: item.importedAt
    });
  }
  return validated;
}
