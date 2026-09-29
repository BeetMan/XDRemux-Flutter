import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileUri } from '@kit.CoreFileKit';
import systemShare from '@hms.collaboration.systemShare';
import fs from '@ohos.file.fs';

/// Handles xdremux/share: shared files arrive as file:// URIs in systemShare
/// records, which dart:io cannot read, so we copy them into the app cache
/// here and hand back a plain filesystem path.
class ShareIntakeHandler implements MethodCallHandler {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'readSharedFile') {
      try {
        const uri = call.argument('uri') as string;
        result.success(copyUriToCache(this.context, uri));
      } catch (e) {
        result.error('share', `readSharedFile failed: ${e}`, null);
      }
      return;
    }
    if (call.method === 'shareFile') {
      try {
        const path = call.argument('path') as string;
        shareOriginalFile(this.context, path);
        result.success(null);
      } catch (e) {
        result.error('share', `shareFile failed: ${e}`, null);
      }
      return;
    }
    result.notImplemented();
  }
}

function shareOriginalFile(context: common.UIAbilityContext, path: string): void {
  const folder = `${context.cacheDir}/share_original`;
  if (!fs.accessSync(folder)) {
    fs.mkdirSync(folder);
  }
  const src = fs.openSync(path, fs.OpenMode.READ_ONLY);
  const baseName = src.name.substring(src.name.lastIndexOf('/') + 1);
  const dest = `${folder}/${Date.now()}-${baseName}`;
  fs.copyFileSync(src.fd, dest);
  fs.closeSync(src);
  const record: systemShare.SharedRecord = {
    utd: 'general.file',
    uri: fileUri.getUriFromPath(dest),
    title: baseName,
  };
  const options: systemShare.ShareControllerOptions = {
    previewMode: systemShare.SharePreviewMode.DETAIL,
    selectionMode: systemShare.SelectionMode.SINGLE,
  };
  const controller = new systemShare.ShareController(new systemShare.SharedData(record));
  controller.show(context, options).catch((e: Object) => {
    console.error(`shareOriginalFile failed: ${e}`);
  });
}

/// AssetCompatibleCapability with the API-26 supportedMimeType field. The
/// API 24 typings have only supportedHighResolution; the extra field is read
/// dynamically on HarmonyOS 7+ and ignored on older systems.
class HeicCompatCap implements photoAccessHelper.AssetCompatibleCapability {
  supportedHighResolution: boolean = true;
  supportedMimeType: string[] = ['image/heic'];
}

/// PhotoSelectOptions with the API-26 preferredCompatibleMode field. The
/// API 24 SDK typings lack it, so we carry it on a subclass; the system
/// picker on HarmonyOS 7+ reads it and returns the original HEIC instead of
/// a transcoded JPEG. Older systems ignore the extra field.
class HeicSelectOptions extends photoAccessHelper.PhotoSelectOptions {
  preferredCompatibleMode: number = 1; // PreferredCompatibleMode.CURRENT
  assetCompatibleCapability: HeicCompatCap = new HeicCompatCap();
}

/// Handles xdremux/gallery: PhotoViewPicker with the API-26 asset-compat
/// fields runtime-injected so the gallery returns the original HEIC instead
/// of a transcoded JPEG on HarmonyOS 7+ (fields are ignored on older API).
class GalleryPickHandler implements MethodCallHandler {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'pickImages') {
      result.notImplemented();
      return;
    }
    const picker = new photoAccessHelper.PhotoViewPicker();
    const opts = new HeicSelectOptions();
    opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opts.maxSelectNumber = 9;
    picker.select(opts)
      .then((res: photoAccessHelper.PhotoSelectResult) => {
        const uris = res.photoUris;
        if (!uris || uris.length === 0) {
          result.success([]);
          return;
        }
        const paths: string[] = [];
        for (const uri of uris) {
          try {
            paths.push(copyUriToCache(this.context, uri));
          } catch (e) {
            console.error(`copyUriToCache failed for ${uri}: ${e}`);
          }
        }
        result.success(paths);
      })
      .catch((e: Object) => result.error('pick', `${e}`, null));
  }
}

/// Decodes the primary image with Harmony ImageKit and returns a downscaled
/// JPEG. The Rust thumbnail scan picks up the grayscale gain map.
class ThumbnailHandler implements MethodCallHandler {
  private tail: Promise<void> = Promise.resolve();

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'render') {
      result.notImplemented();
      return;
    }
    const path = call.argument('path') as string;
    const requested = call.argument('maxPixelSize') as number;
    const maxPixelSize = requested > 0 ? requested : 320;
    if (!path) {
      result.error('bad_args', 'path is required', null);
      return;
    }
    this.tail = this.tail.catch((_err: Object) => {
    }).then(async () => {
      try {
        const bytes = await renderThumbnailJpeg(path, maxPixelSize);
        result.success(bytes);
      } catch (e) {
        console.error(`thumbnail render failed: ${e}`);
        result.success(null);
      }
    });
  }
}

async function renderThumbnailJpeg(path: string, maxPixelSize: number): Promise<Uint8Array | null> {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  let source: image.ImageSource | undefined;
  let pixelMap: image.PixelMap | undefined;
  let packer: image.ImagePacker | undefined;
  try {
    source = image.createImageSource(file.fd);
    const info = await source.getImageInfo();
    const srcW = info.size.width;
    const srcH = info.size.height;
    const longest = srcW > srcH ? srcW : srcH;
    const scale = longest > maxPixelSize ? maxPixelSize / longest : 1;
    const dstW = Math.max(1, Math.round(srcW * scale));
    const dstH = Math.max(1, Math.round(srcH * scale));
    const desired: image.Size = { width: dstW, height: dstH };
    const decoding: image.DecodingOptions = { desiredSize: desired };
    pixelMap = await source.createPixelMap(decoding);
    packer = image.createImagePacker();
    const packing: image.PackingOption = { format: 'image/jpeg', quality: 80 };
    const packed = await packer.packing(pixelMap, packing);
    if (!packed || packed.byteLength === 0) {
      return null;
    }
    return new Uint8Array(packed);
  } finally {
    try {
      if (packer) {
        await packer.release();
      }
    } catch (e) {
      console.error(`thumbnail packer release: ${e}`);
    }
    try {
      if (pixelMap) {
        await pixelMap.release();
      }
    } catch (e) {
      console.error(`thumbnail pixelmap release: ${e}`);
    }
    try {
      if (source) {
        await source.release();
      }
    } catch (e) {
      console.error(`thumbnail source release: ${e}`);
    }
    try {
      fs.closeSync(file);
    } catch (e) {
      console.error(`thumbnail fd close: ${e}`);
    }
  }
}

function copyUriToCache(context: common.UIAbilityContext, uri: string): string {
  const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
  const name = uri.substring(uri.lastIndexOf('/') + 1) || `shared-${Date.now()}`;
  const dest = `${context.cacheDir}/${Date.now()}-${name}`;
  fs.copyFileSync(file.fd, dest);
  fs.closeSync(file);
  return dest;
}

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const shareChannel = new MethodChannel(messenger, 'xdremux/share');
    shareChannel.setMethodCallHandler(new ShareIntakeHandler(this.context));
    const galleryChannel = new MethodChannel(messenger, 'xdremux/gallery');
    galleryChannel.setMethodCallHandler(new GalleryPickHandler(this.context));
    const thumbnailChannel = new MethodChannel(messenger, 'xdremux/thumbnail');
    thumbnailChannel.setMethodCallHandler(new ThumbnailHandler());
  }
}
