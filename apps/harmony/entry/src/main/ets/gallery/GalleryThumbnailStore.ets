import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import {
  GALLERY_THUMBNAIL_DIRECTORY,
  GALLERY_THUMBNAIL_JPEG_QUALITY,
  GalleryThumbnailQueue,
  galleryExifOrientation,
  galleryOrientationSteps,
  galleryOrientationSwapsAxes,
  galleryThumbnailDecodeSize,
  galleryThumbnailFileName,
  parseGalleryThumbnailFileName
} from './GalleryThumbnailModel';
import type {
  GalleryOrientationStep,
  GallerySize,
  GalleryThumbnailName,
  GalleryThumbnailSource
} from './GalleryThumbnailModel';

export interface GalleryThumbnailInfo {
  /** Absolute path of the thumbnail JPEG (already upright, no EXIF). */
  path: string;
  /** Displayed (EXIF-upright) size of the original photo. */
  width: number;
  height: number;
}

export interface GalleryDecodedImage {
  pixelMap: image.PixelMap;
  /** Displayed (EXIF-upright) size of the source image, not of the decode. */
  width: number;
  height: number;
}

interface GalleryThumbnailFileError {
  code?: number;
  message?: string;
}

/** Tiles waiting on screen get two decoders; the background fill gets one. */
const GALLERY_THUMBNAIL_WORKERS: number = 2;
const NO_SUCH_FILE: number = 13900002;

async function readOrientation(source: image.ImageSource): Promise<number> {
  try {
    return galleryExifOrientation(await source.getImageProperty(image.PropertyKey.ORIENTATION));
  } catch (error) {
    // No EXIF (PNG, WebP, many edited files): the pixels are stored upright.
    return 1;
  }
}

async function applyOrientation(pixelMap: image.PixelMap, orientation: number): Promise<void> {
  const step: GalleryOrientationStep = galleryOrientationSteps(orientation);
  if (step.rotate !== 0) await pixelMap.rotate(step.rotate);
  if (step.flipHorizontal || step.flipVertical) await pixelMap.flip(step.flipHorizontal, step.flipVertical);
}

/**
 * Decode a reduced SDR copy of a photo and turn it upright by its EXIF
 * orientation. The image framework decodes the stored pixels as they are;
 * EXIF is applied only by the Image component's AUTO orientation, and only
 * for files, so PixelMaps must be rotated here. `sizeFor` receives the
 * stored size and returns the decode size.
 */
export async function decodeGalleryPixelMap(
  path: string,
  sizeFor: (width: number, height: number) => GallerySize
): Promise<GalleryDecodedImage> {
  const source: image.ImageSource | undefined = image.createImageSource('file://' + path);
  if (source === undefined) throw new Error('无法打开照片');
  let pixelMap: image.PixelMap | undefined = undefined;
  try {
    const info: image.ImageInfo = await source.getImageInfo();
    const width: number = info.size.width;
    const height: number = info.size.height;
    if (width <= 0 || height <= 0) throw new Error('无法读取照片尺寸');
    const orientation: number = await readOrientation(source);
    pixelMap = await source.createPixelMap({
      desiredSize: sizeFor(width, height),
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      desiredDynamicRange: image.DecodingDynamicRange.SDR
    });
    if (pixelMap === undefined) throw new Error('无法解码照片');
    await applyOrientation(pixelMap, orientation);
    const swapped: boolean = galleryOrientationSwapsAxes(orientation);
    const decoded: GalleryDecodedImage = {
      pixelMap: pixelMap,
      width: swapped ? height : width,
      height: swapped ? width : height
    };
    pixelMap = undefined;
    return decoded;
  } finally {
    if (pixelMap !== undefined) {
      try {
        await pixelMap.release();
      } catch (releaseError) {
        // The decode failed after allocation; nothing else holds it.
      }
    }
    try {
      await source.release();
    } catch (releaseError) {
      // A decoded PixelMap does not depend on its source.
    }
  }
}

/**
 * Owns thumbs-v1/ under the gallery root: indexes existing thumbnails on
 * load, makes missing ones (tiles on screen first, then the rest of the
 * library in the background) and deletes them with their photo.
 */
export class GalleryThumbnailStore {
  private readonly directory: string;
  private readonly known: Map<string, GalleryThumbnailInfo> = new Map<string, GalleryThumbnailInfo>();
  private readonly failed: Set<string> = new Set<string>();
  private readonly running: Set<string> = new Set<string>();
  private readonly regenerated: Set<string> = new Set<string>();
  /** Library photos, id → original path. Work for any other id is dropped. */
  private readonly sources: Map<string, string> = new Map<string, string>();
  private readonly queue: GalleryThumbnailQueue = new GalleryThumbnailQueue();
  private backgroundEnabled: boolean = false;
  private paused: boolean = false;
  private disposed: boolean = false;
  private listener: ((id: string, info: GalleryThumbnailInfo | undefined) => void) | undefined = undefined;

  constructor(galleryRoot: string) {
    this.directory = galleryRoot + '/' + GALLERY_THUMBNAIL_DIRECTORY;
  }

  /** Called when a thumbnail is ready, or with undefined when the photo has to be shown from its original. */
  public setListener(listener: (id: string, info: GalleryThumbnailInfo | undefined) => void): void {
    this.listener = listener;
  }

  /** Index the thumbnails on disk for these photos and delete everything else in the folder. */
  public async load(photos: Array<GalleryThumbnailSource>): Promise<void> {
    this.queue.clear();
    this.known.clear();
    this.failed.clear();
    this.sources.clear();
    this.backgroundEnabled = false;
    for (const photo of photos) this.sources.set(photo.id, photo.path);
    await this.ensureDirectory();
    for (const name of await fileIo.listFile(this.directory)) {
      const path: string = this.directory + '/' + name;
      const parsed: GalleryThumbnailName | undefined = parseGalleryThumbnailFileName(name);
      if (parsed === undefined || !this.sources.has(parsed.id) || this.known.has(parsed.id)) {
        // Temp files of an interrupted write, thumbnails of deleted photos, duplicates.
        if (!this.isRunningTemporary(name)) await this.unlinkQuietly(path);
        continue;
      }
      this.known.set(parsed.id, { path: path, width: parsed.width, height: parsed.height });
    }
  }

  public lookup(id: string): GalleryThumbnailInfo | undefined {
    return this.known.get(id);
  }

  public hasFailed(id: string): boolean {
    return this.failed.has(id);
  }

  public forEachKnown(visit: (id: string, info: GalleryThumbnailInfo) => void): void {
    this.known.forEach((info: GalleryThumbnailInfo, id: string): void => {
      visit(id, info);
    });
  }

  /** A grid tile was built (on screen or in the preload rows): make its thumbnail next. */
  public request(id: string, path: string): void {
    if (this.disposed || this.known.has(id) || this.failed.has(id)) return;
    this.sources.set(id, path);
    if (!this.running.has(id)) this.queue.requestUrgent(id);
    this.pump();
  }

  /** The tile was destroyed before its thumbnail started. */
  public cancel(id: string): void {
    this.queue.cancelUrgent(id);
  }

  /** Fill in the rest of the library, one photo at a time, while no tile is waiting. */
  public startBackground(ids: Array<string>): void {
    this.queue.setBackground(ids.filter((id: string): boolean => !this.known.has(id)));
    this.backgroundEnabled = true;
    this.pump();
  }

  public setPaused(paused: boolean): void {
    this.paused = paused;
    if (!paused) this.pump();
  }

  /** The thumbnail file could not be shown: replace it once, then fall back to the original. */
  public invalidate(id: string): void {
    const info: GalleryThumbnailInfo | undefined = this.known.get(id);
    if (info === undefined) return;
    this.known.delete(id);
    void this.unlinkQuietly(info.path);
    const path: string | undefined = this.sources.get(id);
    if (this.regenerated.has(id) || path === undefined) {
      this.failed.add(id);
      return;
    }
    this.regenerated.add(id);
    this.request(id, path);
  }

  public async remove(id: string): Promise<void> {
    this.sources.delete(id);
    this.queue.remove(id);
    this.failed.delete(id);
    const info: GalleryThumbnailInfo | undefined = this.known.get(id);
    this.known.delete(id);
    if (info !== undefined) await this.unlinkQuietly(info.path);
  }

  public dispose(): void {
    this.disposed = true;
    this.queue.clear();
    this.listener = undefined;
  }

  private pump(): void {
    while (!this.disposed && !this.paused && this.running.size < GALLERY_THUMBNAIL_WORKERS) {
      if (!this.queue.hasUrgent() && (!this.backgroundEnabled || this.running.size > 0)) return;
      const id: string | undefined = this.queue.next(this.backgroundEnabled && this.running.size === 0,
        (candidate: string): boolean => this.known.has(candidate) || this.failed.has(candidate) ||
          this.running.has(candidate) || !this.sources.has(candidate));
      if (id === undefined) return;
      const path: string = this.sources.get(id) as string;
      this.running.add(id);
      void this.generate(id, path);
    }
  }

  private async generate(id: string, path: string): Promise<void> {
    let result: GalleryThumbnailInfo | undefined = undefined;
    let settled: boolean = false;
    try {
      const info: GalleryThumbnailInfo = await this.writeThumbnail(id, path);
      if (!this.disposed && this.sources.get(id) === path) {
        this.known.set(id, info);
        result = info;
        settled = true;
      } else {
        // The photo was deleted or the library reloaded meanwhile.
        await this.unlinkQuietly(info.path);
      }
    } catch (error) {
      if (!this.disposed && this.sources.get(id) === path) {
        this.failed.add(id);
        settled = true;
      }
    }
    this.running.delete(id);
    if (settled && this.listener !== undefined) {
      try {
        this.listener(id, result);
      } catch (listenerError) {
        // A view update must not stop the remaining thumbnails.
      }
    }
    this.pump();
  }

  private async writeThumbnail(id: string, path: string): Promise<GalleryThumbnailInfo> {
    const decoded: GalleryDecodedImage = await decodeGalleryPixelMap(path, galleryThumbnailDecodeSize);
    const temporaryPath: string = this.directory + '/' + id + '.tmp-' + util.generateRandomUUID();
    let packer: image.ImagePacker | undefined = undefined;
    let file: fileIo.File | undefined = undefined;
    try {
      file = await fileIo.open(temporaryPath,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      packer = image.createImagePacker();
      await packer.packToFile(decoded.pixelMap, file.fd, {
        format: 'image/jpeg',
        quality: GALLERY_THUMBNAIL_JPEG_QUALITY
      });
      await fileIo.close(file.fd);
      file = undefined;
      // Published by rename, so a listed thumbnail is always a complete file.
      const finalPath: string = this.directory + '/' + galleryThumbnailFileName(id, decoded.width, decoded.height);
      await fileIo.rename(temporaryPath, finalPath);
      const info: GalleryThumbnailInfo = { path: finalPath, width: decoded.width, height: decoded.height };
      return info;
    } catch (error) {
      if (file !== undefined) {
        try {
          await fileIo.close(file.fd);
        } catch (closeError) {
          // Keep the encode or write error.
        }
      }
      await this.unlinkQuietly(temporaryPath);
      throw this.asError(error);
    } finally {
      if (packer !== undefined) {
        try {
          await packer.release();
        } catch (releaseError) {
          // Encoder release is best effort.
        }
      }
      try {
        await decoded.pixelMap.release();
      } catch (releaseError) {
        // The encoded file no longer needs the decode.
      }
    }
  }

  private isRunningTemporary(name: string): boolean {
    const marker: number = name.indexOf('.tmp-');
    return marker > 0 && this.running.has(name.substring(0, marker));
  }

  private async ensureDirectory(): Promise<void> {
    try {
      const stat: fileIo.Stat = await fileIo.lstat(this.directory);
      if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('缩略图目录不是安全目录');
    } catch (error) {
      const fileError: GalleryThumbnailFileError = error as GalleryThumbnailFileError;
      if (fileError.code !== NO_SUCH_FILE) throw this.asError(error);
      await fileIo.mkdir(this.directory, true);
    }
  }

  private async unlinkQuietly(path: string): Promise<void> {
    try {
      await fileIo.unlink(path);
    } catch (error) {
      // Already gone, or left for the next load's cleanup.
    }
  }

  private asError(error: Object): Error {
    if (error instanceof Error) return error;
    const fileError: GalleryThumbnailFileError = error as GalleryThumbnailFileError;
    return new Error(fileError.message ?? String(error));
  }
}
