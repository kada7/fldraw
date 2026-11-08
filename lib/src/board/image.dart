import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

final _svgImages = Expando<Future<(Size, Uint8List)>>();
Future<(Size, Uint8List)> _svgImage(Uint8List bytes) =>
    _svgImages[bytes] ??= (() async {
      _localSvg(bytes);
      final picture = await vg.loadPicture(SvgBytesLoader(bytes), null);
      try {
        final size = picture.size;
        if (size.width <= 0 || size.height <= 0) {
          throw const FormatException('SVG size is empty');
        }
        final scale = math.min(1.0, 4096 / math.max(size.width, size.height));
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..scale(scale);
        canvas.drawPicture(picture.picture);
        final scaled = recorder.endRecording();
        final image = await scaled.toImage(
          math.max(1, (size.width * scale).ceil()),
          math.max(1, (size.height * scale).ceil()),
        );
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          if (png == null) throw StateError('SVG rasterization failed');
          return (size, png.buffer.asUint8List());
        } finally {
          image.dispose();
          scaled.dispose();
        }
      } finally {
        picture.picture.dispose();
      }
    })();

bool isBoardSvg(Uint8List bytes, [String? mime]) =>
    mime == 'image/svg+xml' ||
    utf8
        .decode(bytes.take(512).toList(), allowMalformed: true)
        .contains('<svg');

void _localSvg(Uint8List bytes) {
  final text = utf8.decode(bytes);
  if (RegExp(
    r'''(?:href|src)\s*=\s*["']\s*(?:https?:|file:|//)''',
    caseSensitive: false,
  ).hasMatch(text)) {
    throw const FormatException('SVG 图片须包含自身使用的资源');
  }
}

Future<Size> boardImageSize(Uint8List bytes, {String? mime}) async {
  if (isBoardSvg(bytes, mime)) {
    return (await _svgImage(bytes)).$1;
  }
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      return Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

Future<void> prepareBoardImage(
  BuildContext context,
  Uint8List bytes, {
  String? mime,
}) async {
  if (isBoardSvg(bytes, mime)) {
    final png = (await _svgImage(bytes)).$2;
    if (!context.mounted) return;
    await prepareBoardImage(context, png, mime: 'image/png');
    return;
  }
  Object? failure;
  await precacheImage(
    MemoryImage(bytes),
    context,
    onError: (error, stack) => failure = error,
  );
  if (failure != null) throw StateError('图片无法读取：$failure');
}

class BoardImage extends StatelessWidget {
  final Uint8List bytes;
  final String? mime;
  const BoardImage({super.key, required this.bytes, this.mime});
  @override
  Widget build(BuildContext context) {
    Widget error() => const Center(child: Icon(Icons.broken_image_outlined));
    if (isBoardSvg(bytes, mime)) {
      return FutureBuilder<(Size, Uint8List)>(
        future: _svgImage(bytes),
        builder: (context, snapshot) {
          if (snapshot.hasError) return error();
          final png = snapshot.data?.$2;
          return png == null
              ? const SizedBox.shrink()
              : Image.memory(
                  png,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => error(),
                );
        },
      );
    }
    return Image.memory(
      bytes,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => error(),
    );
  }
}
