import 'dart:math' as math;

class LayoutHelper {
  static double getBaseSize(double photoWidth, double photoHeight) =>
      math.min(photoWidth, photoHeight);

  static double padding(double baseSize, {double ratio = 0.04}) =>
      baseSize * ratio;

  static double fontSize(double baseSize, {double ratio = 0.028}) =>
      baseSize * ratio;

  static double lineHeight(double baseSize, {double ratio = 0.045}) =>
      baseSize * ratio;

  static double logoSize(double baseSize, {double ratio = 0.15}) =>
      baseSize * ratio;
}
