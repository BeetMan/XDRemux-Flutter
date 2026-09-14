/**
 * The small, platform-neutral part of the native settings contract.
 *
 * Keep these values aligned with Rust's five-byte ConvertConfig.  The UI may
 * use labels, but the persisted representation stores the exact Rust values
 * so that a future UI refactor cannot accidentally turn an enum's display
 * index into an ABI value.
 */

export type SettingsOutputMode = 'oppo' | 'apple';

export interface NativeSettings {
  outputMode: SettingsOutputMode;
  oppoCompat: number;
  oppoCameraTail: number;
  strictTmap: boolean;
  applePhotographicStyles: boolean;
  applePortrait: boolean;
}

export interface SettingsOption {
  value: number;
  label: string;
  help: string;
}

export interface SettingsDecodeResult {
  values: NativeSettings;
  warning: string;
}

export interface SettingsRecord {
  schema: number;
  outputMode: string;
  oppoCompat: number;
  oppoCameraTail: number;
  strictTmap: boolean;
  applePhotographicStyles: boolean;
  applePortrait: boolean;
}

export const SETTINGS_SCHEMA_VERSION: number = 1;

export const DEFAULT_SETTINGS: NativeSettings = {
  outputMode: 'oppo',
  oppoCompat: 2,
  oppoCameraTail: 255,
  strictTmap: false,
  applePhotographicStyles: false,
  applePortrait: false
};

export const OPPO_COMPAT_OPTIONS: Array<SettingsOption> = [
  { value: 1, label: '自动', help: '根据原图标记自动选择；适合大多数照片。' },
  { value: 2, label: 'OPPO 兼容', help: '写入 OPPO 兼容标记，优先保证 OPPO 相册识别。' },
  { value: 3, label: 'OPPO 兼容 + 完整附加信息', help: '写入 OPPO 兼容标记，并完整保留相机附加信息。' },
  { value: 4, label: '标准 ISO', help: '移除 OPPO 标记，写入标准 ISO HDR 标记。' },
  { value: 5, label: '标准 ISO（无本地标记）', help: '标准 ISO HDR，并移除本地 HDR 标记。' },
  { value: 6, label: '标准 ISO（保留元数据图）', help: '清除路由标记，但保留原始元数据关系图。' },
  { value: 0, label: '关闭', help: '不修改路由标记；适合 Apple 照片/纯 ISO 输出。' }
];

export const OPPO_CAMERA_TAIL_OPTIONS: Array<SettingsOption> = [
  { value: 255, label: '自动', help: '兼容模式开启时完整保留；纯 ISO 输出时移除私有 HDR。' },
  { value: 0, label: '不保留', help: '不复制 OPPO 相机尾部元数据。' },
  { value: 1, label: '仅水印', help: '仅保留水印及其辅助元数据。' },
  { value: 2, label: '紧凑（含人像编辑）', help: '保留水印、人像编辑及必要的 HDR 变换条目。' },
  { value: 3, label: '完整保留', help: '原样保留完整相机尾部。' },
  { value: 4, label: '保留（移除人像编辑）', help: '删除景深、分割和人像编辑条目。' },
  { value: 5, label: '保留（移除人像/私有 HDR）', help: '同时删除人像编辑和私有 HDR 条目。' },
  { value: 6, label: '保留（移除私有 UHDR）', help: '仅删除私有 UHDR gain-map 条目。' },
  { value: 7, label: '保留（移除私有 HDR）', help: '删除所有私有 HDR 条目。' },
  { value: 8, label: '保留并中和 UHDR', help: '保留结构，但中和私有 UHDR 条目名。' },
  { value: 9, label: '保留并中和 HDR', help: '保留结构，但中和所有私有 HDR 条目名。' }
];

export function cloneSettings(values: NativeSettings): NativeSettings {
  return {
    outputMode: values.outputMode,
    oppoCompat: values.oppoCompat,
    oppoCameraTail: values.oppoCameraTail,
    strictTmap: values.strictTmap,
    applePhotographicStyles: values.applePhotographicStyles,
    applePortrait: values.applePortrait
  };
}

export function isInteger(value: number): boolean {
  return Number.isFinite(value) && Math.floor(value) === value;
}

export function isValidCompat(value: number): boolean {
  return isInteger(value) && value >= 0 && value <= 6;
}

export function isValidCameraTail(value: number): boolean {
  return value === 255 || (isInteger(value) && value >= 0 && value <= 9);
}

/**
 * Apply the same mode transitions as Flutter's SettingsSheet.  Apple feature
 * graphs require Apple output and no OPPO routing/tail values; selecting an
 * OPPO routing mode clears those Apple-only graphs.  An OPPO `off` value is
 * still a valid explicit choice when no Apple graph is enabled.
 */
export function normalizeSettings(values: NativeSettings): NativeSettings {
  const normalized: NativeSettings = cloneSettings(values);
  if (normalized.outputMode !== 'oppo' && normalized.outputMode !== 'apple') {
    throw new Error('输出模式无效');
  }
  if (!isValidCompat(normalized.oppoCompat)) {
    throw new Error('OPPO 兼容值无效');
  }
  if (!isValidCameraTail(normalized.oppoCameraTail)) {
    throw new Error('相机附加信息值无效');
  }
  if (typeof normalized.strictTmap !== 'boolean' ||
    typeof normalized.applePhotographicStyles !== 'boolean' ||
    typeof normalized.applePortrait !== 'boolean') {
    throw new Error('布尔设置无效');
  }

  if (normalized.outputMode === 'apple' ||
    normalized.applePhotographicStyles || normalized.applePortrait) {
    normalized.outputMode = 'apple';
    normalized.oppoCompat = 0;
    normalized.oppoCameraTail = 0;
  } else {
    normalized.applePhotographicStyles = false;
    normalized.applePortrait = false;
  }
  return normalized;
}

export function settingsToRecord(values: NativeSettings): SettingsRecord {
  const normalized: NativeSettings = normalizeSettings(values);
  return {
    schema: SETTINGS_SCHEMA_VERSION,
    outputMode: normalized.outputMode,
    oppoCompat: normalized.oppoCompat,
    oppoCameraTail: normalized.oppoCameraTail,
    strictTmap: normalized.strictTmap,
    applePhotographicStyles: normalized.applePhotographicStyles,
    applePortrait: normalized.applePortrait
  };
}

export function serializeSettings(values: NativeSettings): string {
  return JSON.stringify(settingsToRecord(values));
}

function invalidStoredSettings(reason: string): SettingsDecodeResult {
  return {
    values: cloneSettings(DEFAULT_SETTINGS),
    warning: '设置文件无效（' + reason + '），已使用默认值；原数据未覆盖，请检查后重试保存。'
  };
}

/**
 * Decode one atomic JSON preference.  Every field is type-checked before it
 * can reach the native ABI.  Invalid persisted data is reported to the UI
 * instead of being silently replaced on disk.
 */
export function decodeSettingsJson(raw: string): SettingsDecodeResult {
  if (raw.length === 0) {
    return { values: cloneSettings(DEFAULT_SETTINGS), warning: '' };
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(raw) as Object;
  } catch (error) {
    return invalidStoredSettings('JSON 格式错误');
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return invalidStoredSettings('记录结构错误');
  }
  const record: SettingsRecord = parsed as SettingsRecord;
  if (typeof record.schema !== 'number' || record.schema !== SETTINGS_SCHEMA_VERSION) {
    return invalidStoredSettings('版本不受支持');
  }
  if (record.outputMode !== 'oppo' && record.outputMode !== 'apple') {
    return invalidStoredSettings('输出模式错误');
  }
  if (typeof record.oppoCompat !== 'number' || !isValidCompat(record.oppoCompat)) {
    return invalidStoredSettings('OPPO 兼容值错误');
  }
  if (typeof record.oppoCameraTail !== 'number' || !isValidCameraTail(record.oppoCameraTail)) {
    return invalidStoredSettings('相机附加信息值错误');
  }
  if (typeof record.strictTmap !== 'boolean' ||
    typeof record.applePhotographicStyles !== 'boolean' ||
    typeof record.applePortrait !== 'boolean') {
    return invalidStoredSettings('布尔值错误');
  }
  try {
    const values: NativeSettings = normalizeSettings({
      outputMode: record.outputMode as SettingsOutputMode,
      oppoCompat: record.oppoCompat,
      oppoCameraTail: record.oppoCameraTail,
      strictTmap: record.strictTmap,
      applePhotographicStyles: record.applePhotographicStyles,
      applePortrait: record.applePortrait
    });
    return { values: values, warning: '' };
  } catch (error) {
    return invalidStoredSettings('设置组合无效');
  }
}

export function settingsEqual(left: NativeSettings, right: NativeSettings): boolean {
  return left.outputMode === right.outputMode &&
    left.oppoCompat === right.oppoCompat &&
    left.oppoCameraTail === right.oppoCameraTail &&
    left.strictTmap === right.strictTmap &&
    left.applePhotographicStyles === right.applePhotographicStyles &&
    left.applePortrait === right.applePortrait;
}

export function compatLabel(value: number): string {
  const option: SettingsOption | undefined = OPPO_COMPAT_OPTIONS.find(
    (candidate: SettingsOption): boolean => candidate.value === value
  );
  return option === undefined ? '无效' : option.label;
}

export function cameraTailLabel(value: number): string {
  const option: SettingsOption | undefined = OPPO_CAMERA_TAIL_OPTIONS.find(
    (candidate: SettingsOption): boolean => candidate.value === value
  );
  return option === undefined ? '无效' : option.label;
}

export function modeLabel(values: NativeSettings): string {
  const normalized: NativeSettings = normalizeSettings(values);
  const labels: Array<string> = [];
  if (normalized.outputMode === 'apple') {
    labels.push('Apple 标准');
    if (normalized.applePhotographicStyles) {
      labels.push('摄影风格');
    }
    if (normalized.applePortrait) {
      labels.push('人像数据');
    }
  } else {
    labels.push('OPPO 兼容');
    labels.push('兼容模式：' + compatLabel(normalized.oppoCompat));
    labels.push('附加信息：' + cameraTailLabel(normalized.oppoCameraTail));
  }
  if (normalized.strictTmap) {
    labels.push('严格 ISO');
  }
  return labels.join(' · ');
}

/**
 * A small injectable serial writer used by SettingsStore and deterministic
 * tests.  A rejected write does not poison the chain, so a later explicit
 * Save can retry after an I/O failure.
 */
export type SettingsWrite = (values: NativeSettings) => Promise<void>;

export class SettingsSaveQueue {
  private chain: Promise<void> = Promise.resolve();
  private readonly write: SettingsWrite;

  constructor(write: SettingsWrite) {
    this.write = write;
  }

  public enqueue(values: NativeSettings): Promise<void> {
    const snapshot: NativeSettings = cloneSettings(values);
    const task: Promise<void> = this.chain.then(
      (): Promise<void> => this.write(snapshot),
      (): Promise<void> => this.write(snapshot)
    );
    this.chain = task.then(
      (): void => undefined,
      (): void => undefined
    );
    return task;
  }
}
