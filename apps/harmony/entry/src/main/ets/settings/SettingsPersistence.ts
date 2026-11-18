import {
  DEFAULT_SETTINGS,
  SettingsSaveQueue,
  cloneSettings,
  decodeSettingsJson,
  normalizeSettings,
  serializeSettings
} from './SettingsModel.ts';
import type { NativeSettings, SettingsDecodeResult } from './SettingsModel.ts';

/** Narrow adapter around Preferences so the transaction can be tested with a
 * deterministic in-memory backend without importing the Harmony module. */
export interface SettingsPreferenceAdapter {
  has(): Promise<boolean>;
  getString(): Promise<string>;
  putString(value: string): void;
  delete(): void;
  flush(): Promise<void>;
}

export interface SettingsPersistenceLoadResult {
  values: NativeSettings;
  warning: string;
}

/**
 * Atomic one-record settings transaction. Preferences mutates its process
 * cache in putSync, so a failed flush is followed by restoration of the exact
 * previous raw record. This class is production code used by SettingsStore,
 * with the adapter also making rollback/failure behavior testable.
 */
export class SettingsPersistence {
  private loaded: boolean = false;
  private persisted: NativeSettings = cloneSettings(DEFAULT_SETTINGS);
  private persistedRaw: string | undefined;
  private persistedExists: boolean = false;
  private readonly saveQueue: SettingsSaveQueue;
  private readonly adapter: SettingsPreferenceAdapter;

  constructor(adapter: SettingsPreferenceAdapter) {
    this.adapter = adapter;
    this.saveQueue = new SettingsSaveQueue(
      (values: NativeSettings): Promise<void> => this.writeSnapshot(values)
    );
  }

  public async load(): Promise<SettingsPersistenceLoadResult> {
    if (this.loaded) {
      return { values: cloneSettings(this.persisted), warning: '' };
    }
    const exists: boolean = await this.adapter.has();
    let raw: string = '';
    if (exists) {
      raw = await this.adapter.getString();
    }
    const decoded: SettingsDecodeResult = decodeSettingsJson(raw);
    this.persisted = cloneSettings(decoded.values);
    this.persistedRaw = exists ? raw : undefined;
    this.persistedExists = exists;
    this.loaded = true;
    return { values: cloneSettings(decoded.values), warning: decoded.warning };
  }

  public save(values: NativeSettings): Promise<void> {
    if (!this.loaded) {
      return Promise.reject(new Error('设置尚未加载完成'));
    }
    let normalized: NativeSettings;
    try {
      normalized = normalizeSettings(values);
    } catch (error) {
      return Promise.reject(error);
    }
    return this.saveQueue.enqueue(normalized);
  }

  private async writeSnapshot(values: NativeSettings): Promise<void> {
    if (!this.loaded) {
      throw new Error('设置尚未加载完成');
    }
    const previousRaw: string | undefined = this.persistedRaw;
    const previousExists: boolean = this.persistedExists;
    const next: NativeSettings = normalizeSettings(values);
    const nextJson: string = serializeSettings(next);
    try {
      this.adapter.putString(nextJson);
      await this.adapter.flush();
      this.persisted = cloneSettings(next);
      this.persistedRaw = nextJson;
      this.persistedExists = true;
    } catch (error) {
      // putString mutates the Preferences cache before flush. Restore the
      // exact raw value, including malformed data, or delete a key that was
      // previously absent. A failed save therefore cannot silently overwrite
      // the record the user may need to inspect.
      try {
        if (previousExists && previousRaw !== undefined) {
          this.adapter.putString(previousRaw);
        } else {
          this.adapter.delete();
        }
        await this.adapter.flush();
      } catch (rollbackError) {
        throw new Error('设置保存失败，恢复旧设置也失败；请重试保存：' + this.errorMessage(error));
      }
      throw new Error('设置保存失败，已保留未保存草稿：' + this.errorMessage(error));
    }
  }

  private errorMessage(error: Object): string {
    const candidate: { message?: string } = error as { message?: string };
    return candidate.message === undefined || candidate.message.length === 0
      ? String(error)
      : candidate.message;
  }
}
