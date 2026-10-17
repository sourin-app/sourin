// ═══════════════════════════════════════════════════════════════════════
//  自建图标表 —— 取代 Material 的 Icons 类（Owner 第 4/8/9 条）
// ═══════════════════════════════════════════════════════════════════════
//
// # 关键发现（决定了这条路可行）
// ```text
// `Icons` 类只在 Material 层，本仓用了 158 个不同图标。
// 最初以为只能换图标体系（Lucide 等），那会改变全部图标外观。
//
// 但读 material_ui 源码后发现它只是常量表：
//   static const IconData error_outline =
//       IconData(0xe238, fontFamily: 'MaterialIcons');
//
// 而 `IconData` 类本身在 flutter/widgets：
//   <FLUTTER_SDK>/packages/flutter/lib/src/widgets/icon_data.dart
// ⇒ 不属于 Material，且 flutter/widgets.dart 已导出它。
// ```
//
// # 结论
// ```text
// 把用到的 158 个图标的 codePoint 抄进本文件，
// 引用 MaterialIcons 字体（字体资源，不是组件库）。
// ⇒ 视觉零变化；摘掉 material_ui 后图标照样显示。
// ```
//
// ⚠️ 本文件由脚本从 material_ui-1.6.0/lib/src/icons.dart 生成，
//    codePoint 不许手改 —— 改了图标会错位或显示成方块。
//
// ignore_for_file: constant_identifier_names
// ↑ snake_case 是**刻意**的：要能与原 `Icons.xxx_yyy` **逐字机械替换**，
//   改成 lowerCamelCase 就得同时改 ' + '158 个调用点，白白引入出错面。
import 'package:flutter/widgets.dart';

/// 自建图标表 —— 与 Material `Icons` 对应项**逐个同码**。
abstract final class AppIcons {
  AppIcons._();

  static const IconData add = IconData(0xe047, fontFamily: 'MaterialIcons');
  static const IconData album_outlined = IconData(0xee67, fontFamily: 'MaterialIcons');
  static const IconData arrow_back = IconData(0xe092, fontFamily: 'MaterialIcons');
  static const IconData arrow_downward = IconData(0xe097, fontFamily: 'MaterialIcons');
  static const IconData arrow_drop_down = IconData(0xe098, fontFamily: 'MaterialIcons');
  static const IconData arrow_upward = IconData(0xe0a0, fontFamily: 'MaterialIcons');
  static const IconData auto_fix_high_outlined = IconData(0xeeab, fontFamily: 'MaterialIcons');
  static const IconData backspace_outlined = IconData(0xeeb5, fontFamily: 'MaterialIcons');
  static const IconData backup_outlined = IconData(0xeeb6, fontFamily: 'MaterialIcons');
  static const IconData bolt = IconData(0xe0ee, fontFamily: 'MaterialIcons');
  static const IconData bolt_outlined = IconData(0xeedd, fontFamily: 'MaterialIcons');
  static const IconData bookmark_outline = IconData(0xe0f4, fontFamily: 'MaterialIcons');
  static const IconData broken_image = IconData(0xe110, fontFamily: 'MaterialIcons');
  static const IconData cast = IconData(0xe144, fontFamily: 'MaterialIcons');
  static const IconData cast_connected = IconData(0xe145, fontFamily: 'MaterialIcons');
  static const IconData category_outlined = IconData(0xef37, fontFamily: 'MaterialIcons');
  static const IconData check = IconData(0xe156, fontFamily: 'MaterialIcons');
  static const IconData check_box_outline_blank_rounded = IconData(0xf632, fontFamily: 'MaterialIcons');
  static const IconData check_box_rounded = IconData(0xf633, fontFamily: 'MaterialIcons');
  static const IconData check_circle = IconData(0xe159, fontFamily: 'MaterialIcons');
  static const IconData check_circle_outline = IconData(0xe15a, fontFamily: 'MaterialIcons');
  static const IconData chevron_left = IconData(0xe15e, fontFamily: 'MaterialIcons');
  static const IconData chevron_right = IconData(0xe15f, fontFamily: 'MaterialIcons');
  static const IconData circle = IconData(0xe163, fontFamily: 'MaterialIcons');
  static const IconData clear = IconData(0xe168, fontFamily: 'MaterialIcons');
  static const IconData close = IconData(0xe16a, fontFamily: 'MaterialIcons');
  static const IconData close_rounded = IconData(0xf647, fontFamily: 'MaterialIcons');
  static const IconData closed_caption = IconData(0xe16c, fontFamily: 'MaterialIcons');
  static const IconData cloud_download_outlined = IconData(0xef60, fontFamily: 'MaterialIcons');
  static const IconData cloud_off = IconData(0xe173, fontFamily: 'MaterialIcons');
  static const IconData cloud_outlined = IconData(0xef62, fontFamily: 'MaterialIcons');
  static const IconData cloud_sync_outlined = IconData(0xf05c9, fontFamily: 'MaterialIcons');
  static const IconData code = IconData(0xe176, fontFamily: 'MaterialIcons');
  static const IconData comment = IconData(0xe17e, fontFamily: 'MaterialIcons');
  static const IconData comments_disabled = IconData(0xf04d2, fontFamily: 'MaterialIcons');
  static const IconData computer_outlined = IconData(0xef74, fontFamily: 'MaterialIcons');
  static const IconData content_cut = IconData(0xe191, fontFamily: 'MaterialIcons');
  static const IconData content_cut_outlined = IconData(0xef80, fontFamily: 'MaterialIcons');
  static const IconData copy_all = IconData(0xe197, fontFamily: 'MaterialIcons');
  static const IconData crop_square_rounded = IconData(0xf68a, fontFamily: 'MaterialIcons');
  static const IconData delete_outline = IconData(0xe1bb, fontFamily: 'MaterialIcons');
  static const IconData delete_outline_rounded = IconData(0xf696, fontFamily: 'MaterialIcons');
  static const IconData delete_sweep_outlined = IconData(0xefab, fontFamily: 'MaterialIcons');
  static const IconData description_outlined = IconData(0xefae, fontFamily: 'MaterialIcons');
  static const IconData dns_outlined = IconData(0xefd4, fontFamily: 'MaterialIcons');
  static const IconData download = IconData(0xe201, fontFamily: 'MaterialIcons');
  static const IconData download_done = IconData(0xe202, fontFamily: 'MaterialIcons');
  static const IconData download_done_outlined = IconData(0xeff0, fontFamily: 'MaterialIcons');
  static const IconData download_done_rounded = IconData(0xf6dd, fontFamily: 'MaterialIcons');
  static const IconData download_outlined = IconData(0xeff2, fontFamily: 'MaterialIcons');
  static const IconData drag_indicator = IconData(0xe207, fontFamily: 'MaterialIcons');
  static const IconData edit_outlined = IconData(0xf00d, fontFamily: 'MaterialIcons');
  static const IconData error_outline = IconData(0xe238, fontFamily: 'MaterialIcons');
  static const IconData error_outline_rounded = IconData(0xf712, fontFamily: 'MaterialIcons');
  static const IconData expand_less = IconData(0xe245, fontFamily: 'MaterialIcons');
  static const IconData expand_more = IconData(0xe246, fontFamily: 'MaterialIcons');
  static const IconData explore = IconData(0xe248, fontFamily: 'MaterialIcons');
  static const IconData explore_outlined = IconData(0xf037, fontFamily: 'MaterialIcons');
  static const IconData extension_outlined = IconData(0xf03f, fontFamily: 'MaterialIcons');
  static const IconData file_download_outlined = IconData(0xf05b, fontFamily: 'MaterialIcons');
  static const IconData file_upload_outlined = IconData(0xf05d, fontFamily: 'MaterialIcons');
  static const IconData filter_none_rounded = IconData(0xf75c, fontFamily: 'MaterialIcons');
  static const IconData folder_open = IconData(0xe2a4, fontFamily: 'MaterialIcons');
  static const IconData folder_open_outlined = IconData(0xf090, fontFamily: 'MaterialIcons');
  static const IconData folder_outlined = IconData(0xf091, fontFamily: 'MaterialIcons');
  static const IconData fullscreen = IconData(0xe2cb, fontFamily: 'MaterialIcons');
  static const IconData fullscreen_exit = IconData(0xe2cc, fontFamily: 'MaterialIcons');
  static const IconData help_outline = IconData(0xe30b, fontFamily: 'MaterialIcons');
  static const IconData high_quality = IconData(0xe30f, fontFamily: 'MaterialIcons');
  static const IconData history = IconData(0xe314, fontFamily: 'MaterialIcons');
  static const IconData hourglass_top = IconData(0xe327, fontFamily: 'MaterialIcons');
  static const IconData hub_outlined = IconData(0xf0616, fontFamily: 'MaterialIcons');
  static const IconData inbox_outlined = IconData(0xf126, fontFamily: 'MaterialIcons');
  static const IconData info_outline = IconData(0xe33d, fontFamily: 'MaterialIcons');
  static const IconData keyboard_arrow_down = IconData(0xe353, fontFamily: 'MaterialIcons');
  static const IconData keyboard_arrow_up = IconData(0xe356, fontFamily: 'MaterialIcons');
  static const IconData keyboard_outlined = IconData(0xf144, fontFamily: 'MaterialIcons');
  static const IconData lan_outlined = IconData(0xf062c, fontFamily: 'MaterialIcons');
  static const IconData link = IconData(0xe380, fontFamily: 'MaterialIcons');
  static const IconData link_off = IconData(0xe381, fontFamily: 'MaterialIcons');
  static const IconData list = IconData(0xe384, fontFamily: 'MaterialIcons');
  static const IconData list_alt = IconData(0xe385, fontFamily: 'MaterialIcons');
  static const IconData list_alt_outlined = IconData(0xf16c, fontFamily: 'MaterialIcons');
  static const IconData live_tv = IconData(0xe387, fontFamily: 'MaterialIcons');
  static const IconData live_tv_outlined = IconData(0xf16f, fontFamily: 'MaterialIcons');
  static const IconData lock_outline = IconData(0xe3b1, fontFamily: 'MaterialIcons');
  static const IconData login = IconData(0xe3b2, fontFamily: 'MaterialIcons');
  static const IconData monitor_heart_outlined = IconData(0xf0635, fontFamily: 'MaterialIcons');
  static const IconData more_horiz = IconData(0xe402, fontFamily: 'MaterialIcons');
  static const IconData more_vert = IconData(0xe404, fontFamily: 'MaterialIcons');
  static const IconData movie_outlined = IconData(0xf1f5, fontFamily: 'MaterialIcons');
  static const IconData network_check = IconData(0xe424, fontFamily: 'MaterialIcons');
  static const IconData notifications = IconData(0xe44f, fontFamily: 'MaterialIcons');
  static const IconData notifications_active = IconData(0xe450, fontFamily: 'MaterialIcons');
  static const IconData notifications_none = IconData(0xe451, fontFamily: 'MaterialIcons');
  static const IconData open_in_new = IconData(0xe45c, fontFamily: 'MaterialIcons');
  static const IconData palette_outlined = IconData(0xf24f, fontFamily: 'MaterialIcons');
  static const IconData password = IconData(0xe47a, fontFamily: 'MaterialIcons');
  static const IconData pause = IconData(0xe47c, fontFamily: 'MaterialIcons');
  static const IconData pause_circle_outline = IconData(0xe47f, fontFamily: 'MaterialIcons');
  static const IconData person_off_outlined = IconData(0xf279, fontFamily: 'MaterialIcons');
  static const IconData person_outline = IconData(0xe497, fontFamily: 'MaterialIcons');
  static const IconData photo_camera = IconData(0xe4b6, fontFamily: 'MaterialIcons');
  static const IconData picture_in_picture_alt = IconData(0xe4c2, fontFamily: 'MaterialIcons');
  static const IconData picture_in_picture_alt_outlined = IconData(0xf2a5, fontFamily: 'MaterialIcons');
  static const IconData pin_outlined = IconData(0xf2aa, fontFamily: 'MaterialIcons');
  static const IconData play_arrow = IconData(0xe4cb, fontFamily: 'MaterialIcons');
  static const IconData play_arrow_rounded = IconData(0xf00a0, fontFamily: 'MaterialIcons');
  static const IconData play_circle_fill = IconData(0xe4cd, fontFamily: 'MaterialIcons');
  static const IconData play_circle_outline = IconData(0xe4ce, fontFamily: 'MaterialIcons');
  static const IconData playlist_add_check = IconData(0xe4d3, fontFamily: 'MaterialIcons');
  static const IconData playlist_add_check_circle_outlined = IconData(0xf0646, fontFamily: 'MaterialIcons');
  static const IconData radio_button_checked = IconData(0xe503, fontFamily: 'MaterialIcons');
  static const IconData radio_button_unchecked = IconData(0xe504, fontFamily: 'MaterialIcons');
  static const IconData receipt_long_outlined = IconData(0xf2ef, fontFamily: 'MaterialIcons');
  static const IconData refresh = IconData(0xe514, fontFamily: 'MaterialIcons');
  static const IconData remove = IconData(0xe516, fontFamily: 'MaterialIcons');
  static const IconData remove_rounded = IconData(0xf00f1, fontFamily: 'MaterialIcons');
  static const IconData reorder = IconData(0xe51e, fontFamily: 'MaterialIcons');
  static const IconData save_alt = IconData(0xe551, fontFamily: 'MaterialIcons');
  static const IconData schedule = IconData(0xe556, fontFamily: 'MaterialIcons');
  static const IconData search = IconData(0xe567, fontFamily: 'MaterialIcons');
  static const IconData search_off = IconData(0xe568, fontFamily: 'MaterialIcons');
  static const IconData search_outlined = IconData(0xf34b, fontFamily: 'MaterialIcons');
  static const IconData search_rounded = IconData(0xf013d, fontFamily: 'MaterialIcons');
  static const IconData settings = IconData(0xe57f, fontFamily: 'MaterialIcons');
  static const IconData settings_outlined = IconData(0xf36e, fontFamily: 'MaterialIcons');
  static const IconData skip_next = IconData(0xe5bd, fontFamily: 'MaterialIcons');
  static const IconData skip_previous = IconData(0xe5be, fontFamily: 'MaterialIcons');
  static const IconData speed = IconData(0xe5e0, fontFamily: 'MaterialIcons');
  static const IconData star = IconData(0xe5f9, fontFamily: 'MaterialIcons');
  static const IconData star_border = IconData(0xe5fa, fontFamily: 'MaterialIcons');
  static const IconData star_border_rounded = IconData(0xf01cf, fontFamily: 'MaterialIcons');
  static const IconData star_rounded = IconData(0xf01d4, fontFamily: 'MaterialIcons');
  static const IconData stop = IconData(0xe606, fontFamily: 'MaterialIcons');
  static const IconData storage_outlined = IconData(0xf3ec, fontFamily: 'MaterialIcons');
  static const IconData subdirectory_arrow_right = IconData(0xe615, fontFamily: 'MaterialIcons');
  static const IconData subtitles_outlined = IconData(0xf3fd, fontFamily: 'MaterialIcons');
  static const IconData swap_horiz = IconData(0xe625, fontFamily: 'MaterialIcons');
  static const IconData sync = IconData(0xe62f, fontFamily: 'MaterialIcons');
  static const IconData system_update_alt = IconData(0xe637, fontFamily: 'MaterialIcons');
  static const IconData tips_and_updates_outlined = IconData(0xf0681, fontFamily: 'MaterialIcons');
  static const IconData touch_app_outlined = IconData(0xf453, fontFamily: 'MaterialIcons');
  static const IconData travel_explore = IconData(0xe67c, fontFamily: 'MaterialIcons');
  static const IconData travel_explore_outlined = IconData(0xf45f, fontFamily: 'MaterialIcons');
  static const IconData tune = IconData(0xe683, fontFamily: 'MaterialIcons');
  static const IconData tv = IconData(0xe687, fontFamily: 'MaterialIcons');
  static const IconData tv_off = IconData(0xe688, fontFamily: 'MaterialIcons');
  static const IconData volume_down = IconData(0xe6c2, fontFamily: 'MaterialIcons');
  static const IconData volume_off = IconData(0xe6c4, fontFamily: 'MaterialIcons');
  static const IconData volume_off_outlined = IconData(0xf4a7, fontFamily: 'MaterialIcons');
  static const IconData volume_up = IconData(0xe6c5, fontFamily: 'MaterialIcons');
  static const IconData volume_up_outlined = IconData(0xf4a8, fontFamily: 'MaterialIcons');
  static const IconData warning_amber = IconData(0xe6cc, fontFamily: 'MaterialIcons');
  static const IconData warning_amber_outlined = IconData(0xf4ae, fontFamily: 'MaterialIcons');
  static const IconData wifi_off = IconData(0xe6eb, fontFamily: 'MaterialIcons');
  static const IconData wifi_tethering = IconData(0xe6ed, fontFamily: 'MaterialIcons');
  static const IconData zoom_in_map = IconData(0xf05af, fontFamily: 'MaterialIcons');
}
