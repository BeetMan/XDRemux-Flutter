import assert from 'node:assert/strict';
import {
  decodeGalleryLibrary,
  emptyGalleryLibrary,
  encodeGalleryLibrary,
  galleryExtensionFromName,
  galleryItemPath,
  galleryMimeTypeForExtension
} from '../entry/src/main/ets/gallery/GalleryLibraryModel.ts';

const photo = {
  id: 'd3f2b843-aeb0-46aa-919a-a8b3d168be59',
  displayName: 'IMG_1001.HEIC',
  extension: '.heic',
  mimeType: 'image/heic',
  size: 2048,
  importedAt: 1790315000000
};

assert.deepEqual(emptyGalleryLibrary(), { schema: 1, items: [] });
assert.deepEqual(decodeGalleryLibrary(encodeGalleryLibrary([photo])).items, [photo]);
assert.equal(galleryItemPath('/private/xdremux-gallery', photo),
  '/private/xdremux-gallery/items/d3f2b843-aeb0-46aa-919a-a8b3d168be59.heic');
assert.equal(galleryExtensionFromName('file://media/Camera/IMG_1001.JPEG?grant=1'), '.jpeg');
assert.equal(galleryExtensionFromName('photo-without-extension'), '.img');
assert.equal(galleryMimeTypeForExtension('.heif'), 'image/heic');
assert.equal(galleryMimeTypeForExtension('.jpeg'), 'image/jpeg');

assert.throws(() => decodeGalleryLibrary('{'), /JSON/);
assert.throws(() => decodeGalleryLibrary(JSON.stringify({ schema: 2, items: [] })), /版本/);
assert.throws(() => encodeGalleryLibrary([photo, photo]), /重复/);
assert.throws(() => encodeGalleryLibrary([{ ...photo, extension: '/../outside' }]), /扩展名/);
assert.throws(() => encodeGalleryLibrary([{ ...photo, size: 0 }]), /文件大小/);

console.log('gallery local-library model: all assertions passed');
