# Strict Clang compatibility edits retain /W4 /WX and the shutdown correction.
function(sourin_media_replace_exact variable before_variable after_variable)
  set(value "${${variable}}")
  set(before "${${before_variable}}")
  set(after "${${after_variable}}")
  string(FIND "${value}" "${before}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "media_kit_video Clang compatibility anchor missing")
  endif()
  string(LENGTH "${before}" before_length)
  math(EXPR tail_begin "${position} + ${before_length}")
  string(SUBSTRING "${value}" ${tail_begin} -1 tail)
  string(FIND "${tail}" "${before}" duplicate)
  if(NOT duplicate EQUAL -1)
    message(FATAL_ERROR "media_kit_video Clang compatibility anchor duplicated")
  endif()
  string(REPLACE "${before}" "${after}" value "${value}")
  set(${variable} "${value}" PARENT_SCOPE)
endfunction()

# media_kit_video 1.3.1 wakes its destructor while textures_mutex_ is held.
# Keep render-context cleanup, mutex release and object lifetime in order.
# Compile a private copy, preserving the shared dependency cache.
function(sourin_fix_media_kit_video_shutdown)
  set(plugin media_kit_video_plugin)
  get_target_property(plugin_dir ${plugin} SOURCE_DIR)
  get_target_property(sources ${plugin} SOURCES)
  file(SHA256 "${plugin_dir}/angle_surface_manager.h" compatibility_hash)
  if(NOT compatibility_hash STREQUAL "3c7f24a94a8f7e8b551877142ea12b92d1543d4f8384370d55c3b5147eefe6ef")
    message(FATAL_ERROR "media_kit_video angle_surface_manager.h changed; review Clang compatibility fix")
  endif()
  file(SHA256 "${plugin_dir}/angle_surface_manager.cc" compatibility_hash)
  if(NOT compatibility_hash STREQUAL "04eadbea88ce1d825a732c8ea96f9557bb19c275330f4abf7836950e7efd2e2a")
    message(FATAL_ERROR "media_kit_video angle_surface_manager.cc changed; review Clang compatibility fix")
  endif()
  file(SHA256 "${plugin_dir}/utils.cc" compatibility_hash)
  if(NOT compatibility_hash STREQUAL "e5161298b1c4c464e9171cd82368d579d177b185fab5fd558efaf5ea550f56da")
    message(FATAL_ERROR "media_kit_video utils.cc changed; review Clang compatibility fix")
  endif()
  file(SHA256 "${plugin_dir}/video_output.cc" compatibility_hash)
  if(NOT compatibility_hash STREQUAL "198cb59a97070b61df5ee8ae35ac3e0bc344f3174f6e4aaf7b77e7357d606548")
    message(FATAL_ERROR "media_kit_video video_output.cc changed; review Clang compatibility fix")
  endif()
  file(SHA256 "${plugin_dir}/video_output.h" compatibility_hash)
  if(NOT compatibility_hash STREQUAL "e276c8b80e9e117d60713b3b25b12ddb0df1878a2c076fe946847ac7eec7c17a")
    message(FATAL_ERROR "media_kit_video video_output.h changed; review Clang compatibility fix")
  endif()
  set(original "${plugin_dir}/video_output.cc")
  file(READ "${original}" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  string(FIND "${source}" "VideoOutput::~VideoOutput() {" begin)
  string(FIND "${source}" "void VideoOutput::NotifyRender() {" end)
  if(begin EQUAL -1 OR end EQUAL -1 OR end LESS begin)
    message(FATAL_ERROR "media_kit_video destruction source changed; review shutdown fix")
  endif()
  math(EXPR length "${end} - ${begin}")
  string(SUBSTRING "${source}" ${begin} ${length} before)
  string(SHA256 digest "${before}")
  if(NOT digest STREQUAL "32701e8fed9e1ced74d688dfef66189f8d99094ba0a8fbfae53b741e43e97e9a")
    message(FATAL_ERROR "media_kit_video destruction contract changed; review shutdown fix")
  endif()
  set(after [=[VideoOutput::~VideoOutput() {
  {
    // Serialize admission of both render tasks with NotifyRender. An update
    // callback that already passed its check must enqueue before this fence.
    std::lock_guard<std::mutex> lock(textures_mutex_);
    destroyed_ = true;
  }
  // Pending CheckAndResize may replace texture_id_. Finish it before choosing
  // the final texture to unregister. Manager's mutex excludes new SetSize work.
  thread_pool_ref_->Post([]() {}).wait();
  auto promise = std::make_shared<std::promise<void>>();
  auto finished = promise->get_future();
  auto cleanup = [this, promise]() {
    // libmpv may wait for an in-flight update callback here. That callback
    // acquires textures_mutex_, so never hold it while disabling callbacks.
    if (render_context_) {
      mpv_render_context_set_update_callback(render_context_, nullptr, nullptr);
    }
    {
      std::lock_guard<std::mutex> lock(textures_mutex_);
      // libmpv must release its renderer before its core or EGL context.
      // This task runs after pending render/resize work on the same worker.
      if (render_context_) {
        if (surface_manager_) {
          surface_manager_->MakeCurrent(true);
        }
        mpv_render_context_free(render_context_);
        render_context_ = nullptr;
        if (surface_manager_) {
          surface_manager_->MakeCurrent(false);
        }
      }
      if (texture_id_) {
        std::cout << "media_kit: VideoOutput: Free Texture: " << texture_id_
                  << std::endl;
        std::cout << "VideoOutput::~VideoOutput: "
                  << reinterpret_cast<int64_t>(handle_) << std::endl;
      }
      texture_variants_.clear();
      textures_.clear();
      pixel_buffer_textures_.clear();
      surface_manager_.reset(nullptr);
    }
    // The waiting thread may delete this object as soon as it is signaled.
    // Release its mutex first and do not access this afterwards.
    promise->set_value();
  };
  if (texture_id_) {
    registrar_->texture_registrar()->UnregisterTexture(
        texture_id_, [this, cleanup]() { thread_pool_ref_->Post(cleanup); });
  } else {
    thread_pool_ref_->Post(cleanup);
  }
  finished.wait();
  texture_id_ = 0;
}

]=])
  string(REPLACE "${before}" "${after}" source "${source}")
  set(before [=[void VideoOutput::NotifyRender() {
  if (destroyed_) {
    return;
  }
  thread_pool_ref_->Post(std::bind(&VideoOutput::CheckAndResize, this));
  thread_pool_ref_->Post(std::bind(&VideoOutput::Render, this));
}]=])
  set(after [=[void VideoOutput::NotifyRender() {
  std::lock_guard<std::mutex> lock(textures_mutex_);
  if (destroyed_) {
    return;
  }
  thread_pool_ref_->Post(std::bind(&VideoOutput::CheckAndResize, this));
  thread_pool_ref_->Post(std::bind(&VideoOutput::Render, this));
}]=])
  string(FIND "${source}" "${before}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "media_kit_video render admission changed; review shutdown fix")
  endif()
  string(REPLACE "${before}" "${after}" source "${source}")
  set(before [====[    : handle_(reinterpret_cast<mpv_handle*>(handle)),
      width_(configuration.width),
      height_(configuration.height),
      configuration_(configuration),]====])
  set(after [====[    : height_(configuration.height),
      width_(configuration.width),
      configuration_(configuration),
      handle_(reinterpret_cast<mpv_handle*>(handle)),]====])
  sourin_media_replace_exact(source before after)
  set(before [====[{MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL}]====])
  set(after [====[{MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)}]====])
  sourin_media_replace_exact(source before after)
  set(before [====[{MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW}]====])
  set(after [====[{MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_SW)}]====])
  sourin_media_replace_exact(source before after)
  set(before [====[{MPV_RENDER_PARAM_SW_FORMAT, "rgb0"}]====])
  set(after [====[{MPV_RENDER_PARAM_SW_FORMAT, const_cast<char*>("rgb0")}]====])
  sourin_media_replace_exact(source before after)
  set(patch_dir "${CMAKE_CURRENT_BINARY_DIR}/sourin_plugin_fixes/media_kit_video")
  set(patched "${patch_dir}/video_output.cc")
  file(MAKE_DIRECTORY "${patch_dir}")
  file(WRITE "${patched}.in" "${source}")
  configure_file("${patched}.in" "${patched}" COPYONLY)
  # Keep the quoted video_output.h -> angle_surface_manager.h include private.
  configure_file("${plugin_dir}/video_output.h" "${patch_dir}/video_output.h" COPYONLY)
  file(READ "${plugin_dir}/angle_surface_manager.h" compatibility_source)
  string(REPLACE "\r\n" "\n" compatibility_source "${compatibility_source}")
  set(before [====[  const int32_t width() const { return width_; }]====])
  set(after [====[  int32_t width() const { return width_; }]====])
  sourin_media_replace_exact(compatibility_source before after)
  set(before [====[  const int32_t height() const { return height_; }]====])
  set(after [====[  int32_t height() const { return height_; }]====])
  sourin_media_replace_exact(compatibility_source before after)
  set(before [====[  const HANDLE handle() const { return handle_; }]====])
  set(after [====[  HANDLE handle() const { return handle_; }]====])
  sourin_media_replace_exact(compatibility_source before after)
  file(WRITE "${patch_dir}/angle_surface_manager.h.in" "${compatibility_source}")
  configure_file("${patch_dir}/angle_surface_manager.h.in" "${patch_dir}/angle_surface_manager.h" COPYONLY)
  file(READ "${plugin_dir}/angle_surface_manager.cc" compatibility_source)
  string(REPLACE "\r\n" "\n" compatibility_source "${compatibility_source}")
  set(before [====[  auto d3d11_texture2D_desc = D3D11_TEXTURE2D_DESC{0};]====])
  set(after [====[  auto d3d11_texture2D_desc = D3D11_TEXTURE2D_DESC{};]====])
  sourin_media_replace_exact(compatibility_source before after)
  file(WRITE "${patch_dir}/angle_surface_manager.cc.in" "${compatibility_source}")
  configure_file("${patch_dir}/angle_surface_manager.cc.in" "${patch_dir}/angle_surface_manager.cc" COPYONLY)
  file(READ "${plugin_dir}/utils.cc" compatibility_source)
  string(REPLACE "\r\n" "\n" compatibility_source "${compatibility_source}")
  set(before [====[  RTL_OSVERSIONINFOW rtl_os_version_info = {0};]====])
  set(after [====[  RTL_OSVERSIONINFOW rtl_os_version_info = {};]====])
  sourin_media_replace_exact(compatibility_source before after)
  file(WRITE "${patch_dir}/utils.cc.in" "${compatibility_source}")
  configure_file("${patch_dir}/utils.cc.in" "${patch_dir}/utils.cc" COPYONLY)
  # The Dart controller awaits this platform call before the core is disposed.
  # Reply after destruction finishes, rather than after merely starting it.
  file(READ "${plugin_dir}/video_output_manager.h" manager_header)
  set(before "void Dispose(int64_t handle);")
  set(after "void Dispose(int64_t handle, std::function<void()> completion);")
  string(FIND "${manager_header}" "${before}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "media_kit_video Dispose declaration changed; review shutdown fix")
  endif()
  string(REPLACE "${before}" "${after}" manager_header "${manager_header}")
  file(WRITE "${patch_dir}/video_output_manager.h.in" "${manager_header}")
  configure_file("${patch_dir}/video_output_manager.h.in" "${patch_dir}/video_output_manager.h" COPYONLY)
  # This header includes the manager header with quotes. Copy it alongside the
  # patched manager so its relative include cannot select the original ABI.
  configure_file("${plugin_dir}/media_kit_video_plugin.h"
                 "${patch_dir}/media_kit_video_plugin.h" COPYONLY)
  configure_file("${plugin_dir}/media_kit_video_plugin_c_api.cc"
                 "${patch_dir}/media_kit_video_plugin_c_api.cc" COPYONLY)
  file(READ "${plugin_dir}/video_output_manager.cc" manager_source)
  string(REPLACE "\r\n" "\n" manager_source "${manager_source}")
  set(before [=[void VideoOutputManager::Dispose(int64_t handle) {
  std::thread([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (video_outputs_.find(handle) != video_outputs_.end()) {
      video_outputs_.erase(handle);
    }
  }).detach();
}]=])
  set(after [=[void VideoOutputManager::Dispose(int64_t handle,
                                 std::function<void()> completion) {
  std::thread([=]() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      video_outputs_.erase(handle);
    }
    completion();
  }).detach();
}]=])
  string(FIND "${manager_source}" "${before}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "media_kit_video Dispose implementation changed; review shutdown fix")
  endif()
  string(REPLACE "${before}" "${after}" manager_source "${manager_source}")
  file(WRITE "${patch_dir}/video_output_manager.cc.in" "${manager_source}")
  configure_file("${patch_dir}/video_output_manager.cc.in" "${patch_dir}/video_output_manager.cc" COPYONLY)
  file(READ "${plugin_dir}/media_kit_video_plugin.cc" channel_source)
  string(REPLACE "\r\n" "\n" channel_source "${channel_source}")
  set(before "    video_output_manager_->Dispose(handle_value);\n    result->Success(flutter::EncodableValue(std::monostate{}));")
  set(after [=[    auto completion =
        std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
    video_output_manager_->Dispose(handle_value, [completion]() {
      completion->Success(flutter::EncodableValue(std::monostate{}));
    });]=])
  string(FIND "${channel_source}" "${before}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "media_kit_video Dispose reply changed; review shutdown fix")
  endif()
  string(REPLACE "${before}" "${after}" channel_source "${channel_source}")
  file(WRITE "${patch_dir}/media_kit_video_plugin.cc.in" "${channel_source}")
  configure_file("${patch_dir}/media_kit_video_plugin.cc.in" "${patch_dir}/media_kit_video_plugin.cc" COPYONLY)
  set(updated)
  set(replaced 0)
  foreach(item IN LISTS sources)
    if(NOT IS_ABSOLUTE "${item}" AND NOT item MATCHES "^\\$<")
      set(item "${plugin_dir}/${item}")
    endif()
    if(item STREQUAL original OR item STREQUAL "${plugin_dir}/video_output_manager.cc" OR
       item STREQUAL "${plugin_dir}/media_kit_video_plugin.cc" OR
       item STREQUAL "${plugin_dir}/media_kit_video_plugin_c_api.cc" OR
       item STREQUAL "${plugin_dir}/angle_surface_manager.cc" OR
       item STREQUAL "${plugin_dir}/utils.cc")
      get_filename_component(name "${item}" NAME)
      list(APPEND updated "${patch_dir}/${name}")
      math(EXPR replaced "${replaced} + 1")
    else()
      list(APPEND updated "${item}")
    endif()
  endforeach()
  if(NOT replaced EQUAL 6)
    message(FATAL_ERROR "media_kit_video source list changed; review shutdown fix")
  endif()
  set_property(TARGET ${plugin} PROPERTY SOURCES "${updated}")
  target_include_directories(${plugin} PRIVATE "${plugin_dir}")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${original}"
    "${plugin_dir}/video_output_manager.h" "${plugin_dir}/video_output_manager.cc"
    "${plugin_dir}/media_kit_video_plugin.cc" "${plugin_dir}/media_kit_video_plugin.h"
    "${plugin_dir}/media_kit_video_plugin_c_api.cc"
    "${plugin_dir}/angle_surface_manager.h" "${plugin_dir}/angle_surface_manager.cc"
    "${plugin_dir}/video_output.h" "${plugin_dir}/utils.cc")
endfunction()

sourin_fix_media_kit_video_shutdown()
