import 'dart:math' as math;

import 'package:flutter/material.dart';

enum BoardTool { select, pencil, eraser, rectangle, ellipse, line, arrow, text }

enum BoardDash { solid, dashed, dotted }

dynamic _freeze(dynamic value) => switch (value) {
  Map map => Map<String, dynamic>.unmodifiable({
    for (final e in map.entries) e.key as String: _freeze(e.value),
  }),
  List list => List<dynamic>.unmodifiable(list.map(_freeze)),
  null || String() || bool() || num() => value,
  _ => throw const FormatException('Custom canvas data must be JSON'),
};

double _number(Object? value) {
  if (value is! num || !value.isFinite || value.abs() > 10000000) {
    throw const FormatException('Invalid canvas coordinate');
  }
  return value.toDouble();
}

Offset readBoardPoint(dynamic value) {
  if (value is! List || value.length != 2) {
    throw const FormatException('Invalid canvas point');
  }
  return Offset(_number(value[0]), _number(value[1]));
}

class BoardStyle {
  final Color stroke, fill;
  final double width, fontSize;
  final BoardDash dash;
  final bool bold, italic;
  final TextAlign align;
  const BoardStyle({
    this.stroke = const Color(0xff303846),
    this.fill = const Color(0x00ffffff),
    this.width = 2,
    this.fontSize = 20,
    this.dash = BoardDash.solid,
    this.bold = false,
    this.italic = false,
    this.align = TextAlign.left,
  });
  BoardStyle copyWith({
    Color? stroke,
    Color? fill,
    double? width,
    double? fontSize,
    BoardDash? dash,
    bool? bold,
    bool? italic,
    TextAlign? align,
  }) => BoardStyle(
    stroke: stroke ?? this.stroke,
    fill: fill ?? this.fill,
    width: width ?? this.width,
    fontSize: fontSize ?? this.fontSize,
    dash: dash ?? this.dash,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    align: align ?? this.align,
  );
  Map<String, dynamic> toJson() => {
    'stroke': stroke.toARGB32(),
    'fill': fill.toARGB32(),
    'width': width,
    'fontSize': fontSize,
    'dash': dash.name,
    'bold': bold,
    'italic': italic,
    'align': align.name,
  };
  factory BoardStyle.fromJson(Map value) {
    final width = _number(value['width'] ?? 2);
    final size = _number(value['fontSize'] ?? 20);
    if (width <= 0 || width > 100 || size < 6 || size > 256) {
      throw const FormatException('Invalid canvas style');
    }
    return BoardStyle(
      stroke: Color(value['stroke'] as int? ?? 0xff303846),
      fill: Color(value['fill'] as int? ?? 0x00ffffff),
      width: width,
      fontSize: size,
      dash: BoardDash.values.byName(value['dash'] as String? ?? 'solid'),
      bold: value['bold'] as bool? ?? false,
      italic: value['italic'] as bool? ?? false,
      align: TextAlign.values.byName(value['align'] as String? ?? 'left'),
    );
  }
}

class BoardAnchor {
  final String objectId;
  final Offset relative;
  const BoardAnchor(this.objectId, this.relative);
  Map<String, dynamic> toJson() => {
    'id': objectId,
    'relative': [relative.dx, relative.dy],
  };
  factory BoardAnchor.fromJson(Map value) =>
      BoardAnchor(value['id'] as String, readBoardPoint(value['relative']));
}

/// All objects share ordering, geometry, style, history, and serialization.
/// Custom payloads are owned by the host and must be JSON values.
class BoardObject {
  final String id, type, text;
  final Rect rect;
  final List<Offset> points;
  final BoardStyle style;
  final Map<String, dynamic> data;
  final BoardAnchor? start, end;
  BoardObject({
    required this.id,
    required this.type,
    required this.rect,
    this.text = '',
    List<Offset> points = const [],
    this.style = const BoardStyle(),
    Map<String, dynamic> data = const {},
    this.start,
    this.end,
  }) : points = List.unmodifiable(points),
       data = _freeze(data) as Map<String, dynamic>;

  BoardObject copyWith({
    Rect? rect,
    List<Offset>? points,
    String? text,
    BoardStyle? style,
    Map<String, dynamic>? data,
    BoardAnchor? start,
    BoardAnchor? end,
  }) => BoardObject(
    id: id,
    type: type,
    rect: rect ?? this.rect,
    text: text ?? this.text,
    points: points ?? this.points,
    style: style ?? this.style,
    data: data ?? this.data,
    start: start ?? this.start,
    end: end ?? this.end,
  );

  BoardObject transformed(Rect target) {
    final sx = target.width / math.max(rect.width, .001);
    final sy = target.height / math.max(rect.height, .001);
    return copyWith(
      rect: target,
      points: points
          .map(
            (p) => Offset(
              target.left + (p.dx - rect.left) * sx,
              target.top + (p.dy - rect.top) * sy,
            ),
          )
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'rect': [rect.left, rect.top, rect.width, rect.height],
    'points': [
      for (final p in points) [p.dx, p.dy],
    ],
    'text': text,
    'style': style.toJson(),
    'data': data,
    if (start != null) 'start': start!.toJson(),
    if (end != null) 'end': end!.toJson(),
  };
  factory BoardObject.fromJson(Map value) {
    final r = value['rect'];
    final type = value['type'];
    if (value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        !{
          'rectangle',
          'ellipse',
          'pencil',
          'line',
          'arrow',
          'text',
          'image',
          'custom',
        }.contains(type) ||
        r is! List ||
        r.length != 4) {
      throw const FormatException('Invalid canvas object');
    }
    final rect = Rect.fromLTWH(
      _number(r[0]),
      _number(r[1]),
      _number(r[2]),
      _number(r[3]),
    );
    if (rect.width <= 0 || rect.height <= 0) {
      throw const FormatException('Invalid canvas size');
    }
    final points = [
      for (final p in value['points'] as List? ?? []) readBoardPoint(p),
    ];
    if (['line', 'arrow', 'pencil'].contains(type) && points.isEmpty) {
      throw const FormatException('Missing canvas path');
    }
    return BoardObject(
      id: value['id'] as String,
      type: type as String,
      rect: rect,
      points: points,
      text: value['text'] as String? ?? '',
      style: BoardStyle.fromJson(value['style'] as Map? ?? {}),
      data: Map<String, dynamic>.from(value['data'] as Map? ?? {}),
      start: value['start'] == null
          ? null
          : BoardAnchor.fromJson(value['start'] as Map),
      end: value['end'] == null
          ? null
          : BoardAnchor.fromJson(value['end'] as Map),
    );
  }
}

class BoardDocument {
  final List<BoardObject> objects;
  final Offset offset;
  final double zoom;
  BoardDocument({
    List<BoardObject> objects = const [],
    this.offset = Offset.zero,
    this.zoom = 1,
  }) : objects = List.unmodifiable(objects);
  BoardDocument copyWith({
    List<BoardObject>? objects,
    Offset? offset,
    double? zoom,
  }) => BoardDocument(
    objects: objects ?? this.objects,
    offset: offset ?? this.offset,
    zoom: zoom ?? this.zoom,
  );
  Map<String, dynamic> toJson() => {
    'schema': 1,
    'objects': objects.map((o) => o.toJson()).toList(),
    'viewport': {
      'offset': [offset.dx, offset.dy],
      'zoom': zoom,
    },
  };
  factory BoardDocument.fromJson(Map value) {
    if (value['schema'] != 1 || value['objects'] is! List) {
      throw const FormatException('Unsupported fldraw document');
    }
    final objects = [
      for (final o in value['objects'] as List) BoardObject.fromJson(o as Map),
    ];
    if (objects.map((o) => o.id).toSet().length != objects.length) {
      throw const FormatException('Duplicate canvas object');
    }
    final viewport = value['viewport'] as Map? ?? {};
    final zoom = _number(viewport['zoom'] ?? 1);
    if (zoom < .05 || zoom > 16) {
      throw const FormatException('Invalid canvas zoom');
    }
    return BoardDocument(
      objects: objects,
      zoom: zoom,
      offset: readBoardPoint(viewport['offset'] ?? [0, 0]),
    );
  }
  BoardObject resolved(BoardObject object) {
    if (!['arrow', 'line'].contains(object.type) || object.points.length < 2) {
      return object;
    }
    Offset endpoint(BoardAnchor? anchor, Offset fallback) {
      if (anchor == null) return fallback;
      final target = objects.where((o) => o.id == anchor.objectId).firstOrNull;
      if (target == null) return fallback;
      return target.rect.topLeft +
          Offset(
            target.rect.width * anchor.relative.dx,
            target.rect.height * anchor.relative.dy,
          );
    }

    final points = [
      endpoint(object.start, object.points.first),
      endpoint(object.end, object.points.last),
    ];
    return object.copyWith(points: points, rect: boundsOfPoints(points));
  }

  Rect get bounds => objects.isEmpty
      ? const Rect.fromLTWH(0, 0, 1, 1)
      : objects
            .map(
              (o) => resolved(o).rect.inflate(
                o.type == 'arrow' ? o.style.width * 2 + 12 : o.style.width + 8,
              ),
            )
            .reduce((a, b) => a.expandToInclude(b));
}

Rect boundsOfPoints(List<Offset> points) {
  var rect = Rect.fromLTWH(points.first.dx, points.first.dy, .01, .01);
  for (final p in points.skip(1)) {
    rect = rect.expandToInclude(Rect.fromLTWH(p.dx, p.dy, .01, .01));
  }
  return rect;
}
