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
