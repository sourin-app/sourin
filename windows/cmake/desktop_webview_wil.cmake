# desktop_webview_window 0.4.0 bundles MSVC-specific WIL declarations.
# Call after the shutdown fix so the private tree retains that corrected source.
# Generate two minimally corrected WIL headers from exact hash-pinned originals.
# No diagnostic flags are changed. Quoted includes resolve inside a private copy.
# Exact literal replacement with an explicit observed occurrence count.
# Arguments are variable names, so C++ semicolons remain one CMake value.
function(sourin_wil_replace_exact variable before_variable after_variable expected)
  set(value "${${variable}}")
  set(before "${${before_variable}}")
  set(after "${${after_variable}}")
  string(LENGTH "${before}" before_length)
  if(before_length EQUAL 0)
    message(FATAL_ERROR "desktop_webview WIL empty compatibility anchor")
  endif()
  set(tail "${value}")
  set(count 0)
  while(TRUE)
    string(FIND "${tail}" "${before}" position)
    if(position EQUAL -1)
      break()
    endif()
    math(EXPR count "${count} + 1")
    math(EXPR next "${position} + ${before_length}")
    string(SUBSTRING "${tail}" ${next} -1 tail)
  endwhile()
  if(NOT count EQUAL expected)
    message(FATAL_ERROR "desktop_webview WIL compatibility anchor count changed")
  endif()
  string(REPLACE "${before}" "${after}" value "${value}")
  set(${variable} "${value}" PARENT_SCOPE)
endfunction()

function(sourin_fix_desktop_webview_wil)
  if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    return()
  endif()
  set(plugin desktop_webview_window_plugin)
  get_target_property(plugin_dir ${plugin} SOURCE_DIR)
  get_target_property(sources ${plugin} SOURCES)
  get_filename_component(plugin_root "${plugin_dir}/.." ABSOLUTE)
  set(private_root "${CMAKE_CURRENT_BINARY_DIR}/sourin_plugin_fixes/desktop_webview_wil")
  set(shutdown "${CMAKE_CURRENT_BINARY_DIR}/sourin_plugin_fixes/web_view_window_plugin.cc")
  if(NOT EXISTS "${shutdown}")
    message(FATAL_ERROR "desktop_webview WIL overlay requires the generated shutdown correction first")
  endif()
  file(SHA256 "${plugin_dir}/wil/resource.h" resource_hash)
  file(SHA256 "${plugin_dir}/wil/result_macros.h" macros_hash)
  if(NOT resource_hash STREQUAL "4f22b3c4bc6e5013b285c936b045f3ef284822e41890eee224fa2298776b4be0"
      OR NOT macros_hash STREQUAL "f89d36590f9752e9d94bf63f4eb01f0f1aa0e753b4818065cea706072fa748e9")
    message(FATAL_ERROR "desktop_webview vendored WIL changed; review the private compatibility headers")
  endif()
  file(GLOB_RECURSE private_inputs CONFIGURE_DEPENDS LIST_DIRECTORIES FALSE
       "${plugin_dir}/*" "${plugin_root}/src/*")
  foreach(original IN LISTS private_inputs)
    file(RELATIVE_PATH relative "${plugin_root}" "${original}")
    if(relative MATCHES "^\\.\\./" OR IS_SYMLINK "${original}")
      message(FATAL_ERROR "desktop_webview private copy input escaped source root")
    endif()
    get_filename_component(parent "${private_root}/${relative}" DIRECTORY)
    file(MAKE_DIRECTORY "${parent}")
    configure_file("${original}" "${private_root}/${relative}" COPYONLY)
  endforeach()
  # Retain the separately reviewed production shutdown correction byte-for-byte.
  configure_file("${shutdown}" "${private_root}/windows/web_view_window_plugin.cc" COPYONLY)
  file(READ "${plugin_dir}/wil/resource.h" resource)
  string(REPLACE "\r\n" "\n" resource "${resource}")
  set(before [====[        template <typename pointer,                                           // The handle type
            typename close_fn_t,                                              // The handle close function type
            close_fn_t close_fn,                                              //      * and function pointer
            typename pointer_access = pointer_access_all,                     // all, noaddress or none to control pointer method access
            typename pointer_storage = pointer,                               // The type used to store the handle (usually the same as the handle itself)
            typename invalid_t = pointer,                                     // The invalid handle value type
            invalid_t invalid = invalid_t(),                                  //      * and its value (default ZERO value)
            typename pointer_invalid = wistd::nullptr_t>                      // nullptr_t if the invalid handle value is compatible with nullptr, otherwise pointer
            struct resource_policy
        {
            typedef pointer_storage pointer_storage;
            typedef pointer pointer;
            typedef pointer_invalid pointer_invalid;
            typedef pointer_access pointer_access;
]====])
  set(after [====[        template <typename pointer_type,                                           // The handle type
            typename close_fn_t,                                              // The handle close function type
            close_fn_t close_fn,                                              //      * and function pointer
            typename pointer_access_type = pointer_access_all,                     // all, noaddress or none to control pointer method access
            typename pointer_storage_type = pointer_type,                               // The type used to store the handle (usually the same as the handle itself)
            typename invalid_t = pointer_type,                                     // The invalid handle value type
            invalid_t invalid = invalid_t(),                                  //      * and its value (default ZERO value)
            typename pointer_invalid_type = wistd::nullptr_t>                      // nullptr_t if the invalid handle value is compatible with nullptr, otherwise pointer
            struct resource_policy
        {
            typedef pointer_storage_type pointer_storage;
            typedef pointer_type pointer;
            typedef pointer_invalid_type pointer_invalid;
            typedef pointer_access_type pointer_access;
]====])
  sourin_wil_replace_exact(resource before after 1)
  set(before [====[template <typename policy>
        class unique_storage
        {
        protected:
            typedef policy policy;]====])
  set(after [====[template <typename policy_type>
        class unique_storage
        {
        protected:
            typedef policy_type policy;]====])
  sourin_wil_replace_exact(resource before after 1)
  set(before [====[template <typename unique_t>
        class shared_storage
        {
        protected:
            typedef unique_t unique_t;]====])
  set(after [====[template <typename unique_type>
        class shared_storage
        {
        protected:
            typedef unique_type unique_t;]====])
  sourin_wil_replace_exact(resource before after 1)
  set(before [====[template <typename shared_t>
    class weak_any
    {
    public:
        typedef shared_t shared_t;]====])
  set(after [====[template <typename shared_type>
    class weak_any
    {
    public:
        typedef shared_type shared_t;]====])
  sourin_wil_replace_exact(resource before after 1)
  set(before [====[template <typename err_policy>
        event_watcher_t(unique_any_t<event_t<details::unique_storage<details::handle_resource_policy>, err_policy>> &&eventHandle,]====])
  set(after [====[template <typename event_error_policy>
        event_watcher_t(unique_any_t<event_t<details::unique_storage<details::handle_resource_policy>, event_error_policy>> &&eventHandle,]====])
  sourin_wil_replace_exact(resource before after 1)
  file(WRITE "${private_root}/windows/wil/resource.h.in" "${resource}")
  configure_file("${private_root}/windows/wil/resource.h.in" "${private_root}/windows/wil/resource.h" COPYONLY)
  file(READ "${plugin_dir}/wil/result_macros.h" macros)
  string(REPLACE "\r\n" "\n" macros "${macros}")
  set(before [====[static HRESULT volatile s_hrErrorLast = S_OK;]====])
  set(after [====[[[maybe_unused]] static HRESULT volatile s_hrErrorLast = S_OK;]====])
  sourin_wil_replace_exact(macros before after 4)
  file(WRITE "${private_root}/windows/wil/result_macros.h.in" "${macros}")
  configure_file("${private_root}/windows/wil/result_macros.h.in" "${private_root}/windows/wil/result_macros.h" COPYONLY)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
               "${plugin_dir}/wil/resource.h" "${plugin_dir}/wil/result_macros.h")
  # Preserve the original aggregate zero-initialization and supplied field values.
  file(SHA256 "${plugin_dir}/default_composer.cc" composer_hash)
  if(NOT composer_hash STREQUAL "3e4fe1f4f6379ae2350e2d7eea527093edd7158197e1a0a7172b40f7cbf50db0")
    message(FATAL_ERROR "desktop_webview default composer changed; review the Clang initialization fix")
  endif()
  file(READ "${plugin_dir}/default_composer.cc" composer)
  string(REPLACE "\r\n" "\n" composer "${composer}")
  set(before [====[  HIGHCONTRASTW contrast{sizeof(contrast)};]====])
  set(after [====[  HIGHCONTRASTW contrast{};
  contrast.cbSize = sizeof(contrast);]====])
  sourin_wil_replace_exact(composer before after 1)
  set(before [====[    RTL_OSVERSIONINFOW info{sizeof(info)};]====])
  set(after [====[    RTL_OSVERSIONINFOW info{};
    info.dwOSVersionInfoSize = sizeof(info);]====])
  sourin_wil_replace_exact(composer before after 1)
  set(before [====[  DTTOPTS options{sizeof(options)};]====])
  set(after [====[  DTTOPTS options{};
  options.dwSize = sizeof(options);]====])
  sourin_wil_replace_exact(composer before after 1)
  set(before [====[  NONCLIENTMETRICSW metrics{sizeof(metrics)};]====])
  set(after [====[  NONCLIENTMETRICSW metrics{};
  metrics.cbSize = sizeof(metrics);]====])
  sourin_wil_replace_exact(composer before after 1)
  set(before [====[  BP_PAINTPARAMS params{sizeof(params), BPPF_ERASE};]====])
  set(after [====[  BP_PAINTPARAMS params{};
  params.cbSize = sizeof(params);
  params.dwFlags = BPPF_ERASE;]====])
  sourin_wil_replace_exact(composer before after 1)
  set(before [====[  MSG msg{bar.window, message, 0, MAKELPARAM(point.x, point.y)};]====])
  set(after [====[  MSG msg{};
  msg.hwnd = bar.window;
  msg.message = message;
  msg.wParam = 0;
  msg.lParam = MAKELPARAM(point.x, point.y);]====])
  sourin_wil_replace_exact(composer before after 1)
  set(before [====[    TTTOOLINFOW tool{TTTOOLINFOW_V2_SIZE};]====])
  set(after [====[    TTTOOLINFOW tool{};
    tool.cbSize = static_cast<UINT>(TTTOOLINFOW_V2_SIZE);]====])
  sourin_wil_replace_exact(composer before after 2)
  set(before [====[        TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, window};]====])
  set(after [====[        TRACKMOUSEEVENT track{};
        track.cbSize = sizeof(track);
        track.dwFlags = TME_LEAVE;
        track.hwndTrack = window;]====])
  sourin_wil_replace_exact(composer before after 1)
  set(before [====[        TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE | TME_NONCLIENT, window};]====])
  set(after [====[        TRACKMOUSEEVENT track{};
        track.cbSize = sizeof(track);
        track.dwFlags = TME_LEAVE | TME_NONCLIENT;
        track.hwndTrack = window;]====])
  sourin_wil_replace_exact(composer before after 1)
  file(WRITE "${private_root}/windows/default_composer.cc.in" "${composer}")
  configure_file("${private_root}/windows/default_composer.cc.in" "${private_root}/windows/default_composer.cc" COPYONLY)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${plugin_dir}/default_composer.cc")

  # COM providers release their own exact concrete type; they have no subclasses.
  # Mark them final without changing COM vtables or adding a virtual destructor.
  file(SHA256 "${plugin_dir}/title_bar_accessibility.cc" accessibility_hash)
  if(NOT accessibility_hash STREQUAL "46bfb738876d2849f9c096ae4d98389c0acabac9d428d480ba9972bae9597b52")
    message(FATAL_ERROR "desktop_webview accessibility providers changed; review the final types")
  endif()
  file(READ "${plugin_dir}/title_bar_accessibility.cc" accessibility)
  string(REPLACE "\r\n" "\n" accessibility "${accessibility}")
  set(before "class Button : public IRawElementProviderSimple,")
  set(after "class Button final : public IRawElementProviderSimple,")
  sourin_wil_replace_exact(accessibility before after 1)
  set(before "class Root : public IRawElementProviderSimple,")
  set(after "class Root final : public IRawElementProviderSimple,")
  sourin_wil_replace_exact(accessibility before after 1)
  file(WRITE "${private_root}/windows/title_bar_accessibility.cc.in" "${accessibility}")
  configure_file("${private_root}/windows/title_bar_accessibility.cc.in"
                 "${private_root}/windows/title_bar_accessibility.cc" COPYONLY)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
               "${plugin_dir}/title_bar_accessibility.cc")

  set(updated)
  set(shutdown_count 0)
  foreach(item IN LISTS sources)
    if(item MATCHES "^\\$<")
      message(FATAL_ERROR "desktop_webview source expression requires explicit overlay review")
    endif()
    get_filename_component(absolute "${item}" ABSOLUTE BASE_DIR "${plugin_dir}")
    if(absolute STREQUAL shutdown)
      list(APPEND updated "${private_root}/windows/web_view_window_plugin.cc")
      math(EXPR shutdown_count "${shutdown_count} + 1")
    else()
      file(RELATIVE_PATH relative "${plugin_root}" "${absolute}")
      if(relative MATCHES "^\\.\\./" OR IS_ABSOLUTE "${relative}"
          OR NOT EXISTS "${private_root}/${relative}")
        message(FATAL_ERROR "desktop_webview source is outside the complete private overlay")
      endif()
      list(APPEND updated "${private_root}/${relative}")
    endif()
  endforeach()
  if(NOT shutdown_count EQUAL 1)
    message(FATAL_ERROR "desktop_webview shutdown source ownership changed")
  endif()
  set_property(TARGET ${plugin} PROPERTY SOURCES "${updated}")
  # Rebind all target-owned direct/public include paths under this plugin. The
  # other Flutter/WebView dependency includes remain as resolved by their targets.
  foreach(property INCLUDE_DIRECTORIES INTERFACE_INCLUDE_DIRECTORIES)
    get_target_property(includes ${plugin} ${property})
    set(rebound)
    foreach(item IN LISTS includes)
      if(item MATCHES "^\\$<")
        list(APPEND rebound "${item}")
      else()
        get_filename_component(absolute "${item}" ABSOLUTE BASE_DIR "${plugin_dir}")
        file(RELATIVE_PATH relative "${plugin_root}" "${absolute}")
        if(NOT relative MATCHES "^\\.\\./" AND NOT IS_ABSOLUTE "${relative}")
          list(APPEND rebound "${private_root}/${relative}")
        else()
          list(APPEND rebound "${item}")
        endif()
      endif()
    endforeach()
    set_property(TARGET ${plugin} PROPERTY ${property} "${rebound}")
  endforeach()
endfunction()

sourin_fix_desktop_webview_wil()
