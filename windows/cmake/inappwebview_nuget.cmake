# InAppWebView 0.6.0 relies on MSBuild imports for its native NuGet inputs.
# Keep the ordinary Win32 Dynamic loader policy when using other generators.
if(CMAKE_GENERATOR MATCHES "^Visual Studio")
  return()
endif()

function(sourin_configure_inappwebview_nuget)
  set(plugin flutter_inappwebview_windows_plugin)
  set(download flutter_inappwebview_windows_DEPENDENCIES_DOWNLOAD)
  if(NOT TARGET ${plugin} OR NOT TARGET ${download})
    message(FATAL_ERROR "InAppWebView dependency targets changed; review native NuGet integration")
  endif()
  get_target_property(plugin_dir ${plugin} SOURCE_DIR)
  file(READ "${plugin_dir}/CMakeLists.txt" plugin_cmake)
  foreach(anchor IN ITEMS
      "set(WIL_VERSION \"1.0.231216.1\")"
      "set(WEBVIEW_VERSION \"1.0.2792.45\")"
      "set(NLOHMANN_JSON \"3.11.2\")")
    string(FIND "${plugin_cmake}" "${anchor}" position)
    if(position EQUAL -1)
      message(FATAL_ERROR "InAppWebView NuGet versions changed; review native dependency rules")
    endif()
  endforeach()

  # Select the target architecture, including clang-cl without a VS generator.
  if(CMAKE_VS_PLATFORM_NAME)
    set(architecture "${CMAKE_VS_PLATFORM_NAME}")
  else()
    set(architecture "${MSVC_CXX_ARCHITECTURE_ID}")
  endif()
  string(TOLOWER "${architecture}" architecture)
  if(NOT architecture STREQUAL "x64" AND NOT architecture STREQUAL "arm64")
    message(FATAL_ERROR "Unsupported InAppWebView target architecture: '${architecture}'")
  endif()

  set(packages "${CMAKE_BINARY_DIR}/packages")
  set(webview "${packages}/Microsoft.Web.WebView2/build/native")
  set(wil "${packages}/Microsoft.Windows.ImplementationLibrary")
  set(json "${packages}/nlohmann.json/build/native")
  set(xml_imports
    "${webview}/Microsoft.Web.WebView2.targets"
    "${wil}/build/native/Microsoft.Windows.ImplementationLibrary.targets"
    "${json}/nlohmann.json.targets")
  get_target_property(libraries ${plugin} LINK_LIBRARIES)
  set(native_libraries)
  set(removed 0)
  foreach(library IN LISTS libraries)
    if(library IN_LIST xml_imports)
      math(EXPR removed "${removed} + 1")
    else()
      list(APPEND native_libraries "${library}")
    endif()
  endforeach()
  if(NOT removed EQUAL 3)
    message(FATAL_ERROR "InAppWebView MSBuild import list changed; review native NuGet integration")
  endif()
  set_property(TARGET ${plugin} PROPERTY LINK_LIBRARIES "${native_libraries}")
  target_include_directories(${plugin} PRIVATE
    "${webview}/include"
    "${wil}/include"
    "${json}/include")

  set(loader_import "${webview}/${architecture}/WebView2Loader.dll.lib")
  set(loader "${webview}/${architecture}/WebView2Loader.dll")
  # The existing NuGet commands produce both files. An explicit checked output
  # bridge gives Ninja a real producer for the otherwise unknown link input.
  # compare_files fails if download did not produce a file; nothing is created
  # or substituted by this bridge.
  add_custom_command(
    OUTPUT "${loader_import}" "${loader}"
    COMMAND ${CMAKE_COMMAND} -E compare_files "${loader_import}" "${loader_import}"
    COMMAND ${CMAKE_COMMAND} -E compare_files "${loader}" "${loader}"
    DEPENDS ${download}
    COMMENT "Checking InAppWebView native NuGet loader outputs"
    VERBATIM)
  add_custom_target(sourin_inappwebview_nuget_ready
    DEPENDS "${loader_import}" "${loader}")
  add_dependencies(${plugin} sourin_inappwebview_nuget_ready)
  target_link_libraries(${plugin} PRIVATE "${loader_import}")
  # generated_plugins.cmake has already collected the plugin bundle list.
  # The application install graph owns the shared runner runtime directory.
  list(APPEND PLUGIN_BUNDLED_LIBRARIES "${loader}")
  set(PLUGIN_BUNDLED_LIBRARIES "${PLUGIN_BUNDLED_LIBRARIES}" PARENT_SCOPE)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${plugin_dir}/CMakeLists.txt")
endfunction()

sourin_configure_inappwebview_nuget()
