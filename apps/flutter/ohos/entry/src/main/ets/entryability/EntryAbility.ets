import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
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
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const name = uri.substring(uri.lastIndexOf('/') + 1) || `shared-${Date.now()}`;
      const dest = `${this.context.cacheDir}/${Date.now()}-${name}`;
      fs.copyFileSync(file.fd, dest);
      fs.closeSync(file);
      result.success(dest);
    } catch (e) {
      result.error('share', `readSharedFile failed: ${e}`, null);
    }
  }
}

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    const channel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xdremux/share');
    channel.setMethodCallHandler(new ShareIntakeHandler(this.context));
  }
}
