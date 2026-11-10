import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../app_scaffold.dart';
import '../tokens.dart';
import 'app_page_header.dart';

/// Shared Miuix header, back behavior and content spacing for settings pages.
class SettingsSubPage extends StatelessWidget {
  const SettingsSubPage({
    super.key,
    required this.title,
    required this.subtitle,
    this.children = const [],
    this.pinnedHeader,
    this.scrollBody,
    this.onBack,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final Widget? pinnedHeader;
  final Widget? scrollBody;

  /// Return true when an inner search/selection layer consumed the back action.
  final bool Function(BuildContext context)? onBack;

  void _back(BuildContext context) {
    if (onBack?.call(context) ?? false) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final inset = Layout.horizontalInsetOf(context);
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.goBack)) {
          _back(context);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AppScaffold(
        header: Padding(
          padding: inset,
          child: AppPageHeader(
            title: title,
            subtitle: subtitle,
            onBack: () => _back(context),
          ),
        ),
        child: Padding(
          padding: inset,
          child: scrollBody == null
              ? CustomScrollView(
                  slivers: [
                    const SliverToBoxAdapter(child: SizedBox(height: Sp.x3)),
                    SliverList(delegate: SliverChildListDelegate(children)),
                    SliverToBoxAdapter(
                      child: SizedBox(height: Sp.bottomBarInset),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: Sp.x3),
                    if (pinnedHeader != null) ...[
                      pinnedHeader!,
                      const SizedBox(height: Sp.x3),
                    ],
                    Expanded(child: scrollBody!),
                  ],
                ),
        ),
      ),
    );
  }
}
