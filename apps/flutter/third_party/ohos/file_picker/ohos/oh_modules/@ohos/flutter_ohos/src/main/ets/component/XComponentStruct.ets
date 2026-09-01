/*
* Copyright (c) 2025 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/
import Any from '../plugin/common/Any';
import ApplicationInfoLoader from '../embedding/engine/loader/ApplicationInfoLoader';

import { BuilderParams, DVModelParameters } from '../view/DynamicView/dynamicView';

/**
 * XComponent structure for rendering Flutter content.
 * This component creates an XComponent with TEXTURE type to display Flutter views.
 * It handles both debug and release modes with different background color configurations.
 */
@Component
struct XComponentStruct {
  private context: Any;
  private applicationInfo = ApplicationInfoLoader.load(getContext());
  /** Parameters for the DynamicView model, including XComponent ID and other attributes. */
  dvModelParams: DVModelParameters = new DVModelParameters();

  /**
   * Builds the XComponent structure for Flutter rendering.
   * Creates an XComponent with TEXTURE type, handling both debug and release modes.
   * @returns The XComponent tree
   */
  build() {
    // todo OS解决默认背景色后可以移除冗余重复代码,仅保留差异的backgroundColor属性条件配置
    if (this.applicationInfo.isDebugMode) {
      XComponent({
        id: (this.dvModelParams as Record<string, Any>)["xComponentId"],
        type: XComponentType.TEXTURE,
        libraryname: 'flutter'
      })
        .onLoad((context) => {
          this.context = context;
        })
        .onDestroy(() => {
        })
        .backgroundColor(Color.White)
    } else {
      XComponent({
        id: (this.dvModelParams as Record<string, Any>)["xComponentId"],
        type: XComponentType.TEXTURE,
        libraryname: 'flutter'
      })
        .onLoad((context) => {
          this.context = context;
        })
        .onDestroy(() => {
        })
    }
  }
}

/**
 * Builder function for creating an XComponentStruct component.
 * This function is used in DynamicView to build XComponent instances for Flutter rendering.
 * @param buildParams - The BuilderParams containing the DVModelParameters for the XComponent
 */
@Builder
export function BuildXComponentStruct(buildParams: BuilderParams) {
  XComponentStruct({ dvModelParams: buildParams.params });
}