# Clang-specific private sources; preserve every original plugin source and shutdown fix.
if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  return()
endif()
include("${CMAKE_CURRENT_LIST_DIR}/inappwebview_clang_core.cmake")
set(SOURIN_INAPP_SDK_SCRIPT "${CMAKE_CURRENT_LIST_DIR}/inappwebview_clang_sdk.cmake")

function(sourin_inapp_copy_tree origin destination)
  file(GLOB_RECURSE inputs CONFIGURE_DEPENDS LIST_DIRECTORIES FALSE "${origin}/*")
  foreach(input IN LISTS inputs)
    file(RELATIVE_PATH relative "${origin}" "${input}")
    if(relative MATCHES "^\\.\\./" OR IS_ABSOLUTE "${relative}" OR IS_SYMLINK "${input}")
      message(FATAL_ERROR "InAppWebView private input escaped its source tree")
    endif()
    get_filename_component(parent "${destination}/${relative}" DIRECTORY)
    file(MAKE_DIRECTORY "${parent}")
    configure_file("${input}" "${destination}/${relative}" COPYONLY)
  endforeach()
endfunction()

function(sourin_fix_inappwebview_clang)
  set(plugin flutter_inappwebview_windows_plugin)
  get_target_property(plugin_dir ${plugin} SOURCE_DIR)
  get_target_property(sources ${plugin} SOURCES)
  set(private "${CMAKE_CURRENT_BINARY_DIR}/sourin_plugin_fixes/inappwebview_clang/windows")
  set(sdk "${CMAKE_CURRENT_BINARY_DIR}/packages/Microsoft.Web.WebView2/build/native/include")
  set(private_sdk "${CMAKE_CURRENT_BINARY_DIR}/sourin_plugin_fixes/inappwebview_clang/webview2")
  set(shutdown "${CMAKE_CURRENT_BINARY_DIR}/sourin_plugin_fixes/in_app_webview_manager.cpp")
  if(NOT EXISTS "${shutdown}")
    message(FATAL_ERROR "InAppWebView private compatibility requires shutdown preparation")
  endif()
  set(download flutter_inappwebview_windows_DEPENDENCIES_DOWNLOAD)
  if(NOT TARGET ${download})
    message(FATAL_ERROR "InAppWebView NuGet dependency target changed")
  endif()
  sourin_inapp_copy_tree("${plugin_dir}" "${private}")
  file(MAKE_DIRECTORY "${private_sdk}")
  configure_file("${shutdown}" "${private}/in_app_webview/in_app_webview_manager.cpp" COPYONLY)
  sourin_apply_inapp_core_compatibility(${plugin} "${private}")
  # Normal clean builds automatically restore through the existing target first.
  # Re-running this target checks input hashes and only changes differing outputs.
  add_custom_target(sourin_inappwebview_clang_sdk
    COMMAND "${CMAKE_COMMAND}"
      "-DSOURIN_SDK_BUILD_ROOT=${CMAKE_CURRENT_BINARY_DIR}"
      "-DSOURIN_SDK_ORIGIN=${sdk}"
      "-DSOURIN_SDK_DESTINATION=${private_sdk}"
      -P "${SOURIN_INAPP_SDK_SCRIPT}"
    BYPRODUCTS "${private_sdk}/WebView2.h" "${private_sdk}/WebView2.h.in"
      "${private_sdk}/WebView2EnvironmentOptions.h" "${private_sdk}/WebView2EnvironmentOptions.h.in"
      "${private_sdk}/generation-receipt.json" "${private_sdk}/generation-receipt.json.in"
    COMMENT "Preparing reviewed private InAppWebView SDK headers"
    VERBATIM)
  add_dependencies(sourin_inappwebview_clang_sdk ${download})
  add_dependencies(${plugin} sourin_inappwebview_clang_sdk)
  file(SHA256 "${plugin_dir}/cookie_manager.cpp" original_hash)
  if(NOT original_hash STREQUAL "37be59b0be89d325bb306a91246af4cc3befb5627fdb2fe70f527ab32135e075")
    message(FATAL_ERROR "InAppWebView cookie_manager.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/cookie_manager.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[jsonCookie["sameSite"].get<std::string>() : make_fl_value()]====] [====[flutter::EncodableValue(jsonCookie["sameSite"].get<std::string>()) : make_fl_value()]====] 2)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
                {"name", cookieName},
                {"value", jsonCookie["value"].get<std::string>()},
                {"domain", jsonCookie["domain"].get<std::string>()},
                {"path", jsonCookie["path"].get<std::string>()},
                {"expiresDate", jsonCookie["expires"].get<int64_t>()},
                {"isHttpOnly", jsonCookie["httpOnly"].get<bool>()},
                {"isSecure", jsonCookie["secure"].get<bool>()},
                {"isSessionOnly", jsonCookie["session"].get<bool>()},
                {"sameSite", jsonCookie.contains("sameSite") ? flutter::EncodableValue(jsonCookie["sameSite"].get<std::string>()) : make_fl_value()}
                }]====] [====[flutter::EncodableMap{
                {flutter::EncodableValue("name"), flutter::EncodableValue(cookieName)},
                {flutter::EncodableValue("value"), flutter::EncodableValue(jsonCookie["value"].get<std::string>())},
                {flutter::EncodableValue("domain"), flutter::EncodableValue(jsonCookie["domain"].get<std::string>())},
                {flutter::EncodableValue("path"), flutter::EncodableValue(jsonCookie["path"].get<std::string>())},
                {flutter::EncodableValue("expiresDate"), flutter::EncodableValue(jsonCookie["expires"].get<int64_t>())},
                {flutter::EncodableValue("isHttpOnly"), flutter::EncodableValue(jsonCookie["httpOnly"].get<bool>())},
                {flutter::EncodableValue("isSecure"), flutter::EncodableValue(jsonCookie["secure"].get<bool>())},
                {flutter::EncodableValue("isSessionOnly"), flutter::EncodableValue(jsonCookie["session"].get<bool>())},
                {flutter::EncodableValue("sameSite"), jsonCookie.contains("sameSite") ? flutter::EncodableValue(jsonCookie["sameSite"].get<std::string>()) : make_fl_value()}
                }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
              {"name", jsonCookie["name"].get<std::string>()},
              {"value", jsonCookie["value"].get<std::string>()},
              {"domain", jsonCookie["domain"].get<std::string>()},
              {"path", jsonCookie["path"].get<std::string>()},
              {"expiresDate", jsonCookie["expires"].get<int64_t>()},
              {"isHttpOnly", jsonCookie["httpOnly"].get<bool>()},
              {"isSecure", jsonCookie["secure"].get<bool>()},
              {"isSessionOnly", jsonCookie["session"].get<bool>()},
              {"sameSite", jsonCookie.contains("sameSite") ? flutter::EncodableValue(jsonCookie["sameSite"].get<std::string>()) : make_fl_value()}
              }]====] [====[flutter::EncodableMap{
              {flutter::EncodableValue("name"), flutter::EncodableValue(jsonCookie["name"].get<std::string>())},
              {flutter::EncodableValue("value"), flutter::EncodableValue(jsonCookie["value"].get<std::string>())},
              {flutter::EncodableValue("domain"), flutter::EncodableValue(jsonCookie["domain"].get<std::string>())},
              {flutter::EncodableValue("path"), flutter::EncodableValue(jsonCookie["path"].get<std::string>())},
              {flutter::EncodableValue("expiresDate"), flutter::EncodableValue(jsonCookie["expires"].get<int64_t>())},
              {flutter::EncodableValue("isHttpOnly"), flutter::EncodableValue(jsonCookie["httpOnly"].get<bool>())},
              {flutter::EncodableValue("isSecure"), flutter::EncodableValue(jsonCookie["secure"].get<bool>())},
              {flutter::EncodableValue("isSessionOnly"), flutter::EncodableValue(jsonCookie["session"].get<bool>())},
              {flutter::EncodableValue("sameSite"), jsonCookie.contains("sameSite") ? flutter::EncodableValue(jsonCookie["sameSite"].get<std::string>()) : make_fl_value()}
              }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[->Success(created)]====] [====[->Success(flutter::EncodableValue(created))]====] 1)
  sourin_plugin_compat_replace_exact(source [====[->Success(cookies)]====] [====[->Success(flutter::EncodableValue(cookies))]====] 1)
  sourin_plugin_compat_replace_exact(source [====[->Success(deleted)]====] [====[->Success(flutter::EncodableValue(deleted))]====] 3)
  sourin_plugin_compat_replace_exact(source [====[completionHandler(flutter::EncodableMap{
                {flutter::EncodableValue("name"), flutter::EncodableValue(cookieName)},
                {flutter::EncodableValue("value"), flutter::EncodableValue(jsonCookie["value"].get<std::string>())},
                {flutter::EncodableValue("domain"), flutter::EncodableValue(jsonCookie["domain"].get<std::string>())},
                {flutter::EncodableValue("path"), flutter::EncodableValue(jsonCookie["path"].get<std::string>())},
                {flutter::EncodableValue("expiresDate"), flutter::EncodableValue(jsonCookie["expires"].get<int64_t>())},
                {flutter::EncodableValue("isHttpOnly"), flutter::EncodableValue(jsonCookie["httpOnly"].get<bool>())},
                {flutter::EncodableValue("isSecure"), flutter::EncodableValue(jsonCookie["secure"].get<bool>())},
                {flutter::EncodableValue("isSessionOnly"), flutter::EncodableValue(jsonCookie["session"].get<bool>())},
                {flutter::EncodableValue("sameSite"), jsonCookie.contains("sameSite") ? flutter::EncodableValue(jsonCookie["sameSite"].get<std::string>()) : make_fl_value()}
                })]====] [====[completionHandler(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("name"), flutter::EncodableValue(cookieName)},
                {flutter::EncodableValue("value"), flutter::EncodableValue(jsonCookie["value"].get<std::string>())},
                {flutter::EncodableValue("domain"), flutter::EncodableValue(jsonCookie["domain"].get<std::string>())},
                {flutter::EncodableValue("path"), flutter::EncodableValue(jsonCookie["path"].get<std::string>())},
                {flutter::EncodableValue("expiresDate"), flutter::EncodableValue(jsonCookie["expires"].get<int64_t>())},
                {flutter::EncodableValue("isHttpOnly"), flutter::EncodableValue(jsonCookie["httpOnly"].get<bool>())},
                {flutter::EncodableValue("isSecure"), flutter::EncodableValue(jsonCookie["secure"].get<bool>())},
                {flutter::EncodableValue("isSessionOnly"), flutter::EncodableValue(jsonCookie["session"].get<bool>())},
                {flutter::EncodableValue("sameSite"), jsonCookie.contains("sameSite") ? flutter::EncodableValue(jsonCookie["sameSite"].get<std::string>()) : make_fl_value()}
                }))]====] 1)
  sourin_plugin_compat_replace_exact(source [====[cookies.push_back(flutter::EncodableMap{
              {flutter::EncodableValue("name"), flutter::EncodableValue(jsonCookie["name"].get<std::string>())},
              {flutter::EncodableValue("value"), flutter::EncodableValue(jsonCookie["value"].get<std::string>())},
              {flutter::EncodableValue("domain"), flutter::EncodableValue(jsonCookie["domain"].get<std::string>())},
              {flutter::EncodableValue("path"), flutter::EncodableValue(jsonCookie["path"].get<std::string>())},
              {flutter::EncodableValue("expiresDate"), flutter::EncodableValue(jsonCookie["expires"].get<int64_t>())},
              {flutter::EncodableValue("isHttpOnly"), flutter::EncodableValue(jsonCookie["httpOnly"].get<bool>())},
              {flutter::EncodableValue("isSecure"), flutter::EncodableValue(jsonCookie["secure"].get<bool>())},
              {flutter::EncodableValue("isSessionOnly"), flutter::EncodableValue(jsonCookie["session"].get<bool>())},
              {flutter::EncodableValue("sameSite"), jsonCookie.contains("sameSite") ? flutter::EncodableValue(jsonCookie["sameSite"].get<std::string>()) : make_fl_value()}
              })]====] [====[cookies.push_back(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("name"), flutter::EncodableValue(jsonCookie["name"].get<std::string>())},
              {flutter::EncodableValue("value"), flutter::EncodableValue(jsonCookie["value"].get<std::string>())},
              {flutter::EncodableValue("domain"), flutter::EncodableValue(jsonCookie["domain"].get<std::string>())},
              {flutter::EncodableValue("path"), flutter::EncodableValue(jsonCookie["path"].get<std::string>())},
              {flutter::EncodableValue("expiresDate"), flutter::EncodableValue(jsonCookie["expires"].get<int64_t>())},
              {flutter::EncodableValue("isHttpOnly"), flutter::EncodableValue(jsonCookie["httpOnly"].get<bool>())},
              {flutter::EncodableValue("isSecure"), flutter::EncodableValue(jsonCookie["secure"].get<bool>())},
              {flutter::EncodableValue("isSessionOnly"), flutter::EncodableValue(jsonCookie["session"].get<bool>())},
              {flutter::EncodableValue("sameSite"), jsonCookie.contains("sameSite") ? flutter::EncodableValue(jsonCookie["sameSite"].get<std::string>()) : make_fl_value()}
              }))]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "36e3ba792e3956ffe83645cf3c737b3d2ad896c5e293258c45a7bbbe74d8fda7")
    message(FATAL_ERROR "InAppWebView cookie_manager.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/cookie_manager.cpp.in" "${source}")
  configure_file("${private}/cookie_manager.cpp.in" "${private}/cookie_manager.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/custom_platform_view/custom_platform_view.cc" original_hash)
  if(NOT original_hash STREQUAL "b54fd686fb213cf2bd0817dfb27fbaf36c451c00f149d5e55a17a16c6adcf086")
    message(FATAL_ERROR "InAppWebView custom_platform_view/custom_platform_view.cc changed; review explicit value conversions")
  endif()
  file(READ "${private}/custom_platform_view/custom_platform_view.cc" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap { {
              flutter::EncodableValue(kEventType),
                flutter::EncodableValue("cursorChanged")
            },
          { flutter::EncodableValue(kEventValue), name }}]====] [====[flutter::EncodableMap { {
              flutter::EncodableValue(kEventType),
                flutter::EncodableValue("cursorChanged")
            },
          { flutter::EncodableValue(kEventValue), flutter::EncodableValue(name) }}]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "9686c24ae7f575503cf13e69727dfdd4e296de986db1e26115bdef645b4d3d76")
    message(FATAL_ERROR "InAppWebView custom_platform_view/custom_platform_view.cc normalized candidate differs")
  endif()
  file(WRITE "${private}/custom_platform_view/custom_platform_view.cc.in" "${source}")
  configure_file("${private}/custom_platform_view/custom_platform_view.cc.in" "${private}/custom_platform_view/custom_platform_view.cc" COPYONLY)
  file(SHA256 "${plugin_dir}/headless_in_app_webview/headless_in_app_webview_manager.cpp" original_hash)
  if(NOT original_hash STREQUAL "ea4349deddf3e98b11ba5d6d3d9f7d67eca9d1940f225b9c6deb2576321497a6")
    message(FATAL_ERROR "InAppWebView headless_in_app_webview/headless_in_app_webview_manager.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/headless_in_app_webview/headless_in_app_webview_manager.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[->Success(true)]====] [====[->Success(flutter::EncodableValue(true))]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "c7eb9cf22484ba8d4a1eb3bf55c13fbf4a6ef3adb1f180bbcb986631d2a5f763")
    message(FATAL_ERROR "InAppWebView headless_in_app_webview/headless_in_app_webview_manager.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/headless_in_app_webview/headless_in_app_webview_manager.cpp.in" "${source}")
  configure_file("${private}/headless_in_app_webview/headless_in_app_webview_manager.cpp.in" "${private}/headless_in_app_webview/headless_in_app_webview_manager.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/in_app_browser/in_app_browser.cpp" original_hash)
  if(NOT original_hash STREQUAL "b89c6d6d39de971d56ca3e8fa4eef59b843ea3463cea6b7099f7f4bc5fc2e310")
    message(FATAL_ERROR "InAppWebView in_app_browser/in_app_browser.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/in_app_browser/in_app_browser.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[return encodableMap;]====] [====[return flutter::EncodableValue(encodableMap);]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "7ca95a566ef1e90084b04186ea92b30c9f1649991416661fe1c69ecab5a78b52")
    message(FATAL_ERROR "InAppWebView in_app_browser/in_app_browser.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/in_app_browser/in_app_browser.cpp.in" "${source}")
  configure_file("${private}/in_app_browser/in_app_browser.cpp.in" "${private}/in_app_browser/in_app_browser.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/in_app_browser/in_app_browser_manager.cpp" original_hash)
  if(NOT original_hash STREQUAL "fd48e78a6b9e9e517921302e65f633783b210eb283de35f281e945efad7e6274")
    message(FATAL_ERROR "InAppWebView in_app_browser/in_app_browser_manager.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/in_app_browser/in_app_browser_manager.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[->Success(true)]====] [====[->Success(flutter::EncodableValue(true))]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "a7f320357b5e9f2f4a6d3682dfe807c80b55cc49f3de3a286d6196ddcee0134d")
    message(FATAL_ERROR "InAppWebView in_app_browser/in_app_browser_manager.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/in_app_browser/in_app_browser_manager.cpp.in" "${source}")
  configure_file("${private}/in_app_browser/in_app_browser_manager.cpp.in" "${private}/in_app_browser/in_app_browser_manager.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/in_app_browser/in_app_browser_settings.cpp" original_hash)
  if(NOT original_hash STREQUAL "ae4e9723e9c8d25bed6cf79f9e8dd07b1bb35124cc56d3455a1ab72b53424dc0")
    message(FATAL_ERROR "InAppWebView in_app_browser/in_app_browser_settings.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/in_app_browser/in_app_browser_settings.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[windowFrame->toEncodableMap() : make_fl_value()]====] [====[flutter::EncodableValue(windowFrame->toEncodableMap()) : make_fl_value()]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"hidden", hidden},
      {"windowType", inAppBrowserWindowTypeToString(windowType)},
      {"toolbarTopFixedTitle", toolbarTopFixedTitle},
      {"windowAlphaValue", windowAlphaValue},
      {"windowFrame", windowFrame ? flutter::EncodableValue(windowFrame->toEncodableMap()) : make_fl_value()},
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("hidden"), flutter::EncodableValue(hidden)},
      {flutter::EncodableValue("windowType"), flutter::EncodableValue(inAppBrowserWindowTypeToString(windowType))},
      {flutter::EncodableValue("toolbarTopFixedTitle"), flutter::EncodableValue(toolbarTopFixedTitle)},
      {flutter::EncodableValue("windowAlphaValue"), flutter::EncodableValue(windowAlphaValue)},
      {flutter::EncodableValue("windowFrame"), windowFrame ? flutter::EncodableValue(windowFrame->toEncodableMap()) : make_fl_value()},
    }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[settingsMap["hidden"] = inAppBrowser->isHidden();]====] [====[settingsMap[flutter::EncodableValue("hidden")] = flutter::EncodableValue(inAppBrowser->isHidden());]====] 1)
  sourin_plugin_compat_replace_exact(source [====[settingsMap["windowAlphaValue"] = (double)alphaValue;]====] [====[settingsMap[flutter::EncodableValue("windowAlphaValue")] = flutter::EncodableValue((double)alphaValue);]====] 1)
  sourin_plugin_compat_replace_exact(source [====[settingsMap["windowFrame"] = std::make_unique<Rect>(position.left, position.top, position.right - position.left, position.bottom - position.top)->toEncodableMap();]====] [====[settingsMap[flutter::EncodableValue("windowFrame")] = flutter::EncodableValue(std::make_unique<Rect>(position.left, position.top, position.right - position.left, position.bottom - position.top)->toEncodableMap());]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "6dcdeb7b3859b905f90e4097f47f515588a2383122c6ba68d762196ce13b9580")
    message(FATAL_ERROR "InAppWebView in_app_browser/in_app_browser_settings.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/in_app_browser/in_app_browser_settings.cpp.in" "${source}")
  configure_file("${private}/in_app_browser/in_app_browser_settings.cpp.in" "${private}/in_app_browser/in_app_browser_settings.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/in_app_webview/in_app_webview.cpp" original_hash)
  if(NOT original_hash STREQUAL "4cb00551207fc4f3b5f9642c2c6a79c50f89c86b2c859129c99c12d524ddeb18")
    message(FATAL_ERROR "InAppWebView in_app_webview/in_app_webview.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/in_app_webview/in_app_webview.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[return settings->getRealSettings(this);]====] [====[return flutter::EncodableValue(settings->getRealSettings(this));]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "bd0b3686e2e8e098a6c6ecfcb272edc502027e7723071f5a8dd4f97d2adc2a3e")
    message(FATAL_ERROR "InAppWebView in_app_webview/in_app_webview.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/in_app_webview/in_app_webview.cpp.in" "${source}")
  configure_file("${private}/in_app_webview/in_app_webview.cpp.in" "${private}/in_app_webview/in_app_webview.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/in_app_webview/in_app_webview_manager.cpp" original_hash)
  if(NOT original_hash STREQUAL "eefc7b984c208696b3a3a34f99b0ddc11779fb7470009ebbabcfd274421d77ab")
    message(FATAL_ERROR "InAppWebView in_app_webview/in_app_webview_manager.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/in_app_webview/in_app_webview_manager.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  string(SHA256 shutdown_hash "${source}")
  if(NOT shutdown_hash STREQUAL "d6d5b7366a03ab2897973aadcdb204f559d5ff8342ea38d589e7e7f2308a6470")
    message(FATAL_ERROR "InAppWebView shutdown copy changed; review compatibility composition")
  endif()
  sourin_plugin_compat_replace_exact(source [====[->Success(textureId)]====] [====[->Success(flutter::EncodableValue(textureId))]====] 2)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "b89a57419db8976699a9f70f868799b91a73a79a667452b2ec7d26c137efda9a")
    message(FATAL_ERROR "InAppWebView in_app_webview/in_app_webview_manager.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/in_app_webview/in_app_webview_manager.cpp.in" "${source}")
  configure_file("${private}/in_app_webview/in_app_webview_manager.cpp.in" "${private}/in_app_webview/in_app_webview_manager.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/in_app_webview/in_app_webview_settings.cpp" original_hash)
  if(NOT original_hash STREQUAL "0855ff0ebce4f3a4d446bcf226a37bc40da33d16f0eb2e58651ba17d4055878b")
    message(FATAL_ERROR "InAppWebView in_app_webview/in_app_webview_settings.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/in_app_webview/in_app_webview_settings.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"useShouldOverrideUrlLoading", useShouldOverrideUrlLoading},
      {"useOnLoadResource", useOnLoadResource},
      {"useOnDownloadStart", useOnDownloadStart},
      {"useShouldInterceptRequest", useShouldInterceptRequest},
      {"userAgent", userAgent},
      {"javaScriptEnabled", javaScriptEnabled},
      {"transparentBackground", transparentBackground},
      {"supportZoom", supportZoom},
      {"isInspectable", isInspectable},
      {"disableContextMenu", disableContextMenu},
      {"incognito", incognito},
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("useShouldOverrideUrlLoading"), flutter::EncodableValue(useShouldOverrideUrlLoading)},
      {flutter::EncodableValue("useOnLoadResource"), flutter::EncodableValue(useOnLoadResource)},
      {flutter::EncodableValue("useOnDownloadStart"), flutter::EncodableValue(useOnDownloadStart)},
      {flutter::EncodableValue("useShouldInterceptRequest"), flutter::EncodableValue(useShouldInterceptRequest)},
      {flutter::EncodableValue("userAgent"), flutter::EncodableValue(userAgent)},
      {flutter::EncodableValue("javaScriptEnabled"), flutter::EncodableValue(javaScriptEnabled)},
      {flutter::EncodableValue("transparentBackground"), flutter::EncodableValue(transparentBackground)},
      {flutter::EncodableValue("supportZoom"), flutter::EncodableValue(supportZoom)},
      {flutter::EncodableValue("isInspectable"), flutter::EncodableValue(isInspectable)},
      {flutter::EncodableValue("disableContextMenu"), flutter::EncodableValue(disableContextMenu)},
      {flutter::EncodableValue("incognito"), flutter::EncodableValue(incognito)},
    }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[settingsMap["javaScriptEnabled"] = (bool)realJavaScriptEnabled;]====] [====[settingsMap[flutter::EncodableValue("javaScriptEnabled")] = flutter::EncodableValue((bool)realJavaScriptEnabled);]====] 1)
  sourin_plugin_compat_replace_exact(source [====[settingsMap["supportZoom"] = (bool)realSupportZoom;]====] [====[settingsMap[flutter::EncodableValue("supportZoom")] = flutter::EncodableValue((bool)realSupportZoom);]====] 1)
  sourin_plugin_compat_replace_exact(source [====[settingsMap["isInspectable"] = (bool)realIsInspectable;]====] [====[settingsMap[flutter::EncodableValue("isInspectable")] = flutter::EncodableValue((bool)realIsInspectable);]====] 1)
  sourin_plugin_compat_replace_exact(source [====[settingsMap["disableContextMenu"] = !(bool)areDefaultContextMenusEnabled;]====] [====[settingsMap[flutter::EncodableValue("disableContextMenu")] = flutter::EncodableValue(!(bool)areDefaultContextMenusEnabled);]====] 1)
  sourin_plugin_compat_replace_exact(source [====[settingsMap["userAgent"] = wide_to_utf8(realUserAgent.get());]====] [====[settingsMap[flutter::EncodableValue("userAgent")] = flutter::EncodableValue(wide_to_utf8(realUserAgent.get()));]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "604782871167c96fcf5660008c990b29b9d346b7186b0606d349e9e79cf9bdbe")
    message(FATAL_ERROR "InAppWebView in_app_webview/in_app_webview_settings.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/in_app_webview/in_app_webview_settings.cpp.in" "${source}")
  configure_file("${private}/in_app_webview/in_app_webview_settings.cpp.in" "${private}/in_app_webview/in_app_webview_settings.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/in_app_webview/webview_channel_delegate.cpp" original_hash)
  if(NOT original_hash STREQUAL "e3a491fea03e5be934c6aec29c6e176f581250f9814eb179f8e0421c37bdbf3e")
    message(FATAL_ERROR "InAppWebView in_app_webview/webview_channel_delegate.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/in_app_webview/webview_channel_delegate.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[data.value()->toEncodableMap() : make_fl_value()]====] [====[flutter::EncodableValue(data.value()->toEncodableMap()) : make_fl_value()]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"url", make_fl_value(url)},
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("url"), make_fl_value(url)},
      }]====] 2)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"request", request->toEncodableMap()},
      {"error", error->toEncodableMap()},
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("request"), flutter::EncodableValue(request->toEncodableMap())},
      {flutter::EncodableValue("error"), flutter::EncodableValue(error->toEncodableMap())},
      }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"request", request->toEncodableMap()},
      {"errorResponse", errorResponse->toEncodableMap()},
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("request"), flutter::EncodableValue(request->toEncodableMap())},
      {flutter::EncodableValue("errorResponse"), flutter::EncodableValue(errorResponse->toEncodableMap())},
      }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"title", make_fl_value(title)}
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("title"), make_fl_value(title)}
      }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"url", make_fl_value(url)},
      {"isReload", make_fl_value(isReload)}
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("url"), make_fl_value(url)},
      {flutter::EncodableValue("isReload"), make_fl_value(isReload)}
      }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"handlerName", handlerName},
      {"args", args}
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("handlerName"), flutter::EncodableValue(handlerName)},
      {flutter::EncodableValue("args"), flutter::EncodableValue(args)}
      }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"message", message},
      {"messageLevel", messageLevel}
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("message"), flutter::EncodableValue(message)},
      {flutter::EncodableValue("messageLevel"), flutter::EncodableValue(messageLevel)}
      }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"eventName", eventName},
      {"data", data}
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("eventName"), flutter::EncodableValue(eventName)},
      {flutter::EncodableValue("data"), flutter::EncodableValue(data)}
      }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"progress", progress}
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("progress"), flutter::EncodableValue(progress)}
      }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"origin", origin},
      {"resources", make_fl_value(resources)}
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("origin"), flutter::EncodableValue(origin)},
      {flutter::EncodableValue("resources"), make_fl_value(resources)}
      }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"request", request->toEncodableMap()},
      }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("request"), flutter::EncodableValue(request->toEncodableMap())},
      }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[->Success(true)]====] [====[->Success(flutter::EncodableValue(true))]====] 21)
  sourin_plugin_compat_replace_exact(source [====[->Success(webView->canGoBack())]====] [====[->Success(flutter::EncodableValue(webView->canGoBack()))]====] 1)
  sourin_plugin_compat_replace_exact(source [====[->Success(webView->canGoForward())]====] [====[->Success(flutter::EncodableValue(webView->canGoForward()))]====] 1)
  sourin_plugin_compat_replace_exact(source [====[->Success(value)]====] [====[->Success(flutter::EncodableValue(value))]====] 3)
  sourin_plugin_compat_replace_exact(source [====[->Success(webView->isLoading())]====] [====[->Success(flutter::EncodableValue(webView->isLoading()))]====] 1)
  sourin_plugin_compat_replace_exact(source [====[->Success(value->toEncodableMap())]====] [====[->Success(flutter::EncodableValue(value->toEncodableMap()))]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "a413ce36f95b3a9ebdf56c9fede05f8cc9dbfd3330e2e4da0834dc08b2df4005")
    message(FATAL_ERROR "InAppWebView in_app_webview/webview_channel_delegate.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/in_app_webview/webview_channel_delegate.cpp.in" "${source}")
  configure_file("${private}/in_app_webview/webview_channel_delegate.cpp.in" "${private}/in_app_webview/webview_channel_delegate.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/create_window_action.cpp" original_hash)
  if(NOT original_hash STREQUAL "e4d7bba5a14055ac235d883355e59b1d89c6370d81f975a3d873829327cf11e0")
    message(FATAL_ERROR "InAppWebView types/create_window_action.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/create_window_action.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[windowFeatures.value()->toEncodableMap() : make_fl_value()]====] [====[flutter::EncodableValue(windowFeatures.value()->toEncodableMap()) : make_fl_value()]====] 1)
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"request", request->toEncodableMap()},
      {"isForMainFrame", isForMainFrame},
      {"windowId", windowId},
      {"hasGesture", make_fl_value(hasGesture)},
      {"windowFeatures", windowFeatures.has_value() ? flutter::EncodableValue(windowFeatures.value()->toEncodableMap()) : make_fl_value()}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("request"), flutter::EncodableValue(request->toEncodableMap())},
      {flutter::EncodableValue("isForMainFrame"), flutter::EncodableValue(isForMainFrame)},
      {flutter::EncodableValue("windowId"), flutter::EncodableValue(windowId)},
      {flutter::EncodableValue("hasGesture"), make_fl_value(hasGesture)},
      {flutter::EncodableValue("windowFeatures"), windowFeatures.has_value() ? flutter::EncodableValue(windowFeatures.value()->toEncodableMap()) : make_fl_value()}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "698d9f5767b61abb5858d14c5eeab4bb192e2d8eb6b28fb27207975348db755d")
    message(FATAL_ERROR "InAppWebView types/create_window_action.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/create_window_action.cpp.in" "${source}")
  configure_file("${private}/types/create_window_action.cpp.in" "${private}/types/create_window_action.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/custom_scheme_registration.cpp" original_hash)
  if(NOT original_hash STREQUAL "e8e1ccae308fe8471a4227e36d04fb6def74ff8089fa76f58e95039df8a6b877")
    message(FATAL_ERROR "InAppWebView types/custom_scheme_registration.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/custom_scheme_registration.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"scheme", make_fl_value(scheme)},
      {"allowedOrigins", make_fl_value(allowedOrigins)},
      {"treatAsSecure", make_fl_value(treatAsSecure)},
      {"hasAuthorityComponent", make_fl_value(hasAuthorityComponent)}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("scheme"), make_fl_value(scheme)},
      {flutter::EncodableValue("allowedOrigins"), make_fl_value(allowedOrigins)},
      {flutter::EncodableValue("treatAsSecure"), make_fl_value(treatAsSecure)},
      {flutter::EncodableValue("hasAuthorityComponent"), make_fl_value(hasAuthorityComponent)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "77d5006890a0d4173e990c3d1ef0e476255329499095712979468d49fe4713cb")
    message(FATAL_ERROR "InAppWebView types/custom_scheme_registration.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/custom_scheme_registration.cpp.in" "${source}")
  configure_file("${private}/types/custom_scheme_registration.cpp.in" "${private}/types/custom_scheme_registration.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/custom_scheme_response.cpp" original_hash)
  if(NOT original_hash STREQUAL "c20753dcbb5a12be39e2000b4fc269ecd1bdbf59e41f40ec1ec9b2a5c314d020")
    message(FATAL_ERROR "InAppWebView types/custom_scheme_response.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/custom_scheme_response.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"data", make_fl_value(data)},
      {"contentType", make_fl_value(contentType)},
      {"contentEncoding", make_fl_value(contentEncoding)}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("data"), make_fl_value(data)},
      {flutter::EncodableValue("contentType"), make_fl_value(contentType)},
      {flutter::EncodableValue("contentEncoding"), make_fl_value(contentEncoding)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "84a80f2b93b10cabd9f23030d03ce3c6e67682e787113535f7f8c8e0e76f53c3")
    message(FATAL_ERROR "InAppWebView types/custom_scheme_response.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/custom_scheme_response.cpp.in" "${source}")
  configure_file("${private}/types/custom_scheme_response.cpp.in" "${private}/types/custom_scheme_response.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/navigation_action.cpp" original_hash)
  if(NOT original_hash STREQUAL "339da1cf5b167bdfa4d603ebe96c9503597e382ff40b77c83662bcb158e3ac74")
    message(FATAL_ERROR "InAppWebView types/navigation_action.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/navigation_action.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"request", request->toEncodableMap()},
      {"isForMainFrame", isForMainFrame},
      {"isRedirect", make_fl_value(isRedirect)},
      {"navigationType", make_fl_value(navigationType)}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("request"), flutter::EncodableValue(request->toEncodableMap())},
      {flutter::EncodableValue("isForMainFrame"), flutter::EncodableValue(isForMainFrame)},
      {flutter::EncodableValue("isRedirect"), make_fl_value(isRedirect)},
      {flutter::EncodableValue("navigationType"), make_fl_value(navigationType)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "b46e2ec267c9e876ed94e81d3464261725a7d73ca9538c7f5222f37526f5e878")
    message(FATAL_ERROR "InAppWebView types/navigation_action.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/navigation_action.cpp.in" "${source}")
  configure_file("${private}/types/navigation_action.cpp.in" "${private}/types/navigation_action.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/permission_response.cpp" original_hash)
  if(NOT original_hash STREQUAL "a4729b254355a33450b1b01429a6b4534776975fa8be1b3598c2fab324086090")
    message(FATAL_ERROR "InAppWebView types/permission_response.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/permission_response.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"resources", make_fl_value(resources)},
      {"action", make_fl_value(action)},
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("resources"), make_fl_value(resources)},
      {flutter::EncodableValue("action"), make_fl_value(action)},
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "a5067dba8b3daa0d91a3ebbe7ce361e38308a12a8cb9bcff28c86258b8038b04")
    message(FATAL_ERROR "InAppWebView types/permission_response.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/permission_response.cpp.in" "${source}")
  configure_file("${private}/types/permission_response.cpp.in" "${private}/types/permission_response.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/rect.cpp" original_hash)
  if(NOT original_hash STREQUAL "af9c47dead5eca4883e98e7db535b7aeaf6eb9acc1fcf564401fb9e4777f95bd")
    message(FATAL_ERROR "InAppWebView types/rect.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/rect.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"x", x},
      {"y", y},
      {"width", width},
      {"height", height}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("x"), flutter::EncodableValue(x)},
      {flutter::EncodableValue("y"), flutter::EncodableValue(y)},
      {flutter::EncodableValue("width"), flutter::EncodableValue(width)},
      {flutter::EncodableValue("height"), flutter::EncodableValue(height)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "1966828bc7949f03c95ca8e7946a083c99ff981a7a13b1117d98d4d7117d9050")
    message(FATAL_ERROR "InAppWebView types/rect.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/rect.cpp.in" "${source}")
  configure_file("${private}/types/rect.cpp.in" "${private}/types/rect.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/size_2d.cpp" original_hash)
  if(NOT original_hash STREQUAL "16058aefa40b78742b55904539103218abd2a65dbee2505de873f3f230f2f637")
    message(FATAL_ERROR "InAppWebView types/size_2d.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/size_2d.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"width", width},
      {"height", height}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("width"), flutter::EncodableValue(width)},
      {flutter::EncodableValue("height"), flutter::EncodableValue(height)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "428b52885d4d43523573a7d40abf3ea6f4ba0c7e5762d78a5d14c13d9418671c")
    message(FATAL_ERROR "InAppWebView types/size_2d.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/size_2d.cpp.in" "${source}")
  configure_file("${private}/types/size_2d.cpp.in" "${private}/types/size_2d.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/ssl_certificate.cpp" original_hash)
  if(NOT original_hash STREQUAL "dc5b9e6791b3692ebddf42e08e10e9225e9428563c7375e93d1c5d3636558e58")
    message(FATAL_ERROR "InAppWebView types/ssl_certificate.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/ssl_certificate.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"x509Certificate", make_fl_value(x509Certificate)}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("x509Certificate"), make_fl_value(x509Certificate)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "82e787e36a6f440d516f279ce3e901fc1edb33a9d2e3e402d31ac8fb0d7a86d6")
    message(FATAL_ERROR "InAppWebView types/ssl_certificate.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/ssl_certificate.cpp.in" "${source}")
  configure_file("${private}/types/ssl_certificate.cpp.in" "${private}/types/ssl_certificate.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/url_request.cpp" original_hash)
  if(NOT original_hash STREQUAL "08ba12bc327a12c4c344e98bbf1113e3a876eab01c83da8275c2c506129038b4")
    message(FATAL_ERROR "InAppWebView types/url_request.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/url_request.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"url", make_fl_value(url)},
      {"method", make_fl_value(method)},
      {"headers", make_fl_value(headers)},
      {"body", make_fl_value(body)}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("url"), make_fl_value(url)},
      {flutter::EncodableValue("method"), make_fl_value(method)},
      {flutter::EncodableValue("headers"), make_fl_value(headers)},
      {flutter::EncodableValue("body"), make_fl_value(body)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "6339f80a2ec637372892ac22efa624620bf8dd40dc0ae36e53c1921d3ac93f6f")
    message(FATAL_ERROR "InAppWebView types/url_request.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/url_request.cpp.in" "${source}")
  configure_file("${private}/types/url_request.cpp.in" "${private}/types/url_request.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/web_history.cpp" original_hash)
  if(NOT original_hash STREQUAL "a4c4e52de4372f3f15be8bf262f93d6da4775e942a3c74768fa40704a8ab9b6d")
    message(FATAL_ERROR "InAppWebView types/web_history.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/web_history.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"currentIndex", make_fl_value(currentIndex)},
      {"list", make_fl_value(functional_map(list, [](const std::shared_ptr<WebHistoryItem>& item) { return item->toEncodableMap(); }))}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("currentIndex"), make_fl_value(currentIndex)},
      {flutter::EncodableValue("list"), make_fl_value(functional_map(list, [](const std::shared_ptr<WebHistoryItem>& item) { return item->toEncodableMap(); }))}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "0caaec57f906c56593c409e264bfd63be1c4fdc305715bdba68be301cc98249c")
    message(FATAL_ERROR "InAppWebView types/web_history.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/web_history.cpp.in" "${source}")
  configure_file("${private}/types/web_history.cpp.in" "${private}/types/web_history.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/web_history_item.cpp" original_hash)
  if(NOT original_hash STREQUAL "3b3734b0d453507fb5ce489f463107028baca4c8d37cd8bd67e920c201bd0ef9")
    message(FATAL_ERROR "InAppWebView types/web_history_item.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/web_history_item.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"entryId", make_fl_value(entryId)},
      {"index", make_fl_value(index)},
      {"offset", make_fl_value(offset)},
      {"originalUrl", make_fl_value(originalUrl)},
      {"title", make_fl_value(title)},
      {"url", make_fl_value(url)}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("entryId"), make_fl_value(entryId)},
      {flutter::EncodableValue("index"), make_fl_value(index)},
      {flutter::EncodableValue("offset"), make_fl_value(offset)},
      {flutter::EncodableValue("originalUrl"), make_fl_value(originalUrl)},
      {flutter::EncodableValue("title"), make_fl_value(title)},
      {flutter::EncodableValue("url"), make_fl_value(url)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "aba3d1d98ec0a9ff6ae811f02c6d5cde3866ba76454412ddfab86a07ecfce3ac")
    message(FATAL_ERROR "InAppWebView types/web_history_item.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/web_history_item.cpp.in" "${source}")
  configure_file("${private}/types/web_history_item.cpp.in" "${private}/types/web_history_item.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/web_resource_error.cpp" original_hash)
  if(NOT original_hash STREQUAL "7c7651dd9e3563a07c767ca6516540834a81e22aa2fd2f946abb5d9ff80c01f8")
    message(FATAL_ERROR "InAppWebView types/web_resource_error.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/web_resource_error.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"description", make_fl_value(description)},
      {"type", make_fl_value(type)}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("description"), make_fl_value(description)},
      {flutter::EncodableValue("type"), make_fl_value(type)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "253f75edfd626a3664cc6a4d8f3e412cd9b68cbdf055317de45532133fa64e22")
    message(FATAL_ERROR "InAppWebView types/web_resource_error.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/web_resource_error.cpp.in" "${source}")
  configure_file("${private}/types/web_resource_error.cpp.in" "${private}/types/web_resource_error.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/web_resource_request.cpp" original_hash)
  if(NOT original_hash STREQUAL "ff4e9d29e277ca799d2a332f472c5bf2565c491f883d1879d6223500c1ab862a")
    message(FATAL_ERROR "InAppWebView types/web_resource_request.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/web_resource_request.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"url", make_fl_value(url)},
      {"method", make_fl_value(method)},
      {"headers", make_fl_value(headers)},
      {"isForMainFrame", make_fl_value(isForMainFrame)}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("url"), make_fl_value(url)},
      {flutter::EncodableValue("method"), make_fl_value(method)},
      {flutter::EncodableValue("headers"), make_fl_value(headers)},
      {flutter::EncodableValue("isForMainFrame"), make_fl_value(isForMainFrame)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "64bba4dd04e7af9385ba514f11addb42f34a908cb208f545ee322325c3b07e72")
    message(FATAL_ERROR "InAppWebView types/web_resource_request.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/web_resource_request.cpp.in" "${source}")
  configure_file("${private}/types/web_resource_request.cpp.in" "${private}/types/web_resource_request.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/web_resource_response.cpp" original_hash)
  if(NOT original_hash STREQUAL "9529c6cc513a8f8ada0650a081ed1be51a5e87dbd1eab93d090f642d0fa5d437")
    message(FATAL_ERROR "InAppWebView types/web_resource_response.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/web_resource_response.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
    {"contentEncoding", make_fl_value(contentEncoding)},
    {"contentType", make_fl_value(contentType)},
    {"statusCode", make_fl_value(statusCode)},
    {"reasonPhrase", make_fl_value(reasonPhrase)},
    {"headers", make_fl_value(headers)},
    {"data", make_fl_value(data)}
    }]====] [====[flutter::EncodableMap{
    {flutter::EncodableValue("contentEncoding"), make_fl_value(contentEncoding)},
    {flutter::EncodableValue("contentType"), make_fl_value(contentType)},
    {flutter::EncodableValue("statusCode"), make_fl_value(statusCode)},
    {flutter::EncodableValue("reasonPhrase"), make_fl_value(reasonPhrase)},
    {flutter::EncodableValue("headers"), make_fl_value(headers)},
    {flutter::EncodableValue("data"), make_fl_value(data)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "f35c7bf81acb2ddd2318deeb7f78fa7ff770251e73e93c33a31dc214dd659ff3")
    message(FATAL_ERROR "InAppWebView types/web_resource_response.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/web_resource_response.cpp.in" "${source}")
  configure_file("${private}/types/web_resource_response.cpp.in" "${private}/types/web_resource_response.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/types/window_features.cpp" original_hash)
  if(NOT original_hash STREQUAL "b1fbabab0afde1c9c5b7e22b2c68256c99fe9e59cee09364916a3ce8c85dd58a")
    message(FATAL_ERROR "InAppWebView types/window_features.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/types/window_features.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"width", make_fl_value(width)},
      {"height", make_fl_value(height)},
      {"x", make_fl_value(x)},
      {"y", make_fl_value(y)},
      {"menuBarVisibility", make_fl_value(menuBarVisibility)},
      {"statusBarVisibility", make_fl_value(statusBarVisibility)},
      {"toolbarsVisibility", make_fl_value(toolbarsVisibility)}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("width"), make_fl_value(width)},
      {flutter::EncodableValue("height"), make_fl_value(height)},
      {flutter::EncodableValue("x"), make_fl_value(x)},
      {flutter::EncodableValue("y"), make_fl_value(y)},
      {flutter::EncodableValue("menuBarVisibility"), make_fl_value(menuBarVisibility)},
      {flutter::EncodableValue("statusBarVisibility"), make_fl_value(statusBarVisibility)},
      {flutter::EncodableValue("toolbarsVisibility"), make_fl_value(toolbarsVisibility)}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "00a05b7bd8081a7e0d5c7bbf3777574e5a7ffd458665666c1b6640d5ab735841")
    message(FATAL_ERROR "InAppWebView types/window_features.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/types/window_features.cpp.in" "${source}")
  configure_file("${private}/types/window_features.cpp.in" "${private}/types/window_features.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/utils/flutter.h" original_hash)
  if(NOT original_hash STREQUAL "f715d6ac6e846976f1f25feb27a9dc3cc2cb18af15591c4cf92120276fefae04")
    message(FATAL_ERROR "InAppWebView utils/flutter.h changed; review explicit value conversions")
  endif()
  file(READ "${private}/utils/flutter.h" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[return encodableList;]====] [====[return flutter::EncodableValue(encodableList);]====] 2)
  sourin_plugin_compat_replace_exact(source [====[return encodableMap;]====] [====[return flutter::EncodableValue(encodableMap);]====] 2)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "897fea0ee53ff2c354a962ffc2eea9daa8e48de9503b9a52c0e90f0d11812678")
    message(FATAL_ERROR "InAppWebView utils/flutter.h normalized candidate differs")
  endif()
  file(WRITE "${private}/utils/flutter.h.in" "${source}")
  configure_file("${private}/utils/flutter.h.in" "${private}/utils/flutter.h" COPYONLY)
  file(SHA256 "${plugin_dir}/webview_environment/webview_environment_manager.cpp" original_hash)
  if(NOT original_hash STREQUAL "e05330be2a9bf83aed578189b8e2bb505b530fce6854f32e2a46f07a46ae9659")
    message(FATAL_ERROR "InAppWebView webview_environment/webview_environment_manager.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/webview_environment/webview_environment_manager.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[->Success(true)]====] [====[->Success(flutter::EncodableValue(true))]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "036da895496c7f1069558673a7e2323a648ee4d183bd40922215609974265f69")
    message(FATAL_ERROR "InAppWebView webview_environment/webview_environment_manager.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/webview_environment/webview_environment_manager.cpp.in" "${source}")
  configure_file("${private}/webview_environment/webview_environment_manager.cpp.in" "${private}/webview_environment/webview_environment_manager.cpp" COPYONLY)
  file(SHA256 "${plugin_dir}/webview_environment/webview_environment_settings.cpp" original_hash)
  if(NOT original_hash STREQUAL "ff19e8d96a400a4c886bdd01a4fb4dabcfa8da7d85fb0896a1beb1afaaee10db")
    message(FATAL_ERROR "InAppWebView webview_environment/webview_environment_settings.cpp changed; review explicit value conversions")
  endif()
  file(READ "${private}/webview_environment/webview_environment_settings.cpp" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[flutter::EncodableMap{
      {"browserExecutableFolder", make_fl_value(browserExecutableFolder)},
      {"userDataFolder", make_fl_value(userDataFolder)},
      {"additionalBrowserArguments", make_fl_value(additionalBrowserArguments)},
      {"allowSingleSignOnUsingOSPrimaryAccount", make_fl_value(allowSingleSignOnUsingOSPrimaryAccount)},
      {"language", make_fl_value(language)},
      {"targetCompatibleBrowserVersion", make_fl_value(targetCompatibleBrowserVersion)},
      {"customSchemeRegistrations", make_fl_value(functional_map(customSchemeRegistrations, [](const std::shared_ptr<CustomSchemeRegistration>& item) { return item->toEncodableMap(); }))}
    }]====] [====[flutter::EncodableMap{
      {flutter::EncodableValue("browserExecutableFolder"), make_fl_value(browserExecutableFolder)},
      {flutter::EncodableValue("userDataFolder"), make_fl_value(userDataFolder)},
      {flutter::EncodableValue("additionalBrowserArguments"), make_fl_value(additionalBrowserArguments)},
      {flutter::EncodableValue("allowSingleSignOnUsingOSPrimaryAccount"), make_fl_value(allowSingleSignOnUsingOSPrimaryAccount)},
      {flutter::EncodableValue("language"), make_fl_value(language)},
      {flutter::EncodableValue("targetCompatibleBrowserVersion"), make_fl_value(targetCompatibleBrowserVersion)},
      {flutter::EncodableValue("customSchemeRegistrations"), make_fl_value(functional_map(customSchemeRegistrations, [](const std::shared_ptr<CustomSchemeRegistration>& item) { return item->toEncodableMap(); }))}
    }]====] 1)
  string(SHA256 candidate_hash "${source}")
  if(NOT candidate_hash STREQUAL "fdac1efa14211e6d37df6d923b3817f6b3ea8b55aab8640349f6772eda2a51d6")
    message(FATAL_ERROR "InAppWebView webview_environment/webview_environment_settings.cpp normalized candidate differs")
  endif()
  file(WRITE "${private}/webview_environment/webview_environment_settings.cpp.in" "${source}")
  configure_file("${private}/webview_environment/webview_environment_settings.cpp.in" "${private}/webview_environment/webview_environment_settings.cpp" COPYONLY)

  file(SHA256 "${plugin_dir}/utils/string.h" original_hash)
  if(NOT original_hash STREQUAL "cdb61074014333331504a587b540d258a9195445048148da027f3188efdbae01")
    message(FATAL_ERROR "InAppWebView utils/string.h changed; review string compatibility")
  endif()
  file(READ "${private}/utils/string.h" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  sourin_plugin_compat_replace_exact(source [====[[delim](auto& a, auto& b) { return a + delim + b; }]====] [====[[delim](const auto& a, auto& b) { return a + delim + b; }]====] 1)
  sourin_plugin_compat_replace_exact(source [====[  void to_uppercase(const std::basic_string<T>& s)
  {
    std::transform(s.begin(), s.end(), s.begin(),
      [](const T v) { return static_cast<T>(std::toupper(v)); });
    return s2;
  }]====] [====[  void to_uppercase(const std::basic_string<T>& s)
  {
    std::transform(s.begin(), s.end(), s.begin(),
      [](const T v) { return static_cast<T>(std::toupper(v)); });
  }]====] 1)
  string(SHA256 patched_hash "${source}")
  if(NOT patched_hash STREQUAL "aec6515464a641267fdbb08bb7f2c589b1256703afe0049d5cd7c8c2c7b70e4b")
    message(FATAL_ERROR "InAppWebView utils/string.h compatibility output differs")
  endif()
  file(WRITE "${private}/utils/string.h.in" "${source}")
  configure_file("${private}/utils/string.h.in" "${private}/utils/string.h" COPYONLY)

  set(updated)
  set(shutdown_count 0)
  foreach(item IN LISTS sources)
    if(item MATCHES "^\\$<")
      message(FATAL_ERROR "InAppWebView source expression requires explicit private mapping")
    endif()
    get_filename_component(absolute "${item}" ABSOLUTE BASE_DIR "${plugin_dir}")
    if(absolute STREQUAL shutdown)
      list(APPEND updated "${private}/in_app_webview/in_app_webview_manager.cpp")
      math(EXPR shutdown_count "${shutdown_count} + 1")
    else()
      file(RELATIVE_PATH relative "${plugin_dir}" "${absolute}")
      if(relative MATCHES "^\\.\\./" OR IS_ABSOLUTE "${relative}" OR NOT EXISTS "${private}/${relative}")
        message(FATAL_ERROR "InAppWebView source is outside its complete private copy")
      endif()
      list(APPEND updated "${private}/${relative}")
    endif()
  endforeach()
  if(NOT shutdown_count EQUAL 1)
    message(FATAL_ERROR "InAppWebView shutdown source ownership changed")
  endif()
  set_property(TARGET ${plugin} PROPERTY SOURCES "${updated}")
  set(sdk_include_count 0)
  foreach(property INCLUDE_DIRECTORIES INTERFACE_INCLUDE_DIRECTORIES)
    get_target_property(includes ${plugin} ${property})
    if(includes STREQUAL "includes-NOTFOUND")
      continue()
    endif()
    set(rebound)
    foreach(item IN LISTS includes)
      if(item MATCHES "^\\$<")
        message(FATAL_ERROR "InAppWebView include expression requires explicit private mapping")
      endif()
      get_filename_component(absolute "${item}" ABSOLUTE BASE_DIR "${plugin_dir}")
      file(RELATIVE_PATH relative "${plugin_dir}" "${absolute}")
      if(absolute STREQUAL sdk)
        list(APPEND rebound "${private_sdk}")
        math(EXPR sdk_include_count "${sdk_include_count} + 1")
      elseif(NOT relative MATCHES "^\\.\\./" AND NOT IS_ABSOLUTE "${relative}")
        list(APPEND rebound "${private}/${relative}")
      else()
        list(APPEND rebound "${item}")
      endif()
    endforeach()
    set_property(TARGET ${plugin} PROPERTY ${property} "${rebound}")
  endforeach()
  if(NOT sdk_include_count EQUAL 1)
    message(FATAL_ERROR "InAppWebView SDK include ownership changed")
  endif()
endfunction()

sourin_fix_inappwebview_clang()
