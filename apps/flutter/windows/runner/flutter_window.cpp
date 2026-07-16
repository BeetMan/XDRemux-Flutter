#include "flutter_window.h"

#include <shellapi.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Set up the drop channel so we can forward WM_DROPFILES to Dart.
  drop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "xdremux/drop",
      &flutter::StandardMethodCodec::GetInstance());

  // Register the window for file-drop support (WM_DROPFILES).
  DragAcceptFiles(GetHandle(), TRUE);

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case WM_DROPFILES: {
      HDROP hDrop = reinterpret_cast<HDROP>(wparam);
      UINT fileCount = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);

      flutter::EncodableList paths;
      for (UINT i = 0; i < fileCount; ++i) {
        UINT len = DragQueryFileW(hDrop, i, nullptr, 0);
        if (len == 0) continue;
        std::vector<wchar_t> wideBuf(len + 1);
        DragQueryFileW(hDrop, i, wideBuf.data(),
                       static_cast<UINT>(wideBuf.size()));
        // Convert wide path to UTF-8 for Dart.
        int utf8Len = WideCharToMultiByte(CP_UTF8, 0, wideBuf.data(), -1,
                                          nullptr, 0, nullptr, nullptr);
        if (utf8Len <= 0) continue;
        std::string utf8Path(utf8Len - 1, '\0');
        WideCharToMultiByte(CP_UTF8, 0, wideBuf.data(), -1, &utf8Path[0],
                            utf8Len, nullptr, nullptr);
        paths.push_back(flutter::EncodableValue(utf8Path));
      }

      DragFinish(hDrop);

      if (drop_channel_ && !paths.empty()) {
        drop_channel_->InvokeMethod(
            "onFilesDropped",
            std::make_unique<flutter::EncodableValue>(paths));
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
