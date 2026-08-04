#include "heic_thumbnail_renderer.h"

#include <wincodec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

namespace {

// Minimal COM wrapper: releases on destruction. Avoids the WRL headers, which
// are not part of the base MSVC Build Tools install.
template <typename T>
class ComPtr {
 public:
  ComPtr() : ptr_(nullptr) {}
  explicit ComPtr(T* ptr) : ptr_(ptr) {}
  ~ComPtr() { reset(); }

  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;

  T** address_of() { return &ptr_; }
  T* get() const { return ptr_; }
  T* operator->() const { return ptr_; }

  void reset() {
    if (ptr_) {
      ptr_->Release();
      ptr_ = nullptr;
    }
  }

 private:
  T* ptr_;
};

// Convert a UTF-8 path to a wide string for WIC.
std::wstring toWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) return std::wstring();
  std::wstring wide(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      &wide[0], len);
  return wide;
}

// Resize a WIC source to `max_pixel_size` on the long edge using a scaler.
// Returns a scaler whose width/height are the target dimensions.
HRESULT createScaledSource(IWICImagingFactory* factory,
                           IWICBitmapSource* source, int max_pixel_size,
                           IWICBitmapScaler** out_scaler) {
  UINT width = 0, height = 0;
  HRESULT hr = source->GetSize(&width, &height);
  if (FAILED(hr) || width == 0 || height == 0) return E_FAIL;

  double scale = 1.0;
  if (width > height && width > static_cast<UINT>(max_pixel_size)) {
    scale = static_cast<double>(max_pixel_size) / width;
  } else if (height >= width &&
             height > static_cast<UINT>(max_pixel_size)) {
    scale = static_cast<double>(max_pixel_size) / height;
  }

  IWICBitmapScaler* scaler = nullptr;
  hr = factory->CreateBitmapScaler(&scaler);
  if (FAILED(hr)) return hr;
  hr = scaler->Initialize(source, static_cast<UINT>(width * scale),
                          static_cast<UINT>(height * scale),
                          WICBitmapInterpolationModeFant);
  if (FAILED(hr)) {
    scaler->Release();
    return hr;
  }
  *out_scaler = scaler;
  return S_OK;
}

// Encode a WIC source as JPEG bytes.
HRESULT encodeJpeg(IWICImagingFactory* factory, IWICBitmapSource* source,
                   std::vector<uint8_t>* out) {
  ComPtr<IWICStream> stream;
  HRESULT hr =
      factory->CreateStream(stream.address_of());
  if (FAILED(hr)) return hr;
  // Memory-backed stream: initialize with a growing memory pool.
  IStream* memory_stream = nullptr;
  hr = CreateStreamOnHGlobal(nullptr, TRUE, &memory_stream);
  if (FAILED(hr)) return hr;
  hr = stream->InitializeFromIStream(memory_stream);
  memory_stream->Release();
  if (FAILED(hr)) return hr;

  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr,
                              encoder.address_of());
  if (FAILED(hr)) return hr;
  hr = encoder->Initialize(stream.get(), WICBitmapEncoderNoCache);
  if (FAILED(hr)) return hr;

  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  hr = encoder->CreateNewFrame(frame.address_of(), props.address_of());
  if (FAILED(hr)) return hr;

  // JPEG quality ~0.85.
  PROPBAG2 option = {};
  option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
  VARIANT var;
  VariantInit(&var);
  var.vt = VT_R4;
  var.fltVal = 0.85f;
  hr = props->Write(1, &option, &var);
  VariantClear(&var);
  if (FAILED(hr)) return hr;

  hr = frame->Initialize(props.get());
  if (FAILED(hr)) return hr;

  UINT width = 0, height = 0;
  source->GetSize(&width, &height);
  hr = frame->SetSize(width, height);
  if (FAILED(hr)) return hr;

  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  hr = frame->SetPixelFormat(&format);
  if (FAILED(hr)) return hr;

  hr = frame->WriteSource(source, nullptr);
  if (FAILED(hr)) return hr;
  hr = frame->Commit();
  if (FAILED(hr)) return hr;
  hr = encoder->Commit();
  if (FAILED(hr)) return hr;

  // Read back the memory stream contents.
  STATSTG stat = {};
  hr = memory_stream->Stat(&stat, STATFLAG_NONAME);
  if (FAILED(hr) || stat.cbSize.QuadPart <= 0) return E_FAIL;
  ULARGE_INTEGER size = stat.cbSize;
  out->resize(static_cast<size_t>(size.QuadPart));

  LARGE_INTEGER zero = {};
  memory_stream->Seek(zero, STREAM_SEEK_SET, nullptr);
  ULONG read = 0;
  hr = memory_stream->Read(out->data(), static_cast<ULONG>(size.QuadPart),
                           &read);
  if (FAILED(hr)) return hr;
  out->resize(read);
  return S_OK;
}

}  // namespace

std::vector<uint8_t> HeicThumbnailRenderer::renderThumbnail(
    const std::string& path, int max_pixel_size) {
  std::vector<uint8_t> result;

  if (max_pixel_size <= 0) max_pixel_size = 256;

  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  // Only uninitialize when this call actually initialized COM on this thread.
  // RPC_E_CHANGED_MODE means COM was already initialized in another mode; that
  // existing initialization remains valid and must not be torn down here.
  bool owns_com = SUCCEEDED(hr);
  if (hr == RPC_E_CHANGED_MODE) owns_com = false;
  if (!SUCCEEDED(hr) && hr != RPC_E_CHANGED_MODE) return result;

  ComPtr<IWICImagingFactory> factory;
  hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                        IID_PPV_ARGS(factory.address_of()));
  if (FAILED(hr)) {
    if (owns_com) CoUninitialize();
    return result;
  }

  std::wstring wide_path = toWide(path);
  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromFilename(
      wide_path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
      decoder.address_of());
  if (FAILED(hr)) {
    if (owns_com) CoUninitialize();
    return result;
  }

  // Frame 0 is the primary image for HEIC (HEIF extension). Additional frames
  // may be the gain map / depth / thumbnails.
  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, frame.address_of());
  if (FAILED(hr)) {
    if (owns_com) CoUninitialize();
    return result;
  }

  ComPtr<IWICBitmapScaler> scaler;
  hr = createScaledSource(factory.get(), frame.get(), max_pixel_size,
                          scaler.address_of());
  if (FAILED(hr)) {
    if (owns_com) CoUninitialize();
    return result;
  }

  hr = encodeJpeg(factory.get(), scaler.get(), &result);

  if (owns_com) CoUninitialize();
  return result;
}
