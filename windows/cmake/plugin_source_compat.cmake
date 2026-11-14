# Private compatibility sources for pinned Windows plugins.
# Include after generated_plugins.cmake. No compile options/definitions change.
if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  return()
endif()

function(sourin_plugin_compat_replace_exact variable before after expected)
  set(rest "${${variable}}")
  set(count 0)
  string(LENGTH "${before}" width)
  if(width EQUAL 0)
    message(FATAL_ERROR "Empty private compatibility replacement")
  endif()
  while(TRUE)
    string(FIND "${rest}" "${before}" position)
    if(position EQUAL -1)
      break()
    endif()
    math(EXPR count "${count} + 1")
    math(EXPR offset "${position} + ${width}")
    string(SUBSTRING "${rest}" ${offset} -1 rest)
  endwhile()
  if(NOT count EQUAL expected)
    message(FATAL_ERROR "Private plugin source replacement count changed: ${count}, expected ${expected}")
  endif()
  string(REPLACE "${before}" "${after}" updated "${${variable}}")
  set(${variable} "${updated}" PARENT_SCOPE)
endfunction()

function(sourin_plugin_compat_prepare plugin target)
  if(NOT TARGET ${target})
    message(FATAL_ERROR "Required private compatibility target missing: ${target}")
  endif()
  get_target_property(plugin_dir ${target} SOURCE_DIR)
  get_target_property(sources ${target} SOURCES)
  set(private "${CMAKE_CURRENT_BINARY_DIR}/sourin_plugin_fixes/strict_clang/${plugin}/windows")
  file(GLOB_RECURSE private_inputs CONFIGURE_DEPENDS LIST_DIRECTORIES FALSE "${plugin_dir}/*")
  foreach(original IN LISTS private_inputs)
    file(RELATIVE_PATH relative "${plugin_dir}" "${original}")
    if(relative MATCHES "^\\.\\./" OR IS_ABSOLUTE "${relative}" OR IS_SYMLINK "${original}")
      message(FATAL_ERROR "Plugin compatibility input escapes source root")
    endif()
    get_filename_component(parent "${private}/${relative}" DIRECTORY)
    file(MAKE_DIRECTORY "${parent}")
    configure_file("${original}" "${private}/${relative}" COPYONLY)
  endforeach()
  if(plugin STREQUAL "dynamic_color")
    file(SHA256 "${plugin_dir}/dynamic_color_plugin.cpp" original_hash)
    if(NOT original_hash STREQUAL "f53b205e8d91def50757eddbe9397f0addf10ae7fbc511c2347bd45cfb8dc13e")
      message(FATAL_ERROR "dynamic_color/dynamic_color_plugin.cpp changed; review strict Clang compatibility")
    endif()
    file(READ "${plugin_dir}/dynamic_color_plugin.cpp" source)
    string(REPLACE "\r\n" "\n" source "${source}")
    sourin_plugin_compat_replace_exact(source [====[result->Success(nullptr);]====] [====[result->Success();]====] 1)
    file(WRITE "${private}/dynamic_color_plugin.cpp.in" "${source}")
    configure_file("${private}/dynamic_color_plugin.cpp.in" "${private}/dynamic_color_plugin.cpp" COPYONLY)
    file(READ "${private}/dynamic_color_plugin.cpp" candidate_content)
    string(REPLACE "\r\n" "\n" candidate_content "${candidate_content}")
    string(SHA256 candidate_hash "${candidate_content}")
    if(NOT candidate_hash STREQUAL "34e1b41be173ea1273bc379e453dd3b4238df5c7f19ae170d7caec149a76708b")
      message(FATAL_ERROR "dynamic_color/dynamic_color_plugin.cpp candidate LF-normalized bytes differ from reviewed transformation")
    endif()
  endif()
  if(plugin STREQUAL "screen_retriever_windows")
    file(SHA256 "${plugin_dir}/screen_retriever_windows_plugin.h" original_hash)
    if(NOT original_hash STREQUAL "d6daf6e166c580d76a356626f72e7fba627880f6554ed6e9c5e0a5620e353839")
      message(FATAL_ERROR "screen_retriever_windows/screen_retriever_windows_plugin.h changed; review strict Clang compatibility")
    endif()
    file(READ "${plugin_dir}/screen_retriever_windows_plugin.h" source)
    string(REPLACE "\r\n" "\n" source "${source}")
    sourin_plugin_compat_replace_exact(source [====[void ScreenRetrieverWindowsPlugin::]====] [====[void ]====] 3)
    file(WRITE "${private}/screen_retriever_windows_plugin.h.in" "${source}")
    configure_file("${private}/screen_retriever_windows_plugin.h.in" "${private}/screen_retriever_windows_plugin.h" COPYONLY)
    file(READ "${private}/screen_retriever_windows_plugin.h" candidate_content)
    string(REPLACE "\r\n" "\n" candidate_content "${candidate_content}")
    string(SHA256 candidate_hash "${candidate_content}")
    if(NOT candidate_hash STREQUAL "e8dafbb99481d182a121771c57759359009b987de13dedfa841a91ae58e99319")
      message(FATAL_ERROR "screen_retriever_windows/screen_retriever_windows_plugin.h candidate LF-normalized bytes differ from reviewed transformation")
    endif()
  endif()
  if(plugin STREQUAL "window_manager")
    file(SHA256 "${plugin_dir}/window_manager.cpp" original_hash)
    if(NOT original_hash STREQUAL "fe90a377f8d14b37f5643e7db4550ea0fb64a54d8f0a9751cb7ae10744860b53")
      message(FATAL_ERROR "window_manager/window_manager.cpp changed; review strict Clang compatibility")
    endif()
    file(READ "${plugin_dir}/window_manager.cpp" source)
    string(REPLACE "\r\n" "\n" source "${source}")
    sourin_plugin_compat_replace_exact(source [====[class WindowManager {
 public:
  WindowManager();

  virtual ~WindowManager();

  HWND native_window;

  int last_state = STATE_NORMAL;

  bool has_shadow_ = false;
  bool is_always_on_bottom_ = false;
  bool is_frameless_ = false;
  bool is_prevent_close_ = false;
  double aspect_ratio_ = 0;
  POINT minimum_size_ = {0, 0};
  POINT maximum_size_ = {-1, -1};
  double pixel_ratio_ = 1;
  bool is_resizable_ = true;
  int is_docked_ = 0;
  bool is_registered_for_docking_ = false;
  bool is_skip_taskbar_ = true;
  std::string title_bar_style_ = "normal";
  double opacity_ = 1;

  bool is_resizing_ = false;
  bool is_moving_ = false;

  HWND GetMainWindow();
  void WindowManager::ForceRefresh();
  void WindowManager::ForceChildRefresh();
  void WindowManager::SetAsFrameless();
  void WindowManager::WaitUntilReadyToShow();
  void WindowManager::Destroy();
  void WindowManager::Close();
  bool WindowManager::IsPreventClose();
  void WindowManager::SetPreventClose(const flutter::EncodableMap& args);
  void WindowManager::Focus();
  void WindowManager::Blur();
  bool WindowManager::IsFocused();
  void WindowManager::Show();
  void WindowManager::Hide();
  bool WindowManager::IsVisible();
  bool WindowManager::IsMaximized();
  void WindowManager::Maximize(const flutter::EncodableMap& args);
  void WindowManager::Unmaximize();
  bool WindowManager::IsMinimized();
  void WindowManager::Minimize();
  void WindowManager::Restore();
  bool WindowManager::IsDockable();
  int WindowManager::IsDocked();
  void WindowManager::Dock(const flutter::EncodableMap& args);
  bool WindowManager::Undock();
  bool WindowManager::IsFullScreen();
  void WindowManager::SetFullScreen(const flutter::EncodableMap& args);
  void WindowManager::SetAspectRatio(const flutter::EncodableMap& args);
  void WindowManager::SetBackgroundColor(const flutter::EncodableMap& args);
  flutter::EncodableMap WindowManager::GetBounds(
      const flutter::EncodableMap& args);
  void WindowManager::SetBounds(const flutter::EncodableMap& args);
  void WindowManager::SetMinimumSize(const flutter::EncodableMap& args);
  void WindowManager::SetMaximumSize(const flutter::EncodableMap& args);
  bool WindowManager::IsResizable();
  void WindowManager::SetResizable(const flutter::EncodableMap& args);
  bool WindowManager::IsMinimizable();
  void WindowManager::SetMinimizable(const flutter::EncodableMap& args);
  bool WindowManager::IsMaximizable();
  void WindowManager::SetMaximizable(const flutter::EncodableMap& args);
  bool WindowManager::IsClosable();
  void WindowManager::SetClosable(const flutter::EncodableMap& args);
  bool WindowManager::IsAlwaysOnTop();
  void WindowManager::SetAlwaysOnTop(const flutter::EncodableMap& args);
  bool WindowManager::IsAlwaysOnBottom();
  void WindowManager::SetAlwaysOnBottom(const flutter::EncodableMap& args);
  std::string WindowManager::GetTitle();
  void WindowManager::SetTitle(const flutter::EncodableMap& args);
  void WindowManager::SetTitleBarStyle(const flutter::EncodableMap& args);
  int WindowManager::GetTitleBarHeight();
  bool WindowManager::IsSkipTaskbar();
  void WindowManager::SetSkipTaskbar(const flutter::EncodableMap& args);
  void WindowManager::SetProgressBar(const flutter::EncodableMap& args);
  void WindowManager::SetIcon(const flutter::EncodableMap& args);
  bool WindowManager::HasShadow();
  void WindowManager::SetHasShadow(const flutter::EncodableMap& args);
  double WindowManager::GetOpacity();
  void WindowManager::SetOpacity(const flutter::EncodableMap& args);
  void WindowManager::SetBrightness(const flutter::EncodableMap& args);
  void WindowManager::SetIgnoreMouseEvents(const flutter::EncodableMap& args);
  void WindowManager::PopUpWindowMenu(const flutter::EncodableMap& args);
  void WindowManager::StartDragging();
  void WindowManager::StartResizing(const flutter::EncodableMap& args);

 private:
  static constexpr auto kFlutterViewWindowClassName = L"FLUTTERVIEW";
  bool g_is_window_fullscreen = false;
  std::string g_title_bar_style_before_fullscreen;
  RECT g_frame_before_fullscreen;
  bool g_maximized_before_fullscreen;
  LONG g_style_before_fullscreen;
  ITaskbarList3* taskbar_ = nullptr;
  double GetDpiForHwnd(HWND hWnd);
  BOOL WindowManager::RegisterAccessBar(HWND hwnd, BOOL fRegister);
  void PASCAL WindowManager::AppBarQuerySetPos(HWND hwnd,
                                               UINT uEdge,
                                               LPRECT lprc,
                                               PAPPBARDATA pabd);
  void WindowManager::DockAccessBar(HWND hwnd, UINT edge, UINT windowWidth);
};]====] [====[class WindowManager {
 public:
  WindowManager();

  virtual ~WindowManager();

  HWND native_window;

  int last_state = STATE_NORMAL;

  bool has_shadow_ = false;
  bool is_always_on_bottom_ = false;
  bool is_frameless_ = false;
  bool is_prevent_close_ = false;
  double aspect_ratio_ = 0;
  POINT minimum_size_ = {0, 0};
  POINT maximum_size_ = {-1, -1};
  double pixel_ratio_ = 1;
  bool is_resizable_ = true;
  int is_docked_ = 0;
  bool is_registered_for_docking_ = false;
  bool is_skip_taskbar_ = true;
  std::string title_bar_style_ = "normal";
  double opacity_ = 1;

  bool is_resizing_ = false;
  bool is_moving_ = false;

  HWND GetMainWindow();
  void ForceRefresh();
  void ForceChildRefresh();
  void SetAsFrameless();
  void WaitUntilReadyToShow();
  void Destroy();
  void Close();
  bool IsPreventClose();
  void SetPreventClose(const flutter::EncodableMap& args);
  void Focus();
  void Blur();
  bool IsFocused();
  void Show();
  void Hide();
  bool IsVisible();
  bool IsMaximized();
  void Maximize(const flutter::EncodableMap& args);
  void Unmaximize();
  bool IsMinimized();
  void Minimize();
  void Restore();
  bool IsDockable();
  int IsDocked();
  void Dock(const flutter::EncodableMap& args);
  bool Undock();
  bool IsFullScreen();
  void SetFullScreen(const flutter::EncodableMap& args);
  void SetAspectRatio(const flutter::EncodableMap& args);
  void SetBackgroundColor(const flutter::EncodableMap& args);
  flutter::EncodableMap GetBounds(
      const flutter::EncodableMap& args);
  void SetBounds(const flutter::EncodableMap& args);
  void SetMinimumSize(const flutter::EncodableMap& args);
  void SetMaximumSize(const flutter::EncodableMap& args);
  bool IsResizable();
  void SetResizable(const flutter::EncodableMap& args);
  bool IsMinimizable();
  void SetMinimizable(const flutter::EncodableMap& args);
  bool IsMaximizable();
  void SetMaximizable(const flutter::EncodableMap& args);
  bool IsClosable();
  void SetClosable(const flutter::EncodableMap& args);
  bool IsAlwaysOnTop();
  void SetAlwaysOnTop(const flutter::EncodableMap& args);
  bool IsAlwaysOnBottom();
  void SetAlwaysOnBottom(const flutter::EncodableMap& args);
  std::string GetTitle();
  void SetTitle(const flutter::EncodableMap& args);
  void SetTitleBarStyle(const flutter::EncodableMap& args);
  int GetTitleBarHeight();
  bool IsSkipTaskbar();
  void SetSkipTaskbar(const flutter::EncodableMap& args);
  void SetProgressBar(const flutter::EncodableMap& args);
  void SetIcon(const flutter::EncodableMap& args);
  bool HasShadow();
  void SetHasShadow(const flutter::EncodableMap& args);
  double GetOpacity();
  void SetOpacity(const flutter::EncodableMap& args);
  void SetBrightness(const flutter::EncodableMap& args);
  void SetIgnoreMouseEvents(const flutter::EncodableMap& args);
  void PopUpWindowMenu(const flutter::EncodableMap& args);
  void StartDragging();
  void StartResizing(const flutter::EncodableMap& args);

 private:
  static constexpr auto kFlutterViewWindowClassName = L"FLUTTERVIEW";
  bool g_is_window_fullscreen = false;
  std::string g_title_bar_style_before_fullscreen;
  RECT g_frame_before_fullscreen;
  bool g_maximized_before_fullscreen;
  LONG g_style_before_fullscreen;
  ITaskbarList3* taskbar_ = nullptr;
  double GetDpiForHwnd(HWND hWnd);
  BOOL RegisterAccessBar(HWND hwnd, BOOL fRegister);
  void PASCAL AppBarQuerySetPos(HWND hwnd,
                                               UINT uEdge,
                                               LPRECT lprc,
                                               PAPPBARDATA pabd);
  void DockAccessBar(HWND hwnd, UINT edge, UINT windowWidth);
};]====] 1)
    sourin_plugin_compat_replace_exact(source [====[#pragma once
]====] [====[]====] 1)
    set(prefix [====[#ifndef SOURIN_WINDOW_MANAGER_PRIVATE_IMPLEMENTATION_INCLUDED
#define SOURIN_WINDOW_MANAGER_PRIVATE_IMPLEMENTATION_INCLUDED

]====])
    set(suffix [====[

#endif  // SOURIN_WINDOW_MANAGER_PRIVATE_IMPLEMENTATION_INCLUDED
]====])
    set(source "${prefix}${source}${suffix}")
    sourin_plugin_compat_replace_exact(source [====[constexpr const wchar_t kWindowClassName[]]====] [====[[[maybe_unused]] constexpr const wchar_t kWindowClassName[]]====] 1)
    sourin_plugin_compat_replace_exact(source [====[} ACCENT_STATE;]====] [====[} ACCENT_STATE [[maybe_unused]];]====] 1)
    file(WRITE "${private}/window_manager.cpp.in" "${source}")
    configure_file("${private}/window_manager.cpp.in" "${private}/window_manager.cpp" COPYONLY)
    file(READ "${private}/window_manager.cpp" candidate_content)
    string(REPLACE "\r\n" "\n" candidate_content "${candidate_content}")
    string(SHA256 candidate_hash "${candidate_content}")
    if(NOT candidate_hash STREQUAL "07aabf85d461a6fdeb42cdb137a57fffde81d6b21fb4bab0aa3d6758f8ba61ef")
      message(FATAL_ERROR "window_manager/window_manager.cpp candidate LF-normalized bytes differ from reviewed transformation")
    endif()
  endif()
  if(plugin STREQUAL "window_manager")
    file(SHA256 "${plugin_dir}/window_manager_plugin.cpp" original_hash)
    if(NOT original_hash STREQUAL "6fa2dc3eea3543108957a142e273a4fc9faf101bae09444bcd9be4712d3238d0")
      message(FATAL_ERROR "window_manager/window_manager_plugin.cpp changed; review strict Clang compatibility")
    endif()
    file(READ "${plugin_dir}/window_manager_plugin.cpp" source)
    string(REPLACE "\r\n" "\n" source "${source}")
    sourin_plugin_compat_replace_exact(source [====[class WindowManagerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  WindowManagerPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~WindowManagerPlugin();

 private:
  std::unique_ptr<
      flutter::MethodChannel<flutter::EncodableValue>,
      std::default_delete<flutter::MethodChannel<flutter::EncodableValue>>>
      channel = nullptr;

  WindowManager* window_manager;
  flutter::PluginRegistrarWindows* registrar;

  // The ID of the WindowProc delegate registration.
  int window_proc_id = -1;

  void WindowManagerPlugin::_EmitEvent(std::string eventName);
  // Called for top-level WindowProc delegation.
  std::optional<LRESULT> WindowManagerPlugin::HandleWindowProc(HWND hWnd,
                                                               UINT message,
                                                               WPARAM wParam,
                                                               LPARAM lParam);
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void adjustNCCALCSIZE(HWND hwnd, NCCALCSIZE_PARAMS* sz) {
    LONG l = 8;
    LONG t = 8;

    // HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    // Don't use `MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)` above.
    // Because if the window is restored from minimized state, the window is not
    // in the correct monitor. The monitor is always the left-most monitor.
    // https://github.com/leanflutter/window_manager/issues/489
    HMONITOR monitor = MonitorFromRect(&sz->rgrc[0], MONITOR_DEFAULTTONEAREST);
    if (monitor != NULL) {
      MONITORINFO monitorInfo;
      monitorInfo.cbSize = sizeof(MONITORINFO);
      if (TRUE == GetMonitorInfo(monitor, &monitorInfo)) {
        l = sz->rgrc[0].left - monitorInfo.rcWork.left;
        t = sz->rgrc[0].top - monitorInfo.rcWork.top;
      } else {
        // GetMonitorInfo failed, use (8, 8) as default value
      }
    } else {
      // unreachable code
    }

    sz->rgrc[0].left -= l;
    sz->rgrc[0].top -= t;
    sz->rgrc[0].right += l;
    sz->rgrc[0].bottom += t;
  }
};]====] [====[class WindowManagerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  WindowManagerPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~WindowManagerPlugin();

 private:
  std::unique_ptr<
      flutter::MethodChannel<flutter::EncodableValue>,
      std::default_delete<flutter::MethodChannel<flutter::EncodableValue>>>
      channel = nullptr;

  WindowManager* window_manager;
  flutter::PluginRegistrarWindows* registrar;

  // The ID of the WindowProc delegate registration.
  int window_proc_id = -1;

  void _EmitEvent(std::string eventName);
  // Called for top-level WindowProc delegation.
  std::optional<LRESULT> HandleWindowProc(HWND hWnd,
                                                               UINT message,
                                                               WPARAM wParam,
                                                               LPARAM lParam);
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void adjustNCCALCSIZE(HWND hwnd, NCCALCSIZE_PARAMS* sz) {
    LONG l = 8;
    LONG t = 8;

    // HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    // Don't use `MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)` above.
    // Because if the window is restored from minimized state, the window is not
    // in the correct monitor. The monitor is always the left-most monitor.
    // https://github.com/leanflutter/window_manager/issues/489
    HMONITOR monitor = MonitorFromRect(&sz->rgrc[0], MONITOR_DEFAULTTONEAREST);
    if (monitor != NULL) {
      MONITORINFO monitorInfo;
      monitorInfo.cbSize = sizeof(MONITORINFO);
      if (TRUE == GetMonitorInfo(monitor, &monitorInfo)) {
        l = sz->rgrc[0].left - monitorInfo.rcWork.left;
        t = sz->rgrc[0].top - monitorInfo.rcWork.top;
      } else {
        // GetMonitorInfo failed, use (8, 8) as default value
      }
    } else {
      // unreachable code
    }

    sz->rgrc[0].left -= l;
    sz->rgrc[0].top -= t;
    sz->rgrc[0].right += l;
    sz->rgrc[0].bottom += t;
  }
};]====] 1)
    file(WRITE "${private}/window_manager_plugin.cpp.in" "${source}")
    configure_file("${private}/window_manager_plugin.cpp.in" "${private}/window_manager_plugin.cpp" COPYONLY)
    file(READ "${private}/window_manager_plugin.cpp" candidate_content)
    string(REPLACE "\r\n" "\n" candidate_content "${candidate_content}")
    string(SHA256 candidate_hash "${candidate_content}")
    if(NOT candidate_hash STREQUAL "1455699bded1159a8bc33483fb22dbe0a51fc410dfeb156dadb6bd168147c2b8")
      message(FATAL_ERROR "window_manager/window_manager_plugin.cpp candidate LF-normalized bytes differ from reviewed transformation")
    endif()
  endif()
  if(plugin STREQUAL "tray_manager")
    file(SHA256 "${plugin_dir}/tray_manager_plugin.cpp" original_hash)
    if(NOT original_hash STREQUAL "24e19d45827a6d9ded599d1f3c3a7a1d0acc2ef095daf8ae784378a974be4460")
      message(FATAL_ERROR "tray_manager/tray_manager_plugin.cpp changed; review compatibility")
    endif()
    file(READ "${plugin_dir}/tray_manager_plugin.cpp" source)
    string(REPLACE "\r\n" "\n" source "${source}")
    sourin_plugin_compat_replace_exact(source [====[class TrayManagerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  TrayManagerPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~TrayManagerPlugin();

 private:
  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> g_converter;

  flutter::PluginRegistrarWindows* registrar;
  NOTIFYICONDATA nid;
  NOTIFYICONIDENTIFIER niif;
  // do create pop-up menu only once.
  HMENU hMenu = CreatePopupMenu();
  bool tray_icon_setted = false;
  UINT windows_taskbar_created_message_id = 0;

  // The ID of the WindowProc delegate registration.
  int window_proc_id = -1;

  void TrayManagerPlugin::_CreateMenu(HMENU menu, flutter::EncodableMap args);
  void TrayManagerPlugin::_ApplyIcon();

  // Called for top-level WindowProc delegation.
  std::optional<LRESULT> TrayManagerPlugin::HandleWindowProc(HWND hwnd,
                                                             UINT message,
                                                             WPARAM wparam,
                                                             LPARAM lparam);
  HWND TrayManagerPlugin::GetMainWindow();
  void TrayManagerPlugin::Destroy(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetIcon(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetToolTip(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetContextMenu(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::PopUpContextMenu(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::GetBounds(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};]====] [====[class TrayManagerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  TrayManagerPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~TrayManagerPlugin();

 private:
  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> g_converter;

  flutter::PluginRegistrarWindows* registrar;
  NOTIFYICONDATA nid;
  NOTIFYICONIDENTIFIER niif;
  // do create pop-up menu only once.
  HMENU hMenu = CreatePopupMenu();
  bool tray_icon_setted = false;
  UINT windows_taskbar_created_message_id = 0;

  // The ID of the WindowProc delegate registration.
  int window_proc_id = -1;

  void _CreateMenu(HMENU menu, flutter::EncodableMap args);
  void _ApplyIcon();

  // Called for top-level WindowProc delegation.
  std::optional<LRESULT> HandleWindowProc(HWND hwnd,
                                                             UINT message,
                                                             WPARAM wparam,
                                                             LPARAM lparam);
  HWND GetMainWindow();
  void Destroy(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void SetIcon(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void SetToolTip(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void SetContextMenu(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void PopUpContextMenu(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void GetBounds(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};]====] 1)
    file(WRITE "${private}/tray_manager_plugin.cpp.in" "${source}")
    configure_file("${private}/tray_manager_plugin.cpp.in" "${private}/tray_manager_plugin.cpp" COPYONLY)
    file(READ "${private}/tray_manager_plugin.cpp" candidate_content)
    string(REPLACE "\r\n" "\n" candidate_content "${candidate_content}")
    string(SHA256 candidate_hash "${candidate_content}")
    if(NOT candidate_hash STREQUAL "4f83c53361e22e2439ec456c623864381e8eca9da36f383e380b18b063a3764c")
      message(FATAL_ERROR "tray_manager/tray_manager_plugin.cpp normalized candidate mismatch")
    endif()
  endif()
  if(plugin STREQUAL "volume_controller")
    file(SHA256 "${plugin_dir}/include/volume_controller/volume_callback.h" original_hash)
    if(NOT original_hash STREQUAL "0e91358f16802747e97deed10d88d3eb1a858097d6b46a2e19732e5f42d94bbf")
      message(FATAL_ERROR "volume_controller/include/volume_controller/volume_callback.h changed; review compatibility")
    endif()
    file(READ "${plugin_dir}/include/volume_controller/volume_callback.h" source)
    string(REPLACE "\r\n" "\n" source "${source}")
    sourin_plugin_compat_replace_exact(source [====[class VolumeCallback : public IAudioEndpointVolumeCallback]====] [====[class VolumeCallback final : public IAudioEndpointVolumeCallback]====] 1)
    file(WRITE "${private}/include/volume_controller/volume_callback.h.in" "${source}")
    configure_file("${private}/include/volume_controller/volume_callback.h.in" "${private}/include/volume_controller/volume_callback.h" COPYONLY)
    file(READ "${private}/include/volume_controller/volume_callback.h" candidate_content)
    string(REPLACE "\r\n" "\n" candidate_content "${candidate_content}")
    string(SHA256 candidate_hash "${candidate_content}")
    if(NOT candidate_hash STREQUAL "8aa4cbdc34e79d57ee42057b3e4fa741bbc5f6521e6f180e90a33f1f1b3bfbe8")
      message(FATAL_ERROR "volume_controller/include/volume_controller/volume_callback.h normalized candidate mismatch")
    endif()
  endif()
  if(plugin STREQUAL "volume_controller")
    file(SHA256 "${plugin_dir}/include/volume_controller/volume_controller.cpp" original_hash)
    if(NOT original_hash STREQUAL "c7b5beccded9fb0b8d6229837c479e80e94931a2953603c5223df134479d5340")
      message(FATAL_ERROR "volume_controller/include/volume_controller/volume_controller.cpp changed; review compatibility")
    endif()
    file(READ "${plugin_dir}/include/volume_controller/volume_controller.cpp" source)
    string(REPLACE "\r\n" "\n" source "${source}")
    sourin_plugin_compat_replace_exact(source [====[class DeviceNotificationClient : public IMMNotificationClient]====] [====[class DeviceNotificationClient final : public IMMNotificationClient]====] 1)
    file(WRITE "${private}/include/volume_controller/volume_controller.cpp.in" "${source}")
    configure_file("${private}/include/volume_controller/volume_controller.cpp.in" "${private}/include/volume_controller/volume_controller.cpp" COPYONLY)
    file(READ "${private}/include/volume_controller/volume_controller.cpp" candidate_content)
    string(REPLACE "\r\n" "\n" candidate_content "${candidate_content}")
    string(SHA256 candidate_hash "${candidate_content}")
    if(NOT candidate_hash STREQUAL "70c521fa297bda29633889f2d47fb7b5b99249f13e32f8c8a120f290c523a36b")
      message(FATAL_ERROR "volume_controller/include/volume_controller/volume_controller.cpp normalized candidate mismatch")
    endif()
  endif()
  set(updated)
  foreach(item IN LISTS sources)
    if(item MATCHES "^\\$<")
      message(FATAL_ERROR "Plugin source expression requires explicit private-copy review")
    endif()
    get_filename_component(absolute "${item}" ABSOLUTE BASE_DIR "${plugin_dir}")
    file(RELATIVE_PATH relative "${plugin_dir}" "${absolute}")
    if(relative MATCHES "^\\.\\./" OR IS_ABSOLUTE "${relative}" OR NOT EXISTS "${private}/${relative}")
      message(FATAL_ERROR "Plugin source is outside complete private copy: ${item}")
    endif()
    list(APPEND updated "${private}/${relative}")
  endforeach()
  list(LENGTH sources before_count)
  list(LENGTH updated after_count)
  if(NOT before_count EQUAL after_count)
    message(FATAL_ERROR "Plugin source count changed during private mapping")
  endif()
  set_property(TARGET ${target} PROPERTY SOURCES "${updated}")
  foreach(property INCLUDE_DIRECTORIES INTERFACE_INCLUDE_DIRECTORIES)
    get_target_property(includes ${target} ${property})
    if(includes STREQUAL "includes-NOTFOUND")
      continue()
    endif()
    set(rebound)
    foreach(item IN LISTS includes)
      if(item MATCHES "^\\$<")
        message(FATAL_ERROR "Plugin include expression requires explicit private-copy review")
      endif()
      get_filename_component(absolute "${item}" ABSOLUTE BASE_DIR "${plugin_dir}")
      file(RELATIVE_PATH relative "${plugin_dir}" "${absolute}")
      if(NOT relative MATCHES "^\\.\\./" AND NOT IS_ABSOLUTE "${relative}")
        list(APPEND rebound "${private}/${relative}")
      else()
        list(APPEND rebound "${item}")
      endif()
    endforeach()
    set_property(TARGET ${target} PROPERTY ${property} "${rebound}")
  endforeach()
endfunction()

sourin_plugin_compat_prepare(dynamic_color dynamic_color_plugin)
sourin_plugin_compat_prepare(screen_retriever_windows screen_retriever_windows_plugin)
sourin_plugin_compat_prepare(window_manager window_manager_plugin)

sourin_plugin_compat_prepare(tray_manager tray_manager_plugin)
sourin_plugin_compat_prepare(volume_controller volume_controller_plugin)
