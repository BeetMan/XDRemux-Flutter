import assert from 'node:assert/strict';
import {
  decodeGalleryLibrary,
  emptyGalleryLibrary,
  encodeGalleryLibrary,
  galleryExtensionFromName,
  galleryItemPath,
  galleryMimeTypeForExtension,
  recoverGalleryItems,
  removeGalleryLibraryItem
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
const otherPhoto = {
  ...photo,
  id: 'a3f2b843-aeb0-46aa-919a-a8b3d168be59',
  displayName: 'other.jpg',
  extension: '.jpg',
  mimeType: 'image/jpeg'
};
assert.deepEqual(removeGalleryLibraryItem([photo], photo.id), []);
assert.deepEqual(removeGalleryLibraryItem([photo, otherPhoto], photo.id), [otherPhoto]);
assert.throws(() => removeGalleryLibraryItem([photo], 'not-present'), /不在本地图库/);

assert.throws(() => decodeGalleryLibrary('{'), /JSON/);
assert.throws(() => decodeGalleryLibrary(JSON.stringify({ schema: 2, items: [] })), /版本/);
assert.throws(() => encodeGalleryLibrary([photo, photo]), /重复/);
assert.throws(() => encodeGalleryLibrary([{ ...photo, extension: '/../outside' }]), /扩展名/);
assert.throws(() => encodeGalleryLibrary([{ ...photo, size: 0 }]), /文件大小/);

console.log('gallery local-library model: all assertions passed');

// Recovery after a damaged index: keep known entries whose file still exists
// (with the file's real size), add unknown <uuid><ext> files, drop the rest.
{
  const known = [
    { id: 'd3f2b843-aeb0-46aa-919a-a8b3d168be59', displayName: 'IMG_1001.HEIC', extension: '.heic',
      mimeType: 'image/heic', size: 10, importedAt: 2000 },
    { id: '0b6f3c1e-5a2d-4e8f-9c7b-1a2b3c4d5e6f', displayName: 'gone.jpg', extension: '.jpg',
      mimeType: 'image/jpeg', size: 5, importedAt: 3000 }
  ];
  const recovered = recoverGalleryItems(known, [
    { name: 'd3f2b843-aeb0-46aa-919a-a8b3d168be59.heic', size: 4096, modifiedAt: 1500 },
    { name: '7c9e6679-7425-40de-944b-e07fc1f90ae7.jpg', size: 2048, modifiedAt: 2500 },
    { name: 'not-a-uuid.jpg', size: 10, modifiedAt: 1 },
    { name: '7c9e6679-7425-40de-944b-e07fc1f90ae8.jpg', size: 0, modifiedAt: 1 },
    { name: 'notes.txt', size: 10, modifiedAt: 1 }
  ]);
  assert.deepEqual(recovered.map((item) => [item.id.substring(0, 8), item.displayName, item.size, item.importedAt]), [
    ['7c9e6679', '恢复的照片-7c9e6679.jpg', 2048, 2500],
    ['d3f2b843', 'IMG_1001.HEIC', 4096, 2000]
  ]);
  assert.equal(recovered[0].mimeType, 'image/jpeg');
  // The recovered list must itself be a valid index.
  assert.equal(decodeGalleryLibrary(encodeGalleryLibrary(recovered)).items.length, 2);
  assert.deepEqual(recoverGalleryItems([], []), []);
  console.log('gallery recovery passed');
}
