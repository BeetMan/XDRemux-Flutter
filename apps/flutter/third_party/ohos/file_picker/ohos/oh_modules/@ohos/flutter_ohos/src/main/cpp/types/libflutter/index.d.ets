/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import common from '@ohos.app.ability.common';
import resourceManager from '@ohos.resourceManager';
import image from '@ohos.multimedia.image';
import FlutterNapi from '../../../ets/embedding/engine/FlutterNapi';
import { ByteBuffer } from '../../../ets/util/ByteBuffer';
import { FlutterCallbackInformation } from '../../../ets/view/FlutterCallbackInformation';

/**
 * Updates the refresh rate for the Flutter engine.
 * @param rate - The refresh rate value to set
 */
export const nativeUpdateRefreshRate: (
  rate: number
) => void;

/**
 * Initializes SkFontMgr::RefDefault() to prefetch the default font manager.
 * This should be called before using fonts in the Flutter engine.
 */
export const nativePrefetchDefaultFontManager: () => void;

/**
 * Checks and reloads fonts for the specified shell holder.
 * @param nativeShellHolderId - The ID of the native shell holder
 */
export const nativeCheckAndReloadFont: (nativeShellHolderId: number) => void;

/**
 * Updates the size of the Flutter view.
 * @param width - The new width in pixels
 * @param height - The new height in pixels
 */
export const nativeUpdateSize: (
  width: number,
  height: number
) => void;

/**
 * Updates the pixel density of the display.
 * @param densityPixels - The pixel density value (dots per inch)
 */
export const nativeUpdateDensity: (
  densityPixels: number
) => void;

/**
 * Initializes the Dart VM and Flutter engine.
 * @param context - The application context
 * @param args - Command line arguments for the Flutter engine
 * @param bundlePath - Path to the Flutter bundle
 * @param appStoragePath - Path to the application storage directory
 * @param engineCachesPath - Path to the engine caches directory
 * @param initTimeMillis - Initialization time in milliseconds
 * @param productModel - Product model identifier
 * @returns The native shell holder ID, or null if initialization fails
 */
export const nativeInit: (
  context: common.Context,
  args: Array<string>,
  bundlePath: string,
  appStoragePath: string,
  engineCachesPath: string,
  initTimeMillis: number,
  productModel: string
) => number | null;

/**
 * Attaches a FlutterNapi instance to the engine.
 * @param napi - The FlutterNapi instance to attach
 * @returns The native shell holder ID
 */
export const nativeAttach: (napi: FlutterNapi) => number;

/**
 * Spawns a new Flutter shell instance.
 * @param nativeSpawningShellId - The ID of the spawning shell, or null for a new shell
 * @param entrypointFunctionName - Name of the entrypoint function
 * @param pathToEntrypointFunction - Path to the entrypoint function
 * @param initialRoute - Initial route for navigation
 * @param entrypointArgs - Arguments to pass to the entrypoint function
 * @param napi - The FlutterNapi instance
 * @returns The native shell holder ID of the spawned shell
 */
export const nativeSpawn: (
  nativeSpawningShellId: number | null,
  entrypointFunctionName: string,
  pathToEntrypointFunction: string,
  initialRoute: string,
  entrypointArgs: Array<string>,
  napi: FlutterNapi
) => number;

/**
 * Runs a Flutter bundle and snapshot from a library.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param bundlePath - Path to the Flutter bundle
 * @param entrypointFunctionName - Name of the entrypoint function
 * @param pathToEntrypointFunction - Path to the entrypoint function
 * @param assetManager - Resource manager for accessing assets
 * @param entrypointArgs - Arguments to pass to the entrypoint function
 */
export const nativeRunBundleAndSnapshotFromLibrary: (
  nativeShellHolderId: number,
  bundlePath: string,
  entrypointFunctionName: string,
  pathToEntrypointFunction: string,
  assetManager: resourceManager.ResourceManager,
  entrypointArgs: Array<string>
) => void;

/**
 * Sends a data-carrying response to a platform message received from Dart.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param responseId - The response ID for the platform message
 * @param message - The message data as an ArrayBuffer
 * @param position - The position in the message buffer
 */
export const nativeInvokePlatformMessageResponseCallback: (nativeShellHolderId: number, responseId: number, message: ArrayBuffer, position: number) => void;

/**
 * Sends an empty response to a platform message received from Dart.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param responseId - The response ID for the platform message
 */
export const nativeInvokePlatformMessageEmptyResponseCallback: (nativeShellHolderId: number, responseId: number) => void;

/**
 * Sends a data-carrying platform message to Dart.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param channel - The channel name for the platform message
 * @param message - The message data as an ArrayBuffer
 * @param position - The position in the message buffer
 * @param responseId - The response ID for the platform message
 */
export const nativeDispatchPlatformMessage: (nativeShellHolderId: number, channel: String, message: ArrayBuffer, position: number, responseId: number) => void;

/**
 * Sends an empty platform message to Dart.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param channel - The channel name for the platform message
 * @param responseId - The response ID for the platform message
 */
export const nativeDispatchEmptyPlatformMessage: (nativeShellHolderId: number, channel: String, responseId: number) => void;

/**
 * Sets the viewport metrics for the Flutter view.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param devicePixelRatio - The device pixel ratio
 * @param physicalWidth - Physical width in pixels
 * @param physicalHeight - Physical height in pixels
 * @param physicalPaddingTop - Top padding in physical pixels
 * @param physicalPaddingRight - Right padding in physical pixels
 * @param physicalPaddingBottom - Bottom padding in physical pixels
 * @param physicalPaddingLeft - Left padding in physical pixels
 * @param physicalViewInsetTop - Top view inset in physical pixels
 * @param physicalViewInsetRight - Right view inset in physical pixels
 * @param physicalViewInsetBottom - Bottom view inset in physical pixels
 * @param physicalViewInsetLeft - Left view inset in physical pixels
 * @param systemGestureInsetTop - Top system gesture inset
 * @param systemGestureInsetRight - Right system gesture inset
 * @param systemGestureInsetBottom - Bottom system gesture inset
 * @param systemGestureInsetLeft - Left system gesture inset
 * @param physicalTouchSlop - Physical touch slop value
 * @param displayFeaturesBounds - Array of display feature bounds
 * @param displayFeaturesType - Array of display feature types
 * @param displayFeaturesState - Array of display feature states
 */
export const nativeSetViewportMetrics: (nativeShellHolderId: number, devicePixelRatio: number, physicalWidth: number
                                        , physicalHeight: number, physicalPaddingTop: number, physicalPaddingRight: number
                                        , physicalPaddingBottom: number, physicalPaddingLeft: number, physicalViewInsetTop: number
                                        , physicalViewInsetRight: number, physicalViewInsetBottom: number, physicalViewInsetLeft: number
                                        , systemGestureInsetTop: number, systemGestureInsetRight: number, systemGestureInsetBottom: number
                                        , systemGestureInsetLeft: number, physicalTouchSlop: number, displayFeaturesBounds: Array<number>
                                        , displayFeaturesType: Array<number>, displayFeaturesState: Array<number>) => void;

/**
 * Gets the system languages and populates the provided array.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param languages - Array to be populated with system language codes
 */
export const nativeGetSystemLanguages: (nativeShellHolderId: number, languages: Array<string>) => void;

/**
 * Attaches a Flutter engine to an XComponent.
 * @param xcomponentId - The ID of the XComponent
 * @param nativeShellHolderId - The ID of the native shell holder
 */
export const nativeXComponentAttachFlutterEngine: (xcomponentId: string, nativeShellHolderId: number) => void;

/**
 * Called before drawing the XComponent.
 * @param xcomponentId - The ID of the XComponent
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param width - The width of the component
 * @param height - The height of the component
 */
export const nativeXComponentPreDraw: (xcomponentId: string, nativeShellHolderId: number, width: number, height: number) => void;

/**
 * Detaches a Flutter engine from an XComponent.
 * @param xcomponentId - The ID of the XComponent
 * @param nativeShellHolderId - The ID of the native shell holder
 */
export const nativeXComponentDetachFlutterEngine: (xcomponentId: string, nativeShellHolderId: number) => void;

/**
 * Dispatches a mouse wheel event to the Flutter engine.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param xcomponentId - The ID of the XComponent
 * @param eventType - The type of the mouse wheel event
 * @param fingerId - The finger ID for the event
 * @param globalX - Global X coordinate
 * @param globalY - Global Y coordinate
 * @param offsetY - Vertical scroll offset
 * @param timestamp - Event timestamp
 */
export const nativeXComponentDispatchMouseWheel: (nativeShellHolderId: number,
                                                  xcomponentId: string,
                                                  eventType: string,
                                                  fingerId: number,
                                                  globalX: number,
                                                  globalY: number,
                                                  offsetY: number,
                                                  timestamp: number
                                                  ) => void;


/**
 * Detaches the association between FlutterNapi and the engine.
 * This method should only be called when FlutterNapi is already associated with the engine.
 * @param nativeShellHolderId - The ID of the native shell holder to destroy
 */
export const nativeDestroy: (
  nativeShellHolderId: number
) => void;


/**
 * Unregisters a texture from the Flutter engine.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture to unregister
 */
export const nativeUnregisterTexture: (nativeShellHolderId: number, textureId: number) => void;

/**
 * Registers a PixelMap as a texture in the Flutter engine.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture
 * @param pixelMap - The PixelMap to register
 */
export const nativeRegisterPixelMap: (nativeShellHolderId: number, textureId: number, pixelMap: PixelMap) => void;

/**
 * Sets the background PixelMap for a texture.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture
 * @param pixelMap - The PixelMap to use as background
 */
export const nativeSetTextureBackGroundPixelMap: (nativeShellHolderId: number, textureId: number, pixelMap: PixelMap) => void;

/**
 * Sets the background color for a texture.
 * @deprecated since 3.7
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture
 * @param color - The color value as a number
 */
export const nativeSetTextureBackGroundColor: (nativeShellHolderId: number, textureId: number, color: number) => void;

/**
 * Registers a texture with the Flutter engine.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture to register
 * @returns The registered texture ID
 */
export const nativeRegisterTexture: (nativeShellHolderId: number, textureId: number) => number;

/**
 * Gets the window ID for a texture.
 * @deprecated since 3.22
 * @useinstead nativeGetTextureWindowPtr
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture
 * @returns The window ID
 */
export const nativeGetTextureWindowId: (nativeShellHolderId: number, textureId: number) => number;

/**
 * Gets the window pointer for a texture.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture
 * @returns The window pointer as a bigint
 */
export const nativeGetTextureWindowPtr: (nativeShellHolderId: number, textureId: number) => bigint;

/**
 * Sets an external native image for a texture.
 * @deprecated since 3.22
 * @useinstead nativeSetExternalNativeImagePtr
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture
 * @param native_image - The native image ID
 * @returns The result code
 */
export const nativeSetExternalNativeImage: (nativeShellHolderId: number, textureId: number, native_image: number) => number;

/**
 * Sets an external native image pointer for a texture.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture
 * @param native_image_ptr - The native image pointer as a bigint
 * @returns The result code
 */
export const nativeSetExternalNativeImagePtr: (nativeShellHolderId: number, textureId: number, native_image_ptr: bigint) => number;

/**
 * Resets an external texture.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture
 * @param need_surfaceId - Whether a surface ID is needed
 * @returns The result code
 */
export const nativeResetExternalTexture: (nativeShellHolderId: number, textureId: number, need_surfaceId: boolean) => number;

/**
 * Encodes a string to UTF-8 bytes.
 * @param str - The string to encode
 * @returns The UTF-8 encoded bytes as a Uint8Array
 */
export const nativeEncodeUtf8: (str: string) => Uint8Array;

/**
 * Decodes UTF-8 bytes to a string.
 * @param array - The UTF-8 encoded bytes as a Uint8Array
 * @returns The decoded string
 */
export const nativeDecodeUtf8: (array: Uint8Array) => string;

/**
 * Sets the buffer size for a texture.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture
 * @param width - The buffer width
 * @param height - The buffer height
 */
export const nativeSetTextureBufferSize: (nativeShellHolderId: number, textureId: number, width: number, height: number) => void;

/**
 * Notifies the Flutter engine that a texture is being resized.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param textureId - The ID of the texture
 * @param width - The new width
 * @param height - The new height
 */
export const nativeNotifyTextureResizing: (nativeShellHolderId: number, textureId: number, width: number, height: number) => void;

/**
 * Enables or disables frame caching for the Flutter engine.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param enable - Whether to enable frame caching
 */
export const nativeEnableFrameCache: (nativeShellHolderId: number, enable: boolean) => void;

/**
 * Updates whether the same engine is still visible in a PiP window.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param visible - Whether the PiP window is visible
 */
export const nativeSetPipVisible: (nativeShellHolderId: number, visible: boolean) => void;

/**
 * Looks up callback information for a given handler.
 * @param callback - The FlutterCallbackInformation object to populate
 * @param handler - The handler number
 * @returns The result code
 */
export const nativeLookupCallbackInformation: (callback: FlutterCallbackInformation, handler: number) => number;

/**
 * Looks up callback information for a given handler (bigint).
 * @param callback - The FlutterCallbackInformation object to populate
 * @param handler - The handler as a bigint
 * @returns The result code
 */
export const nativeLookupCallbackInformationBigInt: (callback: FlutterCallbackInformation, handler: bigint) => number;

/**
 * Checks if a Unicode code point is an emoji.
 * @param code - The Unicode code point
 * @returns 1 if it is an emoji, 0 otherwise
 */
export const nativeUnicodeIsEmoji: (code: number) => number;

/**
 * Checks if a Unicode code point is an emoji modifier.
 * @param code - The Unicode code point
 * @returns 1 if it is an emoji modifier, 0 otherwise
 */
export const nativeUnicodeIsEmojiModifier: (code: number) => number;

/**
 * Checks if a Unicode code point is an emoji modifier base.
 * @param code - The Unicode code point
 * @returns 1 if it is an emoji modifier base, 0 otherwise
 */
export const nativeUnicodeIsEmojiModifierBase: (code: number) => number;

/**
 * Checks if a Unicode code point is a variation selector.
 * @param code - The Unicode code point
 * @returns 1 if it is a variation selector, 0 otherwise
 */
export const nativeUnicodeIsVariationSelector: (code: number) => number;

/**
 * Checks if a Unicode code point is a regional indicator symbol.
 * @param code - The Unicode code point
 * @returns 1 if it is a regional indicator symbol, 0 otherwise
 */
export const nativeUnicodeIsRegionalIndicatorSymbol: (code: number) => number;

/**
 * Sets accessibility features in the accessibility channel.
 * @param accessibilityFeatureFlags - The accessibility feature flags
 * @param responseId - The response ID for the platform message
 */
export const nativeSetAccessibilityFeatures: (accessibilityFeatureFlags: number, responseId: number) => void;

/**
 * Notifies the Flutter engine of an accessibility state change.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param state - The new accessibility state
 */
export const nativeAccessibilityStateChange: (nativeShellHolderId: number, state: Boolean) => void;

/**
 * Announces an accessibility message to the Flutter engine.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param message - The message to announce
 */
export const nativeAccessibilityAnnounce: (nativeShellHolderId: number, message: string) => void;

/**
 * Handles an accessibility tap event.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param nodeId - The ID of the accessibility node that was tapped
 */
export const nativeAccessibilityOnTap: (nativeShellHolderId: number, nodeId: number) => void;

/**
 * Handles an accessibility long press event.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param nodeId - The ID of the accessibility node that was long pressed
 */
export const nativeAccessibilityOnLongPress: (nativeShellHolderId: number, nodeId: number) => void;

/**
 * Handles an accessibility tooltip event.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param message - The tooltip message
 */
export const nativeAccessibilityOnTooltip: (nativeShellHolderId: number, message: string) => void;

/**
 * Enables or disables semantics for the Flutter engine.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param enabled - Whether to enable semantics
 */
export const nativeSetSemanticsEnabled: (nativeShellHolderId: number, enabled: boolean) => void;

/**
 * Sets the font weight scale for the Flutter engine.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param fontWeightScale - The font weight scale value
 */
export const nativeSetFontWeightScale: (nativeShellHolderId: number, fontWeightScale: number) => void;

/**
 * Sets the Flutter navigation action state.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param isNavigate - Whether navigation is active
 */
export const nativeSetFlutterNavigationAction: (nativeShellHolderId: number, isNavigate: boolean) => void;

/**
 * Enables or disables VSync for the Flutter engine.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param isEnable - Whether to enable VSync
 */
export const nativeSetDVsyncSwitch: (nativeShellHolderId: number, isEnable: boolean) => void;

/**
 * Updates the current XComponent ID.
 * @param xcomponent_id - The ID of the XComponent
 */
export const nativeUpdateCurrentXComponentId: (xcomponent_id: string) => void;

/**
 * @brief  [LTPO] Performs animation voting based on type and velocity.
 * @note
 * @param  type: Animation type, 0-TRANSLATE, 1-SCALE, 2-ROTATION
 * @param  velocity: Current animation velocity. Unit is logical pixels
 * @return none
 */
export const nativeAnimationVoting: (type: number, velocity: number) => void;

/**
 * @brief  [LTPO] Performs video voting based on duration and frame count.
 * @note
 * @param  seconds: Seconds
 * @param  frameCount: Frame count within a certain period of time
 * @return none
 */
export const nativeVideoVoting: (seconds: number, frameCount: number) => void;

/**
 * @brief  [LTPO] Preload Frame Rate Configuration File
 * @note
 * @param  none
 * @return none
 */
export const nativePrefetchFramesCfg: () => void;

/**
 * @brief  [LTPO] Check LTPO Activation Status
 * @note
 * @param  none
 * @return number 0: Disabled, 1: Enabled, 2: Uninitialized
 */
export const nativeCheckLTPOSwitchState: () => number;

/**
 * Sets QoS (Quality of Service) settings when low memory is detected.
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param lowMemoryLevel - The low memory level
 */
export const nativeSetQosOnLowMemory: (nativeShellHolderId: number, lowMemoryLevel: number) => void;

/**
 * Reports scrolling / animation status to the OHOS hiAppEvent pipeline (e.g. scroll start vs scroll end).
 * @param nativeShellHolderId - The ID of the native shell holder
 * @param animationStatus - Scrolling status code (e.g. scroll start / scroll end for hiAppEvent)
 */
export const nativeSetAnimationStatus: (nativeShellHolderId: number, animationStatus: number) => void;

/**
 * Notifies the system that the current UI page changed (OH_AbilityRuntime_NotifyPageChanged). Requires API 23+.
 * @param pageName - Name of the current page
 * @param pageNameLen - Length of the page name string (as required by the native API)
 * @param windowID - Window identifier for the page
 * @returns 0 on success, non-zero on failure; returns 0 when the API is not supported on older SDKs
 */
export const nativeNotifyPageChanged: (pageName: string, pageNameLen: number, windowID: number) => number;

/**
 * @brief  [LTPO] Send high frame rate request when LTPO is enabled
 * @note
 * @param  nativeShellHolderId - The ID of the native shell holder
 * @return none
 */
export const nativeLTPODispatchHighFrameRate: (nativeShellHolderId: number) => void;
