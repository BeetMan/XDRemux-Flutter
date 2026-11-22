import assert from 'node:assert/strict';
import {
  GalleryThumbnailQueue,
  galleryExifOrientation,
  galleryLongEdgeDecodeSize,
  galleryOrientationSteps,
  galleryOrientationSwapsAxes,
  galleryThumbnailDecodeSize,
  galleryThumbnailFileName,
  parseGalleryThumbnailFileName
} from '../entry/src/main/ets/gallery/GalleryThumbnailModel.ts';

const id = '0f8fad5b-d9cb-469f-a165-70867728950e';

// Names carry the displayed size and round-trip; nothing else parses.
assert.equal(galleryThumbnailFileName(id, 3000, 4000), id + '_3000x4000.jpg');
assert.deepEqual(parseGalleryThumbnailFileName(id + '_3000x4000.jpg'), { id, width: 3000, height: 4000 });
assert.deepEqual(parseGalleryThumbnailFileName(id.toUpperCase() + '_1x1.JPG'), { id: id.toUpperCase(), width: 1, height: 1 });
for (const name of [
  id + '.tmp-0f8fad5b', id + '_0x10.jpg', id + '_10x10.png', 'x_10x10.jpg',
  id + '_10x10.jpg.tmp', id + '_1234567x10.jpg', id + '_10x10', '../' + id + '_10x10.jpg'
]) {
  assert.equal(parseGalleryThumbnailFileName(name), undefined, name);
}

// EXIF Orientation as the image framework reports it (libexif names or digits).
assert.equal(galleryExifOrientation('Top-left'), 1);
assert.equal(galleryExifOrientation('Right-top'), 6);
assert.equal(galleryExifOrientation(' left-bottom '), 8);
assert.equal(galleryExifOrientation('Bottom-right'), 3);
assert.equal(galleryExifOrientation('5'), 5);
assert.equal(galleryExifOrientation('Unknown Value 9'), 1);
assert.equal(galleryExifOrientation('0'), 1);
assert.equal(galleryExifOrientation(''), 1);
assert.deepEqual([1, 2, 3, 4, 5, 6, 7, 8].map(galleryOrientationSwapsAxes),
  [false, false, false, false, true, true, true, true]);

// The pixel steps must show every orientation upright. Model a stored image
// of labelled pixels, apply the steps the way PixelMap.rotate (clockwise)
// and flip do, and compare with the EXIF definition of the displayed image.
const W = 3;
const H = 2;
const stored = { w: W, h: H, at: (x, y) => `${x},${y}` };
const rotateClockwise = (img, degrees) => {
  if (degrees === 90) return { w: img.h, h: img.w, at: (x, y) => img.at(y, img.h - 1 - x) };
  if (degrees === 180) return { w: img.w, h: img.h, at: (x, y) => img.at(img.w - 1 - x, img.h - 1 - y) };
  if (degrees === 270) return { w: img.h, h: img.w, at: (x, y) => img.at(img.w - 1 - y, x) };
  return img;
};
const flip = (img, horizontal, vertical) => ({
  w: img.w,
  h: img.h,
  at: (x, y) => img.at(horizontal ? img.w - 1 - x : x, vertical ? img.h - 1 - y : y)
});
// Displayed pixel (x, y) → stored pixel, per the EXIF 2.3 orientation table.
const exifDisplayed = {
  1: (x, y) => [x, y],
  2: (x, y) => [W - 1 - x, y],
  3: (x, y) => [W - 1 - x, H - 1 - y],
  4: (x, y) => [x, H - 1 - y],
  5: (x, y) => [y, x],
  6: (x, y) => [y, H - 1 - x],
  7: (x, y) => [W - 1 - y, H - 1 - x],
  8: (x, y) => [W - 1 - y, x]
};
for (let orientation = 1; orientation <= 8; orientation += 1) {
  const step = galleryOrientationSteps(orientation);
  const shown = flip(rotateClockwise(stored, step.rotate), step.flipHorizontal, step.flipVertical);
  const swapped = galleryOrientationSwapsAxes(orientation);
  assert.deepEqual([shown.w, shown.h], swapped ? [H, W] : [W, H], `size for ${orientation}`);
  for (let y = 0; y < shown.h; y += 1) {
    for (let x = 0; x < shown.w; x += 1) {
      const [sx, sy] = exifDisplayed[orientation](x, y);
      assert.equal(shown.at(x, y), `${sx},${sy}`, `orientation ${orientation} at ${x},${y}`);
    }
  }
}

// Thumbnails: shorter side 512, long side capped, never upscaled.
assert.deepEqual(galleryThumbnailDecodeSize(4000, 3000), { width: 683, height: 512 });
assert.deepEqual(galleryThumbnailDecodeSize(3000, 4000), { width: 512, height: 683 });
assert.deepEqual(galleryThumbnailDecodeSize(8000, 2000), { width: 1536, height: 384 });
assert.deepEqual(galleryThumbnailDecodeSize(300, 200), { width: 300, height: 200 });
assert.deepEqual(galleryLongEdgeDecodeSize(4000, 3000, 1920), { width: 1920, height: 1440 });
assert.deepEqual(galleryLongEdgeDecodeSize(1000, 800, 1920), { width: 1000, height: 800 });
assert.deepEqual(galleryLongEdgeDecodeSize(9000, 10, 240), { width: 240, height: 1 });

// Work order: newest on-screen request first, then the library in order.
const queue = new GalleryThumbnailQueue();
const done = new Set(['b']);
const isDone = (candidate) => done.has(candidate);
queue.setBackground(['a', 'b', 'c', 'd']);
queue.requestUrgent('x');
queue.requestUrgent('y');
queue.requestUrgent('x');
assert.equal(queue.hasUrgent(), true);
assert.equal(queue.next(true, isDone), 'x');
assert.equal(queue.next(false, isDone), 'y');
assert.equal(queue.hasUrgent(), false);
assert.equal(queue.next(false, isDone), undefined);
assert.equal(queue.next(true, isDone), 'a');
queue.requestUrgent('z');
queue.cancelUrgent('z');
queue.remove('c');
assert.equal(queue.next(true, isDone), 'd');
assert.equal(queue.next(true, isDone), undefined);
done.add('w');
queue.requestUrgent('w');
assert.equal(queue.next(true, isDone), undefined);
queue.requestUrgent('v');
queue.clear();
assert.equal(queue.next(true, isDone), undefined);

console.log('gallery_thumbnail_model_test passed');
