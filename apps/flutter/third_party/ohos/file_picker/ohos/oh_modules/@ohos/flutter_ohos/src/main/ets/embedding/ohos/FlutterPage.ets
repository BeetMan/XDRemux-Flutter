/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

import Log from '../../util/Log';
import { FlutterView } from '../../view/FlutterView';
import FlutterManager from './FlutterManager';
import { DVModel, DVModelChildren, DynamicView } from '../../view/DynamicView/dynamicView';
import Any from '../../plugin/common/Any';
import deviceInfo from '@ohos.deviceInfo';
import flutter from 'libflutter.so';
const TAG = "FlutterPage";

/**
 * Hosts one `XComponent` surface for `FlutterPage`. In `onLoad`, resolves `FlutterView` and stores the token from
 * `FlutterView.onSurfaceCreated`; in `onDestroy`, passes that token to `FlutterView.onSurfaceDestroyed` so a stale
 * `onDestroy` after fast route replacement cannot detach the current surface.
 */
@Component
struct FlutterSurface {
  @Prop safeAreaEdges: SafeAreaEdge[] | undefined = [];
  @Prop safeAreaTypes: SafeAreaType[] | undefined = [];
  @Prop viewId: string = ""
  @Prop xComponentType: XComponentType = XComponentType.SURFACE
  @Prop xComponentRenderFit: RenderFit = RenderFit.RESIZE_FILL;
  @Prop firstFrameDisplayed: boolean = false;
  @Prop xComponentColor: Color = Color.Black
  @Prop defaultFocusOnTouch: boolean = false;

  private surfaceLifecycleToken: number = 0;
  private flutterView?: FlutterView | null;

  build() {
    XComponent({ id: this.viewId, type: this.xComponentType, libraryname: 'flutter' })
      .id(this.viewId)
      .focusable(true)
      .focusOnTouch(this.defaultFocusOnTouch)
      .onLoad((context) => {
        this.flutterView = FlutterManager.getInstance().getFlutterView(this.viewId);
        this.surfaceLifecycleToken = this.flutterView?.onSurfaceCreated() ?? 0;
        // Callback is triggered when the xcomponent window is partially visible or completely hidden.
        if (deviceInfo.sdkApiVersion < 15) {
          this.getUIContext()?.getAttachedFrameNodeById(this.viewId)?.commonEvent.setOnVisibleAreaApproximateChange(
            { ratios: [0.0, 1.0], expectedUpdateInterval: 0 },
            (isExpanding: boolean, currentRatio: number) => {
              if (isExpanding) {
                Log.i(TAG, "setOnVisibleAreaApproximateChange -> xcomponentId: " + this.viewId +
                  " isExpanding: " + isExpanding + " ratio: " + currentRatio);
                flutter.nativeUpdateCurrentXComponentId(this.viewId);
              }
            }
          )
        }
        Log.d(TAG, "XComponent onLoad ");
      })
      .onDestroy(() => {
        Log.d(TAG, "XComponent onDestroy ");
        this.flutterView?.onSurfaceDestroyed(this.surfaceLifecycleToken)
        this.flutterView = null;
      })
      .renderFit(this.xComponentRenderFit)
      .backgroundColor(this.firstFrameDisplayed && this.xComponentRenderFit == RenderFit.RESIZE_FILL ?
      this.xComponentColor : Color.Transparent)
      .expandSafeArea(this.safeAreaTypes, this.safeAreaEdges)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        // Only handle when Y position changes (window decoration state changed)
        if (oldValue.globalPosition.y != newValue.globalPosition.y) {
          FlutterManager.getInstance().handleWindowDecorSafeArea(this.viewId, this.getUIContext().getHostContext());
        }
      })
  }
}


/**
 * Basic page component that hosts XComponent for Flutter rendering.
 * This component handles the display of Flutter content within an OpenHarmony page.
 */
@Component
export struct FlutterPage {
  /** Safe area edges to expand, or undefined for default. */
  @Prop safeAreaEdges: SafeAreaEdge[] | undefined = [];
  /** Safe area types to expand, or undefined for default. */
  @Prop safeAreaTypes: SafeAreaType[] | undefined = [];
  /** The unique identifier for the XComponent view. */
  @Prop viewId: string = ""
  /** The XComponent type for rendering. */
  @Prop xComponentType: XComponentType = XComponentType.SURFACE
  /**
   * renderFit under XComponent has a default setting of RESIZE_FILL.
   * If the size of XComponent may change, this property needs to be passed in and set to a size-preserving property,
   * such as TOP_LEFT.
   */
  @Prop xComponentRenderFit: RenderFit = RenderFit.RESIZE_FILL;

  /**
   * A switch for enabling the frame cache.
   * When it is true, one frame of response latency will be increased in exchange for higher smoothness,
   * and occasional timeouts in rendering frame submissions will not result in frame dropping.
   */
  @Prop enableFrameCacheForSmooth: boolean = true;

  /**
   * Empty builder function used as default.
   */
  @Builder
  doNothingBuilder() {
  }

  defaultFocusOnTouch = false;
  
  @BuilderParam splashScreenView: () => void = this.doNothingBuilder;

  /**
   * Default page builder that displays Flutter content with XComponent.
   */
  @Builder
  defaultPage() {
    Stack() {
      ForEach(this.rootDvModel!!, (child: ESObject) => {
        DynamicView({
          model: child as DVModel,
          params: child.params,
          events: child.events,
          children: child.children,
          customBuilder: child.builder
        })
      }, (child: ESObject) => `${child.id_}`)

      Text("").id("unfocus-xcomponent-node").focusable(true)

      FlutterSurface({
        safeAreaEdges: this.safeAreaEdges,
        safeAreaTypes: this.safeAreaTypes,
        viewId: this.viewId,
        xComponentType: this.xComponentType,
        xComponentRenderFit: this.xComponentRenderFit,
        firstFrameDisplayed: this.firstFrameDisplayed,
        xComponentColor: this.xComponentColor,
        defaultFocusOnTouch: this.defaultFocusOnTouch
      })
      if (this.showSplashScreen) {
        this.splashScreenView();
      }
    }
    .defaultFocus(true)
    .onKeyPreIme((event: KeyEvent) => {
      return this.flutterView?.onKeyPreIme(event) ?? false;
    })
    .onKeyEvent((event: KeyEvent) => {
      return this.flutterView?.onKeyEvent(event) ?? false;
    })
    .onDragEnter((event: DragEvent, extraParams: string) => {
      FlutterManager.getInstance().getDragEnterCbs().forEach(dragEnterCb => {
        dragEnterCb.do(event, extraParams);
      });
      Log.d(TAG, "onDragEnter");
    })
    .onDragMove((event: DragEvent, extraParams: string) => {
      FlutterManager.getInstance().getDragMoveCbs().forEach(dragMoveCb => {
        dragMoveCb.do(event, extraParams);
      });
      Log.d(TAG, "onDragMove");
    })
    .onDragLeave((event: DragEvent, extraParams: string) => {
      FlutterManager.getInstance().getDragLeaveCbs().forEach(dragLeaveCb => {
        dragLeaveCb.do(event, extraParams);
      });
      Log.d(TAG, "onDragLeave");
    })
    .onDrop((event: DragEvent, extraParams: string) => {
      FlutterManager.getInstance().getDropCbs().forEach(dropCb => {
        dropCb.do(event, extraParams);
      });
      Log.d(TAG, "onDrop");
    })
  }

  /**
   * Page builder that supports mouse wheel gestures.
   */
  @Builder
  mouseWheelPage() {
    Stack() {
      ForEach(this.rootDvModel!!, (child: Any) => {
        DynamicView({
          model: child as DVModel,
          params: child.params,
          events: child.events,
          children: child.children,
          customBuilder: child.builder
        })
      }, (child: ESObject) => `${child.id_}`)

      Text("").id("unfocus-xcomponent-node").focusable(true)

      FlutterSurface({
        safeAreaEdges: this.safeAreaEdges,
        safeAreaTypes: this.safeAreaTypes,
        viewId: this.viewId,
        xComponentType: this.xComponentType,
        xComponentRenderFit: this.xComponentRenderFit,
        firstFrameDisplayed: this.firstFrameDisplayed,
        xComponentColor: this.xComponentColor,
        defaultFocusOnTouch: this.defaultFocusOnTouch
      })

      if (this.showSplashScreen) {
        this.splashScreenView();
      }
    }
    .defaultFocus(true)
    .onKeyPreIme((event: KeyEvent) => {
      return this.flutterView?.onKeyPreIme(event) ?? false;
    })
    .onKeyEvent((event: KeyEvent) => {
      this.flutterView?.onKeyEvent(event)
    })
    .onDragEnter((event: DragEvent, extraParams: string) => {
      FlutterManager.getInstance().getDragEnterCbs().forEach(dragEnterCb => {
        dragEnterCb.do(event, extraParams);
      });
      Log.d(TAG, "onDragEnter");
    })
    .onDragMove((event: DragEvent, extraParams: string) => {
      FlutterManager.getInstance().getDragMoveCbs().forEach(dragMoveCb => {
        dragMoveCb.do(event, extraParams);
      });
      Log.d(TAG, "onDragMove");
    })
    .onDragLeave((event: DragEvent, extraParams: string) => {
      FlutterManager.getInstance().getDragLeaveCbs().forEach(dragLeaveCb => {
        dragLeaveCb.do(event, extraParams);
      });
      Log.d(TAG, "onDragLeave");
    })
    .onDrop((event: DragEvent, extraParams: string) => {
      FlutterManager.getInstance().getDropCbs().forEach(dropCb => {
        dropCb.do(event, extraParams);
      });
      Log.d(TAG, "onDrop");
    })
    .gesture(
      PanGesture(this.panOption)
        .onActionStart((event: GestureEvent) => {
          this.flutterView?.onMouseWheel("actionStart", event);
        })
        .onActionUpdate((event: GestureEvent) => {
          this.flutterView?.onMouseWheel("actionUpdate", event);
        })
        .onActionEnd((event: GestureEvent) => {
          this.flutterView?.onMouseWheel("actionEnd", event);
        })
    )
  }

  /** Whether to show the splash screen. */
  @State showSplashScreen: boolean = true;
  /**
   * To address the black(or other color set by usr) flashing frame when switching between ArkUI and Flutter pages,
   * the background color should be kept transparent until the onFirstFrame is called.
   * When the window size changes, modifying the renderFit property in the relevant callback does not take effect immediately.
   * The first frame will use the old renderFit property and the old background color, resulting in visual artifacts (such as stretching or a black screen).
   * Therefore, we cannot automatically change the relevant properties through state variables at this time.
   */
  @State firstFrameDisplayed: boolean = false;
  /** Background color for the XComponent. */
  @State xComponentColor: Color = Color.Black

  /** Whether to check for full screen mode. */
  @State checkFullScreen: boolean = true;
  /** Whether to check for keyboard visibility. */
  @State checkKeyboard: boolean = true;
  /** Whether to check for gesture navigation. */
  @State checkGesture: boolean = true;
  /** Whether to enable mouse wheel gesture support. */
  @State checkMouseWheel: boolean = true;
  /** Whether to check for AI bar. */
  @State checkAiBar: boolean = true;
  /** Top padding value, or undefined if not set. */
  @Prop @Watch("onPaddingChange")paddingTop?: number = undefined;
  /** Storage link for node width. */
  @StorageLink('nodeWidth') storageLinkWidth: number = 0;
  /** Storage link for node height. */
  @StorageLink('nodeHeight') storageLinkHeight: number = 0;

  /** Root dynamic view model children, or undefined if not set. */
  @State rootDvModel: DVModelChildren | undefined = undefined

  private flutterView?: FlutterView | null
  private panOption: PanGestureOptions = new PanGestureOptions({ direction: PanDirection.Up | PanDirection.Down });

  /**
   * Called when the page is about to appear.
   * Initializes the FlutterView and sets up listeners and callbacks.
   */
  aboutToAppear() {
    this.flutterView = FlutterManager.getInstance().getFlutterView(this.viewId);
    this.flutterView?.addFirstFrameListener(this)
    this.flutterView?.addFirstPreloadFrameListener(this)

    // api18开始支持getDistance()接口
    if (deviceInfo.sdkApiVersion >= 18) {
      this.flutterView?.setTouchSlopCallbackValue(() => {
        return this.panOption.getDistance()
      })
    }

    this.flutterView?.setCheckFullScreen(this.checkFullScreen)
    this.flutterView?.setCheckKeyboard(this.checkKeyboard)
    this.flutterView?.setCheckGesture(this.checkGesture)
    this.flutterView?.setPaddingTop(this.paddingTop)
    this.flutterView?.setCheckAiBar(this.checkAiBar)
    this.flutterView?.enableFrameCache(this.enableFrameCacheForSmooth);

    this.rootDvModel = this.flutterView!!.getDVModel().children
  }

  /**
   * Called when the page is about to disappear.
   * Removes frame listeners to clean up resources.
   */
  aboutToDisappear() {
    this.flutterView?.removeFirstFrameListener(this);
    this.flutterView?.removeFirstPreloadFrameListener(this)
  }

  /**
   * Called when the first frame is displayed.
   * Hides the splash screen and marks the first frame as displayed.
   */
  onFirstFrame() {
    this.showSplashScreen = false;
    this.firstFrameDisplayed = true;
  }

  /**
   * Called when the first preload frame is displayed.
   */
  onFirstPreloadFrame() {
  }

  /**
   * Called when padding changes.
   * Updates the FlutterView's padding.
   */
  onPaddingChange() {
    this.flutterView?.setPaddingTop(this.paddingTop);
  }

  /**
   * Builds the page UI.
   * Selects between mouse wheel page and default page based on configuration.
   */
  build() {
    if (this.checkMouseWheel) {
      this.mouseWheelPage();
    } else {
      this.defaultPage();
    }
  }
}
