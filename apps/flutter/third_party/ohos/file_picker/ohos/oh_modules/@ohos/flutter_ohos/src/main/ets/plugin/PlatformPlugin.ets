/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on PlatformPlugin.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { BusinessError } from '@kit.BasicServicesKit';
import PlatformChannel, {
  AppSwitcherDescription,
  Brightness,
  ClipboardContentFormat,
  HapticFeedbackType,
  PlatformMessageHandler,
  SoundType,
  SystemChromeStyle,
  SystemUiMode,
  SystemUiOverlay
} from '../embedding/engine/systemchannels/PlatformChannel';
import FlutterManager from '../embedding/ohos/FlutterManager';
import pasteboard from '@ohos.pasteboard';
import Log from '../util/Log';
import vibrator from '@ohos.vibrator';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { MethodResult } from './common/MethodChannel';
import Any from './common/Any';
import router from '@ohos.router';
import { PasteboardUtils } from '../util/PasteboardUtils';
import { FlutterView } from '../view/FlutterView';

/**
 * Plugin for handling platform-specific functionality in Flutter applications.
 * This class manages system UI, clipboard, haptic feedback, and other platform services.
 */
export default class PlatformPlugin {
  private static TAG = "PlatformPlugin";
  /** The callback handler for platform messages. */
  callback = new PlatformPluginCallback();

  /**
   * Constructs a new PlatformPlugin instance.
   * @param platformChannel - The PlatformChannel for communication with Flutter.
   * @param context - The application context.
   * @param platformPluginDelegate - Optional delegate for platform-specific behavior.
   */
  constructor(platformChannel: PlatformChannel, context: common.Context,
    platformPluginDelegate?: PlatformPluginDelegate) {
    this.callback.platformChannel = platformChannel;
    this.callback.context = context;
    this.callback.applicationContext = context?.getApplicationContext();
    this.callback.platform = this;
    this.callback.platformPluginDelegate = platformPluginDelegate ?? null;
    this.callback.platformChannel?.setPlatformMessageHandler(this.callback);
  }

  /**
   * Initializes the window references for system UI management.
   */
  initWindow() {
    try {
      let context = this.callback.context!!
      window.getLastWindow(context, (err, data) => {
        if (err.code) {
          Log.e(PlatformPlugin.TAG, "Failed to obtain the top window. Cause: " + JSON.stringify(err));
          return;
        }
        this.callback.lastWindow = data;
      });
      const uiAbility = FlutterManager.getInstance().getUIAbility(context);
      const windowStage = FlutterManager.getInstance().getWindowStage(uiAbility);
      this.callback.mainWindow = windowStage.getMainWindowSync();
    } catch (err) {
      Log.e(PlatformPlugin.TAG, "Failed to obtain the top window. Cause: " + JSON.stringify(err));
    }
  }


  /**
   * Updates the system UI overlays (status bar and navigation bar) visibility.
   */
  updateSystemUiOverlays(): void {
    this.callback.mainWindow?.setWindowSystemBarEnable(this.callback.showBarOrNavigation);

    if (FlutterManager.getInstance().isWindowDecorSafeAreaAvoidSupported(this.callback.context)) {
      const shouldHideWindowDecor = this.callback.shouldHideWindowDecor();
      this.callback.mainWindow?.setWindowDecorVisible(!shouldHideWindowDecor);

      // Adjust padding based on window decoration visibility
      if (shouldHideWindowDecor) {
        const titleButtonRect = this.callback.mainWindow?.getTitleButtonRect();
        const paddingHeight = (titleButtonRect && titleButtonRect.height > 0) ? titleButtonRect.height : 0;
        this.callback.flutterView?.setPaddingTop(vp2px(paddingHeight));
      } else {
        this.callback.flutterView?.setPaddingTop(0);
      }
    }

    if (this.callback.currentTheme != null) {
      this.callback.setSystemChromeSystemUIOverlayStyle(this.callback.currentTheme);
    }
  }

  /**
   * Sets the UIAbility context for platform operations.
   * @param context - The UIAbility context
   */
  setUIAbilityContext(context: common.UIAbilityContext): void {
    this.callback.uiAbilityContext = context;
  }

  /**
   * Sets up a listener for system configuration changes.
   */
  setSystemChromeChangeListener(): void {
    if (this.callback.callbackId == null && this.callback.applicationContext != null) {
      let that = this;
      this.callback.callbackId = this.callback.applicationContext?.on('environment', {
        onConfigurationUpdated(config) {
          Log.d(PlatformPlugin.TAG, "onConfigurationUpdated: " + that.callback.showBarOrNavigation);
          that.callback.platformChannel?.systemChromeChanged(that.callback.showBarOrNavigation.includes('status'));
        },
        onMemoryLevel(level) {
        }
      })
    }
  }

  /**
   * Binds a FlutterView to this plugin.
   * @param flutterView - The FlutterView instance
   */
  setFlutterView(flutterView: FlutterView): void {
    this.callback.flutterView = flutterView;
  }

  /**
   * Destroys the platform plugin and cleans up resources.
   */
  public destroy() {
    this.callback.platformChannel?.setPlatformMessageHandler(null);
  }
}

/**
 * Delegate interface for platform-specific behavior.
 */
export interface PlatformPluginDelegate {
  /**
   * Called when the system navigator should be popped.
   * @returns True if the delegate handled the pop, false otherwise.
   */
  popSystemNavigator(): boolean;
}

/**
 * Callback implementation for handling platform messages from Flutter.
 */
export class PlatformPluginCallback implements PlatformMessageHandler {
  private static TAG = "PlatformPluginCallback";
  /** The PlatformPlugin instance this callback is associated with. */
  platform: PlatformPlugin | null = null;
  /** The main window for system UI operations. */
  mainWindow: window.Window | null = null;
  /** The last window reference. */
  lastWindow: window.Window | null = null;
  /** The PlatformChannel for communication with Flutter. */
  platformChannel: PlatformChannel | null = null;
  /** The delegate for platform-specific behavior. */
  platformPluginDelegate: PlatformPluginDelegate | null = null;
  /** The application context. */
  context: common.Context | null = null;
  /** Array indicating which system bars should be shown ('status' and/or 'navigation'). */
  showBarOrNavigation: ('status' | 'navigation')[] = ['status', 'navigation'];
  /** The UIAbility context for platform operations. */
  uiAbilityContext: common.UIAbilityContext | null = null;
  /** The callback ID for system configuration changes. */
  callbackId: number | null = null;
  /** The application context. */
  applicationContext: common.ApplicationContext | null = null;
  /** The current system UI theme style. */
  currentTheme: SystemChromeStyle | null = null;
  /** The FlutterView instance for padding control. */
  flutterView: FlutterView | null = null;

  /**
   * Plays a system sound.
   * @param soundType - The type of sound to play.
   */
  playSystemSound(soundType: SoundType) {
  }

  /**
   * Triggers haptic feedback vibration.
   * @param feedbackType - The type of haptic feedback
   */
  async vibrateHapticFeedback(feedbackType: HapticFeedbackType) {
    switch (feedbackType) {
      case HapticFeedbackType.STANDARD:
        await vibrator.startVibration({ type: 'time', duration: 75 },
          { id: 0, usage: 'touch' });
        break;
      case HapticFeedbackType.LIGHT_IMPACT:
        await vibrator.startVibration({ type: 'time', duration: 25 },
          { id: 0, usage: 'touch' });
        break;
      case HapticFeedbackType.MEDIUM_IMPACT:
        await vibrator.startVibration({ type: 'time', duration: 150 },
          { id: 0, usage: 'touch' });
        break;
      case HapticFeedbackType.HEAVY_IMPACT:
        await vibrator.startVibration({ type: 'time', duration: 300 },
          { id: 0, usage: 'touch' });
        break;
      case HapticFeedbackType.SELECTION_CLICK:
        await vibrator.startVibration({ type: 'time', duration: 100 },
          { id: 0, usage: 'touch' });
        break;
    }
  }

  /**
   * Sets the preferred screen orientation.
   * @param ohosOrientation - The orientation value.
   * @param result - The method result callback.
   */
  setPreferredOrientations(ohosOrientation: number, result: MethodResult) {
    try {
      Log.d(PlatformPluginCallback.TAG, "ohosOrientation: " + ohosOrientation);
      this.mainWindow!.setPreferredOrientation(ohosOrientation, (err: BusinessError) => {
        const errCode: number = err.code;
        if (errCode) {
          Log.e(PlatformPluginCallback.TAG, "Failed to set window orientation:" + JSON.stringify(err));
          result.error("error", JSON.stringify(err), null);
          return;
        }
        result.success(null);
      });
    } catch (exception) {
      Log.e(PlatformPluginCallback.TAG, "Failed to set window orientation:" + JSON.stringify(exception));
      result.error("error", JSON.stringify(exception), null);
    }
  }

  /**
   * Sets the application switcher description (mission label).
   * @param description - The app switcher description.
   */
  setApplicationSwitcherDescription(description: AppSwitcherDescription) {
    Log.d(PlatformPluginCallback.TAG, "setApplicationSwitcherDescription: " + JSON.stringify(description));
    try {
      let label: string = description?.label;
      this.uiAbilityContext?.setMissionLabel(label).then(() => {
        Log.d(PlatformPluginCallback.TAG, "Succeeded in seting mission label");
      })
    } catch (err) {
      Log.d(PlatformPluginCallback.TAG, "Failed to set mission label: " + JSON.stringify(err));
    }
  }

  /**
   * Shows the specified system UI overlays.
   * @param overlays - Array of overlays to show.
   */
  showSystemOverlays(overlays: SystemUiOverlay[]) {
    this.setSystemChromeEnabledSystemUIOverlays(overlays);
  }

  /**
   * Sets the system UI mode.
   * @param mode - The system UI mode to set.
   */
  showSystemUiMode(mode: SystemUiMode) {
    this.setSystemChromeEnabledSystemUIMode(mode);
  }

  /**
   * Sets up a listener for system UI changes.
   */
  setSystemUiChangeListener() {
    this.platform?.setSystemChromeChangeListener();
  }

  /**
   * Restores the system UI overlays to their previous state.
   */
  restoreSystemUiOverlays() {
    this.platform?.updateSystemUiOverlays();
  }

  /**
   * Sets the system UI overlay style (colors, brightness, etc.).
   * @param systemUiOverlayStyle - The style to apply.
   */
  setSystemUiOverlayStyle(systemUiOverlayStyle: SystemChromeStyle) {
    Log.d(PlatformPluginCallback.TAG, "systemUiOverlayStyle:" + JSON.stringify(systemUiOverlayStyle));
    this.setSystemChromeSystemUIOverlayStyle(systemUiOverlayStyle);
  }

  /**
   * Pops the system navigator (goes back in navigation stack).
   */
  popSystemNavigator() {
    if (this.platformPluginDelegate != null && this.platformPluginDelegate?.popSystemNavigator()) {
      return;
    }
    router.back();
  }

  /**
   * Gets data from the system clipboard.
   * @param result - The method result callback.
   */
  getClipboardData(result: MethodResult): void {
    let atManager = abilityAccessCtrl.createAtManager();
    atManager.requestPermissionsFromUser(this.uiAbilityContext, ['ohos.permission.READ_PASTEBOARD']).then((data) => {
      // https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-permissionrequestresult-V5
      // Permission request result codes:
      // -1: Not authorized, permission is configured but requires user to modify in Settings
      //  0: Granted
      //  2: Not authorized, request is invalid, possible reasons:
      //   - Target permission not declared in configuration file
      //   - Invalid permission name
      //   - Special conditions for certain permissions not met
      enum AuthResultStatus {
        NOT_CONFIGURED = -1,
        GRANTED = 0,
        INVALID_REQ = 2
      }

      let message: string = 'Failed to request permissions from user.';
      let authResult: number = data.authResults[0];
      switch (authResult) {
        case AuthResultStatus.GRANTED: {
          let systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
          systemPasteboard.getData().then(async (pasteData: pasteboard.PasteData) => {
            let pasteText: string = '';
            const recordCount: number = pasteData.getRecordCount();
            for (let i = 0; i < recordCount; i++) {
              const record = pasteData.getRecord(i);
              let text: string = '';
              if (typeof record.getValidTypes === 'function') {
                // For api14 and above, click here. More formats are supported
                text = await PasteboardUtils.getTargetTypesData(record);
              } else if (record.mimeType === pasteboard.MIMETYPE_TEXT_HTML) {
                const htmlText: StyledString = await StyledString.fromHtml(record.htmlText);
                text = htmlText.getString();
              } else if (record.mimeType === pasteboard.MIMETYPE_TEXT_PLAIN) {
                text = record.plainText;
              }
              pasteText += text;
            }
            let response: Any = new Map().set("text", pasteText);
            result.success(response);
          }).catch((err: BusinessError) => {
            Log.e(PlatformPluginCallback.TAG, "Failed to get PasteData. Cause: " + JSON.stringify(err));
            result.error("error", JSON.stringify(err), null);
          });
          break;
        }
        case AuthResultStatus.NOT_CONFIGURED: {
          message += 'Cause: Not configured in Settings';
          Log.i(PlatformPluginCallback.TAG, message);
          result.success(null);
          break;
        }
        case AuthResultStatus.INVALID_REQ: {
          message += 'Cause: Invalid request';
          Log.i(PlatformPluginCallback.TAG, message);
          result.success(null);
          break;
        }
        default: {
          message += `Unknown error: authResult=${authResult}`;
          result.error("error", message, null);
          break;
        }
      }
    }).catch((err: BusinessError) => {
      Log.e(PlatformPluginCallback.TAG, "Failed to request permissions from user. Cause: " + JSON.stringify(err));
      result.error("error", JSON.stringify(err), null);
    })
  }

  /**
   * Sets data to the system clipboard.
   * @param text - The text to set
   * @param result - The method result callback
   */
  setClipboardData(text: string, result: MethodResult) {
    let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    let systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
    try {
      systemPasteboard.setDataSync(pasteData);
      result.success(null);
    } catch (err) {
      Log.d(PlatformPluginCallback.TAG, "Failed to set PasteData. Cause: " + JSON.stringify(err));
      result.error("error", JSON.stringify(err), null);
    }
  }

  /**
   * Checks if the clipboard contains string data.
   * @returns True if clipboard has strings, false otherwise
   */
  clipboardHasStrings(): boolean {
    return false;
  }

  /**
   * Sets the system UI mode (fullscreen, immersive, etc.).
   * @param mode - The system UI mode to set
   */
  setSystemChromeEnabledSystemUIMode(mode: SystemUiMode): void {
    Log.d(PlatformPluginCallback.TAG, "mode: " + mode);
    let uiConfig: ('status' | 'navigation')[] = [];
    if (mode == SystemUiMode.LEAN_BACK) {
      // Full screen mode, status and navigation bars can be shown by tapping anywhere on the display
      FlutterManager.getInstance().setUseFullScreen(true, null);
    } else if (mode == SystemUiMode.IMMERSIVE) {
      // Full screen mode, status and navigation bars can be shown by swiping from display edges, gesture not received by app
      FlutterManager.getInstance().setUseFullScreen(true, null);
    } else if (mode == SystemUiMode.IMMERSIVE_STICKY) {
      // Full screen mode, status and navigation bars can be shown by swiping from display edges, gesture received by app
      FlutterManager.getInstance().setUseFullScreen(true, null);
    } else if (mode == SystemUiMode.EDGE_TO_EDGE) {
      uiConfig = ['status', 'navigation'];
    } else {
      return;
    }
    this.showBarOrNavigation = uiConfig;
    this.platform?.updateSystemUiOverlays();
  }

  /**
   * Sets the system UI overlay style with colors and brightness.
   * @param systemChromeStyle - The style configuration
   */
  setSystemChromeSystemUIOverlayStyle(systemChromeStyle: SystemChromeStyle): void {
    let isStatusBarLightIconValue: boolean = false;
    let statusBarContentColorValue: string | undefined = undefined;
    let statusBarColorValue: string | undefined = undefined;
    let navigationBarColorValue: string | undefined = undefined;
    let isNavigationBarLightIconValue: boolean = false;

    const currentProps = this.mainWindow?.getWindowSystemBarProperties();

    if (systemChromeStyle.statusBarIconBrightness != null) {
      switch (systemChromeStyle.statusBarIconBrightness) {
        case Brightness.DARK:
          isStatusBarLightIconValue = false;
          statusBarContentColorValue = '#000000';
          break;
        case Brightness.LIGHT:
          isStatusBarLightIconValue = true;
          statusBarContentColorValue = '#FFFFFF';
          break;
      }
    } else {
      isStatusBarLightIconValue = currentProps?.isStatusBarLightIcon ?? false;
      statusBarContentColorValue = currentProps?.statusBarContentColor ??
        (isStatusBarLightIconValue ? '#FFFFFF' : '#000000');
    }

    if (systemChromeStyle.statusBarColor != null) {
      statusBarColorValue = "#" + systemChromeStyle.statusBarColor.toString(16).padStart(8, '0');
    } else {
      statusBarColorValue = currentProps?.statusBarColor
    }

    if (systemChromeStyle.systemStatusBarContrastEnforced != null) {

    }

    if (systemChromeStyle.systemNavigationBarIconBrightness != null) {
      switch (systemChromeStyle.systemNavigationBarIconBrightness) {
        case Brightness.DARK:
          isNavigationBarLightIconValue = true;
          break;
        case Brightness.LIGHT:
          isNavigationBarLightIconValue = false;
      }
    } else {
      isNavigationBarLightIconValue = currentProps?.isNavigationBarLightIcon ?? false
    }

    if (systemChromeStyle.systemNavigationBarColor != null) {
      navigationBarColorValue = "#" + systemChromeStyle.systemNavigationBarColor.toString(16).padStart(8, '0');
    } else {
      navigationBarColorValue = currentProps?.navigationBarColor
    }

    if (systemChromeStyle.systemNavigationBarContrastEnforced != null) {

    }
    this.currentTheme = systemChromeStyle;
    const systemBarProperties: window.SystemBarProperties = {
      statusBarColor: statusBarColorValue,
      isStatusBarLightIcon: isStatusBarLightIconValue,
      statusBarContentColor: statusBarContentColorValue,
      navigationBarColor: navigationBarColorValue,
      isNavigationBarLightIcon: isNavigationBarLightIconValue,
      navigationBarContentColor: currentProps?.navigationBarContentColor,
      enableStatusBarAnimation: currentProps?.enableStatusBarAnimation,
      enableNavigationBarAnimation: currentProps?.enableNavigationBarAnimation,
    }
    Log.d(PlatformPluginCallback.TAG, "systemBarProperties: " + JSON.stringify(systemBarProperties));
    this.mainWindow?.setWindowSystemBarProperties(systemBarProperties);
  }

  /**
   * Sets which system UI overlays should be enabled.
   * @param overlays - Array of overlays to enable
   */
  setSystemChromeEnabledSystemUIOverlays(overlays: SystemUiOverlay[]): void {
    let uiConfig: ('status' | 'navigation')[] = [];
    if (overlays.length == 0) {

    }
    for (let index = 0; index < overlays.length; ++index) {
      let overlayToShow = overlays[index];
      switch (overlayToShow) {
        case SystemUiOverlay.TOP_OVERLAYS:
          uiConfig.push('status'); //hide navigation
          break;
        case SystemUiOverlay.BOTTOM_OVERLAYS:
          uiConfig.push('navigation'); //hide bar
          break;
      }
    }
    this.showBarOrNavigation = uiConfig;
    this.platform?.updateSystemUiOverlays();
  }

  /**
   * Determines whether to hide window decoration based on system UI overlay settings.
   * @returns True to hide window decoration, false to show it
   */
  shouldHideWindowDecor(): boolean {
    const hasStatus = this.showBarOrNavigation.includes('status');
    const hasNavigation = this.showBarOrNavigation.includes('navigation');

    // Fullscreen: [] → hide
    // Edge-to-edge: ['status', 'navigation'] → hide
    // Bottom only: ['navigation'] → hide
    // Top only: ['status'] → show

    return !hasStatus || hasNavigation;
  }
}
