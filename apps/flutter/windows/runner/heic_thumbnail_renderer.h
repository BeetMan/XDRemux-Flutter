#ifndef RUNNER_HEIC_THUMBNAIL_RENDERER_H_
#define RUNNER_HEIC_THUMBNAIL_RENDERER_H_

#include <string>
#include <vector>

// Render a JPEG thumbnail of a HEIC/HEIF image using Windows Imaging
// Component (WIC). Decodes the full-resolution primary image (frame 0) —
// crisper and full-colour, unlike the Rust EXIF-embedded JPEG path which can
// pick up a grayscale gain map or a random JPEG-looking fragment from the
// mdat. Requires the OS HEIF extension; returns empty on failure so callers
// can fall back to the FFI path.
//
// Mirrors macOS Runner/HeicThumbnailRenderer.swift (ImageIO) on Windows.
class HeicThumbnailRenderer {
 public:
  // Render a JPEG thumbnail of `path`, `max_pixel_size` on the long edge.
  // Returns JPEG bytes, or empty vector on failure.
  static std::vector<uint8_t> renderThumbnail(const std::string& path,
                                              int max_pixel_size);
};

#endif  // RUNNER_HEIC_THUMBNAIL_RENDERER_H_
