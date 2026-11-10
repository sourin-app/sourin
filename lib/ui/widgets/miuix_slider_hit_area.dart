import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Gives the native Miuix slider a slim visual track and a full-height target.
/// Pointer dispatch remains with Miuix's tap/drag recognizers. Only the hit-test
/// probe's vertical coordinate is clamped; the event's horizontal position and
/// transform are unchanged, preserving its native value and gesture handling.
class MiuixSliderHitArea extends SingleChildRenderObjectWidget {
  const MiuixSliderHitArea({
    super.key,
    required this.height,
    required this.trackHeight,
    required super.child,
  }) : assert(height >= trackHeight && trackHeight > 0);

  final double height;
  final double trackHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSliderHitArea(height, trackHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSliderHitArea renderObject,
  ) => renderObject.updateDimensions(height, trackHeight);
}

class _RenderSliderHitArea extends RenderShiftedBox {
  _RenderSliderHitArea(this._height, this._trackHeight) : super(null);
  double _height;
  double _trackHeight;

  void updateDimensions(double height, double trackHeight) {
    if (_height == height && _trackHeight == trackHeight) return;
    _height = height;
    _trackHeight = trackHeight;
    markNeedsLayout();
  }

  BoxConstraints _trackConstraints(BoxConstraints constraints) =>
      constraints.copyWith(
        minWidth: constraints.hasBoundedWidth
            ? constraints.maxWidth
            : constraints.minWidth,
        minHeight: _trackHeight,
        maxHeight: _trackHeight,
      );

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(_trackConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(Size(child.size.width, _height));
    (child.parentData! as BoxParentData).offset = Offset(
      0,
      (size.height - child.size.height) / 2,
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childSize = child!.getDryLayout(_trackConstraints(constraints));
    return constraints.constrain(Size(childSize.width, _height));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child!;
    final offset = (child.parentData! as BoxParentData).offset;
    return result.addWithPaintOffset(
      offset: offset,
      position: position,
      hitTest: (result, local) => child.hitTest(
        result,
        position: Offset(
          local.dx,
          local.dy.clamp(0.0, child.size.height - precisionErrorTolerance),
        ),
      ),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child!;
    context.paintChild(
      child,
      offset + (child.parentData! as BoxParentData).offset,
    );
  }
}
