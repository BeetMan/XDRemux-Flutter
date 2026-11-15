/**
 * Grid thumbnails: small upright JPEGs kept beside the gallery originals, so
 * scrolling the grid never decodes a full-size photo. The file name carries
 * the original's displayed size, so one directory listing also gives every
 * photo's aspect ratio for the detail view.
 */
export const GALLERY_THUMBNAIL_DIRECTORY: string = 'thumbs-v1';
/** Shorter side of a grid thumbnail; a 3-column grid tile is about 450-550 px. */
export const GALLERY_THUMBNAIL_SHORT_EDGE: number = 512;
/** Keeps panoramas from turning into large thumbnails. */
export const GALLERY_THUMBNAIL_MAX_LONG_EDGE: number = 1536;
export const GALLERY_THUMBNAIL_JPEG_QUALITY: number = 85;

export interface GallerySize {
  width: number;
  height: number;
}

export interface GalleryThumbnailName {
  id: string;
  width: number;
  height: number;
}

export interface GalleryThumbnailSource {
  id: string;
  path: string;
}

const THUMBNAIL_NAME_PATTERN: RegExp =
  /^([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})_([1-9][0-9]{0,5})x([1-9][0-9]{0,5})\.jpg$/i;

export function galleryThumbnailFileName(id: string, width: number, height: number): string {
  return id + '_' + String(Math.round(width)) + 'x' + String(Math.round(height)) + '.jpg';
}

/** The photo id and displayed size encoded in a thumbnail name; undefined for any other file. */
export function parseGalleryThumbnailFileName(name: string): GalleryThumbnailName | undefined {
  const match: RegExpExecArray | null = THUMBNAIL_NAME_PATTERN.exec(name);
  if (match === null) return undefined;
  return { id: match[1], width: Number(match[2]), height: Number(match[3]) };
}

// The image framework reports EXIF Orientation as libexif names; some
// decoders return the bare number.
const ORIENTATION_NAMES: Array<string> = [
  'top-left', 'top-right', 'bottom-right', 'bottom-left',
  'left-top', 'right-top', 'right-bottom', 'left-bottom'
];

/** EXIF orientation 1-8 from a property value; anything unknown is 1 (upright). */
export function galleryExifOrientation(value: string): number {
  const normalized: string = value.trim().toLowerCase();
  const index: number = ORIENTATION_NAMES.indexOf(normalized);
  if (index >= 0) return index + 1;
  if (/^[1-8]$/.test(normalized)) return Number(normalized);
  return 1;
}

/** Orientations 5-8 turn the stored image a quarter turn, so width and height trade places. */
export function galleryOrientationSwapsAxes(orientation: number): boolean {
  return orientation >= 5 && orientation <= 8;
}

export interface GalleryOrientationStep {
  rotate: number;
  flipHorizontal: boolean;
  flipVertical: boolean;
}

/**
 * Pixel operations that show a stored image upright, applied in order:
 * rotate clockwise by `rotate` degrees, then flip. Orientation 5 is a
 * transpose (rotate 90, mirror) and 7 a transverse (rotate 90, flip).
 */
export function galleryOrientationSteps(orientation: number): GalleryOrientationStep {
  switch (orientation) {
    case 2: return { rotate: 0, flipHorizontal: true, flipVertical: false };
    case 3: return { rotate: 180, flipHorizontal: false, flipVertical: false };
    case 4: return { rotate: 0, flipHorizontal: false, flipVertical: true };
    case 5: return { rotate: 90, flipHorizontal: true, flipVertical: false };
    case 6: return { rotate: 90, flipHorizontal: false, flipVertical: false };
    case 7: return { rotate: 90, flipHorizontal: false, flipVertical: true };
    case 8: return { rotate: 270, flipHorizontal: false, flipVertical: false };
    default: return { rotate: 0, flipHorizontal: false, flipVertical: false };
  }
}

function scaledSize(width: number, height: number, scale: number): GallerySize {
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale))
  };
}

/** Decode size whose shorter side is the thumbnail edge (never upscaled). */
export function galleryThumbnailDecodeSize(width: number, height: number): GallerySize {
  const scale: number = Math.min(1,
    GALLERY_THUMBNAIL_SHORT_EDGE / Math.min(width, height),
    GALLERY_THUMBNAIL_MAX_LONG_EDGE / Math.max(width, height));
  return scaledSize(width, height, scale);
}

/** Decode size whose longer side is at most `maxLongEdge` (never upscaled). */
export function galleryLongEdgeDecodeSize(width: number, height: number, maxLongEdge: number): GallerySize {
  return scaledSize(width, height, Math.min(1, maxLongEdge / Math.max(width, height)));
}

/**
 * Order of thumbnail work: tiles on screen first, the most recently shown
 * first (where the user is looking now), then the rest of the library in
 * grid order. Callers skip ids that are already done when taking work.
 */
export class GalleryThumbnailQueue {
  private urgent: Array<string> = [];
  private background: Array<string> = [];
  private backgroundIndex: number = 0;

  /** A tile came on screen (or into the grid's preload rows). */
  public requestUrgent(id: string): void {
    const existing: number = this.urgent.indexOf(id);
    if (existing >= 0) this.urgent.splice(existing, 1);
    this.urgent.push(id);
  }

  /** A tile left the grid before its thumbnail was started. */
  public cancelUrgent(id: string): void {
    const existing: number = this.urgent.indexOf(id);
    if (existing >= 0) this.urgent.splice(existing, 1);
  }

  public setBackground(ids: Array<string>): void {
    this.background = ids.slice();
    this.backgroundIndex = 0;
  }

  public hasUrgent(): boolean {
    return this.urgent.length > 0;
  }

  /** Next id to generate, or undefined. `done` skips settled or running ids. */
  public next(includeBackground: boolean, done: (id: string) => boolean): string | undefined {
    while (this.urgent.length > 0) {
      const id: string = this.urgent.pop() as string;
      if (!done(id)) return id;
    }
    if (!includeBackground) return undefined;
    while (this.backgroundIndex < this.background.length) {
      const id: string = this.background[this.backgroundIndex];
      this.backgroundIndex += 1;
      if (!done(id)) return id;
    }
    return undefined;
  }

  public remove(id: string): void {
    this.cancelUrgent(id);
    const index: number = this.background.indexOf(id, this.backgroundIndex);
    if (index >= 0) this.background.splice(index, 1);
  }

  public clear(): void {
    this.urgent = [];
    this.background = [];
    this.backgroundIndex = 0;
  }
}
