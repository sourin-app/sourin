import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'motion_prefs.dart';
import 'page_transition.dart';
import 'settings_kit.dart';
import 'settings_sub_page.dart';

/// Uses the same transition implementation as tabs and pushed pages.
class SettingsMotionPanel extends StatefulWidget {
  const SettingsMotionPanel({super.key});

  @override
  State<SettingsMotionPanel> createState() => _SettingsMotionPanelState();
}

class _SettingsMotionPanelState extends State<SettingsMotionPanel>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: Motion.base,
    value: 1,
  );
  late final _curved = CurvedAnimation(
    parent: _animation,
    curve: Motion.easeOut,
  );

  void _preview() {
    if (MotionPrefs.resolvedCurrent(context) == PageTransitionStyle.none) {
      _animation.value = 1;
    } else {
      _animation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<PageTransitionStyle>(
        valueListenable: PageTransitionStyleStore.current,
        builder: (context, style, _) {
          final colors = Theme.of(context).colorScheme;
          final reduced = MotionPrefs.reduce(context);
          return SettingsBlock(
            title: '动画效果',
            children: [
              SettingsGestureChoice<PageTransitionStyle>(
                label: '页面切换动画',
                options: PageTransition.options,
                value: style,
                labelOf: (s) => s.label,
                onChanged: (s) {
                  PageTransitionStyleStore.set(s);
                  _preview();
                },
              ),
              const SizedBox(height: Sp.x3),
              Text(
                reduced ? '系统已关闭动态效果。开启系统动画后，所选风格会自动生效。' : style.hint,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Sp.x4),
              ClipRect(
                child: SizedBox(
                  height: Sp.x16 + Sp.x8,
                  width: double.infinity,
                  child: AnimatedBuilder(
                    animation: _curved,
                    builder: (context, child) => PageTransition.apply(
                      animation: _curved,
                      style: MotionPrefs.resolve(context, style),
                      child: child!,
                    ),
                    child: Container(
                      key: const ValueKey('motion-preview-card'),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: Radii.rLg,
                      ),
                      child: Text(
                        style.label,
                        style: TextStyle(
                          color: colors.onPrimaryContainer,
                          fontSize: FontSizes.lg,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Sp.x3),
              Wrap(
                spacing: Sp.x3,
                runSpacing: Sp.x2,
                children: [
                  SettingsGesturePill(
                    text: '再次预览',
                    selected: false,
                    onTap: _preview,
                  ),
                  SettingsGesturePill(
                    text: '试试页面切换',
                    selected: false,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => const Scaffold(
                          body: SettingsSubPage(
                            title: '动画预览',
                            subtitle: '返回时也会使用当前动画',
                            children: [Text('页面切换使用你选择的风格。')],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
}
