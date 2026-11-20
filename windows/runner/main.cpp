#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <memory>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kWorkstationMutex[] = L"Local\\ai.lvpai.zhenji.workstation";
constexpr ULONGLONG kWindowStartupTimeoutMs = 5000;

struct CloseHandleOnExit {
  void operator()(HANDLE handle) const { ::CloseHandle(handle); }
};

bool ActivateExistingWindow() {
  const HWND window = ::FindWindowW(Win32Window::kClassName, nullptr);
  if (!window) {
    return false;
  }
  DWORD owner_pid = 0;
  ::GetWindowThreadProcessId(window, &owner_pid);
  if (!owner_pid) {
    return false;
  }
  // Explorer can grant foreground activation to the existing instance.
  ::AllowSetForegroundWindow(owner_pid);
  DWORD_PTR activated = 0;
  return ::SendMessageTimeoutW(window, Win32Window::ActivationMessage(), 0, 0,
                               SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, &activated) &&
         activated == 1;
}

int StartupError(const wchar_t* message) {
  ::MessageBoxW(nullptr, message, L"帧集", MB_OK | MB_ICONWARNING);
  return EXIT_FAILURE;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Take the mutex before starting Flutter, the tray or the print service.
  const std::unique_ptr<void, CloseHandleOnExit> mutex(
      ::CreateMutexW(nullptr, FALSE, kWorkstationMutex));
  if (!mutex || !Win32Window::ActivationMessage()) {
    return StartupError(L"暂时无法打开工作台，请稍后再试。");
  }
  const ULONGLONG deadline = ::GetTickCount64() + kWindowStartupTimeoutMs;
  for (;;) {
    const DWORD state = ::WaitForSingleObject(mutex.get(), 0);
    if (state == WAIT_OBJECT_0 || state == WAIT_ABANDONED) {
      break;
    }
    if (state != WAIT_TIMEOUT) {
      return StartupError(L"暂时无法打开工作台，请稍后再试。");
    }
    if (ActivateExistingWindow()) {
      return EXIT_SUCCESS;
    }
    if (::GetTickCount64() >= deadline) {
      return StartupError(L"帧集已经在运行，请从任务栏或系统托盘打开。");
    }
    // A launch at the same time as the first one may beat window creation.
    ::Sleep(50);
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"帧集 · 上传与打印工作台", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
