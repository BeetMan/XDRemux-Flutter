import type { NativePhotoDetails } from './NativeTypes';

interface HuaweiPortraitReport {
  detected?: boolean;
  safeToTransform?: boolean;
}

interface HuaweiReport {
  schema?: string;
  isHuaweiHdr?: boolean;
  hasHuaweiPortrait?: boolean;
  huaweiPortrait?: HuaweiPortraitReport;
}

interface HuaweiConversionReport {
  success?: boolean;
  error?: string;
}

interface StyleLayerReport {
  status?: string;
  message?: string;
  added?: Array<string>;
}

export function hasNativeHuaweiStyleGraft(json: string): boolean {
  const report: StyleLayerReport = JSON.parse(json) as StyleLayerReport;
  return report !== null && report.status === 'attached' &&
    Array.isArray(report.added) && report.added.includes('styles-native');
}

interface StillExtractReport {
  success?: boolean;
  errorMessage?: string;
  stillBytes?: number;
}

export function verifyStillExtraction(json: string): void {
  const report: StillExtractReport = JSON.parse(json) as StillExtractReport;
  if (report === null || report.success !== true || !Number.isSafeInteger(report.stillBytes) ||
    (report.stillBytes ?? 0) <= 0) {
    throw new Error(report?.errorMessage ?? 'Motion Photo 静态图提取失败');
  }
}

export function livePhotoStylesCompatible(result: {
  applePhotographicStyles?: boolean;
  applePhotographicStyles3?: boolean;
}): boolean {
  // Older results have no immutable style record, so require reconversion.
  return result.applePhotographicStyles !== undefined &&
    (result.applePhotographicStyles !== true || result.applePhotographicStyles3 === true);
}

export function mergeHuaweiInspection(details: NativePhotoDetails, json: string): NativePhotoDetails {
  const report: HuaweiReport = JSON.parse(json) as HuaweiReport;
  if (report === null || report.schema !== 'xdremux-huawei-heic-v1') {
    throw new Error('华为照片识别结果无效');
  }
  return {
    ...details,
    huaweiHdr: report.isHuaweiHdr === true,
    huaweiPortrait: report.hasHuaweiPortrait === true && report.huaweiPortrait?.detected === true,
    huaweiPortraitReady: report.hasHuaweiPortrait === true &&
      report.huaweiPortrait?.detected === true && report.huaweiPortrait?.safeToTransform === true
  };
}

export interface HuaweiPortraitBridge {
  remux: (input: string, output: string) => Promise<string>;
  verify: (path: string) => Promise<boolean>;
  attach: (input: string, output: string, seed: number, flags: number) => Promise<string>;
}

/** Keep the verified portrait file separate from the optional styles output.
 * A styles failure never overwrites the verified base file. */
export async function convertHuaweiPortrait(
  bridge: HuaweiPortraitBridge, input: string, baseOutput: string,
  styledOutput: string, seed: number, styles: boolean, styles3: boolean
): Promise<string> {
  if (input === baseOutput || input === styledOutput || baseOutput === styledOutput) {
    throw new Error('华为人像转换必须使用独立输出文件');
  }
  const report: HuaweiConversionReport = JSON.parse(await bridge.remux(input, baseOutput)) as HuaweiConversionReport;
  if (report === null || report.success !== true) {
    throw new Error(report?.error ?? '华为人像转换失败');
  }
  if (!await bridge.verify(baseOutput)) throw new Error('华为人像输出校验失败');
  const flags: number = styles3 ? 7 : (styles ? 1 : 0);
  if (flags === 0) return baseOutput;
  const attached: StyleLayerReport = JSON.parse(
    await bridge.attach(baseOutput, styledOutput, seed, flags)) as StyleLayerReport;
  if (attached === null || (attached.status !== 'attached' && attached.status !== 'already-complete')) {
    throw new Error('华为人像摄影风格写入失败：' + (attached?.message ?? attached?.status ?? '无效结果'));
  }
  if (!await bridge.verify(styledOutput)) throw new Error('附加摄影风格后的人像输出校验失败');
  return styledOutput;
}
