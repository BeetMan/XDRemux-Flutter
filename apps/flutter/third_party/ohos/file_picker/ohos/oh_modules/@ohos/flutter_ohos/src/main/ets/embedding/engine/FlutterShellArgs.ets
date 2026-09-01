/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterShellArgs.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import Want from '@ohos.app.ability.Want';

/**
 * Encapsulates arguments for the Flutter shell.
 * This class provides methods to parse and manage command-line arguments
 * that are passed to the Flutter engine during initialization.
 */
export default class FlutterShellArgs {
  static ARG_KEY_TRACE_STARTUP = "trace-startup";
  static ARG_TRACE_STARTUP = "--trace-startup";
  static ARG_KEY_START_PAUSED = "start-paused";
  static ARG_START_PAUSED = "--start-paused";
  static ARG_KEY_DISABLE_SERVICE_AUTH_CODES = "disable-service-auth-codes";
  static ARG_DISABLE_SERVICE_AUTH_CODES = "--disable-service-auth-codes";
  static ARG_KEY_ENDLESS_TRACE_BUFFER = "endless-trace-buffer";
  static ARG_ENDLESS_TRACE_BUFFER = "--endless-trace-buffer";
  static ARG_KEY_USE_TEST_FONTS = "use-test-fonts";
  static ARG_USE_TEST_FONTS = "--use-test-fonts";
  static ARG_KEY_ENABLE_DART_PROFILING = "enable-dart-profiling";
  static ARG_ENABLE_DART_PROFILING = "--enable-dart-profiling";
  static ARG_KEY_PROFILE_STARTUP = "profile-startup";
  static ARG_PROFILE_STARTUP = "--profile-startup";
  static ARG_KEY_ENABLE_SOFTWARE_RENDERING = "enable-software-rendering";
  static ARG_ENABLE_SOFTWARE_RENDERING = "--enable-software-rendering";
  static ARG_KEY_SKIA_DETERMINISTIC_RENDERING = "skia-deterministic-rendering";
  static ARG_SKIA_DETERMINISTIC_RENDERING = "--skia-deterministic-rendering";
  static ARG_KEY_TRACE_SKIA = "trace-skia";
  static ARG_TRACE_SKIA = "--trace-skia";
  static ARG_KEY_TRACE_SKIA_ALLOWLIST = "trace-skia-allowlist";
  static ARG_TRACE_SKIA_ALLOWLIST = "--trace-skia-allowlist=";
  static ARG_KEY_TRACE_SYSTRACE = "trace-systrace";
  static ARG_TRACE_SYSTRACE = "--trace-systrace";
  static ARG_KEY_ENABLE_IMPELLER = "enable-impeller";
  static ARG_ENABLE_IMPELLER = "--enable-impeller";
  static ARG_KEY_DUMP_SHADER_SKP_ON_SHADER_COMPILATION =
    "dump-skp-on-shader-compilation";
  static ARG_DUMP_SHADER_SKP_ON_SHADER_COMPILATION =
    "--dump-skp-on-shader-compilation";
  static ARG_KEY_CACHE_SKSL = "cache-sksl";
  static ARG_CACHE_SKSL = "--cache-sksl";
  static ARG_KEY_PURGE_PERSISTENT_CACHE = "purge-persistent-cache";
  static ARG_PURGE_PERSISTENT_CACHE = "--purge-persistent-cache";
  static ARG_KEY_VERBOSE_LOGGING = "verbose-logging";
  static ARG_VERBOSE_LOGGING = "--verbose-logging";
  static ARG_KEY_OBSERVATORY_PORT = "observatory-port";
  static ARG_OBSERVATORY_PORT = "--observatory-port=";
  static ARG_KEY_DART_FLAGS = "dart-flags";
  static ARG_DART_FLAGS = "--dart-flags=";
  static ARG_KEY_MSAA_SAMPLES = "msaa-samples";
  static ARG_MSAA_SAMPLES = "--msaa-samples=";

  /**
   * Parses arguments from a Want object and creates a FlutterShellArgs instance.
   * @param want - The Want object containing the parameters
   * @returns A FlutterShellArgs instance with parsed arguments
   */
  static fromWant(want: Want): FlutterShellArgs {
    let flutterShellArgs: FlutterShellArgs = new FlutterShellArgs();
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_TRACE_STARTUP, FlutterShellArgs.ARG_TRACE_STARTUP, want,
      flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_START_PAUSED, FlutterShellArgs.ARG_START_PAUSED, want,
      flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_DISABLE_SERVICE_AUTH_CODES,
      FlutterShellArgs.ARG_DISABLE_SERVICE_AUTH_CODES, want, flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_ENDLESS_TRACE_BUFFER, FlutterShellArgs.ARG_ENDLESS_TRACE_BUFFER,
      want, flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_USE_TEST_FONTS, FlutterShellArgs.ARG_USE_TEST_FONTS, want,
      flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_ENABLE_DART_PROFILING,
      FlutterShellArgs.ARG_ENABLE_DART_PROFILING, want, flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_PROFILE_STARTUP,
      FlutterShellArgs.ARG_PROFILE_STARTUP, want, flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_ENABLE_SOFTWARE_RENDERING,
      FlutterShellArgs.ARG_ENABLE_SOFTWARE_RENDERING, want, flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_SKIA_DETERMINISTIC_RENDERING,
      FlutterShellArgs.ARG_SKIA_DETERMINISTIC_RENDERING, want, flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_TRACE_SKIA, FlutterShellArgs.ARG_TRACE_SKIA, want,
      flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_TRACE_SYSTRACE, FlutterShellArgs.ARG_TRACE_SYSTRACE, want,
      flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_ENABLE_IMPELLER, FlutterShellArgs.ARG_ENABLE_IMPELLER, want,
      flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_DUMP_SHADER_SKP_ON_SHADER_COMPILATION,
      FlutterShellArgs.ARG_DUMP_SHADER_SKP_ON_SHADER_COMPILATION, want, flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_CACHE_SKSL, FlutterShellArgs.ARG_CACHE_SKSL, want,
      flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_PURGE_PERSISTENT_CACHE,
      FlutterShellArgs.ARG_PURGE_PERSISTENT_CACHE, want, flutterShellArgs);
    FlutterShellArgs.checkArg(FlutterShellArgs.ARG_KEY_VERBOSE_LOGGING, FlutterShellArgs.ARG_VERBOSE_LOGGING, want,
      flutterShellArgs);

    let skia_allow_list: Object = want.parameters![FlutterShellArgs.ARG_KEY_TRACE_SKIA_ALLOWLIST];
    if (skia_allow_list != undefined) {
      flutterShellArgs.add(FlutterShellArgs.ARG_TRACE_SKIA_ALLOWLIST + (skia_allow_list as string));
    }

    let observatory_port: Object = want.parameters![FlutterShellArgs.ARG_KEY_OBSERVATORY_PORT];
    if (observatory_port != undefined && (observatory_port as number > 0)) {
      flutterShellArgs.add(FlutterShellArgs.ARG_OBSERVATORY_PORT + (observatory_port as number));
    }

    let msaa: Object = want.parameters![FlutterShellArgs.ARG_KEY_MSAA_SAMPLES];
    if (msaa != undefined && (msaa as number > 1)) {
      flutterShellArgs.add(FlutterShellArgs.ARG_MSAA_SAMPLES + (msaa as number));
    }

    let dart_flags: Object = want.parameters![FlutterShellArgs.ARG_KEY_DART_FLAGS];
    if (dart_flags != undefined) {
      flutterShellArgs.add(FlutterShellArgs.ARG_DART_FLAGS + (msaa as string));
    }
    return flutterShellArgs;
  }

  /**
   * Checks if an argument exists in the Want parameters and adds it to FlutterShellArgs if present.
   * @param argKey - The key to look for in the Want parameters
   * @param argFlag - The command-line flag to add if the argument is present
   * @param want - The Want object containing the parameters
   * @param flutterShellArgs - The FlutterShellArgs instance to add the flag to
   */
  static checkArg(argKey: string, argFlag: string, want: Want, flutterShellArgs: FlutterShellArgs) {
    if (want.parameters == undefined) {
      return;
    }
    let value: Object = want.parameters![argKey];
    if (value != undefined && value as Boolean) {
      flutterShellArgs.add(argFlag);
    }
  }

  /** Command-line arguments for the Flutter shell. */
  args: Set<string> = new Set();

  /**
   * Adds an argument to the set of shell arguments.
   * @param arg - The argument string to add
   */
  add(arg: string) {
    this.args.add(arg);
  }

  /**
   * Removes an argument from the set of shell arguments.
   * @param arg - The argument string to remove
   */
  remove(arg: string) {
    this.args.delete(arg);
  }

  /**
   * Converts the set of arguments to an array.
   * @returns An array containing all shell arguments
   */
  toArray(): Array<string> {
    return Array.from(this.args);
  }
}