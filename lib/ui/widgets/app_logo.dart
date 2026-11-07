import 'package:flutter/widgets.dart';

import '../../core/app_logo.dart';
import '../tokens.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = Sp.x6});
  final double size;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppLogoStyle>(
    valueListenable: AppLogoPreference.current,
    builder: (context, style, _) => Image.asset(
      style.imageAsset,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: '源影 · ${style.label}',
    ),
  );
}
