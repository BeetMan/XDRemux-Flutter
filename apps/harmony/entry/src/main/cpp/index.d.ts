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

export const version: () => Promise<string>;
export const classify: (path: string) => Promise<ClassificationResult>;
