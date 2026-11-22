// Pure helpers for the transfer sheet: inbox grouping, Live Photo bundles,
// device naming and the subnet-scan target list. No I/O here, so the rules
// are covered by host tests (tests/transfer_inbox_test.mjs).
import type { TransferReceipt } from './TransferModel.ts';

export type TransferInboxKind = 'photo' | 'live' | 'live-zip' | 'file';

/** One inbox row. A loose Live Photo pair shows as one row carrying both receipts. */
export interface TransferInboxEntry {
  kind: TransferInboxKind;
  receipt: TransferReceipt;
  movie: TransferReceipt | undefined;
}

const STILL_EXTENSIONS: Array<string> = ['heic', 'heif', 'jpg', 'jpeg'];
const PHOTO_EXTENSIONS: Array<string> = ['heic', 'heif', 'jpg', 'jpeg', 'png'];

function extensionOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
}

function stemOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/** LocalSend moves files, not folders, so a `.pvt` Live Photo travels as `<stem>.pvt.zip`. */
export function isLivePhotoZipName(name: string): boolean {
  return name.toLowerCase().endsWith('.pvt.zip') && name.length > '.pvt.zip'.length;
}

export function isTransferStillName(name: string): boolean {
  return STILL_EXTENSIONS.includes(extensionOf(name));
}

export function isTransferPhotoFile(name: string): boolean {
  return PHOTO_EXTENSIONS.includes(extensionOf(name));
}

/**
 * Group receipts for display. A still and a MOV from the same session with the
 * same stem (how LocalSend on iPhone sends a Live Photo) become one 'live' row;
 * the MOV does not get its own row. Order follows the input (newest first).
 */
export function groupTransferInbox(receipts: Array<TransferReceipt>): Array<TransferInboxEntry> {
  const movies: Map<string, TransferReceipt> = new Map<string, TransferReceipt>();
  for (const receipt of receipts) {
    if (extensionOf(receipt.name) === 'mov') {
      movies.set(receipt.sessionId + '\u0000' + stemOf(receipt.name).toLowerCase(), receipt);
    }
  }
  const pairedMovies: Set<string> = new Set<string>();
  const stillEntries: Map<string, TransferInboxEntry> = new Map<string, TransferInboxEntry>();
  for (const receipt of receipts) {
    if (!isTransferStillName(receipt.name)) continue;
    const movie: TransferReceipt | undefined =
      movies.get(receipt.sessionId + '\u0000' + stemOf(receipt.name).toLowerCase());
    if (movie !== undefined && !pairedMovies.has(movie.id)) {
      pairedMovies.add(movie.id);
      stillEntries.set(receipt.id, { kind: 'live', receipt: receipt, movie: movie });
    }
  }
  const entries: Array<TransferInboxEntry> = [];
  for (const receipt of receipts) {
    if (pairedMovies.has(receipt.id)) continue;
    const live: TransferInboxEntry | undefined = stillEntries.get(receipt.id);
    if (live !== undefined) {
      entries.push(live);
    } else if (isLivePhotoZipName(receipt.name)) {
      entries.push({ kind: 'live-zip', receipt: receipt, movie: undefined });
    } else if (isTransferPhotoFile(receipt.name)) {
      entries.push({ kind: 'photo', receipt: receipt, movie: undefined });
    } else {
      entries.push({ kind: 'file', receipt: receipt, movie: undefined });
    }
  }
  return entries;
}

export interface LivePhotoBundleParts {
  still: string;
  movie: string;
}

/**
 * Validate the entry names of a received `<stem>.pvt.zip` after extraction:
 * only flat files under `<stem>.pvt/`, no hidden or nested paths, and exactly
 * one still plus one MOV. Returns their leaf names.
 */
export function validateLivePhotoBundleEntries(zipName: string, entries: Array<string>): LivePhotoBundleParts {
  if (!isLivePhotoZipName(zipName)) throw new Error('不是 .pvt.zip');
  const bundle: string = zipName.substring(0, zipName.length - '.zip'.length);
  const leaves: Array<string> = [];
  for (const entry of entries) {
    const parts: Array<string> = entry.split('/').filter((part: string): boolean => part.length > 0);
    if (parts.length === 1 && parts[0] === bundle && entry.endsWith('/')) continue;
    if (parts.length !== 2 || parts[0] !== bundle || parts[1].startsWith('.') ||
      parts[1].includes('\\') || parts[1] === '..') {
      throw new Error('.pvt 包结构无效');
    }
    leaves.push(parts[1]);
  }
  const stills: Array<string> = leaves.filter((leaf: string): boolean => isTransferStillName(leaf));
  const movies: Array<string> = leaves.filter((leaf: string): boolean => extensionOf(leaf) === 'mov');
  if (stills.length !== 1 || movies.length !== 1) throw new Error('.pvt 包必须包含一张照片和一个 MOV');
  return { still: stills[0], movie: movies[0] };
}

/** Trim, drop control characters and cap at 64 characters; blank means "use the model name". */
export function cleanTransferDeviceName(name: string): string {
  const clean: string = name.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  return clean.length > 64 ? clean.substring(0, 64) : clean;
}

export interface TransferScanTarget {
  host: string;
  port: number;
}

export const LOCALSEND_PORTS: Array<number> = [53319, 53317];

function isPrivateIPv4(address: string): boolean {
  const parts: Array<number> = address.split('.').map((part: string): number => Number(part));
  if (parts.length !== 4 || parts.some((part: number): boolean => !Number.isInteger(part) || part < 0 || part > 255)) {
    return false;
  }
  return parts[0] === 10 || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
    (parts[0] === 192 && parts[1] === 168);
}

/**
 * LocalSend's fallback when multicast stays quiet: every /24 neighbour of this
 * device's private IPv4 addresses on both LocalSend ports, excluding itself.
 */
export function transferScanTargets(ownAddresses: Array<string>): Array<TransferScanTarget> {
  const own: Array<string> = ownAddresses.filter(isPrivateIPv4);
  const prefixes: Set<string> = new Set<string>(own.map((address: string): string =>
    address.substring(0, address.lastIndexOf('.'))));
  const targets: Array<TransferScanTarget> = [];
  for (const prefix of prefixes) {
    for (let i = 1; i < 255; i += 1) {
      const host: string = prefix + '.' + String(i);
      if (own.includes(host)) continue;
      for (const port of LOCALSEND_PORTS) targets.push({ host: host, port: port });
    }
  }
  return targets;
}

/** "IP:port" for a manually typed peer; rejects anything but a dotted IPv4. */
export function parseTransferAddress(input: string, defaultPort: number): string {
  const text: string = input.trim();
  const match: RegExpMatchArray | null = text.match(/^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?$/);
  if (match === null) throw new Error('请输入 IPv4 地址，例如 192.168.1.20');
  const host: string = match[1];
  if (host.split('.').some((part: string): boolean => Number(part) > 255)) throw new Error('IP 地址无效');
  const port: number = match[2] === undefined ? defaultPort : Number(match[2]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('端口无效');
  return host + ':' + String(port);
}
