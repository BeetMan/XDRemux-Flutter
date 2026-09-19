export interface NativeClassificationResult {
  modeKey: string | null;
  folderName: string | null;
  status: string | null;
  rawUserComment: string | null;
  hasTagFlags: boolean;
  tagFlags: bigint;
  unknownFlags: bigint;
  hdrKind: string | null;
  family: string | null;
}

export interface NativePhotoDetails {
  success: boolean;
  errorMessage?: string;
  make?: string;
  model?: string;
  dateTime?: string;
  exposureTime?: string;
  fNumber?: string;
  iso?: string;
  focalLength?: string;
  focalLength35mm?: string;
  exposureBias?: string;
  width?: number;
  height?: number;
  hdrKind?: string;
  edrScale?: number;
  gainMapMax?: number;
}

export interface NativeConversionResult {
  success: boolean;
  mode: string | null;
  family: string | null;
  edrScale: number;
  gainMapMax: number;
  errorMessage: string | null;
}

export interface NativeConvertConfig {
  oppoCompat: number;
  oppoCameraTail: number;
  strictTmap: number;
  applePhotographicStyles: number;
  applePortrait: number;
}

export interface NativeProgress {
  stage: number;
  current: number;
  total: number;
}

/** JSON string returned by xdremux_motion_photo_inspect is parsed and
 * range-checked by MotionPhotoModel before these fields are displayed. */
export interface NativeMotionPhotoItem {
  mime: string;
  semantic: string;
  length: number;
  padding: number;
}

export interface NativeMotionPhotoReport {
  isMotionPhoto: boolean;
  sourceKind: string;
  stillStart: number;
  stillEnd: number;
  videoStart: number;
  videoEnd: number;
  isDualStream?: boolean;
  items: Array<NativeMotionPhotoItem>;
  presentationTimestampUs?: number;
  presentationSource?: string;
  videoWidth?: number;
  videoHeight?: number;
  durationMs?: number;
  fps?: number;
  frameCount?: number;
  videoCodec?: string;
  hasAudio?: boolean;
  audioCodec?: string;
  audioChannels?: number;
  audioSampleRate?: number;
  audioDurationMs?: number;
  primaryBytes?: number;
  secondaryBytes?: number;
  secondaryWidth?: number;
  secondaryHeight?: number;
  secondaryFps?: number;
}
