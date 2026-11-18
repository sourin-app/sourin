#pragma once

#include <windows.h>
#include <string>

// The task launcher opts in; ordinary launches keep the original WinAPI calls.
namespace sourin_task_window {
inline bool Requested() {
  const DWORD saved = ::GetLastError();
  const DWORD size = ::GetEnvironmentVariableW(L"SOURIN_TASK_NO_ACTIVATE", nullptr, 0);
  bool requested = false;
  if (size > 0 && size <= 32768) {
    std::wstring value(size, L'\0');
    const DWORD length = ::GetEnvironmentVariableW(
        L"SOURIN_TASK_NO_ACTIVATE", value.data(), size);
    requested = length > 0 && length < size && value[0] == L'1';
  }
  ::SetLastError(saved);
  return requested;
}

inline bool Owned(HWND window) {
  const DWORD saved = ::GetLastError();
  DWORD pid = 0;
  const bool owned = window && ::GetWindowThreadProcessId(window, &pid) &&
                     pid == ::GetCurrentProcessId();
  ::SetLastError(saved);
  return owned;
}

inline bool Iconic(HWND window) {
  const DWORD saved = ::GetLastError();
  const bool iconic = ::IsIconic(window) != FALSE;
  ::SetLastError(saved);
  return iconic;
}

inline bool Minimizing(int command) {
  return command == SW_MINIMIZE || command == SW_SHOWMINIMIZED ||
         command == SW_SHOWMINNOACTIVE || command == SW_FORCEMINIMIZE;
}

inline BOOL WINAPI SetForegroundWindow(HWND window) {
  if (Requested()) return FALSE;
  return ::SetForegroundWindow(window);
}
inline HWND WINAPI SetActiveWindow(HWND window) {
  if (Requested()) return nullptr;
  return ::SetActiveWindow(window);
}
inline HWND WINAPI SetFocus(HWND window) {
  if (Requested()) return nullptr;
  return ::SetFocus(window);
}
inline BOOL WINAPI BringWindowToTop(HWND window) {
  if (Requested()) return FALSE;
  return ::BringWindowToTop(window);
}

inline BOOL WINAPI SetWindowPos(HWND window, HWND after, int x, int y,
                                int width, int height, UINT flags) {
  if (Requested()) {
    if (!Owned(window)) return FALSE;
    if ((flags & SWP_SHOWWINDOW) && Iconic(window)) return FALSE;
    flags |= SWP_NOACTIVATE;
  }
  return ::SetWindowPos(window, after, x, y, width, height, flags);
}

inline BOOL WINAPI ShowWindow(HWND window, int command) {
  if (Requested()) {
    if (!Owned(window)) return FALSE;
    if (command != SW_HIDE && !Minimizing(command) && Iconic(window)) return FALSE;
    command = command == SW_HIDE ? SW_HIDE
              : Minimizing(command) ? SW_SHOWMINNOACTIVE : SW_SHOWNOACTIVATE;
  }
  return ::ShowWindow(window, command);
}
inline BOOL WINAPI ShowWindowAsync(HWND window, int command) {
  if (Requested()) {
    if (!Owned(window)) return FALSE;
    if (command != SW_HIDE && !Minimizing(command) && Iconic(window)) return FALSE;
    command = command == SW_HIDE ? SW_HIDE
              : Minimizing(command) ? SW_SHOWMINNOACTIVE : SW_SHOWNOACTIVATE;
  }
  return ::ShowWindowAsync(window, command);
}

inline bool BlockedMessage(HWND window, UINT message, WPARAM wparam) {
  if (!Owned(window)) return true;
  if (message == WM_NCLBUTTONDOWN || message == WM_NCLBUTTONDBLCLK) return true;
  const WPARAM command = wparam & 0xfff0;
  // These commands can activate through OS default processing, bypassing ShowWindow.
  return message == WM_SYSCOMMAND &&
         (command == SC_RESTORE || command == SC_MAXIMIZE);
}
inline BOOL WINAPI PostMessageW(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (Requested() && BlockedMessage(window, message, wparam)) return FALSE;
  return ::PostMessageW(window, message, wparam, lparam);
}
inline BOOL WINAPI PostMessageA(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (Requested() && BlockedMessage(window, message, wparam)) return FALSE;
  return ::PostMessageA(window, message, wparam, lparam);
}

inline HWND WINAPI CreateWindowExW(DWORD extended, LPCWSTR name, LPCWSTR title,
    DWORD style, int x, int y, int width, int height, HWND parent, HMENU menu,
    HINSTANCE instance, LPVOID parameter) {
  if (Requested()) {
    if (parent && parent != HWND_MESSAGE && !Owned(parent)) return nullptr;
    extended |= WS_EX_NOACTIVATE;
  }
  return ::CreateWindowExW(extended, name, title, style, x, y, width, height,
                           parent, menu, instance, parameter);
}
inline HWND WINAPI CreateWindowExA(DWORD extended, LPCSTR name, LPCSTR title,
    DWORD style, int x, int y, int width, int height, HWND parent, HMENU menu,
    HINSTANCE instance, LPVOID parameter) {
  if (Requested()) {
    if (parent && parent != HWND_MESSAGE && !Owned(parent)) return nullptr;
    extended |= WS_EX_NOACTIVATE;
  }
  return ::CreateWindowExA(extended, name, title, style, x, y, width, height,
                           parent, menu, instance, parameter);
}
}  // namespace sourin_task_window

// These aliases also cover :: calls and the SDK's Unicode/ANSI API aliases.
#define SetForegroundWindow sourin_task_window::SetForegroundWindow
#define SetActiveWindow sourin_task_window::SetActiveWindow
#define SetFocus sourin_task_window::SetFocus
#define BringWindowToTop sourin_task_window::BringWindowToTop
#define SetWindowPos sourin_task_window::SetWindowPos
#define ShowWindow sourin_task_window::ShowWindow
#define ShowWindowAsync sourin_task_window::ShowWindowAsync
#define PostMessageW sourin_task_window::PostMessageW
#define PostMessageA sourin_task_window::PostMessageA
#define CreateWindowExW sourin_task_window::CreateWindowExW
#define CreateWindowExA sourin_task_window::CreateWindowExA
