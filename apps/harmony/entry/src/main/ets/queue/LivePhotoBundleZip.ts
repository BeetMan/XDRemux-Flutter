// Apple Live Photo `.pvt` bundle packaging for HarmonyOS export/share.
//
// Rust (`xdremux_make_live_photo_bundle`) writes `<stem>.pvt/` holding the
// paired HEIC, MOV and metadata.plist. The Harmony save picker and share
// panel only accept files, so the bundle travels as `<stem>.pvt.zip`: stored
// (no compression) entries prefixed with `<stem>.pvt/`, the same layout the
// Flutter app shares on Android/Windows/Linux/OHOS. Unzipping on a Mac yields
// the directory that Photos imports as one Live Photo.

export const PVT_METADATA_FILE: string = 'metadata.plist';
export const PVT_ZIP_MAX_BYTES: number = 0xFFFFFFFE;

export interface StoredZipEntry {
  name: string;
  data: Uint8Array;
}

export interface LivePhotoBundleFile {
  leaf: string;
  data: Uint8Array;
}

export interface LivePhotoBundleReport {
  bundlePath: string;
  stillPath: string;
  videoPath: string;
}

interface LivePhotoBundleRawReport {
  success?: Object;
  errorMessage?: Object;
  bundlePath?: Object;
  stillPath?: Object;
  videoPath?: Object;
}

function buildCrcTable(): Array<number> {
  const table: Array<number> = [];
  for (let n = 0; n < 256; n += 1) {
    let c: number = n;
    for (let k = 0; k < 8; k += 1) {
      c = (c & 1) !== 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table.push(c >>> 0);
  }
  return table;
}

const CRC_TABLE: Array<number> = buildCrcTable();

export function crc32(data: Uint8Array): number {
  let crc: number = 0xFFFFFFFF;
  for (let i = 0; i < data.length; i += 1) {
    crc = CRC_TABLE[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

function encodeAscii(value: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(value.length);
  for (let i = 0; i < value.length; i += 1) {
    const code: number = value.charCodeAt(i);
    if (code < 0x20 || code > 0x7E) throw new Error('zip 条目名必须是可打印 ASCII');
    bytes[i] = code;
  }
  return bytes;
}

/** MS-DOS date/time fields; the zip format cannot express years before 1980. */
export function dosDateTime(date: Date): Array<number> {
  const year: number = Math.max(1980, Math.min(2107, date.getFullYear()));
  const dosDate: number = ((year - 1980) << 9) | ((date.getMonth() + 1) << 5) | date.getDate();
  const dosTime: number = (date.getHours() << 11) | (date.getMinutes() << 5) | Math.floor(date.getSeconds() / 2);
  return [dosDate & 0xFFFF, dosTime & 0xFFFF];
}

/** Build a stored (method 0) zip without zip64; every entry and the total must stay under 4 GiB. */
export function buildStoredZip(entries: Array<StoredZipEntry>, modified: Date): Uint8Array {
  if (entries.length === 0 || entries.length > 0xFFFF) throw new Error('zip 条目数量无效');
  const [dosDate, dosTime] = dosDateTime(modified);
  const names: Array<Uint8Array> = [];
  const crcs: Array<number> = [];
  const seen: Set<string> = new Set<string>();
  let localBytes: number = 0;
  let centralBytes: number = 0;
  for (const entry of entries) {
    if (entry.name.length === 0 || entry.name.startsWith('/') || entry.name.includes('\\') ||
      entry.name.split('/').includes('..') || seen.has(entry.name)) {
      throw new Error('zip 条目名无效或重复：' + entry.name);
    }
    seen.add(entry.name);
    const name: Uint8Array = encodeAscii(entry.name);
    names.push(name);
    crcs.push(crc32(entry.data));
    localBytes += 30 + name.length + entry.data.length;
    centralBytes += 46 + name.length;
  }
  const total: number = localBytes + centralBytes + 22;
  if (total > PVT_ZIP_MAX_BYTES) throw new Error('.pvt 包超过 4 GiB，无法打包为 zip');

  const out: Uint8Array = new Uint8Array(total);
  const view: DataView = new DataView(out.buffer);
  const offsets: Array<number> = [];
  let p: number = 0;
  for (let i = 0; i < entries.length; i += 1) {
    const data: Uint8Array = entries[i].data;
    offsets.push(p);
    view.setUint32(p, 0x04034B50, true);
    view.setUint16(p + 4, 10, true);
    view.setUint16(p + 6, 0, true);
    view.setUint16(p + 8, 0, true);
    view.setUint16(p + 10, dosTime, true);
    view.setUint16(p + 12, dosDate, true);
    view.setUint32(p + 14, crcs[i], true);
    view.setUint32(p + 18, data.length, true);
    view.setUint32(p + 22, data.length, true);
    view.setUint16(p + 26, names[i].length, true);
    view.setUint16(p + 28, 0, true);
    out.set(names[i], p + 30);
    out.set(data, p + 30 + names[i].length);
    p += 30 + names[i].length + data.length;
  }
  const centralStart: number = p;
  for (let i = 0; i < entries.length; i += 1) {
    const size: number = entries[i].data.length;
    view.setUint32(p, 0x02014B50, true);
    view.setUint16(p + 4, (3 << 8) | 20, true);
    view.setUint16(p + 6, 10, true);
    view.setUint16(p + 8, 0, true);
    view.setUint16(p + 10, 0, true);
    view.setUint16(p + 12, dosTime, true);
    view.setUint16(p + 14, dosDate, true);
    view.setUint32(p + 16, crcs[i], true);
    view.setUint32(p + 20, size, true);
    view.setUint32(p + 24, size, true);
    view.setUint16(p + 28, names[i].length, true);
    view.setUint16(p + 30, 0, true);
    view.setUint16(p + 32, 0, true);
    view.setUint16(p + 34, 0, true);
    view.setUint16(p + 36, 0, true);
    // Unix mode 0644 regular file in the high 16 bits.
    view.setUint32(p + 38, (0o100644 << 16) >>> 0, true);
    view.setUint32(p + 42, offsets[i], true);
    out.set(names[i], p + 46);
    p += 46 + names[i].length;
  }
  view.setUint32(p, 0x06054B50, true);
  view.setUint16(p + 4, 0, true);
  view.setUint16(p + 6, 0, true);
  view.setUint16(p + 8, entries.length, true);
  view.setUint16(p + 10, entries.length, true);
  view.setUint32(p + 12, p - centralStart, true);
  view.setUint32(p + 16, centralStart, true);
  view.setUint16(p + 20, 0, true);
  return out;
}

function leafOf(path: string): string {
  const slash: number = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

function stemOf(leaf: string): string {
  const dot: number = leaf.lastIndexOf('.');
  return dot <= 0 ? '' : leaf.substring(0, dot);
}

function extensionOf(leaf: string): string {
  const dot: number = leaf.lastIndexOf('.');
  return dot <= 0 ? '' : leaf.substring(dot + 1).toLowerCase();
}

/** `<stem>.pvt` directory name; Rust names the HEIC/MOV inside after the same stem. */
export function livePhotoBundleName(stem: string): string {
  if (stem.length === 0 || !/^[A-Za-z0-9_-]+$/.test(stem)) {
    throw new Error('Live Photo 文件名不能用于 .pvt 包');
  }
  return stem + '.pvt';
}

/**
 * Order and prefix the bundle files as zip entries: still, MOV, metadata.plist.
 * Hidden files (`.DS_Store`, staging leftovers) are skipped, as in Flutter.
 */
export function livePhotoBundleZipEntries(
  bundleName: string,
  files: Array<LivePhotoBundleFile>
): Array<StoredZipEntry> {
  if (!/^[A-Za-z0-9_-]+\.pvt$/.test(bundleName)) throw new Error('.pvt 包名无效');
  const visible: Array<LivePhotoBundleFile> = files.filter((file: LivePhotoBundleFile): boolean =>
    !file.leaf.startsWith('.'));
  const stills: Array<LivePhotoBundleFile> = visible.filter((file: LivePhotoBundleFile): boolean =>
    ['heic', 'heif', 'jpg', 'jpeg'].includes(extensionOf(file.leaf)));
  const movies: Array<LivePhotoBundleFile> = visible.filter((file: LivePhotoBundleFile): boolean =>
    extensionOf(file.leaf) === 'mov');
  const metadata: Array<LivePhotoBundleFile> = visible.filter((file: LivePhotoBundleFile): boolean =>
    file.leaf === PVT_METADATA_FILE);
  if (stills.length !== 1 || movies.length !== 1 || metadata.length !== 1 ||
    visible.length !== 3) {
    throw new Error('.pvt 包必须只包含一张静态图、一个 MOV 和 metadata.plist');
  }
  if (stemOf(stills[0].leaf) !== stemOf(movies[0].leaf)) {
    throw new Error('.pvt 包内静态图和 MOV 文件名不一致');
  }
  for (const file of visible) {
    if (file.leaf.includes('/') || file.data.length === 0) throw new Error('.pvt 包内文件无效：' + file.leaf);
  }
  return [stills[0], movies[0], metadata[0]].map((file: LivePhotoBundleFile): StoredZipEntry => ({
    name: bundleName + '/' + file.leaf,
    data: file.data
  }));
}

/** Parse the Rust bundle report and require every path inside the requested bundle. */
export function parseLivePhotoBundleReport(rawJson: string, bundlePath: string): LivePhotoBundleReport {
  let parsed: Object;
  try {
    parsed = JSON.parse(rawJson) as Object;
  } catch (error) {
    throw new Error('.pvt 原生报告无法解析');
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('.pvt 原生报告必须是对象');
  }
  const report: LivePhotoBundleRawReport = parsed as LivePhotoBundleRawReport;
  if (report.success !== true) {
    if (typeof report.errorMessage === 'string' && report.errorMessage.length > 0) {
      throw new Error(report.errorMessage as string);
    }
    throw new Error('.pvt 原生打包失败');
  }
  if (report.bundlePath !== bundlePath || typeof report.stillPath !== 'string' ||
    typeof report.videoPath !== 'string') {
    throw new Error('.pvt 报告路径与请求不一致');
  }
  const stillPath: string = report.stillPath as string;
  const videoPath: string = report.videoPath as string;
  for (const path of [stillPath, videoPath]) {
    if (!path.startsWith(bundlePath + '/') || path.substring(bundlePath.length + 1).includes('/')) {
      throw new Error('.pvt 报告文件不在包目录内');
    }
  }
  return { bundlePath: bundlePath, stillPath: stillPath, videoPath: videoPath };
}
