/// OPPO private tail data shown in the photo details sheet.
library;

import '../l10n/l10n.dart';

/// One line of the OPPO section: a label and its value.
class OppoDetailRow {
  final String label;
  final String value;

  /// Long technical values (file names, entry lists) can be selected.
  final bool selectable;

  const OppoDetailRow(this.label, this.value, {this.selectable = false});
}

/// The `oppo` object of `xdremux_inspect_photo_details`. Rust reports only
/// the fields whose layout has been checked and omits what it could not read,
/// so every lookup here tolerates a missing key.
/// See docs/modules/photo-details.md.
class OppoTailDetails {
  final Map<String, dynamic> _json;

  const OppoTailDetails._(this._json);

  /// `null` when the report has no `oppo` object, i.e. the file has no tail.
  static OppoTailDetails? fromJson(Object? json) {
    if (json is! Map) return null;
    return OppoTailDetails._(Map<String, dynamic>.from(json));
  }

  Map<String, dynamic>? _object(String key) {
    final value = _json[key];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  /// Device name the camera prints in the watermark.
  String? get device => _json['device'] as String?;

  /// `(name, payload bytes)` of each tail entry, in manifest order.
  List<(String, int)> get entries {
    final list = _json['entries'];
    if (list is! List) return const [];
    return [
      for (final entry in list)
        if (entry is Map && entry['name'] is String)
          (entry['name'] as String, (entry['length'] as num?)?.toInt() ?? 0),
    ];
  }

  /// "9" for 9.0, "4.5" for 4.5.
  static String _number(num value) {
    final text = value.toStringAsFixed(2);
    return text.contains('.') ? text.replaceFirst(RegExp(r'\.?0+$'), '') : text;
  }

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  static String _join(List<String> parts) => parts.join(t('，', ', '));

  /// The section's lines, in display order. Lines whose data is absent are
  /// left out, so the list is empty only for an empty report.
  List<OppoDetailRow> rows() {
    final rows = <OppoDetailRow>[];
    final device = this.device;
    if (device != null) {
      rows.add(OppoDetailRow(t('水印机型', 'Watermark Device'), device));
    }
    rows.addAll(_watermarkRows());
    rows.addAll(_filterRows());
    final portrait = _portraitRow();
    if (portrait != null) rows.add(portrait);
    final source = _object('sourceImage');
    if (source != null && source['width'] is num && source['height'] is num) {
      rows.add(
        OppoDetailRow(
          t('未处理原图', 'Unprocessed Source'),
          '${source['width']} × ${source['height']}',
        ),
      );
    }
    final entries = this.entries;
    if (entries.isNotEmpty) {
      final total = entries.fold<int>(0, (sum, entry) => sum + entry.$2);
      rows.add(
        OppoDetailRow(
          t('尾部条目', 'Tail Entries'),
          t(
            '${entries.length} 项，共 ${_size(total)}',
            '${entries.length} entries, ${_size(total)}',
          ),
        ),
      );
      rows.add(
        OppoDetailRow(
          t('条目清单', 'Entry List'),
          entries.map((entry) => '${entry.$1} (${_size(entry.$2)})').join('\n'),
          selectable: true,
        ),
      );
    }
    return rows;
  }

  List<OppoDetailRow> _watermarkRows() {
    final watermark = _object('watermark');
    if (watermark == null) return const [];
    final label = t('水印', 'Watermark');
    switch (watermark['kind']) {
      case 'png':
        final size = watermark['width'] is num && watermark['height'] is num
            ? ' ${watermark['width']} × ${watermark['height']}'
            : '';
        return [OppoDetailRow(label, '${t('PNG 叠加层', 'PNG overlay')}$size')];
      case 'frame':
        final style = watermark['style'] as String?;
        final rows = [
          OppoDetailRow(label, t('烘焙边框', 'Baked-in frame')),
          if (style != null)
            OppoDetailRow(
              t('水印样式', 'Watermark Style'),
              style,
              selectable: true,
            ),
        ];
        final picture = watermark['picture'];
        final margins = watermark['margins'];
        if (picture is Map && margins is Map) {
          rows.add(
            OppoDetailRow(
              t('边框内画面', 'Picture Inside Frame'),
              _join([
                '${picture['width']} × ${picture['height']}',
                t(
                  '边框 左 ${margins['left']} 上 ${margins['top']} '
                      '右 ${margins['right']} 下 ${margins['bottom']}',
                  'frame L ${margins['left']} T ${margins['top']} '
                      'R ${margins['right']} B ${margins['bottom']}',
                ),
              ]),
            ),
          );
        }
        return rows;
      case 'unknown':
        return [
          OppoDetailRow(
            label,
            t('有水印条目，类型未识别', 'Watermark entries of an unrecognised kind'),
          ),
        ];
      default:
        return [OppoDetailRow(label, t('无', 'None'))];
    }
  }

  List<OppoDetailRow> _filterRows() {
    final filter = _object('filter');
    if (filter == null) return const [];
    final rows = <OppoDetailRow>[];
    if (filter['enabled'] == false) {
      rows.add(OppoDetailRow(t('滤镜', 'Filter'), t('未启用', 'Off')));
    } else {
      rows.add(
        OppoDetailRow(
          t('滤镜', 'Filter'),
          _join([
            (filter['lut'] as String?) ?? t('未记录名称', 'No name recorded'),
            if (filter['intensity'] is num)
              t(
                '强度 ${filter['intensity']}',
                'intensity ${filter['intensity']}',
              ),
            if (filter['softLight'] == true) t('柔光', 'soft light'),
            if (filter['palette'] == true) t('调色盘', 'palette'),
          ]),
          selectable: true,
        ),
      );
    }
    final scene = [
      if (filter['colorTemperature'] is num)
        t(
          '色温 ${_number(filter['colorTemperature'] as num)}',
          'colour temperature ${_number(filter['colorTemperature'] as num)}',
        ),
      if (filter['luxIndex'] is num)
        t(
          '照度指数 ${_number(filter['luxIndex'] as num)}',
          'lux index ${_number(filter['luxIndex'] as num)}',
        ),
    ];
    if (scene.isNotEmpty) {
      rows.add(OppoDetailRow(t('拍摄时的光线', 'Scene Light'), _join(scene)));
    }
    final mode = filter['captureMode'] as String?;
    if (mode != null) {
      rows.add(OppoDetailRow(t('相机记录的模式', 'Recorded Capture Mode'), mode));
    }
    if (filter['sourceOrientation'] is num) {
      rows.add(
        OppoDetailRow(
          t('原图方向', 'Source Orientation'),
          _join([
            '${filter['sourceOrientation']}°',
            if (filter['mirrored'] == true) t('成片左右镜像', 'saved mirrored'),
          ]),
        ),
      );
    }
    if (filter['version'] is num) {
      rows.add(
        OppoDetailRow(
          t('滤镜数据版本', 'Filter Data Version'),
          (filter['version'] as num).toStringAsFixed(1),
        ),
      );
    }
    return rows;
  }

  OppoDetailRow? _portraitRow() {
    final portrait = _object('portrait');
    if (portrait == null) return null;
    final front = portrait['camera'] == 'front';
    final size = portrait['depthWidth'] is num && portrait['depthHeight'] is num
        ? ' ${portrait['depthWidth']} × ${portrait['depthHeight']}'
        : '';
    final faces = portrait['faceCount'];
    return OppoDetailRow(
      t('人像景深', 'Portrait Depth'),
      _join([
        '${front ? t('前置', 'Front camera') : t('后摄', 'Rear camera')}$size',
        if (portrait['fNumber'] is num)
          t(
            '虚化光圈 f/${_number(portrait['fNumber'] as num)}',
            'blur aperture f/${_number(portrait['fNumber'] as num)}',
          ),
        if (faces is num && faces > 0)
          t('$faces 张人脸', faces == 1 ? '1 face' : '$faces faces'),
        if (portrait['mirrored'] == true) t('成片左右镜像', 'saved mirrored'),
      ]),
    );
  }

  /// The section as plain text, one `label: value` per line.
  String toClipboardText() =>
      rows().map((row) => '${row.label}: ${row.value}').join('\n');
}
