/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*/

/**
 * Basic Flutter component, not yet fully encapsulated.
 * This is a placeholder component that may be used as needed.
 */
@Component
export default struct FlutterComponent {
  /**
   * Builds the component UI.
   * @returns The component tree
   */
  build() {
    Row() {
      Column() {
        Text("xxx")
          .fontSize(50)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
    }
    .height('100%')
  }
}