import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/models/checkpoint_model.dart';
import 'package:xdremux/services/checkpoint_service.dart';
import 'package:xdremux/services/photo_feature_service.dart';

const style = PhotographicStyleSummary(
  styleNameZh: '清透',
  styleNameEn: 'Fresh',
  lutName: 'qing_tou.bin',
  baseImageBytes: 1024,
  intensity: 100,
  tone: 90,
  version: '1.0',
);
const portrait = PortraitSummary(
  hasPortrait: true,
  width: 2,
  height: 2,
  scale: 2.1 / 255,
  scaleMode: 'curve-derived',
  currentFNumber: 2.8,
  hasPortraitMatte: true,
  hasHairMatte: false,
  hasPetMatte: false,
);

QueueItem photo() => QueueItem(
  id: '1',
  inputPath: '/original.jpg',
  outputPath: '/out.heic',
  photographicStyle: style,
  portrait: portrait,
)..portraitInspectionAvailable = true;

void main() {
  test('unavailable legacy inspection preserves global portrait conversion', () {
    final config = ConversionConfig(applePortrait: true);
    final item = photo();
    const PhotoFeatureInspection().applyTo(item);
    expect(item.portrait, portrait);
    expect(item.portraitInspectionAvailable, false);
    expect(item.photoPolicyRejection(config), isNull);
    item.portrait = null; // a newly imported original has no cached summary
    expect(item.photoPolicyRejection(config), isNull);
    item.portraitMode = PortraitMode.applePortrait;
    expect(item.photoPolicyRejection(config), isNotNull);
    item.portraitMode = PortraitMode.standard;
    expect(item.photoPolicyRejection(config), isNull);
  });

  test('confirmed absent depth is distinct from unavailable inspection', () {
    final item = photo();
    const PhotoFeatureInspection(portraitInspectionAvailable: true).applyTo(item);
    expect(item.portrait, isNull);
    expect(item.photoPolicyRejection(ConversionConfig(applePortrait: true)), isNotNull);
    const PhotoFeatureInspection(portrait: portrait, portraitInspectionAvailable: true).applyTo(item);
    expect(item.photoPolicyRejection(ConversionConfig(applePortrait: true)), isNull);
  });

  test(
    'detection does not enable portrait; defaults follow global settings',
    () {
      final item = photo();
      final config = ConversionConfig();
      expect(item.portraitMode, PortraitMode.inherit);
      expect(item.effectiveApplePortrait(config), false);
      config.applePortrait = true;
      expect(item.effectiveApplePortrait(config), true);
      item.portraitMode = PortraitMode.standard;
      expect(item.effectiveApplePortrait(config), false);
      item.portraitMode = PortraitMode.applePortrait;
      config.applePortrait = false;
      expect(item.effectiveApplePortrait(config), true);
      expect(item.motionPhotoMode, MotionPhotoMode.livePhotoPair);
    },
  );

  test(
    'style/portrait/motion/backend combinations reject only destructive base routing',
    () {
      for (final backend in ConversionBackend.values) {
        for (final global in [false, true]) {
          for (final styleMode in PhotographicStyleMode.values) {
            for (final portraitMode in PortraitMode.values) {
              for (final motionMode in MotionPhotoMode.values) {
                final item = photo()
                  ..photographicStyleMode = styleMode
                  ..portraitMode = portraitMode
                  ..motionPhotoMode = motionMode;
                final config = ConversionConfig(
                  backend: backend,
                  applePortrait: global,
                );
                final incompatible =
                    styleMode == PhotographicStyleMode.convertBasePhoto &&
                    item.effectiveApplePortrait(config);
                expect(item.photoPolicyRejection(config) != null, incompatible);
                // Pairing must always continue to reference the original donor.
                expect(item.inputPath, '/original.jpg');
              }
            }
          }
        }
      }
    },
  );

  test('unknown/legacy checkpoint policies keep safe defaults', () {
    final legacy = CheckpointItem.fromJson({
      'inputPath': 'a',
      'outputPath': 'b',
    });
    expect(legacy.photographicStyleMode, 'keepStyle');
    expect(legacy.portraitMode, 'inherit');
    expect(legacy.motionPhotoMode, 'livePhotoPair');
  });

  test(
    'checkpoint snapshots reconcile edited terminal modes and newly added items',
    () {
      final item = photo()..status = QueueItemStatus.converted;
      var snapshot = CheckpointService.createItemsFromQueue([item]);
      expect(snapshot.single.status, CheckpointItemStatus.converted);
      item
        ..portraitMode = PortraitMode.standard
        ..photographicStyleMode = PhotographicStyleMode.convertBasePhoto
        ..status = QueueItemStatus.pending;
      snapshot = CheckpointService.createItemsFromQueue([item, photo()]);
      final edited = CheckpointItem.fromJson(snapshot.first.toJson());
      expect(edited.status, CheckpointItemStatus.pending);
      expect(edited.portraitMode, 'standard');
      expect(edited.photographicStyleMode, 'convertBasePhoto');
      expect(edited.portrait?['scaleMode'], 'curve-derived');
      expect(edited.photographicStyle?['tone'], 90);
      expect(snapshot.last.portraitMode, 'inherit');
      expect(snapshot.last.portrait, isNotNull);
      expect(snapshot.last.motionPhotoMode, 'livePhotoPair');
    },
  );

  test(
    'unavailable calibration stays unavailable and depth focal length uses pixels',
    () {
      final summary = PortraitSummary.fromJson({
        'hasPortrait': true,
        'scaleMode': 'unavailable',
        'focalLengthPixels': 123.0,
      });
      expect(summary.scale, isNull);
      expect(summary.focalLengthPixels, 123);
      expect(PortraitSummary.fromJson(summary.toJson()).scale, isNull);
      expect(
        PhotographicStyleSummary.fromJson(style.toJson()).styleNameEn,
        'Fresh',
      );
    },
  );
  test('policy refresh preserves original checkpoint source fingerprint', () {
    final previous = CheckpointItem(
      inputPath: '/original.jpg',
      outputPath: '/out.heic',
      status: CheckpointItemStatus.converted,
      inputSize: 123,
      inputMtimeMs: 456,
    );
    final item = photo()..portraitMode = PortraitMode.standard;
    final refreshed = CheckpointService.createItemsFromQueue(
      [item],
      previous: [previous],
    ).single;
    expect(refreshed.inputSize, 123);
    expect(refreshed.inputMtimeMs, 456);
    expect(refreshed.portraitMode, 'standard');
    expect(refreshed.status, CheckpointItemStatus.pending);
  });
}
