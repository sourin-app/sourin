#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

// =====================================================================
//  N13 - single instance only
// =====================================================================
//
// # Owner's words
// ```text
// only one instance is allowed; when already running, clicking the icon
// again must activate the existing one instead of starting a new one
// ```
//
// # State before this change
// ```text
// grep "singleInstance|already running|CreateMutex|FindWindow" over lib/
// and rust/ hit only unrelated comments. The startup entry wWinMain had
// NO mutual-exclusion check at all.
// => every icon click spawned a brand new process (2-3 sourin_spike.exe
//    were observed running at once, all sharing one data directory).
// ```
//
// # Approach: named Mutex + find-and-activate the existing window
//
// ```text
// 1) CreateMutexW(name)   - kernel object, auto-released on process exit
// 2) GetLastError() == ERROR_ALREADY_EXISTS => another instance is alive
// 3) find its window -> ShowWindow(SW_RESTORE) + SetForegroundWindow
// 4) exit(0)
// ```
//
// ## Why a Mutex instead of a lock file
// ```text
// A lock file survives a crash, so the next launch would wrongly conclude
// "already running" and refuse to start - the user sees "clicking does
// nothing", which is worse than allowing duplicates.
// A kernel Mutex is reclaimed by the OS when the process ends (including
// crashes), so it cannot go stale.
// ```
//
// ## Why Local\ and not Global\
// ```text
// Global\ is shared across Terminal Services sessions: two Windows users
// on the same machine (or RDP + local login) would block each other, and
// user B clicking the icon would activate user A's window (which B cannot
// even see). Local\ is unique per login session, so each user gets their
// own single instance - the normal desktop-app semantics.
// Cost: the same user in two RDP sessions can run one each (acceptable).
// ```
//
// ## Probe / self-test processes must BYPASS this check
// ```text
// This repo has several one-shot processes (SOURIN_DRAG_SELFTEST,
// SOURIN_WF_DEPENDS_ON_SIZE, SOURIN_FRAME_LOG, SOURIN_SHOT, SOURIN_TABS).
// They run and exit. If the single-instance check blocked them, self-tests
// could never run - and a failed self-test gets misread as "product broken".
// => if ANY of those variables is present, skip the check entirely
//    (not even create the Mutex).
// ```

namespace {

// Single-instance mutex name.
//
// The Local\ prefix means "unique within the current login session"
// (rationale above). The .SingleInstance suffix is for diagnostics: it
// shows up in WinObj / Process Explorer, so whoever holds it is obvious.
constexpr const wchar_t kSingleInstanceMutex[] =
    L"Local\\SourinPlayer.SingleInstance";

// This product's window title (the string passed to window.Create below).
constexpr const wchar_t kWindowTitle[] = L"\u6e90\u5f71"; // app title, set by Dart MaterialApp

// Window class name - must stay in sync with kWindowClassName in
// win32_window.cpp.
//
// That constant is file-local there, so it cannot be referenced from here.
// IMPORTANT: if it changes over there, change it here too, otherwise
// activation will not find the window (symptom: clicking the icon does
// nothing).
constexpr const wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// If any of these env vars is present, this is a probe / self-test process
// and the single-instance check is skipped.
//
// The list comes from `grep -rhoE "SOURIN_[A-Z_]+" lib/ rust/ windows/`,
// keeping only the ones that run as their own process and exit immediately.
const wchar_t* const kProbeEnvVars[] = {
    L"SOURIN_DRAG_SELFTEST",
    L"SOURIN_WF_DEPENDS_ON_SIZE",
    L"SOURIN_FRAME_LOG",
    L"SOURIN_SHOT",
    L"SOURIN_TABS",
};

bool IsProbeProcess() {
  for (const wchar_t* name : kProbeEnvVars) {
    if (::GetEnvironmentVariableW(name, nullptr, 0) > 0) {
      return true;
    }
  }
  return false;
}

// Lower-cased executable file name (no path) owning the given window.
std::wstring ProcessImageName(HWND hwnd) {
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0) return std::wstring();

  HANDLE proc = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (proc == nullptr) return std::wstring();

  wchar_t buf[MAX_PATH] = {};
  DWORD size = MAX_PATH;
  std::wstring name;
  if (::QueryFullProcessImageNameW(proc, 0, buf, &size)) {
    std::wstring full(buf, size);
    const size_t slash = full.find_last_of(L"\\/");
    name = (slash == std::wstring::npos) ? full : full.substr(slash + 1);
    for (auto& ch : name) ch = static_cast<wchar_t>(::towlower(ch));
  }
  ::CloseHandle(proc);
  return name;
}

struct FindCtx {
  HWND found = nullptr;
  DWORD self_pid = 0;
  std::wstring want_exe;
};

// EnumWindows callback: same class + same title + same exe name + not self.
BOOL CALLBACK FindExistingProc(HWND hwnd, LPARAM lparam) {
  auto* ctx = reinterpret_cast<FindCtx*>(lparam);

  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == ctx->self_pid) return TRUE;  // that is us

  wchar_t cls[256] = {};
  ::GetClassNameW(hwnd, cls, 256);
  if (::lstrcmpW(cls, kWindowClass) != 0) return TRUE;

  wchar_t title[512] = {};
  ::GetWindowTextW(hwnd, title, 512);
  if (::lstrcmpW(title, kWindowTitle) != 0) return TRUE;

  // Third check: process name. Prevents activating some OTHER Flutter app
  // on the same machine (the class name is shared by every Flutter app).
  const std::wstring exe = ProcessImageName(hwnd);
  if (exe.empty() || exe != ctx->want_exe) return TRUE;

  // Only top-level windows (skip hidden helper windows).
  if (::GetWindow(hwnd, GW_OWNER) != nullptr) return TRUE;

  ctx->found = hwnd;
  return FALSE;  // stop enumerating
}

// Try to activate the already-running instance.
// Returns true if found and activated (caller should exit).
bool ActivateExistingInstance() {
  FindCtx ctx;
  ctx.self_pid = ::GetCurrentProcessId();

  wchar_t self_path[MAX_PATH] = {};
  DWORD n = MAX_PATH;
  if (::QueryFullProcessImageNameW(::GetCurrentProcess(), 0, self_path, &n)) {
    std::wstring full(self_path, n);
    const size_t slash = full.find_last_of(L"\\/");
    ctx.want_exe = (slash == std::wstring::npos) ? full : full.substr(slash + 1);
    for (auto& ch : ctx.want_exe) ch = static_cast<wchar_t>(::towlower(ch));
  }

  ::EnumWindows(FindExistingProc, reinterpret_cast<LPARAM>(&ctx));
  if (ctx.found == nullptr) return false;

  // SW_RESTORE handles both "minimized" and "maximized but covered".
  // ShowWindow(SW_SHOW) alone would NOT un-minimize - the user would think
  // nothing happened.
  //
  // SetForegroundWindow is subject to the foreground-lock policy (Windows
  // does not let background processes steal focus at will). Here it is
  // triggered by the user clicking the icon, which is an allowed case.
  // If it is refused anyway, correctness is unaffected: the window is
  // already restored, it just may not be on top.
  ::ShowWindow(ctx.found, SW_RESTORE);
  ::SetForegroundWindow(ctx.found);
  ::BringWindowToTop(ctx.found);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // -- N13 single-instance check (MUST run before creating the window) --
  //
  // Probe / self-test processes skip this entirely (not even the Mutex is
  // created); see kProbeEnvVars above.
  HANDLE single_mutex = nullptr;
  if (!IsProbeProcess()) {
    single_mutex = ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
    const DWORD err = ::GetLastError();
    if (single_mutex != nullptr && err == ERROR_ALREADY_EXISTS) {
      // Another instance is alive.
      //
      // We MUST try to activate it before exiting: exiting silently would
      // make the user think the icon click did nothing, which is more
      // confusing than allowing duplicates.
      ::CloseHandle(single_mutex);
      if (ActivateExistingInstance()) {
        return EXIT_SUCCESS;
      }
      // Mutex exists but no window found: the other instance is still
      // starting up (window not created yet) or it is hung.
      //
      // Real case: double-clicking the icon quickly means the first
      // process may not have called CreateWindow yet.
      // => retry briefly, and only exit if still not found.
      for (int i = 0; i < 40; ++i) {  // 40 x 50ms = up to 2 seconds
        ::Sleep(50);
        if (ActivateExistingInstance()) {
          return EXIT_SUCCESS;
        }
      }
      return EXIT_SUCCESS;
    }
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
  if (!window.Create(L"sourin_spike", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  // The OS reclaims the Mutex on exit; closing it explicitly documents intent.
  if (single_mutex != nullptr) {
    ::ReleaseMutex(single_mutex);
    ::CloseHandle(single_mutex);
  }
  return EXIT_SUCCESS;
}
