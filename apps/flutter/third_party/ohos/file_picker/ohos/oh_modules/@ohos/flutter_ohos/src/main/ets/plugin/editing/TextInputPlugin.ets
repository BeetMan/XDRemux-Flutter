/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on TextInputPlugin.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import TextInputChannel, {
  Configuration,
  TextEditState,
  TextInputMethodHandler
} from '../../embedding/engine/systemchannels/TextInputChannel';
import inputMethod from '@ohos.inputMethod';
import Log from '../../util/Log';
import { EditingStateWatcher, ListenableEditingState, PreviewInsertOptions } from './ListenableEditingState';
import Any from '../common/Any';
import { inputDevice } from '@kit.InputKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PointerDeviceKind } from '../../embedding/ohos/OhosTouchProcessor';
import deviceInfo from '@ohos.deviceInfo';
import KeyEventChannel from '../../embedding/engine/systemchannels/KeyEventChannel';
import { appManager, bundleManager } from '@kit.AbilityKit';
import { PreviewTextCoordinator } from './PreviewTextCoordinator';
import { isPreviewTextSupported } from './PreviewTextSupport';
import ArrayList from '@ohos.util.ArrayList';
import { TextEditingDelta } from './TextEditingDelta';

const INPUT_SUPPORT_API = 15;

/** Document half-open [rangeStart, rangeEnd) for Latin finishTextPreview commit (ArkTS: no inline object types). */
interface LatinFinishPreviewRange {
  rangeStart: number;
  rangeEnd: number;
  mode: string;
}

/**
 * Plugin for handling text input in Flutter applications.
 * This class manages the interaction between Flutter's text input system
 * and the OpenHarmony input method framework.
 */
export default class TextInputPlugin implements EditingStateWatcher {
  private static TAG = "TextInputPlugin";
  private textInputChannel: TextInputChannel;
  private keyEventChannel: KeyEventChannel | undefined;
  private mTextInputHandler: TextInputMethodHandlerImpl;

  /**
   * Constructs a new TextInputPlugin instance.
   * @param textInputChannel - The TextInputChannel for communication with Flutter
   * @param viewId - The view ID for focus management
   * @param keyEventChannel - Optional KeyEventChannel for key event handling
   */
  constructor(textInputChannel: TextInputChannel, viewId: string, keyEventChannel?: KeyEventChannel) {
    this.textInputChannel = textInputChannel;
    this.keyEventChannel = keyEventChannel;
    // viewId is used for requestFocus
    this.mTextInputHandler = new TextInputMethodHandlerImpl(this, viewId);
    this.textInputChannel.setTextInputMethodHandler(this.mTextInputHandler);
  }

  /**
   * Clears the current text input client.
   */
  public clearTextInputClient() {
    this.textInputChannel.textInputMethodHandler?.clearClient();
  }

  /**
   * Gets the current editing state.
   * @returns The current ListenableEditingState instance
   */
  getEditingState() {
    return this.mTextInputHandler.mEditable;
  }

  /**
   * Called when the editing state changes. Delegates sync strategy to PreviewTextCoordinator.
   * @param textChanged - Whether the text has changed
   * @param selectionChanged - Whether the selection has changed
   * @param composingRegionChanged - Whether the composing region has changed
   */
  didChangeEditingState(textChanged: boolean, selectionChanged: boolean, composingRegionChanged: boolean): void {
    const editable = this.mTextInputHandler.mEditable;
    const inputTarget = this.mTextInputHandler.inputTarget;
    const configuration = this.mTextInputHandler.configuration;
    const handler = this.mTextInputHandler;
    PreviewTextCoordinator.syncEditingState(
      editable,
      inputTarget.id,
      configuration,
      (id, text, selStart, selEnd, composingStart, composingEnd) =>
        this.textInputChannel.updateEditingState(id, text, selStart, selEnd, composingStart, composingEnd),
      (id, batchDeltas: ArrayList<TextEditingDelta>) => {
        this.textInputChannel.updateEditingStateWithDeltas(id, batchDeltas);
        editable.clearBatchDeltas();
      },
      (text, start, end) => this.mTextInputHandler.notifySelectionToFramework(text, start, end),
      {
        lastOutgoing: handler.mLastOutgoingFrameworkState,
        onOutgoingCommitted: (s: TextEditState): void => {
          handler.mLastOutgoingFrameworkState = s;
        }
      }
    );
  }

  /**
   * Detaches the text input plugin from the input method framework.
   */
  detach(): void {
    this.mTextInputHandler.inputMethodController.detach((err) => {
      if (err) {
        Log.e(TextInputPlugin.TAG, "Failed to detach: " + JSON.stringify(err));
      }
    })
  }

  /**
   * Destroys the text input plugin, hiding the keyboard and cleaning up resources.
   */
  destroy() {
    // Since the Dart side no longer listens to the lifecycle,
    // the keyboard must be explicitly hidden before the engine is destroyed.
    this.mTextInputHandler.hide();
    this.textInputChannel.setTextInputMethodHandler(null);
  }
}

const INPUT_TYPE_NAME =
  ['NONE', 'TEXT', 'MULTILINE', 'NUMBER', 'PHONE', 'DATETIME', 'EMAIL_ADDRESS', 'URL', 'VISIBLE_PASSWORD']

/**
 * Implementation of TextInputMethodHandler for OpenHarmony input method framework.
 * This class handles all interactions with the system input method.
 */
class TextInputMethodHandlerImpl implements TextInputMethodHandler {
  private static TAG = "TextInputMethodHandlerImpl";

  /**
   * Document [rangeStart, rangeEnd) to replace with committed Latin preview: stacked | dup | lr.
   */
  private static latinFinishPreviewReplaceRange(
    leftIdx: number,
    rightIdx: number,
    previewText: string,
    cache: string,
    imcStart: number,
    imcEnd: number,
  ): LatinFinishPreviewRange {
    const imcW = imcEnd - imcStart;
    const previewLen = previewText.length;
    if (previewLen > 0 && leftIdx === imcW && leftIdx < rightIdx && imcStart >= 0 && imcEnd > imcStart && imcW > 0) {
      const rangeEnd = Math.min(cache.length, Math.max(rightIdx, imcW));
      const out: LatinFinishPreviewRange = { rangeStart: 0, rangeEnd: rangeEnd, mode: 'stacked' };
      return out;
    }
    if (
      previewLen > 0 &&
      cache.length >= rightIdx &&
      leftIdx === previewLen &&
      rightIdx === leftIdx + previewLen &&
      cache.startsWith(previewText) &&
      cache.substring(leftIdx, rightIdx) === previewText
    ) {
      const out: LatinFinishPreviewRange = { rangeStart: 0, rangeEnd: rightIdx, mode: 'dup' };
      return out;
    }
    const out: LatinFinishPreviewRange = { rangeStart: leftIdx, rangeEnd: rightIdx, mode: 'lr' };
    return out;
  }

  private static isImeSegmentApostropheLike(ch: string): boolean {
    if (ch === "'" || ch.charCodeAt(0) === 0x2019 || ch.charCodeAt(0) === 0x02bc || ch.charCodeAt(0) === 0xff07) {
      return true;
    }
    return false;
  }

  /**
   * True when preview text contains a segment apostrophe immediately after a Latin letter (e.g. ni'hao).
   * Leading `'` alone (e.g. `'hao` after deleting a syllable prefix) must not defer finishTextPreview:
   * otherwise [leftIdx, rightIdx) is never committed before the CJK insertText candidate.
   */
  private static previewTextHasInternalSegmentApostrophe(previewText: string): boolean {
    for (let idx = 0; idx < previewText.length; idx++) {
      if (!TextInputMethodHandlerImpl.isImeSegmentApostropheLike(previewText.charAt(idx))) {
        continue;
      }
      if (idx > 0) {
        const prev = previewText.charAt(idx - 1);
        if ((prev >= 'a' && prev <= 'z') || (prev >= 'A' && prev <= 'Z')) {
          return true;
        }
      }
    }
    return false;
  }

  /** Leading IME syllable marker before the remaining Latin body (e.g. `'hao`). */
  private static previewStartsWithImeSegmentMarker(previewText: string): boolean {
    if (previewText.length < 1) {
      return false;
    }
    return TextInputMethodHandlerImpl.isImeSegmentApostropheLike(previewText.charAt(0));
  }

  private textConfig: inputMethod.TextConfig;
  /** The input method controller for managing the keyboard. */
  inputMethodController: inputMethod.InputMethodController;
  /** The current input target. */
  inputTarget: InputTarget;
  /** The current text input configuration, or null if not set. */
  public configuration: Configuration | null = null;
  private lastKind?: PointerDeviceKind;
  /** The editable state for text input. */
  mEditable: ListenableEditingState;
  private mRestartInputPending: boolean = false;
  /**
   * Last full editing state pushed from native to Flutter (aligned with Android mLastKnownFrameworkTextEditingState),
   * used to skip duplicate channel updates and to detect Framework echo that mutates the composing region.
   */
  mLastOutgoingFrameworkState: TextEditState | null = null;
  private plugin: EditingStateWatcher | Any;
  private imcFlag: boolean = false;
  private keyboardStatus: inputMethod.KeyboardStatus = inputMethod.KeyboardStatus.HIDE;
  private inputAttribute: inputMethod.InputAttribute =
    { textInputType: inputMethod.TextInputType.TEXT, enterKeyType: inputMethod.EnterKeyType.NONE };
  private keyboardFocusState: boolean = false;
  private focusViewId: string = "";
  // Record the type of soft keyboard that was triggered last time
  private lastInputType?: inputMethod.TextInputType;
  private isInputMethodAttached: boolean = false;
  /**
   * After finishTextPreview commits Latin preview using document [leftIdx, rightIdx), OHOS may still deliver insertText(same).
   * One matching insertText is skipped to avoid duplicate words (e.g. "This This").
   */
  private mConsumeNextInsertTextIfEquals: string | null = null;
  /**
   * finishTextPreview committed with retainPreviewRangeAfterCommit; clear staging on duplicate insertText skip
   * or after the real follow-up insertText.
   */
  private mFinishRetainedPreviewRangePending: boolean = false;

  /**
   * Constructs a new TextInputMethodHandlerImpl instance.
   * @param plugin - The TextInputPlugin instance
   * @param viewId - The view ID for focus management
   */
  constructor(plugin: TextInputPlugin | Any, viewId: string) {
    this.textConfig = {
      inputAttribute: this.inputAttribute
    };
    this.plugin = plugin;
    this.mEditable = new ListenableEditingState(null, 0);
    this.inputMethodController = inputMethod.getController();
    this.inputTarget = new InputTarget(Type.NO_TARGET, 0);
    this.focusViewId = viewId;
  }

  /**
   * Shows the text input keyboard if appropriate.
   * The keyboard is only shown if the input type is not NONE.
   */
  show(): void {
    try {
      let isPhysicalKeyboard = false;
      inputDevice.getDeviceList((Error: Error, ids: Array<number>) => {
        for (let i = 0; i < ids.length; i++) {
          const type = inputDevice.getKeyboardTypeSync(ids[i]);
          if (type === inputDevice.KeyboardType.ALPHABETIC_KEYBOARD ||
            type === inputDevice.KeyboardType.DIGITAL_KEYBOARD) {
            isPhysicalKeyboard = true;
            break;
          }
        }
        // API 20+: with physical keyboard attached, avoid repeatedly raising the soft keyboard.
        if (isPhysicalKeyboard) {
          this.keyboardStatus = inputMethod.KeyboardStatus.SHOW;
        }
      })
    } catch (error) {
      Log.e(TextInputMethodHandlerImpl.TAG,
        `Show function failed to query device. Code is ${error.code}, message is ${error.message}`)
    }
    if (this.canShowTextInput()) {
      // Ensure the Xcomponent gains focus before the soft keyboard is displayed.
      focusControl.requestFocus(this.focusViewId);
      this.keyboardFocusState = true;
      this.showTextInput();
    } else {
      this.hide();
    }
  }

  /**
   * Hides the text input keyboard.
   */
  hide(): void {
    // Ensure the Xcomponent loses focus before the soft keyboard is hided.
    focusControl.requestFocus("unfocus-xcomponent-node");
    this.keyboardFocusState = false;
    this.hideTextInput();
  }

  /**
   * Gets the current keyboard focus state.
   * @returns True if the keyboard has focus, false otherwise
   */
  getKeyboardFocusState() {
    return this.keyboardFocusState;
  }

  /**
   * Notifies the input method framework of current display text and selection.
   * Used by PreviewTextCoordinator so that Plugin does not depend on inputMethodController.
   */
  notifySelectionToFramework(displayText: string, selectionStart: number, selectionEnd: number): void {
    this.inputMethodController.changeSelection(displayText, selectionStart, selectionEnd);
  }

  /** After native edit: `updateEditingState` + `changeSelection`; preview path uses `composeDisplayState` (composing -1). */
  syncImcSelectionAfterEditableChange(): void {
    if (PreviewTextCoordinator.shouldSyncWithPreview(this.mEditable)) {
      const displayState = PreviewTextCoordinator.composeDisplayState(this.mEditable);
      this.plugin.textInputChannel.updateEditingState(
        this.inputTarget.id,
        displayState.text,
        displayState.selectionStart,
        displayState.selectionEnd,
        displayState.composingStart,
        displayState.composingEnd
      );
      this.mLastOutgoingFrameworkState = PreviewTextCoordinator.displayStateToTextEditState(displayState);
      this.inputMethodController.changeSelection(displayState.text, displayState.selectionStart, displayState.selectionEnd);
    } else {
      this.inputMethodController.changeSelection(
        this.mEditable.getStringCache(),
        this.mEditable.getSelectionStart(),
        this.mEditable.getSelectionEnd());
    }
  }

  /**
   * After commitLeadingLatinPreviewWhenCaretOutsideSpan replaces `'+latin` with Han locally, OHOS IME may still
   * emit SetPreviewText for a suffix of the old Latin (e.g. "ha"). Empty-then-full changeSelection clears that state.
   */
  private notifyImcFlushComposingAfterLatinOutsideSpanCommit(): void {
    this.inputMethodController.changeSelection("", -1, -1, (err: BusinessError) => {
      if (err) {
        Log.e(TextInputMethodHandlerImpl.TAG,
          `Failed to changeSelection (flush composing), code: ${err.code}, message: ${err.message}`);
        return;
      }
      const text = this.mEditable.getStringCache();
      const start = this.mEditable.getSelectionStart();
      const end = this.mEditable.getSelectionEnd();
      this.inputMethodController.changeSelection(text, start, end);
    });
  }

  /**
   * Requests autofill functionality.
   */
  requestAutofill(): void {

  }

  /**
   * Finishes the autofill context.
   * @param shouldSave - Whether to save the autofill data
   */
  finishAutofillContext(shouldSave: boolean): void {

  }

  /**
   * Sets the text input client.
   * @param textInputClientId - The client ID
   * @param configuration - The input configuration
   */
  setClient(textInputClientId: number, configuration: Configuration | null): void {
    this.setTextInputClient(textInputClientId, configuration);
  }

  /**
   * Updates the input configuration.
   * @param configuration - The new input configuration
   */
  updateConfig(configuration: Configuration | null) {
    if (configuration) {
      this.lastKind = this.configuration?.deviceKind;
      this.configuration = configuration;
      if (configuration.inputType) {
        this.textConfig.inputAttribute.textInputType = configuration.inputType.type;
        this.textConfig.inputAttribute.enterKeyType = configuration.inputAction as Any;
      }
    }
  }

  /**
   * Sets the platform view client for text input.
   * @param id - The platform view ID
   * @param usesVirtualDisplay - Whether the platform view uses a virtual display
   */
  setPlatformViewClient(id: number, usesVirtualDisplay: boolean): void {

  }

  /**
   * Sets the editable size and transform.
   * @param width - The width of the editable area
   * @param height - The height of the editable area
   * @param transform - The transformation matrix
   */
  setEditableSizeAndTransform(width: number, height: number, transform: number[]): void {

  }

  /**
   * Sets the cursor size and position.
   * @param cursorInfo - The cursor information
   */
  setCursorSizeAndPosition(cursorInfo: inputMethod.CursorInfo) {
    try {
      this.inputMethodController.updateCursor(cursorInfo, (err: BusinessError) => {
        if (err) {
          Log.e(TextInputMethodHandlerImpl.TAG, "Failed to updateCursor:" + JSON.stringify(err));
          return;
        }
      })
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to updateCursor:" + JSON.stringify(err));
    }
  }

  /**
   * Sets the editing state from Flutter.
   * @param editingState - The new editing state
   */
  setEditingState(editingState: TextEditState): void {
    let reconnectImeForComposingDrift = false;
    if (this.mLastOutgoingFrameworkState !== null && this.mLastOutgoingFrameworkState.hasComposing()) {
      if (TextInputMethodHandlerImpl.composingRegionMutatedByFramework(
        this.mLastOutgoingFrameworkState, editingState)) {
        reconnectImeForComposingDrift = true;
      }
    }

    // Preview staging: handle taps inside [leftIdx, rightIdx), strictly before leftIdx, or strictly after rightIdx without falling through to raw Flutter apply.
    if (isPreviewTextSupported() && this.mEditable.isPreviewStagingActive()) {
      const leftIdx = this.mEditable.getLeftIdxOfPreviewTextRange();
      const rightIdx = this.mEditable.getRightIdxOfPreviewTextRange();
      const selStart = editingState.selectionStart;
      const selEnd = editingState.selectionEnd;
      const cursorInsidePreview = (leftIdx !== rightIdx) &&
        selStart >= leftIdx && selStart <= rightIdx && selEnd >= leftIdx && selEnd <= rightIdx;
      if (cursorInsidePreview) {
        const localSelStart = this.mEditable.getSelectionStart();
        const localSelEnd = this.mEditable.getSelectionEnd();
        const displayNow = PreviewTextCoordinator.composeDisplayState(this.mEditable);
        const flutterSelMin = Math.min(selStart, selEnd);
        const flutterSelMax = Math.max(selStart, selEnd);
        const flutterPinsCaretAtPreviewEnd =
          selStart === rightIdx && selEnd === rightIdx;
        const localCaretStrictlyBeforePreviewEnd = localSelStart < rightIdx || localSelEnd < rightIdx;
        const staleEchoSkipsLeft = this.mEditable.getSkipFlutterStaleEndEchoRemaining();
        const skipFlutterSelAsStaleEndEcho =
          staleEchoSkipsLeft > 0 &&
          flutterPinsCaretAtPreviewEnd &&
          localCaretStrictlyBeforePreviewEnd;
        if (skipFlutterSelAsStaleEndEcho) {
          this.mEditable.consumeStaleEndEchoSkipCredit();
        }
        const localPinsCaretAtPreviewEnd =
          localSelStart === rightIdx && localSelEnd === rightIdx;
        const invertedFullPreviewRange =
          selStart === rightIdx && selEnd === leftIdx && rightIdx > leftIdx;
        const skipFlutterSelAsInvertedFullPreviewWhileLocalAtEnd =
          localPinsCaretAtPreviewEnd &&
          invertedFullPreviewRange &&
          editingState.text === displayNow.text;
        const flutterSelectsEntirePreviewRange =
          flutterSelMin === leftIdx &&
          flutterSelMax === rightIdx &&
          selStart !== selEnd;
        const skipFlutterSelAsStaleFullPreviewWhileLocalCaretAtEnd =
          localPinsCaretAtPreviewEnd &&
          flutterSelectsEntirePreviewRange &&
          editingState.text === displayNow.text;
        const skipApplyFlutterSelection =
          skipFlutterSelAsStaleEndEcho ||
          skipFlutterSelAsInvertedFullPreviewWhileLocalAtEnd ||
          skipFlutterSelAsStaleFullPreviewWhileLocalCaretAtEnd;
        if (!skipApplyFlutterSelection) {
          this.mEditable.applyExternalDocumentSelectionWhilePreviewStaging(selStart, selEnd);
        }
        const displayState = PreviewTextCoordinator.composeDisplayState(this.mEditable);
        this.plugin.textInputChannel.updateEditingState(
          this.inputTarget.id,
          displayState.text,
          displayState.selectionStart,
          displayState.selectionEnd,
          displayState.composingStart,
          displayState.composingEnd
        );
        this.mLastOutgoingFrameworkState = PreviewTextCoordinator.displayStateToTextEditState(displayState);
        this.notifySelectionToFramework(displayState.text, displayState.selectionStart, displayState.selectionEnd);
        return;
      }
      const outerSelMin = Math.min(selStart, selEnd);
      const outerSelMax = Math.max(selStart, selEnd);
      const caretStrictlyBeforePreview =
        leftIdx < rightIdx && selStart >= 0 && selEnd >= 0 && outerSelMax < leftIdx;
      if (caretStrictlyBeforePreview) {
        this.mEditable.applyExternalDocumentSelectionWhilePreviewStaging(outerSelMin, outerSelMax);
        const committedLatinPrefix = this.mEditable.commitLeadingLatinPreviewWhenCaretOutsideSpan();
        const displayState = PreviewTextCoordinator.composeDisplayState(this.mEditable);
        this.plugin.textInputChannel.updateEditingState(
          this.inputTarget.id,
          displayState.text,
          displayState.selectionStart,
          displayState.selectionEnd,
          displayState.composingStart,
          displayState.composingEnd,
        );
        this.mLastOutgoingFrameworkState = PreviewTextCoordinator.displayStateToTextEditState(displayState);
        if (committedLatinPrefix) {
          this.notifyImcFlushComposingAfterLatinOutsideSpanCommit();
        } else {
          this.notifySelectionToFramework(displayState.text, displayState.selectionStart, displayState.selectionEnd);
        }
        return;
      }
      const caretStrictlyAfterPreview =
        leftIdx < rightIdx && selStart >= 0 && selEnd >= 0 && outerSelMin > rightIdx;
      if (caretStrictlyAfterPreview) {
        // Same shape as “before”: apply selection, `commitLeadingLatin` then `commitPreviewWhenCursorOutOfRange`, push display, return.
        this.mEditable.applyExternalDocumentSelectionWhilePreviewStaging(outerSelMin, outerSelMax);
        const committedLatinSuffix = this.mEditable.commitLeadingLatinPreviewWhenCaretOutsideSpan();
        let committedCoordinatorOut = false;
        if (!committedLatinSuffix) {
          committedCoordinatorOut = PreviewTextCoordinator.commitPreviewWhenCursorOutOfRange(
            this.mEditable,
            editingState,
            (text, start, end) => this.notifySelectionToFramework(text, start, end)
          );
        }
        if (committedCoordinatorOut) {
          this.mEditable.setIsCursorIdxOutOfPreviewTextRange(false);
          this.inputMethodController.changeSelection("", -1, -1, (err: BusinessError) => {
            if (err) {
              Log.e(TextInputMethodHandlerImpl.TAG, `Failed to changeSelection, code: ${err.code}, message: ${err.message}`);
              return;
            }
            const text = this.mEditable.getStringCache();
            const start = this.mEditable.getSelectionStart();
            const end = this.mEditable.getSelectionEnd();
            this.inputMethodController.changeSelection(text, start, end);
          });
          return;
        }
        const displayState = PreviewTextCoordinator.composeDisplayState(this.mEditable);
        this.plugin.textInputChannel.updateEditingState(
          this.inputTarget.id,
          displayState.text,
          displayState.selectionStart,
          displayState.selectionEnd,
          displayState.composingStart,
          displayState.composingEnd,
        );
        this.mLastOutgoingFrameworkState = PreviewTextCoordinator.displayStateToTextEditState(displayState);
        if (committedLatinSuffix) {
          this.notifyImcFlushComposingAfterLatinOutsideSpanCommit();
        } else {
          this.notifySelectionToFramework(displayState.text, displayState.selectionStart, displayState.selectionEnd);
        }
        return;
      }
    }

    if (isPreviewTextSupported() &&
      PreviewTextCoordinator.commitPreviewWhenCursorOutOfRange(
        this.mEditable,
        editingState,
        (text, start, end) => this.notifySelectionToFramework(text, start, end)
      )) {
      this.mEditable.setIsCursorIdxOutOfPreviewTextRange(false);
      this.inputMethodController.changeSelection("",
        -1, -1, (err: BusinessError) => {
          if (err) {
            Log.e(TextInputMethodHandlerImpl.TAG, `Failed to changeSelection, code: ${err.code}, message: ${err.message}`);
            return;
          }
          const text = this.mEditable.getStringCache();
          const start = this.mEditable.getSelectionStart();
          const end = this.mEditable.getSelectionEnd();
          this.inputMethodController.changeSelection(text, start, end);
        });
      return;
    }

    const flutterEchoesCache = editingState.text === this.mEditable.getStringCache();
    const previewMetaActive = isPreviewTextSupported() &&
      (this.mEditable.getPreviewText() !== '' ||
        this.mEditable.getLeftIdxOfPreviewTextRange() !== this.mEditable.getRightIdxOfPreviewTextRange());
    const previewStagingHeld = isPreviewTextSupported() && this.mEditable.isPreviewStagingActive();
    if ((!flutterEchoesCache && !previewStagingHeld) || !previewMetaActive) {
      this.mEditable.discardPreviewStagingMetadata();
    }
    this.mEditable.setIsCursorIdxOutOfPreviewTextRange(false);
    this.mEditable.updateTextInputState(editingState);
    if (reconnectImeForComposingDrift) {
      this.scheduleImeReconnectAfterFrameworkComposingChange();
    }
    this.inputMethodController.changeSelection("",
      -1, -1, (err: BusinessError) => {
        if (err) {
          Log.e(TextInputMethodHandlerImpl.TAG, `Failed to changeSelection, code: ${err.code}, message: ${err.message}`);
          return;
        }
        const text = this.mEditable.getStringCache();
        const start = this.mEditable.getSelectionStart();
        const end = this.mEditable.getSelectionEnd();
        this.inputMethodController.changeSelection(text, start, end);
      });
  }

  /**
   * Clears the current text input client.
   */
  clearClient(): void {
    this.clearTextInputClient();
  }

  private async showTextInput(): Promise<void> {
    if (!this.lastInputType) {
      this.setLastInputType(this.configuration?.inputType?.type);
    }
    if (this.lastKind === undefined && this.configuration?.deviceKind !== undefined) {
      this.lastKind = this.configuration.deviceKind;
    }
    if (this.keyboardStatus == inputMethod.KeyboardStatus.SHOW) {
      // When keyboard is already SHOW, still call attach; false means attach does not show the keyboard again.
      await this.attach(false);
      if (this.lastKind != this.configuration?.deviceKind ||
        this.hasSecureKeyboardInSwitch()) {
        if (deviceInfo.sdkApiVersion >= INPUT_SUPPORT_API) {
          await this.inputMethodController.showTextInput(this.getRequestReason());
        } else {
          await this.inputMethodController.showTextInput();
        }
        if (this.configuration?.deviceKind !== undefined) {
          this.lastKind = this.configuration.deviceKind;
        }
      }
      this.setLastInputType(this.configuration?.inputType?.type);
      return;
    }
    this.setLastInputType(this.configuration?.inputType?.type);
    await this.attach(true);
    if (this.configuration?.deviceKind !== undefined) {
      this.lastKind = this.configuration.deviceKind;
    }
    if (!this.imcFlag) {
      this.listenKeyBoardEvent();
    }
  }

  private async hideTextInput(): Promise<void> {
    await this.inputMethodController.detach().then(() => {
      this.keyboardStatus = inputMethod.KeyboardStatus.HIDE;
      this.cancelListenKeyBoardEvent();
    }).catch((err: BusinessError) => {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to detach: " + JSON.stringify(err));
      this.keyboardStatus = inputMethod.KeyboardStatus.NONE;
    });
  }

  /**
   * Attaches to the input method controller.
   * @param showKeyboard - Whether to show the keyboard immediately
   * @private
   */
  async attach(showKeyboard: boolean): Promise<void> {
    try {
      // must register preview text callbacks before attachment
      if (isPreviewTextSupported()) {
        this.registerPreviewTextCallbacks();
      }
      if (deviceInfo.sdkApiVersion >= INPUT_SUPPORT_API) {
        await this.inputMethodController.attach(showKeyboard, this.textConfig, this.getRequestReason()).then(async () => {
          await this.handleAttach(showKeyboard);
        });
      } else {
        await this.inputMethodController.attach(showKeyboard, this.textConfig).then(async () => {
          await this.handleAttach(showKeyboard);
        });
      }
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to attach:" + JSON.stringify(err));
      this.keyboardStatus = inputMethod.KeyboardStatus.NONE;
    }
  }

  private async handleAttach(showKeyboard: boolean): Promise<void> {
    let isDetached = false;
    if (showKeyboard) {
      isDetached = await this.detachIfBackground();
    }
    if (isDetached) {
      this.isInputMethodAttached = false;
      this.keyboardStatus = inputMethod.KeyboardStatus.NONE;
    } else {
      this.isInputMethodAttached = true;
      this.cacheMethodCall();
      this.keyboardStatus = inputMethod.KeyboardStatus.SHOW;
    }
  }

  private async detachIfBackground(): Promise<boolean> {
    try {
      const bundleFlags = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
      const bundleInfo: bundleManager.BundleInfo  = await bundleManager.getBundleInfoForSelf(bundleFlags);
      const currentInfo = await appManager.getRunningProcessInformation();
      const targetBundleName = bundleInfo?.name;
      const currentProcess = currentInfo.find(info => info.bundleNames?.includes(targetBundleName));
      // STATE_FOREGROUND: process in foreground; when UI is focused and visible the state is often STATE_ACTIVE.
      // See HarmonyOS appManager ProcessState docs.
      if (
        currentProcess &&
        (currentProcess.state === appManager.ProcessState.STATE_FOREGROUND ||
          currentProcess.state === appManager.ProcessState.STATE_BACKGROUND)
      ) {
          await this.inputMethodController.hideTextInput();
          return true;
      }
    } catch (err) {
      Log.e(
        TextInputMethodHandlerImpl.TAG,
        `detachIfBackground error: ${JSON.stringify(err)}`,
      );
    }
    return false;
  }

  cacheMethodCall(): void {
    // Cache method calls when input method is attached; no-op if not used by this version
  }

  /**
   * Gets the request reason for showing the keyboard based on the input device kind.
   * @returns The request reason for keyboard display
   */
  getRequestReason() : inputMethod.RequestKeyboardReason {
    let deviceKind : PointerDeviceKind = this.configuration?.deviceKind ?? PointerDeviceKind.UNKNOWN
    switch (deviceKind) {
      case PointerDeviceKind.TOUCH:
        return inputMethod.RequestKeyboardReason.TOUCH;
      case PointerDeviceKind.MOUSE:
        return inputMethod.RequestKeyboardReason.MOUSE;
      case PointerDeviceKind.STYLUS:
      case PointerDeviceKind.INVERTED_STYLUS:
      case PointerDeviceKind.TRACKPAD:
        return inputMethod.RequestKeyboardReason.OTHER;
      default:
        return inputMethod.RequestKeyboardReason.NONE;
    }
  }

  /**
   * Handles focus state changes.
   * @param focusState - The new focus state
   */
  handleChangeFocus(focusState: boolean) {
    if (focusState && this.keyboardFocusState) {
      // When the app loses focus, the system automatically detaches the input method.
      // Upon regaining focus, if the input method should be displayed, it must be reattached.
      this.show();
    }
    try {
      inputDevice.getDeviceList((Error: Error, ids: Array<number>) => {
        let isPhysicalKeyboard = false;
        for (let i = 0; i < ids.length; i++) {
          const type = inputDevice.getKeyboardTypeSync(ids[i]);
          if (type == inputDevice.KeyboardType.ALPHABETIC_KEYBOARD || type == inputDevice.KeyboardType.DIGITAL_KEYBOARD) {
            isPhysicalKeyboard = true;
            break;
          }
        }

        if(focusState && isPhysicalKeyboard && this.keyboardFocusState) {
          this.cancelListenKeyBoardEvent();
          this.inputMethodController.detach().then(async () =>{
            await this.attach(true);
            this.listenKeyBoardEvent();
          })
        }
      })
    } catch (error) {
      Log.e(TextInputMethodHandlerImpl.TAG, `Failed to query device. Code is ${error.code}, message is ${error.message}`)
    }
  }

  /**
   * Updates the input attribute configuration.
   */
  async updateAttribute(): Promise<void> {
    if (this.keyboardStatus != inputMethod.KeyboardStatus.SHOW) {
      return;
    }
    try {
      await this.inputMethodController.updateAttribute(this.inputAttribute);
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to updateAttribute:" + JSON.stringify(err));
    }
  }

  /**
   * Sets the text input client with the given configuration.
   * @param client - The client ID
   * @param configuration - The input configuration
   */
  setTextInputClient(client: number, configuration: Configuration | null): void {
    if (configuration) {
      this.lastKind = this.configuration?.deviceKind;
      this.configuration = configuration;
      if (configuration.inputType) {
        this.textConfig.inputAttribute.textInputType = configuration.inputType.type;
        this.textConfig.inputAttribute.enterKeyType = configuration.inputAction as Any;
      }
    }
    if (this.canShowTextInput()) {
      this.inputTarget = new InputTarget(Type.FRAMEWORK_CLIENT, client);
    } else {
      this.inputTarget = new InputTarget(Type.NO_TARGET, client);
    }
    this.mEditable.removeEditingStateListener(this.plugin);

    this.mEditable = new ListenableEditingState(
      this.plugin.textInputChannel, this.inputTarget.id, this.plugin.keyEventChannel);

    this.mRestartInputPending = true;
    this.mLastOutgoingFrameworkState = null;
    this.mEditable.addEditingStateListener(this.plugin);

    this.inputAttribute = this.textConfig.inputAttribute;

    this.updateAttribute();
  }

  setLastInputType(inputType?: inputMethod.TextInputType): void {
    this.lastInputType = inputType;
  }

  // It is used to determine whether there is a safe keyboard for the keyboard type
  // awakened by the two input boxes when a soft keyboard is already suspended
  // and switching input boxes
  hasSecureKeyboardInSwitch(): boolean {
    // Since this method is called in showTextInput to determine whether a secure 
 	  // keyboard needs to be pulled up, the parameter must be true
    this.handleAttach(true);
    return this.lastInputType === inputMethod.TextInputType.VISIBLE_PASSWORD ||
    this.configuration?.inputType?.type === inputMethod.TextInputType.VISIBLE_PASSWORD;
  }

  /**
   * Checks if text input can be shown.
   * @returns True if text input can be shown, false if input type is NONE
   */
  canShowTextInput(): boolean {
    if (this.configuration == null || this.configuration.inputType == null) {
      return true;
    }
    return this.configuration.inputType.type != inputMethod.TextInputType.NONE;
  }

  /**
   * Registers callbacks for preview text functionality.
   */
  registerPreviewTextCallbacks(): void {
    try {
      this.inputMethodController.on("setPreviewText", this.setPreviewTextCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe setPreviewText:" + JSON.stringify(err));
      this.unregisterPreviewTextCallbacks();
      return;
    }

    try {
      this.inputMethodController.on("finishTextPreview", this.finishPreviewTextCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe finishTextPreview:" + JSON.stringify(err));
      this.unregisterPreviewTextCallbacks();
      return;
    }
  }

  /**
   * Unregisters preview text callbacks.
   */
  unregisterPreviewTextCallbacks(): void {
    this.inputMethodController?.off("setPreviewText", this.setPreviewTextCallback)
    this.inputMethodController?.off("finishTextPreview", this.finishPreviewTextCallback);
  }

  /**
   * Registers listeners for keyboard events from the input method framework.
   */
  listenKeyBoardEvent(): void {
    try {
      this.inputMethodController.on('insertText', this.insertTextCallback);
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe insertText:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }

    try {
      this.inputMethodController.on('deleteLeft', this.deleteLeftCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe deleteLeft:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }

    try {
      this.inputMethodController.on('deleteRight', this.deleteRightCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe deleteRight:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }

    try {
      this.inputMethodController.on('sendFunctionKey', this.sendFunctionKeyCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe sendFunctionKey:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }

    try {
      this.inputMethodController.on('sendKeyboardStatus', this.sendKeyboardStatusCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe sendKeyboardStatus:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }

    try {
      this.inputMethodController.on('selectByRange', this.selectByRangeCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe selectByRange:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }

    try {
      this.inputMethodController.on('moveCursor', this.moveCursorCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe moveCursor:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }

    try {
      this.inputMethodController.on('handleExtendAction', this.handleExtendActionCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe handleExtendAction:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }
    try {
      this.inputMethodController.on('selectByMovement', this.selectByMovementCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe selectByMovement:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }
    try {
      this.inputMethodController.on('getLeftTextOfCursor', this.getLeftTextOfCursorCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe getLeftTextOfCursor:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }
    try {
      this.inputMethodController.on('getRightTextOfCursor', this.getRightTextOfCursorCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe getRightTextOfCursor:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }
    try {
      this.inputMethodController.on('getTextIndexAtCursor', this.getTextIndexAtCursorCallback)
    } catch (err) {
      Log.e(TextInputMethodHandlerImpl.TAG, "Failed to subscribe getTextIndexAtCursor:" + JSON.stringify(err));
      this.cancelListenKeyBoardEvent();
      return;
    }

    this.imcFlag = true;
  }

  private setPreviewTextCallback = (text: string, range: inputMethod.Range) => {
    this.mEditable.handleInsertPreviewTextEvent(text, range);
    // Same as insertText/deleteLeft: if merge corrected away from raw IME text, push IMC+Flutter again or IME buffer keeps old tail-delete
    // semantics and suggestions diverge from the field (e.g. field shows abcefg while suggestions still include d).
    if (this.mEditable.consumeImcFullSyncAfterPreviewInsert()) {
      this.syncImcSelectionAfterEditableChange();
    }
  }

  private finishPreviewTextCallback = () => {
    const previewText = this.mEditable.getPreviewText();
    if (typeof previewText !== 'string' || previewText.length === 0) {
      const leftIdx = this.mEditable.getLeftIdxOfPreviewTextRange();
      const rightIdx = this.mEditable.getRightIdxOfPreviewTextRange();
      if (leftIdx < rightIdx) {
        this.mEditable.setPreviewText('');
        return;
      }
      this.mEditable.clearPreviewTextContents();
      return;
    }
    const rawImcStart = this.mEditable.getPreviewTextStart();
    const rawImcEnd = this.mEditable.getPreviewTextEnd();
    let imcStart = rawImcStart;
    let imcEnd = rawImcEnd;
    // When editing preview text, meanwhile switch the app to the background and
    // the preview text will automatically insert into the string cache of TextField.
    // imcMeta start/end are often preview-relative (e.g. 0/4); replacement in the document must use [leftIdx, rightIdx), not imcMeta.
    // OHOS sometimes reports (-1,-1) on finishTextPreview; latinFinishPreviewReplaceRange still needs a half-open
    // preview-relative span — default to [0, previewText.length) so we commit instead of waiting for insertText that never arrives.
    if (imcStart < 0 || imcEnd < 0) {
      imcStart = 0;
      imcEnd = previewText.length;
    }
    // Match `finishTextPreview` defer: internal syllable `'` — wait for `insertText`, no local substitute here.
    if (TextInputMethodHandlerImpl.previewTextHasInternalSegmentApostrophe(previewText)) {
      return;
    }
    const leftIdx = this.mEditable.getLeftIdxOfPreviewTextRange();
    const rightIdx = this.mEditable.getRightIdxOfPreviewTextRange();
    if (!(leftIdx < rightIdx && this.mEditable.isPreviewStagingActive())) {
      return;
    }
    // Caret entirely before span: defer (retainSpan commit with preview cleared breaks in-preview delete UI).
    const selStart = this.mEditable.getSelectionStart();
    const selEnd = this.mEditable.getSelectionEnd();
    if (selStart >= 0 && selEnd >= 0 && Math.max(selStart, selEnd) < leftIdx) {
      return;
    }
    const committedPreview = previewText;
    const cache = this.mEditable.getStringCache();
    const commitRange = TextInputMethodHandlerImpl.latinFinishPreviewReplaceRange(
      leftIdx,
      rightIdx,
      committedPreview,
      cache,
      imcStart,
      imcEnd,
    );
    const retainSpan = TextInputMethodHandlerImpl.previewStartsWithImeSegmentMarker(committedPreview);
    const opts: PreviewInsertOptions = {
      usePreviewRange: true,
      previewStart: commitRange.rangeStart,
      previewEnd: commitRange.rangeEnd,
      retainPreviewRangeAfterCommit: retainSpan,
    };
    this.mEditable.handleInsertTextEvent(committedPreview, opts);
    this.mFinishRetainedPreviewRangePending = retainSpan;
    // Leading-segment tail (e.g. 'hao): IME often sends insertText(same Latin) after finishTextPreview to align
    // the client buffer. Skipping it as "duplicate" can prevent the follow-up insertText(CJK candidate).
    // English / non-retain finish still arms consume to drop the echo word once.
    this.mConsumeNextInsertTextIfEquals = retainSpan ? null : committedPreview;
  }

  private insertTextCallback = (text: string) => {
    if (this.mConsumeNextInsertTextIfEquals !== null) {
      if (text === this.mConsumeNextInsertTextIfEquals) {
        this.mConsumeNextInsertTextIfEquals = null;
        this.syncImcSelectionAfterEditableChange();
        return;
      }
      this.mConsumeNextInsertTextIfEquals = null;
    }
    this.mEditable.handleInsertTextEvent(text);
    this.mFinishRetainedPreviewRangePending = false;
    this.syncImcSelectionAfterEditableChange();
  }

  private deleteLeftCallback = (length: number) => {
    this.mEditable.handleDeleteEvent(false, length, this.configuration?.enableDeltaModel);
    this.syncImcSelectionAfterEditableChange();
  }

  private deleteRightCallback = (length: number) => {
    this.mEditable.handleDeleteEvent(true, length, this.configuration?.enableDeltaModel);
    this.syncImcSelectionAfterEditableChange();
  }

  private sendFunctionKeyCallback = (functionKey: inputMethod.FunctionKey) => {
    if (functionKey.enterKeyType == inputMethod.EnterKeyType.NEWLINE) {
      // insertText callback does not deliver newline; handle it here.
      this.mEditable.handleNewlineEvent();
    }
    this.mEditable.handleFunctionKey(functionKey);
  }

  private sendKeyboardStatusCallback = (state: inputMethod.KeyboardStatus) => {
    // Since API 20, tapping the field with physical keyboard can show soft keyboard; avoid onConnectionClosed then or the field stops accepting input.
    try {
      let isPhysicalKeyboard = false;
      inputDevice.getDeviceList((Error: Error, ids: Array<number>) => {
        for (let i = 0; i < ids.length; i++) {
          const type = inputDevice.getKeyboardTypeSync(ids[i]);
          if (type === inputDevice.KeyboardType.ALPHABETIC_KEYBOARD ||
            type === inputDevice.KeyboardType.DIGITAL_KEYBOARD) {
            isPhysicalKeyboard = true;
            return;
          }
        }
        this.keyboardStatus = state;
        if (state === inputMethod.KeyboardStatus.HIDE) {
          this.plugin.textInputChannel.onConnectionClosed(this.inputTarget.id);
        }
      })
    } catch (error) {
      Log.e(TextInputMethodHandlerImpl.TAG,
        `SendKeyboardStatusCallback function failed to query device. Code is ${error.code}, message is ${error.message}`)
    }
  }

  // obtain the range to update cursor idx to start/end of text cache
  private selectByRangeCallback = (range: inputMethod.Range) => {
    this.mEditable.handleSelectByRangeEvent(range);
    this.syncImcSelectionAfterEditableChange();
  }

  // move cursor postion with left, right, up and down in editing widget
  private moveCursorCallback = (direction: inputMethod.Direction) => {
    this.mEditable.handleMoveCursorEvent(direction);
    this.syncImcSelectionAfterEditableChange();
  }

  // handle extend clipboard actions, like 'select all', 'cut', 'copy' and 'paste'
  private handleExtendActionCallback = (action: inputMethod.ExtendAction) => {
    this.mEditable.handleExtendActionEvent(action);
    this.syncImcSelectionAfterEditableChange();
  }

  // text selection range changed with cursor direction movement
  private selectByMovementCallback = (movement: inputMethod.Movement) => {
    this.mEditable.handleSelectByMovementEvent(movement);
    this.syncImcSelectionAfterEditableChange();
  }

  // return the left-side text string of current cursor index ("abc|345" -> return "abc")
  private getLeftTextOfCursorCallback = (length: number) : string => {
    return this.mEditable.getLeftTextOfCursor(length);
  }

  // return the right-side text string of current cursor index ("abc|345" -> return "345")
  private getRightTextOfCursorCallback = (length: number) : string => {
    return this.mEditable.getRightTextOfCursor(length);
  }

  // return the current cursor index of editing text
  private getTextIndexAtCursorCallback = () => {
    return this.mEditable.getSelectionStart();
  }

  /**
   * Cancels all keyboard event listeners.
   */
  cancelListenKeyBoardEvent(): void {
    this.inputMethodController?.off('insertText', this.insertTextCallback);
    this.inputMethodController?.off('deleteLeft', this.deleteLeftCallback);
    this.inputMethodController?.off('deleteRight', this.deleteRightCallback);
    this.inputMethodController?.off('sendFunctionKey', this.sendFunctionKeyCallback);
    this.inputMethodController?.off('sendKeyboardStatus', this.sendKeyboardStatusCallback);
    this.inputMethodController?.off('selectByRange', this.selectByRangeCallback);
    this.inputMethodController?.off('moveCursor', this.moveCursorCallback);
    this.inputMethodController?.off('handleExtendAction', this.handleExtendActionCallback);
    this.inputMethodController?.off('selectByMovement', this.selectByMovementCallback);
    this.inputMethodController?.off('getLeftTextOfCursor', this.getLeftTextOfCursorCallback);
    this.inputMethodController?.off('getRightTextOfCursor', this.getRightTextOfCursorCallback);
    this.inputMethodController?.off('getTextIndexAtCursor', this.getTextIndexAtCursorCallback);
    this.imcFlag = false;
  }

  /**
   * Clears the text input client.
   */
  public clearTextInputClient(): void {
    if (this.inputTarget.type == Type.VIRTUAL_DISPLAY_PLATFORM_VIEW) {
      return;
    }
    this.mEditable.removeEditingStateListener(this.plugin);
    this.configuration = null;
    this.inputTarget = new InputTarget(Type.NO_TARGET, 0);
    this.mLastOutgoingFrameworkState = null;
  }

  /**
   * Same idea as Android TextInputPlugin.composingChanged: compare only composing region content and length between two TextEditStates.
   */
  private static composingRegionMutatedByFramework(before: TextEditState, after: TextEditState): boolean {
    const regionLen = before.composingEnd - before.composingStart;
    if (regionLen !== (after.composingEnd - after.composingStart)) {
      return true;
    }
    for (let i = 0; i < regionLen; i++) {
      if (before.text.charAt(before.composingStart + i) !== after.text.charAt(after.composingStart + i)) {
        return true;
      }
    }
    return false;
  }

  /** Same idea as Android InputMethodManager.restartInput: reset IME session when Framework mutates composing unexpectedly. */
  private scheduleImeReconnectAfterFrameworkComposingChange(): void {
    if (this.keyboardStatus !== inputMethod.KeyboardStatus.SHOW) {
      return;
    }
    this.inputMethodController.detach()
      .then(() => this.attach(false))
      .then(() => {
        this.listenKeyBoardEvent();
      })
      .catch((err: BusinessError) => {
        Log.e(TextInputMethodHandlerImpl.TAG, 'IME reconnect failed: ' + JSON.stringify(err));
      });
  }
}

/**
 * Enumeration of input target types.
 */
enum Type {
  /** No input target */
  NO_TARGET,
  /** InputConnection is managed by the TextInputPlugin, and events are forwarded to the Flutter framework. */
  FRAMEWORK_CLIENT,
  /** InputConnection is managed by a platform view that is presented on a virtual display. */
  VIRTUAL_DISPLAY_PLATFORM_VIEW,
  /** InputConnection is managed by a platform view that is presented on a physical display. */
  PHYSICAL_DISPLAY_PLATFORM_VIEW,
}

/**
 * Represents a target for text input operations.
 */
export class InputTarget {
  /** The type of input target. */
  type: Type;
  /** The unique identifier for this input target. */
  id: number;

  /**
   * Constructs a new InputTarget instance.
   * @param type - The type of input target
   * @param id - The target ID
   */
  constructor(type: Type, id: number) {
    this.type = type;
    this.id = id;
  }
}
