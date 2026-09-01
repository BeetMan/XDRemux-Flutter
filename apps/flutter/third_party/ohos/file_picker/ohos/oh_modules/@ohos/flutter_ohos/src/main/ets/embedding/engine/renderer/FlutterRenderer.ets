/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import image from '@ohos.multimedia.image';
import { BusinessError } from '@ohos.base';
import { SurfaceTextureEntry, TextureRegistry } from '../../../view/TextureRegistry';
import { FlutterAbility } from '../../ohos/FlutterAbility';
import FlutterNapi from '../FlutterNapi';
import Log from '../../../util/Log';

const TAG = "FlutterRenderer"

/**
 * Renderer for Flutter content that manages textures and rendering operations.
 * This class implements TextureRegistry and provides methods to register and manage textures
 * for use in Flutter applications.
 */
export class FlutterRenderer implements TextureRegistry {
  private flutterNapi: FlutterNapi;
  private static globalTextureId: number = 0;

  /**
   * Constructs a new FlutterRenderer instance.
   * @param flutterNapi - The FlutterNapi instance for native communication
   */
  constructor(flutterNapi: FlutterNapi) {
    this.flutterNapi = flutterNapi;
  }

  /**
   * @deprecated since 3.7
   */
  createSurfaceTexture(): SurfaceTextureEntry {
    let receiver: image.ImageReceiver = this.getImageReceiver();
    return this.registerSurfaceTexture(receiver);
  }

  /**
   * Gets the next available texture ID.
   * @returns A unique texture ID
   */
  getTextureId(): number {
    let nextTextureId: number = FlutterRenderer.globalTextureId + 1;
    FlutterRenderer.globalTextureId = FlutterRenderer.globalTextureId + 1;
    Log.i(TAG, "getTextureId: " + nextTextureId)
    return nextTextureId;
  }

  /**
   * Registers a texture with the Flutter engine.
   * @param textureId - The texture ID to register
   * @returns A SurfaceTextureEntry containing the registered texture information
   */
  registerTexture(textureId: number): SurfaceTextureEntry {
    let surfaceTextureRegistryEntry = new SurfaceTextureRegistryEntry(textureId);
    let surfaceId = this.flutterNapi.registerTexture(textureId);
    Log.i(TAG, "registerTexture, surfaceId=" + surfaceId);
    surfaceTextureRegistryEntry.setSurfaceId(surfaceId);
    let nativeWindowId = this.flutterNapi.getTextureNativeWindowId(textureId);
    surfaceTextureRegistryEntry.setNativeWindowId(nativeWindowId);
    let nativeWindowPtr = this.flutterNapi.getTextureNativeWindowPtr(textureId);
    surfaceTextureRegistryEntry.setNativeWindowPtr(nativeWindowPtr);
    return surfaceTextureRegistryEntry;
  }

  /**
   * @deprecated since 3.7
   */
  registerSurfaceTexture(receiver: image.ImageReceiver): SurfaceTextureEntry {
    let nextTextureId: number = FlutterRenderer.globalTextureId + 1;
    FlutterRenderer.globalTextureId = FlutterRenderer.globalTextureId + 1;
    let surfaceTextureRegistryEntry = new SurfaceTextureRegistryEntry(nextTextureId);
    return surfaceTextureRegistryEntry;
  }

  /**
   * Registers a PixelMap as a texture.
   * @param pixelMap - The PixelMap to register
   * @returns The texture ID assigned to the PixelMap
   */
  registerPixelMap(pixelMap: PixelMap): number {
    let nextTextureId: number = this.getTextureId();
    this.flutterNapi.registerPixelMap(nextTextureId, pixelMap);
    return nextTextureId;
  }

  /**
   * Sets the background PixelMap for a texture.
   * @param textureId - The texture ID
   * @param pixelMap - The PixelMap to use as background
   */
  setTextureBackGroundPixelMap(textureId: number, pixelMap: PixelMap): void {
    this.flutterNapi.setTextureBackGroundPixelMap(textureId, pixelMap);
  }

  /**
   * @deprecated since 3.7
   */
  setTextureBackGroundColor(textureId: number, color: number): void {
    this.flutterNapi.setTextureBackGroundColor(textureId, color);
  }

  /**
   * Sets the buffer size for a texture.
   * @param textureId - The texture ID
   * @param width - The buffer width
   * @param height - The buffer height
   */
  setTextureBufferSize(textureId: number, width: number, height: number): void {
    this.flutterNapi.setTextureBufferSize(textureId, width, height);
  }

  /**
   * Notifies the Flutter engine that a texture is being resized.
   * @param textureId - The texture ID
   * @param width - The new width
   * @param height - The new height
   */
  notifyTextureResizing(textureId: number, width: number, height: number): void {
    this.flutterNapi.notifyTextureResizing(textureId, width, height);
  }

  /**
   * @deprecated since 3.22
   * @useinstead FlutterRenderer#setExternalNativeImagePtr
   */
  setExternalNativeImage(textureId: number, native_image: number): boolean {
    return this.flutterNapi.setExternalNativeImage(textureId, native_image);
  }

  /**
   * Sets an external native image pointer for a texture.
   * @param textureId - The texture ID
   * @param native_image_ptr - The native image pointer as a bigint
   * @returns true if successful, false otherwise
   */
  setExternalNativeImagePtr(textureId: number, native_image_ptr: bigint): boolean {
    return this.flutterNapi.setExternalNativeImagePtr(textureId, native_image_ptr);
  }

  /**
   * Resets an external texture.
   * @param textureId - The texture ID
   * @param need_surfaceId - Whether a surface ID is needed
   * @returns The result code
   */
  resetExternalTexture(textureId: number, need_surfaceId: boolean): number {
    return this.flutterNapi.resetExternalTexture(textureId, need_surfaceId);
  }

  /**
   * Unregisters a texture from the Flutter engine.
   * @param textureId - The texture ID to unregister
   */
  unregisterTexture(textureId: number): void {
    this.flutterNapi.unregisterTexture(textureId);
  }

  /**
   * Called when the system needs to trim memory.
   * @param level - The memory trim level
   */
  onTrimMemory(level: number) {
    throw new Error('Method not implemented.');
  }

  /**
   * @deprecated since 3.7
   */
  private getImageReceiver(): image.ImageReceiver {
    let receiver: image.ImageReceiver = image.createImageReceiver(640, 480, 4, 8);
    if (receiver !== undefined) {
      Log.i(TAG, '[camera test] ImageReceiver is ok');
    } else {
      Log.i(TAG, '[camera test] ImageReceiver is not ok');
    }
    receiver?.on('imageArrival', () => {
      receiver.readNextImage().then(() => { receiver.release() })
    })
    return receiver;
  }

}

/**
 * Entry in the surface texture registry representing a registered texture.
 * This class holds information about a texture including its ID, surface ID, and native window information.
 */
export class SurfaceTextureRegistryEntry implements SurfaceTextureEntry {
  private textureId: number = 0;
  private surfaceId: number = 0;
  private nativeWindowId: number = 0;
  private nativeWindowPtr: bigint = BigInt("0");
  private released: boolean = false;

  /**
   * Constructs a new SurfaceTextureRegistryEntry instance.
   * @param id - The texture ID
   */
  constructor(id: number) {
    this.textureId = id;
  }

  /**
   * Gets the texture ID.
   * @returns The texture ID
   */
  getTextureId(): number {
    return this.textureId;
  }

  /**
   * Gets the surface ID.
   * @returns The surface ID
   */
  getSurfaceId(): number {
    return this.surfaceId;
  }

  /**
   * @deprecated since 3.22
   * @useinstead SurfaceTextureRegistryEntry#getNativeWindowPtr
   */
  getNativeWindowId(): number {
    return this.nativeWindowId;
  }

  /**
   * Gets the native window pointer.
   * @returns The native window pointer as a bigint
   */
  getNativeWindowPtr(): bigint {
    return this.nativeWindowPtr;
  }

  /**
   * Sets the surface ID.
   * @param surfaceId - The surface ID to set
   */
  setSurfaceId(surfaceId: number): void {
    this.surfaceId = surfaceId;
  }

  /**
   * @deprecated since 3.22
   * @useinstead SurfaceTextureRegistryEntry#setNativeWindowPtr
   */
  setNativeWindowId(nativeWindowId: number): void {
    this.nativeWindowId = nativeWindowId;
  }

  /**
   * Sets the native window pointer.
   * @param nativeWindowPtr - The native window pointer as a bigint
   */
  setNativeWindowPtr(nativeWindowPtr: bigint): void {
    this.nativeWindowPtr = nativeWindowPtr;
  }

  /**
   * Releases this texture entry and frees associated resources.
   */
  release() {
    throw new Error('Method not implemented.');
  }
}