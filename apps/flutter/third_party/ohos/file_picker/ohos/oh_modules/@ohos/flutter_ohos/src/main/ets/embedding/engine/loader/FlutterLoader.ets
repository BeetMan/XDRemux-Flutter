/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterLoader.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

/**
 * FlutterLoader is responsible for starting the Dart VM and loading Dart code.
 * This class locates Flutter resources in the HAP package and loads the Flutter native library.
 * It handles initialization, resource copying, and Dart VM configuration.
 */
import FlutterShellArgs from '../FlutterShellArgs';
import FlutterNapi from '../FlutterNapi';
import Log from '../../../util/Log';
import FlutterApplicationInfo from './FlutterApplicationInfo';
import common from '@ohos.app.ability.common';
import StringUtils from '../../../util/StringUtils';
import ApplicationInfoLoader from './ApplicationInfoLoader';
import bundleManager from '@ohos.bundle.bundleManager';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';
import data_preferences from '@ohos.data.preferences';
import { util } from '@kit.ArkTS';
import deviceInfo from '@ohos.deviceInfo';
import { json5Tojson } from '../../../util/Json5ToJson';

const TAG = "FlutterLoader";

// Flutter engine shared library
const DEFAULT_LIBRARY = "libflutter.so";
// Default kernel file for JIT builds
const DEFAULT_KERNEL_BLOB = "kernel_blob.bin";
// Default snapshot library for JIT builds
const VMSERVICE_SNAPSHOT_LIBRARY = "libvmservice_snapshot.so";
// Key for snapshot asset path
const SNAPSHOT_ASSET_PATH_KEY = "snapshot-asset-path";
// Key for VM snapshot data
const VM_SNAPSHOT_DATA_KEY = "vm-snapshot-data";
// Key for isolate snapshot data
const ISOLATE_SNAPSHOT_DATA_KEY = "isolate-snapshot-data";


const AOT_SHARED_LIBRARY_NAME = "aot-shared-library-name";

const AOT_VMSERVICE_SHARED_LIBRARY_NAME = "aot-vmservice-shared-library-name";

// File path separator
const FILE_SEPARATOR = "/";

const TIMESTAMP_PREFIX = "res_timestamp-";

const ENABLE_IMPELLER_TAG = "enable_impeller";

const TRUE_STRING = "true";

const BUILD_INFO_FILE_NAME = "buildinfo.json5";

/**
 * Represents a string item with name and value.
 */
interface StringItem {
  name: string;
  value: string;
}

/**
 * Represents build information data containing an array of string items.
 */
interface InfoData {
  string: StringItem[];
}

/**
 * Prefetches the default font manager asynchronously.
 * This should be called before using fonts in the Flutter engine.
 */
async function prefetchDefaultFontManager(): Promise<void> {
  await new Promise<void>((resolve: Function) => {
    FlutterNapi.prefetchDefaultFontManager()
    resolve()
  })
}

/**
 * FlutterLoader is responsible for starting the Dart VM and loading Dart code.
 * This class locates Flutter resources in the HAP package and loads the Flutter native library.
 * It handles initialization, resource copying, and Dart VM configuration.
 */
export default class FlutterLoader {
  /** The FlutterNapi instance for native communication. */
  flutterNapi: FlutterNapi;
  /** Initialization result containing paths for app storage, engine caches, and data directory. */
  initResult: InitResult | null = null;
  /** Flutter application information including asset paths and build mode. */
  flutterApplicationInfo: FlutterApplicationInfo | null = null;
  /** The application context for accessing resources. */
  context: common.Context | null = null;
  /** Whether the FlutterLoader has been initialized. */
  initialized: boolean = false;
  /** Timestamp when initialization started. */
  initStartTimestampMillis: number = 0;
  /** Whether Impeller rendering backend is enabled. */
  isEnableImpeller: boolean = false;

  /**
   * Constructs a new FlutterLoader instance.
   * @param flutterNapi - The FlutterNapi instance for native communication
   */
  constructor(flutterNapi: FlutterNapi) {
    this.flutterNapi = flutterNapi;
  }

  /**
   * Gets build information from the buildinfo.json5 file.
   * @param context - The application context
   * @returns A map containing build information key-value pairs
   */
 private getBuildInfo(context: common.Context): Map<string, string> {
    let buildInfoMap: Map<string, string> = new Map();
    try {
      let rawFile = context.resourceManager.getRawFileContentSync(BUILD_INFO_FILE_NAME);
        let textDecoder = util.TextDecoder.create('utf-8', {
          ignoreBOM: true
        });
        let record = textDecoder.decodeWithStream(rawFile, {
          stream: false
        });
        let jsonRecord: InfoData = JSON.parse(json5Tojson(record));
        jsonRecord.string.forEach((item: StringItem) => {
          buildInfoMap.set(item.name, item.value);
        });
      return buildInfoMap;
    } catch (error) {
      Log.e(TAG, "can not find buildinfo.json5 file.")
      return buildInfoMap;
    }

  }

  /**
   * Starts initialization of the native system.
   *
   * This loads the Flutter engine's native library to enable subsequent NAPI calls. This also
   * starts locating and unpacking Dart resources packaged in the app's HAP.
   *
   * Calling this method multiple times has no effect.
   *
   * @param context - The OpenHarmony application context
   */
  startInitialization(context: common.Context) {
    Log.d(TAG, "flutterLoader start init")
    this.initStartTimestampMillis = Date.now();
    this.context = context;
    this.flutterApplicationInfo = ApplicationInfoLoader.load(context);
    prefetchDefaultFontManager();
    if (this.flutterApplicationInfo!.isDebugMode) {
      this.copyResource(context)
    }
    let buildInfoMap = this.getBuildInfo(this.context!); 
    if (!buildInfoMap.has(ENABLE_IMPELLER_TAG) || buildInfoMap.get(ENABLE_IMPELLER_TAG) == TRUE_STRING) {
        this.isEnableImpeller = true;
    } else {
      this.isEnableImpeller = false;
    }
    this.initResult = new InitResult(
      `${context.filesDir}/`,
      `${context.cacheDir}/`,
      `${context.filesDir}`
    )
    Log.d(TAG, "flutterLoader end init")
  }

  private copyResource(context: common.Context) {
    let filePath = context.filesDir + FILE_SEPARATOR + this.flutterApplicationInfo!.flutterAssetsDir
    const timestamp = this.checkTimestamp(filePath);
    if (timestamp == null) {
      Log.d(TAG, "no need copyResource")
      return;
    }
    if (this.context != null) {
      Log.d(TAG, "start copyResource")
      if (fs.accessSync(filePath + FILE_SEPARATOR + DEFAULT_KERNEL_BLOB)) {
        Log.d(TAG, "hap has changed, start delete previous file")
        fs.rmdirSync(filePath);
      }

      if (!fs.accessSync(filePath)) {
        fs.mkdirSync(filePath)
      }

      let kernelBuffer =
        this.context.resourceManager.getRawFileContentSync(this.flutterApplicationInfo!.flutterAssetsDir +
          FILE_SEPARATOR + DEFAULT_KERNEL_BLOB)
      let kernelFile =
        fs.openSync(filePath + FILE_SEPARATOR + DEFAULT_KERNEL_BLOB, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
      fs.writeSync(kernelFile.fd, kernelBuffer.buffer)

      let vmBuffer =
        this.context.resourceManager.getRawFileContentSync(this.flutterApplicationInfo!.flutterAssetsDir +
          FILE_SEPARATOR + this.flutterApplicationInfo!.vmSnapshotData)
      let vmFile = fs.openSync(filePath + FILE_SEPARATOR + this.flutterApplicationInfo!.vmSnapshotData,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
      fs.writeSync(vmFile.fd, vmBuffer.buffer)

      let isolateBuffer =
        this.context.resourceManager.getRawFileContentSync(this.flutterApplicationInfo!.flutterAssetsDir +
          FILE_SEPARATOR + this.flutterApplicationInfo!.isolateSnapshotData)
      let isolateFile = fs.openSync(filePath + FILE_SEPARATOR + this.flutterApplicationInfo!.isolateSnapshotData,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
      fs.writeSync(isolateFile.fd, isolateBuffer.buffer)

      if (timestamp != null) {
        fs.closeSync(fs.openSync(filePath + FILE_SEPARATOR + timestamp, fs.OpenMode.READ_ONLY | fs.OpenMode.CREATE))
      }
      fs.closeSync(kernelFile)
      fs.closeSync(vmFile)
      fs.closeSync(isolateFile)
      Log.d(TAG, "copyResource end")
    } else {
      Log.d(TAG, "no copyResource")
    }
  }

  /**
   * Ensures that Dart VM initialization is complete.
   * This method initializes the Dart VM with the appropriate shell arguments
   * based on the build mode (debug, profile, or release).
   * @param shellArgs - Optional array of shell arguments, will be created if null
   */
  ensureInitializationComplete(shellArgs: Array<string> | null) {
    if (this.initialized) {
      return;
    }
    if (shellArgs == null) {
      shellArgs = new Array<string>();
    }
    shellArgs.push("--icu-symbol-prefix=_binary_icudtl_dat");
    shellArgs.push(
      "--icu-native-lib-path="
        + this.flutterApplicationInfo!.nativeLibraryDir
        + FILE_SEPARATOR + DEFAULT_LIBRARY
    );

    let kernelPath: string = "";
    if (this.flutterApplicationInfo!.isDebugMode) {
      Log.d(TAG, "this.initResult!.dataDirPath=" + this.initResult!.dataDirPath)
      const snapshotAssetPath =
        this.initResult!.dataDirPath + FILE_SEPARATOR + this.flutterApplicationInfo!.flutterAssetsDir;
      kernelPath = snapshotAssetPath + FILE_SEPARATOR + DEFAULT_KERNEL_BLOB;
      shellArgs.push("--" + SNAPSHOT_ASSET_PATH_KEY + "=" + snapshotAssetPath);
      shellArgs.push("--" + VM_SNAPSHOT_DATA_KEY + "=" + this.flutterApplicationInfo!.vmSnapshotData);
      shellArgs.push(
        "--" + ISOLATE_SNAPSHOT_DATA_KEY + "=" + this.flutterApplicationInfo!.isolateSnapshotData);
      shellArgs.push('--enable-checked-mode')
      shellArgs.push('--verbose-logging')
    } else {
      shellArgs.push(
        "--" + AOT_SHARED_LIBRARY_NAME + "=" + this.flutterApplicationInfo!.aotSharedLibraryName);
      shellArgs.push(
        "--"
          + AOT_SHARED_LIBRARY_NAME
          + "="
          + this.flutterApplicationInfo!.nativeLibraryDir
          + FILE_SEPARATOR
          + this.flutterApplicationInfo!.aotSharedLibraryName);

      const snapshotAssetPath =
        this.initResult!.dataDirPath + FILE_SEPARATOR + this.flutterApplicationInfo!.flutterAssetsDir;

      if (this.flutterApplicationInfo!.isProfile) {
        shellArgs.push("--" + AOT_VMSERVICE_SHARED_LIBRARY_NAME + "=" + VMSERVICE_SNAPSHOT_LIBRARY);
      }
    }
    shellArgs.push("--cache-dir-path=" + this.initResult!.engineCachesPath);
    if (StringUtils.isNotEmpty(this.flutterApplicationInfo!.domainNetworkPolicy)) {
      shellArgs.push("--domain-network-policy=" + this.flutterApplicationInfo!.domainNetworkPolicy);
    }

    const resourceCacheMaxBytesThreshold = 1080 * 1920 * 12 * 4;
    shellArgs.push("--resource-cache-max-bytes-threshold=" + resourceCacheMaxBytesThreshold);

    shellArgs.push("--prefetched-default-font-manager");

    shellArgs.push("--leak-vm=" + true);

    if (this.isEnableImpeller == true && deviceInfo.productModel != "emulator") {
        shellArgs.push("--enable-impeller");
        Log.d(TAG, "Enable Impeller in Ohos.");
    } else {
      Log.d(TAG, "Do not find enableImpeller tag or enableImpeller tag set to false, enable Skia in Ohos.");
    }

    // Final initialization operation
    const costTime = Date.now() - this.initStartTimestampMillis;
    this.flutterNapi.init(
      this.context!,
      shellArgs,
      kernelPath,
      this.initResult!.appStoragePath,
      this.initResult!.engineCachesPath!,
      costTime
    );
    this.initialized = true;
    Log.d(TAG, "ensureInitializationComplete")
  }

  /**
   * Finds the path to the Flutter app bundle.
   * @returns The path to the Flutter assets directory, or empty string if not initialized
   */
  findAppBundlePath(): string {
    return this.flutterApplicationInfo == null ? "" : this.flutterApplicationInfo!.flutterAssetsDir;
  }

  /**
   * Gets the lookup key for an asset file.
   * @param asset - The asset file path
   * @param packageName - Optional package name for package-specific assets
   * @returns The full asset path lookup key
   */
  getLookupKeyForAsset(asset: string, packageName?: string): string {
    if (typeof packageName === 'string' && packageName.trim().length > 0) {
        return this.fullAssetPathFrom('packages' + FILE_SEPARATOR + packageName + FILE_SEPARATOR + asset);
    }
    return this.fullAssetPathFrom(asset);
  }

  /**
   * Gets the full asset path from a relative file path.
   * @param filePath - The relative file path
   * @returns The full asset path, or empty string if not initialized
   */
  fullAssetPathFrom(filePath: string): string {
    return this.flutterApplicationInfo == null ? "" : this.flutterApplicationInfo!.flutterAssetsDir + "/" + filePath;
  }

  private checkTimestamp(dataDir: string): string | null {
    let bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const expectedTimestamp = TIMESTAMP_PREFIX + bundleInfo.versionCode + "-" + bundleInfo.updateTime;
    const existingTimestamps = this.getExistingTimestamps(dataDir);
    if (existingTimestamps == null) {
      Log.i(TAG, "No extracted resources found");
      return expectedTimestamp;
    }

    if (existingTimestamps.length == 1) {
      Log.i(TAG, "Found extracted resources " + existingTimestamps[0]);
    }

    if (existingTimestamps.length != 1 || !(expectedTimestamp == existingTimestamps[0])) {
      Log.i(TAG, "Resource version mismatch " + expectedTimestamp);
      return expectedTimestamp;
    }

    return null;
  }

  private getExistingTimestamps(dataDir: string): string[] {
    return fs.accessSync(dataDir) ? fs.listFileSync(dataDir, {
      filter: {
        displayName: [`${TIMESTAMP_PREFIX}*`]
      }
    }) : new Array();
  }

  /**
   * Checks if the FlutterLoader has been initialized.
   * @returns true if initialized, false otherwise
   */
  isInitialized(): boolean {
    return this.initialized;
  }
}

/**
 * Contains initialization result paths for the Flutter engine.
 */
class InitResult {
  appStoragePath: string;
  engineCachesPath: string;
  dataDirPath: string;

  /**
   * Constructs a new InitResult instance.
   * @param appStoragePath - Path to the application storage directory
   * @param engineCachesPath - Path to the engine caches directory
   * @param dataDirPath - Path to the data directory
   */
  constructor(appStoragePath: string,
    engineCachesPath: string,
    dataDirPath: string) {
    this.appStoragePath = appStoragePath;
    this.engineCachesPath = engineCachesPath;
    this.dataDirPath = dataDirPath;
  }
}
