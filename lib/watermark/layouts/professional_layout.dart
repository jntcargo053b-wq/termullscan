// ========== PAINT WATERMARK ONLY (UNTUK VIDEO OVERLAY) ==========
@override
void paintWatermarkOnly({
  required ui.Canvas canvas,
  required LayoutMetrics metrics,
  required ui.Image? logoImage,
  required WatermarkData data,
}) {
  final padding = metrics.padding;
  final baseSize = metrics.baseSize;
  final overlayHeight = metrics.stripHeight;
  final photoWidth = metrics.canvasWidth;
  final photoHeight = metrics.canvasHeight;
  double overlayTop;
  TextAlign textAlign;
  final bool overlayAtBottom;

  switch (data.position) {
    case WatermarkPosition.bottomRight:
      overlayTop = photoHeight - overlayHeight;
      textAlign = TextAlign.right;
      overlayAtBottom = true;
      break;
    case WatermarkPosition.bottomLeft:
      overlayTop = photoHeight - overlayHeight;
      textAlign = TextAlign.left;
      overlayAtBottom = true;
      break;
    case WatermarkPosition.topRight:
      overlayTop = 0;
      textAlign = TextAlign.right;
      overlayAtBottom = false;
      break;
    case WatermarkPosition.topLeft:
      overlayTop = 0;
      textAlign = TextAlign.left;
      overlayAtBottom = false;
      break;
    default:
      overlayTop = photoHeight - overlayHeight;
      textAlign = TextAlign.right;
      overlayAtBottom = true;
  }

  // Background gradien
  final gradientPaint = Paint()
    ..shader = ui.Gradient.linear(
      Offset(0, overlayTop),
      Offset(0, overlayTop + overlayHeight),
      overlayAtBottom
          ? [
              Colors.black.withOpacity(0.0),
              Colors.black.withOpacity(data.backgroundOpacity * 0.55),
              Colors.black.withOpacity(data.backgroundOpacity),
            ]
          : [
              Colors.black.withOpacity(data.backgroundOpacity),
              Colors.black.withOpacity(data.backgroundOpacity * 0.55),
              Colors.black.withOpacity(0.0),
            ],
      overlayAtBottom ? [0.0, 0.45, 1.0] : [0.0, 0.55, 1.0],
    );
  canvas.drawRect(
    Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight),
    gradientPaint,
  );

  final dividerY = overlayAtBottom ? overlayTop : overlayTop + overlayHeight;
  canvas.drawLine(
    Offset(0, dividerY),
    Offset(photoWidth, dividerY),
    Paint()
      ..color = Colors.white.withOpacity(0.10)
      ..strokeWidth = 1,
  );

  final logoMaxSize = metrics.logoMaxSize;
  final accentBarW = math.max(2.0, baseSize * 0.004);
  final accentBarSpace = accentBarW + padding * 0.5;
  final logoReserve = (logoImage != null) ? logoMaxSize + padding * 1.4 : 0.0;
  final textContentWidth = photoWidth - padding * 2 - logoReserve - accentBarSpace;

  final double textX = textAlign == TextAlign.left
      ? padding + accentBarSpace
      : photoWidth - padding - textContentWidth;
  double textY = overlayTop + padding * 0.95;

  final barX = textAlign == TextAlign.left
      ? padding
      : photoWidth - padding - accentBarW;
  final barcodeBonus = data.hasBarcode
      ? (WatermarkTypography.lineHeight(WatermarkTypography.barcode(data.fontSize)) -
          metrics.lineHeight)
      : 0.0;
  final textBlockHeight =
      metrics.textRowCount * metrics.lineHeight + barcodeBonus;
  canvas.drawRect(
    Rect.fromLTWH(
      barX,
      overlayTop + padding * 0.85,
      accentBarW,
      textBlockHeight,
    ),
    Paint()..color = const Color(0xFF4FA8E8).withOpacity(0.9),
  );

  void drawLabelValue(String label, String value, Color valueColor, {bool emphasize = false}) {
    final valueFontSize = emphasize
        ? WatermarkTypography.barcode(data.fontSize)
        : WatermarkTypography.body(data.fontSize);
    final rowLineHeight = emphasize
        ? WatermarkTypography.lineHeight(valueFontSize)
        : metrics.lineHeight;

    TextHelper.paintText(
      canvas: canvas,
      text: _spaceOutLabel(label),
      x: textX,
      y: textY,
      maxWidth: textContentWidth,
      color: Colors.white.withOpacity(0.45),
      fontSize: WatermarkTypography.caption(data.fontSize),
      fontWeight: FontWeight.w700,
      maxLines: 1,
      textAlign: textAlign,
      fontFamily: data.fontFamily,
    );
    TextHelper.paintText(
      canvas: canvas,
      text: value,
      x: textX,
      y: textY + valueFontSize * 0.78,
      maxWidth: textContentWidth,
      color: valueColor,
      fontSize: valueFontSize,
      fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
      maxLines: 1,
      textAlign: textAlign,
      fontFamily: data.fontFamily,
    );
    textY += rowLineHeight;
  }

  if (data.hasBarcode) {
    drawLabelValue('KODE BARANG', data.barcodeValue ?? '', Colors.white, emphasize: true);
  }
  if (data.hasOperator) {
    drawLabelValue('OPERATOR', data.operatorName, Colors.white.withOpacity(0.92));
  }
  drawLabelValue('WAKTU', data.formattedTimestamp, Colors.white.withOpacity(0.80));
  drawLabelValue('LOKASI', data.displayLocation, Colors.white.withOpacity(0.70));

  // Logo
  if (logoImage != null) {
    final logoMaxH = logoMaxSize;
    final logoW = logoImage.width.toDouble();
    final logoH = logoImage.height.toDouble();
    final scale = math.min(logoMaxH / logoW, logoMaxH / logoH);
    final drawW = logoW * scale;
    final drawH = logoH * scale;
    double logoX = textAlign == TextAlign.left
        ? photoWidth - padding - drawW
        : padding;
    double logoY = overlayAtBottom
        ? photoHeight - padding - drawH
        : padding;

    final cardPad = drawW * 0.25;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          logoX - cardPad,
          logoY - cardPad,
          drawW + cardPad * 2,
          drawH + cardPad * 2,
        ),
        Radius.circular(cardPad * 0.8),
      ),
      Paint()..color = Colors.black.withOpacity(0.35),
    );
    LogoWidget.paint(
      canvas: canvas,
      logoImage: logoImage,
      x: logoX,
      y: logoY,
      maxWidth: drawW,
      maxHeight: drawH,
      opacity: 1.0,
    );
  }
}
