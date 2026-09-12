import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/app_models.dart';

/// Per-card overrides never enable portrait solely because it was detected.
class PhotoFeatureMenu extends StatelessWidget {
  final QueueItem item;
  final bool enabled;
  final bool applePortraitAvailable;
  final ValueChanged<PhotographicStyleMode> onStyleChanged;
  final ValueChanged<PortraitMode> onPortraitChanged;

  const PhotoFeatureMenu({
    super.key,
    required this.item,
    required this.enabled,
    required this.applePortraitAvailable,
    required this.onStyleChanged,
    required this.onPortraitChanged,
  });

  @override
  Widget build(BuildContext context) => PopupMenuButton<Object>(
    enabled: enabled,
    padding: EdgeInsets.zero,
    icon: const Icon(Icons.tune, size: 18),
    tooltip:
        '${t('照片处理策略', 'Photo policy')}: ${item.portraitMode.displayName} / ${item.photographicStyleMode.displayName}',
    onSelected: (value) {
      if (value is PortraitMode) onPortraitChanged(value);
      if (value is PhotographicStyleMode) onStyleChanged(value);
    },
    itemBuilder: (_) => [
      PopupMenuItem<Object>(
        enabled: false,
        child: Text(t('人像模式', 'Portrait mode')),
      ),
      for (final mode in PortraitMode.values)
        CheckedPopupMenuItem<Object>(
          value: mode,
          checked: item.portraitMode == mode,
          enabled:
              mode != PortraitMode.applePortrait ||
              (item.portrait != null && applePortraitAvailable),
          child: Text(mode.displayName),
        ),
      if (item.photographicStyle != null) ...[
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          enabled: false,
          child: Text(
            t(
              '摄影风格（仅导出原始 JPEG，转换底片须含 Ultra HDR）',
              'Photo style (raw JPEG only; Convert base requires Ultra HDR)',
            ),
          ),
        ),
        for (final mode in PhotographicStyleMode.values)
          CheckedPopupMenuItem<Object>(
            value: mode,
            checked: item.photographicStyleMode == mode,
            child: Text(mode.displayName),
          ),
      ],
    ],
  );
}
