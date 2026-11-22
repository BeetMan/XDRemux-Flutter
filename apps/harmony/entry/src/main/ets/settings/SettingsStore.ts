import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { SettingsPersistence } from './SettingsPersistence';
import type { SettingsPreferenceAdapter } from './SettingsPersistence';
import { cloneSettings, normalizeSettings } from './SettingsModel';
import type { NativeSettings } from './SettingsModel';

export interface SettingsLoadResult {
  values: NativeSettings;
  warning: string;
}

const PREFERENCE_NAME: string = 'xdremux-native-settings';
const PREFERENCE_KEY: string = 'config';

/**
 * Harmony adapter for the platform-neutral settings transaction. The
 * Preferences object is application-scoped and is only used from this UI
 * process. SettingsPersistence serializes all writes and handles rollback.
 */
export class SettingsStore {
  private persistence: SettingsPersistence | undefined;
  private loaded: boolean = false;
  private loadTask: Promise<SettingsLoadResult> | undefined;
  private loadedResult: SettingsLoadResult | undefined;

  public load(context: common.Context): Promise<SettingsLoadResult> {
    if (this.loaded && this.loadedResult !== undefined) {
      return Promise.resolve({
        values: cloneSettings(this.loadedResult.values),
        warning: this.loadedResult.warning
      });
    }
    if (this.loadTask !== undefined) {
      return this.loadTask;
    }
    const task: Promise<SettingsLoadResult> = this.loadInternal(context);
    this.loadTask = task;
    task.catch((): void => {
      if (!this.loaded) {
        this.loadTask = undefined;
        this.persistence = undefined;
      }
    });
    return task;
  }

  public async save(values: NativeSettings): Promise<void> {
    if (!this.loaded || this.persistence === undefined) {
      throw new Error('设置尚未加载完成');
    }
    const normalized: NativeSettings = normalizeSettings(values);
    await this.persistence.save(normalized);
    // Keep repeated load() calls in this process consistent with the record
    // just committed. The warning from a previously malformed raw record is
    // cleared only after put+flush succeeds.
    this.loadedResult = { values: cloneSettings(normalized), warning: '' };
  }

  private async loadInternal(context: common.Context): Promise<SettingsLoadResult> {
    const options: preferences.Options = { name: PREFERENCE_NAME };
    const store: preferences.Preferences = await preferences.getPreferences(context, options);
    const adapter: SettingsPreferenceAdapter = {
      has: (): Promise<boolean> => store.has(PREFERENCE_KEY),
      getString: async (): Promise<string> => {
        const rawValue: preferences.ValueType = await store.get(PREFERENCE_KEY, '');
        if (typeof rawValue !== 'string') {
          throw new Error('设置存储类型错误');
        }
        return rawValue;
      },
      putString: (value: string): void => store.putSync(PREFERENCE_KEY, value),
      delete: (): void => store.deleteSync(PREFERENCE_KEY),
      flush: (): Promise<void> => store.flush()
    };
    const persistence: SettingsPersistence = new SettingsPersistence(adapter);
    const loaded: SettingsLoadResult = await persistence.load();
    this.persistence = persistence;
    this.loadedResult = {
      values: cloneSettings(loaded.values),
      warning: loaded.warning
    };
    this.loaded = true;
    return {
      values: cloneSettings(loaded.values),
      warning: loaded.warning
    };
  }
}
