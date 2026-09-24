export interface ClassificationResult {
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

export interface PhotoDetails {
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

export interface ConversionResult {
  success: boolean;
  mode: string | null;
  family: string | null;
  edrScale: number;
  gainMapMax: number;
  errorMessage: string | null;
}

export interface ConvertConfig {
  oppoCompat: number;
  oppoCameraTail: number;
  strictTmap: number;
  applePhotographicStyles: number;
  applePortrait: number;
}

/** Bridge-only options; these do not change Rust's five-byte ConvertConfig. */
export interface ConvertOptions {
  applePhotographicStyles3?: boolean;
  grainSeed?: number;
}

export interface Progress {
  stage: number;
  current: number;
  total: number;
}

export const version: () => Promise<string>;
export const classify: (path: string) => Promise<ClassificationResult>;
export const inspect: (path: string) => Promise<string>;
export const motionInspect: (path: string) => Promise<string>;
export const motionSplit: (path: string, outputDirectory: string) => Promise<string>;
export const livePhotoMake: (sourcePath: string, stillPath: string, outputDirectory: string) => Promise<string>;
export const livePhotoPairValid: (stillPath: string, movPath: string) => Promise<boolean>;
export const convert: (
  inputPath: string,
  outputPath: string,
  config: ConvertConfig,
  progressHandle: number,
  options?: ConvertOptions
) => Promise<ConversionResult>;
export const progressBegin: () => number;
export const progressRead: (handle: number) => Progress;
export const progressEnd: (handle: number) => void;
