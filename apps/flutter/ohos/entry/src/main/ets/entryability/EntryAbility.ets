import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
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
    if (call.method !== 'readSharedFile') {
      result.notImplemented();
      return;
    }
    try {
      const uri = call.argument('uri') as string;
      result.success(copyUriToCache(this.context, uri));
    } catch (e) {
      result.error('share', `readSharedFile failed: ${e}`, null);
    }
  }
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
  }
}
