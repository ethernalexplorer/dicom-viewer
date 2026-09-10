#include "flutter_window.h"

#include <ShObjIdl.h>
#include <Windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }

  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }

  std::string result(size - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size, nullptr, nullptr);
  return result;
}

std::optional<std::string> PickFolder(HWND owner) {
  IFileOpenDialog* dialog = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr)) {
    return std::nullopt;
  }

  DWORD options = 0;
  if (SUCCEEDED(dialog->GetOptions(&options))) {
    dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
  }
  dialog->SetTitle(L"Выберите папку DICOM исследования");

  hr = dialog->Show(owner);
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    dialog->Release();
    return std::nullopt;
  }
  if (FAILED(hr)) {
    dialog->Release();
    return std::nullopt;
  }

  IShellItem* item = nullptr;
  hr = dialog->GetResult(&item);
  dialog->Release();
  if (FAILED(hr) || item == nullptr) {
    return std::nullopt;
  }

  PWSTR path = nullptr;
  hr = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
  item->Release();
  if (FAILED(hr) || path == nullptr) {
    return std::nullopt;
  }

  std::wstring wide_path(path);
  CoTaskMemFree(path);
  return WideToUtf8(wide_path);
}

}  // namespace

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
  folder_picker_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "dicom_viewer/folder_picker",
      &flutter::StandardMethodCodec::GetInstance());
  folder_picker_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "pickFolder") {
          const auto path = PickFolder(GetHandle());
          if (path.has_value()) {
            result->Success(flutter::EncodableValue(path.value()));
          } else {
            result->Success(flutter::EncodableValue());
          }
          return;
        }

        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (folder_picker_channel_) {
    folder_picker_channel_->SetMethodCallHandler(nullptr);
    folder_picker_channel_ = nullptr;
  }

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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
