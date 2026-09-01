/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterApplicationInfo.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import BuildProfile from "../../../../../../BuildProfile";

const DEFAULT_AOT_SHARED_LIBRARY_NAME = "libapp.so";
const DEFAULT_VM_SNAPSHOT_DATA = "vm_snapshot_data";
const DEFAULT_ISOLATE_SNAPSHOT_DATA = "isolate_snapshot_data";
const DEFAULT_FLUTTER_ASSETS_DIR = "flutter_assets";


/**
 * Contains application information for Flutter initialization.
 * This class holds configuration data such as AOT library names, snapshot data paths,
 * asset directories, and build mode information.
 */
export default class FlutterApplicationInfo {
  /** Name of the AOT shared library. */
  aotSharedLibraryName: string;
  /** Name of the VM snapshot data file. */
  vmSnapshotData: string;
  /** Name of the isolate snapshot data file. */
  isolateSnapshotData: string;
  /** Directory containing Flutter assets. */
  flutterAssetsDir: string;
  /** Domain network policy configuration. */
  domainNetworkPolicy: string;
  /** Directory containing native libraries. */
  nativeLibraryDir: string;
  /** Whether to automatically register plugins. */
  automaticallyRegisterPlugins: boolean;
  /** Whether the application is running in debug mode. */
  isDebugMode: boolean;
  /** Whether the application is running in profile mode. */
  isProfile: boolean;

  /**
   * Constructs a new FlutterApplicationInfo instance.
   * @param aotSharedLibraryName - Name of the AOT shared library, or null to use default
   * @param vmSnapshotData - Name of the VM snapshot data file, or null to use default
   * @param isolateSnapshotData - Name of the isolate snapshot data file, or null to use default
   * @param flutterAssetsDir - Directory containing Flutter assets, or null to use default
   * @param domainNetworkPolicy - Domain network policy, or null for empty string
   * @param nativeLibraryDir - Directory containing native libraries
   * @param automaticallyRegisterPlugins - Whether to automatically register plugins
   */
  constructor(aotSharedLibraryName: string | null,
    vmSnapshotData: string | null,
    isolateSnapshotData: string | null,
    flutterAssetsDir: string | null,
    domainNetworkPolicy: string | null,
    nativeLibraryDir: string,
    automaticallyRegisterPlugins: boolean) {
    this.aotSharedLibraryName = aotSharedLibraryName == null ? DEFAULT_AOT_SHARED_LIBRARY_NAME : aotSharedLibraryName;
    this.vmSnapshotData = vmSnapshotData == null ? DEFAULT_VM_SNAPSHOT_DATA : vmSnapshotData;
    this.isolateSnapshotData = isolateSnapshotData == null ? DEFAULT_ISOLATE_SNAPSHOT_DATA : isolateSnapshotData;
    this.flutterAssetsDir = flutterAssetsDir == null ? DEFAULT_FLUTTER_ASSETS_DIR : flutterAssetsDir;
    this.domainNetworkPolicy = domainNetworkPolicy == null ? "" : domainNetworkPolicy;
    this.nativeLibraryDir = nativeLibraryDir;
    this.automaticallyRegisterPlugins = automaticallyRegisterPlugins;
    this.isDebugMode = "debug" == String(BuildProfile.BUILD_MODE_NAME);
    this.isProfile = "profile" == String(BuildProfile.BUILD_MODE_NAME);
  }
}