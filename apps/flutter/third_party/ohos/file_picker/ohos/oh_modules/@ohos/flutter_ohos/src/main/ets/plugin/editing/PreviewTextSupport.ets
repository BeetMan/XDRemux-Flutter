/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import deviceInfo from '@ohos.deviceInfo';

/** Minimum SDK API level that supports preview text (IME composing / pre-edit). */
const PREVIEW_TEXT_SUPPORT_API = 17;

/**
 * Centralized capability check for preview text.
 * Use this instead of scattering sdkApiVersion checks.
 */
export function isPreviewTextSupported(): boolean {
  return deviceInfo.sdkApiVersion >= PREVIEW_TEXT_SUPPORT_API;
}

export { PREVIEW_TEXT_SUPPORT_API };
