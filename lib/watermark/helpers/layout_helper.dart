import 'dart:math' as math;

class LayoutHelper {
  static double getBaseSize(double photoWidth, double photoHeight) =>
      math.min(photoWidth, photoHeight);

  static double padding(double baseSize, {double ratio = 0.04}) =>
      baseSize * ratio;

  // 🔥 FONT LEBIH BESAR (dari 0.028 → 0.038)
  static double fontSize(double baseSize, {double ratio = 0.038}) =>
      baseSize * ratio;

  // 🔥 SPASI LEBIH LEGA (dari 0.045 → 0.055)
  static double lineHeight(double baseSize, {double ratio = 0.055}) =>
      baseSize * ratio;

  static double logoSize(double baseSize, {double ratio = 0.15}) =>
      baseSize * ratio;
}
