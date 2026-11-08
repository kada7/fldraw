import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import 'controller.dart';
import 'model.dart';
import 'image.dart';

typedef BoardNodeBuilder =
    Widget Function(BuildContext context, BoardObject object, bool exporting);

class BoardView extends StatefulWidget {
  final BoardController controller;
  final BoardNodeBuilder? nodeBuilder;
  final bool readOnly;
  final VoidCallback? onInspect;
  const BoardView({
    super.key,
    required this.controller,
    this.nodeBuilder,
    this.readOnly = false,
    this.onInspect,
  });
  @override
  State<BoardView> createState() => BoardViewState();
}

class BoardViewState extends State<BoardView> {
  BoardController get c => widget.controller;
  final _pointers = <int, Offset>{};
  final _focus = FocusNode();
  Offset? _start, _screenStart;
  BoardDocument? _before;
  String? _action;
  BoardObject? _draft;
  List<Offset> _ink = [];
  bool _blocked = false, _capturing = false;
  Offset _pinchFocus = Offset.zero, _pinchOffset = Offset.zero;
  double _pinchDistance = 1, _pinchZoom = 1;
  BoardAnchor? _anchor;
  late BoardTool _tool;
  final _images = <String, Uint8List>{};
  Uint8List _image(BoardObject object) {
    final encoded = object.data['bytes'] as String;
    return _images.putIfAbsent(encoded, () => base64Decode(encoded));
  }

  @override
  void initState() {
    super.initState();
    _tool = c.tool;
    c.addListener(_changed);
  }

  @override
  void didUpdateWidget(BoardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_changed);
      c.addListener(_changed);
    }
  }

  void _changed() {
    if (_tool != c.tool) {
      _tool = c.tool;
      _action = null;
      _draft = null;
      _blocked = _pointers.isNotEmpty;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  Offset world(Offset local) => (local - c.document.offset) / c.document.zoom;
  bool _content(BoardObject? o, Offset point) =>
      o?.type == 'custom' &&
      point.dy > o!.rect.top + 48 &&
      point.dx > o.rect.left + 10 &&
      point.dx < o.rect.right - 10 &&
      point.dy < o.rect.bottom - 10;

  void _down(PointerDownEvent event) {
    if (widget.readOnly || _capturing) return;
    _focus.requestFocus();
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      c.interacting = true;
      c.cancelGesture();
      _draft = null;
      _action = null;
      _blocked = true;
      final p = _pointers.values.take(2).toList();
      _pinchFocus = (p[0] + p[1]) / 2;
      _pinchDistance = math.max(1, (p[0] - p[1]).distance);
      _pinchZoom = c.document.zoom;
      _pinchOffset = c.document.offset;
      setState(() {});
      return;
    }
    if (_pointers.length != 1 || _blocked) return;
    _start = world(event.localPosition);
    _screenStart = event.localPosition;
    _before = c.document;
    final hit = c.hit(_start!, tolerance: 8 / c.document.zoom);
    if (event.buttons == kMiddleMouseButton) {
      c.interacting = true;
      _action = 'pan';
      return;
    }
    if (c.tool == BoardTool.select) {
      final selected = c.selected;
      if (selected.isNotEmpty) {
        final r = selected
            .map((o) => c.document.resolved(o).rect)
            .reduce((a, b) => a.expandToInclude(b));
        if ((_start! - r.bottomRight).distance * c.document.zoom < 22) {
          _action = 'resize';
          c.interacting = true;
          c.beginGesture();
          return;
        }
      }
      if (hit == null) {
        if (c.multiSelect || HardwareKeyboard.instance.isShiftPressed) {
          _action = 'marquee';
        } else {
          c.select([]);
          _action = 'pan';
          c.interacting = true;
        }
      } else {
        if (c.multiSelect ||
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) {
          c.select([hit.id], toggle: true);
          return;
        }
        if (!c.selection.contains(hit.id)) c.select([hit.id]);
        if (_content(hit, _start!)) return;
        _action = 'move';
        c.interacting = true;
        c.beginGesture();
      }
      return;
    }
    if (c.tool == BoardTool.eraser) {
      _action = 'erase';
      c.interacting = true;
      c.beginGesture();
      _erase(_start!);
      return;
    }
    if (c.tool == BoardTool.text) {
      _editText(_start!);
      return;
    }
    _action = 'draw';
    c.interacting = true;
    _ink = [_start!];
    _anchor = c.tool == BoardTool.arrow || c.tool == BoardTool.line
        ? c.anchorAt(_start!)
        : null;
    _updateDraft(_start!);
  }

  void _erase(Offset point) {
    final hit = c.hit(point, tolerance: 12 / c.document.zoom);
    if (hit?.type == 'pencil') {
      c.replaceObjects(
        c.document.objects.where((o) => o.id != hit!.id).toList(),
        transient: true,
      );
    }
  }

  void _move(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer) ||
        widget.readOnly ||
        _capturing) {
      return;
    }
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length >= 2) {
      final p = _pointers.values.take(2).toList();
      final focal = (p[0] + p[1]) / 2;
      final zoom = (_pinchZoom * (p[0] - p[1]).distance / _pinchDistance).clamp(
        .05,
        16.0,
      );
      c.setViewport(
        focal - (_pinchFocus - _pinchOffset) / _pinchZoom * zoom,
        zoom,
      );
      return;
    }
    if (_blocked || _action == null || _start == null || _before == null) {
      return;
    }
    final current = world(event.localPosition);
    if (_action == 'pan') {
      c.setViewport(
        _before!.offset + event.localPosition - _screenStart!,
        _before!.zoom,
      );
    } else if (_action == 'move') {
      final delta = current - _start!;
      c.replaceObjects([
        for (final o in _before!.objects)
          if (c.selection.contains(o.id))
            o.transformed(o.rect.shift(delta))
          else
            o,
      ], transient: true);
    } else if (_action == 'resize') {
      final objects = _before!.objects
          .where((o) => c.selection.contains(o.id))
          .toList();
      final r = objects
          .map((o) => o.rect)
          .reduce((a, b) => a.expandToInclude(b));
      var sx = math.max(.1, (current.dx - r.left) / math.max(r.width, 1));
      var sy = math.max(.1, (current.dy - r.top) / math.max(r.height, 1));
      if (objects.any((o) => o.type == 'image')) {
        final minimum = objects
            .map(
              (o) => math.max(
                (o.type == 'custom' ? 160 : 20) / o.rect.width,
                (o.type == 'custom' ? 120 : 20) / o.rect.height,
              ),
            )
            .reduce(math.max);
        sx = math.max(sx, minimum);
        sy = sx;
      }
      c.replaceObjects([
        for (final o in _before!.objects)
          if (c.selection.contains(o.id))
            o.transformed(
              Rect.fromLTWH(
                r.left + (o.rect.left - r.left) * sx,
                r.top + (o.rect.top - r.top) * sy,
                math.max(o.type == 'custom' ? 160 : 20, o.rect.width * sx),
                math.max(o.type == 'custom' ? 120 : 20, o.rect.height * sy),
              ),
            )
          else
            o,
      ], transient: true);
    } else if (_action == 'erase') {
      _erase(current);
    } else if (_action == 'draw') {
      _updateDraft(current);
    } else if (_action == 'marquee') {
      setState(() {});
    }
  }

  void _updateDraft(Offset current) {
    if (c.tool == BoardTool.pencil) {
      if ((current - _ink.last).distance > .4) _ink.add(current);
    } else {
      _ink = [_start!, current];
    }
    _draft = BoardObject(
      id: 'draft',
      type: c.tool.name,
      rect:
          c.tool == BoardTool.pencil ||
              c.tool == BoardTool.line ||
              c.tool == BoardTool.arrow
          ? boundsOfPoints(_ink)
          : Rect.fromPoints(_start!, current),
      points: _ink,
      style: c.defaults,
      start: _anchor,
      end: c.tool == BoardTool.arrow || c.tool == BoardTool.line
          ? c.anchorAt(current)
          : null,
    );
    setState(() {});
  }

  void _up(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isNotEmpty) return;
    if (event is PointerCancelEvent) {
      c.cancelGesture();
    } else if (!_blocked) {
      if (_action == 'draw' && _draft != null) {
        final draft = _draft!;
        if (draft.type == 'pencil' ||
            draft.rect.width + draft.rect.height > 6) {
          c.add(
            BoardObject(
              id: c.createId(),
              type: draft.type,
              rect: Rect.fromLTWH(
                draft.rect.left,
                draft.rect.top,
                math.max(.01, draft.rect.width),
                math.max(.01, draft.rect.height),
              ),
              points: draft.points,
              style: draft.style,
              start: draft.start,
              end: draft.end,
            ),
          );
        }
      } else if (_action == 'marquee' && _screenStart != null) {
        final r = Rect.fromPoints(_start!, world(event.localPosition));
        c.select(
          c.document.objects.where((o) => r.overlaps(o.rect)).map((o) => o.id),
        );
      } else {
        c.finishGesture();
      }
    }
    _blocked = false;
    c.interacting = false;
    _action = null;
    _draft = null;
    _before = null;
    if (mounted) setState(() {});
  }

  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || widget.readOnly || _capturing) return;
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!ctrl &&
        c.tool == BoardTool.select &&
        _content(
          c.hit(world(event.localPosition)),
          world(event.localPosition),
        )) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (ctrl) {
        final point = world(event.localPosition);
        final zoom = (c.document.zoom * math.exp(-event.scrollDelta.dy / 350))
            .clamp(.05, 16.0);
        c.setViewport(event.localPosition - point * zoom, zoom);
      } else {
        c.setViewport(c.document.offset - event.scrollDelta, c.document.zoom);
      }
    });
  }

  Future<void> editSelectedText() async {
    if (c.selected.length == 1 && c.selected.single.type == 'text') {
      await _editText(
        c.selected.single.rect.topLeft,
        existing: c.selected.single,
      );
    }
  }

  Future<void> _editText(Offset point, {BoardObject? existing}) async {
    final input = TextEditingController(text: existing?.text);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('画布文字'),
        content: TextField(
          controller: input,
          autofocus: true,
          minLines: 2,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '输入文字'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // The route's closing animation may still paint its TextField.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    input.dispose();
    if (!mounted || value == null || value.isEmpty) return;
    if (existing != null) {
      c.replaceObjects([
        for (final o in c.document.objects)
          if (o.id == existing.id) o.copyWith(text: value) else o,
      ]);
    } else {
      c.add(
        BoardObject(
          id: c.createId(),
          type: 'text',
          rect: Rect.fromLTWH(point.dx, point.dy, 240, 100),
          text: value,
          style: c.defaults,
        ),
      );
    }
    c.setTool(BoardTool.select);
  }

  Widget _scene({
    required Size size,
    required Offset offset,
    required double zoom,
    required bool exporting,
  }) {
    final objects = [
      ...c.document.objects,
      if (!exporting && _draft != null) _draft!,
    ];
    return SizedBox(
      width: size.width,
      height: size.height,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (final original in objects)
              if (exporting ||
                  c.document
                      .resolved(original)
                      .rect
                      .shift(offset / zoom)
                      .overlaps(
                        Rect.fromLTWH(
                          0,
                          0,
                          size.width / zoom,
                          size.height / zoom,
                        ).inflate(64 / zoom),
                      ))
                _object(c.document.resolved(original), offset, zoom, exporting),
            if (!exporting) ..._selectionWidgets(offset, zoom),
          ],
        ),
      ),
    );
  }

  Widget _object(
    BoardObject object,
    Offset offset,
    double zoom,
    bool exporting,
  ) {
    final r = object.rect.inflate(
      object.type == 'arrow'
          ? object.style.width * 2 + 12
          : 6 + object.style.width,
    );
    final local = object.rect;
    Widget body;
    if (object.type == 'custom') {
      body = DecoratedBox(
        decoration: BoxDecoration(
          color: object.style.fill,
          border: Border.all(
            color: object.style.stroke,
            width: object.style.width,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child:
            widget.nodeBuilder?.call(context, object, exporting) ??
            const Center(child: Text('内容不可用')),
      );
    } else if (object.type == 'image') {
      try {
        body = DecoratedBox(
          decoration: BoxDecoration(
            color: object.style.fill,
            border: Border.all(
              color: object.style.stroke,
              width: object.style.width,
            ),
          ),
          child: BoardImage(
            bytes: _image(object),
            mime: object.data['mime'] as String?,
          ),
        );
      } catch (_) {
        body = const Center(child: Icon(Icons.broken_image_outlined));
      }
    } else {
      return Positioned(
        key: ValueKey(object.id),
        left: r.left * zoom + offset.dx,
        top: r.top * zoom + offset.dy,
        width: r.width * zoom,
        height: r.height * zoom,
        child: IgnorePointer(
          child: CustomPaint(
            painter: _ObjectPainter(
              object,
              r,
              zoom,
              Theme.of(context).textTheme.bodyMedium?.fontFamily,
            ),
          ),
        ),
      );
    }
    return Positioned(
      key: ValueKey(object.id),
      left: local.left * zoom + offset.dx,
      top: local.top * zoom + offset.dy,
      width: local.width * zoom,
      height: local.height * zoom,
      child: IgnorePointer(
        ignoring:
            exporting ||
            widget.readOnly ||
            c.tool != BoardTool.select ||
            _blocked,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: local.width,
          maxWidth: local.width,
          minHeight: local.height,
          maxHeight: local.height,
          child: Transform.scale(
            scale: zoom,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: local.width,
              height: local.height,
              child: ClipRect(child: body),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _selectionWidgets(Offset offset, double zoom) {
    if (c.selected.isEmpty) return [];
    final r = c.selected
        .map((o) => c.document.resolved(o).rect)
        .reduce((a, b) => a.expandToInclude(b));
    final screen = Rect.fromLTWH(
      r.left * zoom + offset.dx,
      r.top * zoom + offset.dy,
      r.width * zoom,
      r.height * zoom,
    );
    return [
      Positioned.fromRect(
        rect: screen.inflate(2),
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            ),
          ),
        ),
      ),
      Positioned(
        left: screen.right - 7,
        top: screen.bottom - 7,
        width: 14,
        height: 14,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    ];
  }

  /// Paint the complete world into a separate, fitted scene. The boundary is
  /// laid out at document size, so toImage includes offscreen widgets as well.
  /// A progress surface covers it while retaining a paintable boundary.
  Future<Uint8List> capturePng({Future<void> Function()? prepare}) async {
    if (_capturing) throw StateError('Canvas capture already running');
    _capturing = true;
    OverlayEntry? overlay;
    try {
      c.cancelGesture();
      await prepare?.call();
      if (!mounted) throw StateError('Canvas closed');
      for (final object in c.document.objects.where((o) => o.type == 'image')) {
        if (!mounted) throw StateError('Canvas closed');
        await prepareBoardImage(
          context,
          _image(object),
          mime: object.data['mime'] as String?,
        );
      }
      if (!mounted) throw StateError('Canvas closed');
      final bounds = c.document.bounds.inflate(16);
      final size = Size(math.max(1, bounds.width), math.max(1, bounds.height));
      final key = GlobalKey();
      final scene = InheritedTheme.captureAll(
        context,
        Material(
          child: Stack(
            children: [
              Positioned.fill(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: RepaintBoundary(
                    key: key,
                    child: _scene(
                      size: size,
                      offset: -bounds.topLeft,
                      zoom: 1,
                      exporting: true,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: const Center(child: CircularProgressIndicator()),
                ),
              ),
            ],
          ),
        ),
      );
      overlay = OverlayEntry(
        builder: (_) => Positioned.fill(child: IgnorePointer(child: scene)),
      );
      Overlay.of(context).insert(overlay);
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) throw StateError('Canvas closed');
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final ratio = math.min(
        2.0,
        math.min(
          8192 / math.max(size.width, size.height),
          math.sqrt(24000000 / (size.width * size.height)),
        ),
      );
      final image = await boundary.toImage(pixelRatio: ratio);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('PNG export failed');
        return data.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      overlay?.remove();
      overlay?.dispose();
      _capturing = false;
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    focusNode: _focus,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent || widget.readOnly || _capturing) {
        return KeyEventResult.ignored;
      }
      final key = event.logicalKey;
      final ctrl =
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      if (ctrl && key == LogicalKeyboardKey.keyZ) {
        if (HardwareKeyboard.instance.isShiftPressed) {
          c.redo();
        } else {
          c.undo();
        }
      } else if (ctrl && key == LogicalKeyboardKey.keyY) {
        c.redo();
      } else if (ctrl && key == LogicalKeyboardKey.keyC) {
        c.copy();
      } else if (ctrl && key == LogicalKeyboardKey.keyV) {
        c.paste();
      } else if (ctrl && key == LogicalKeyboardKey.keyA) {
        c.select(c.document.objects.map((o) => o.id));
      } else if (key == LogicalKeyboardKey.delete ||
          key == LogicalKeyboardKey.backspace) {
        c.removeSelected();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    },
    child: LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        final selected = c.selected;
        final rect = selected.isEmpty
            ? null
            : selected
                  .map((o) => c.document.resolved(o).rect)
                  .reduce((a, b) => a.expandToInclude(b));
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _down,
                onPointerMove: _move,
                onPointerUp: _up,
                onPointerCancel: _up,
                onPointerSignal: _signal,
                child: _scene(
                  size: size,
                  offset: c.document.offset,
                  zoom: c.document.zoom,
                  exporting: false,
                ),
              ),
            ),
            if (rect != null && !widget.readOnly && c.tool == BoardTool.select)
              Positioned(
                left: (rect.left * c.document.zoom + c.document.offset.dx)
                    .clamp(0, math.max(0, size.width - 156)),
                top: (rect.top * c.document.zoom + c.document.offset.dy - 52)
                    .clamp(0, math.max(0, size.height - 48)),
                child: Material(
                  elevation: 3,
                  borderRadius: BorderRadius.circular(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '删除选中对象',
                        onPressed: c.removeSelected,
                        icon: const Icon(Icons.delete_outline),
                      ),
                      if (widget.onInspect != null)
                        IconButton(
                          tooltip: '对象属性',
                          onPressed: widget.onInspect,
                          icon: const Icon(Icons.tune),
                        ),
                      if (selected.length == 1 &&
                          selected.single.type == 'text')
                        IconButton(
                          tooltip: '编辑画布文字',
                          onPressed: editSelectedText,
                          icon: const Icon(Icons.edit_outlined),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _ObjectPainter extends CustomPainter {
  final BoardObject object;
  final Rect bounds;
  final double zoom;
  final String? font;
  _ObjectPainter(this.object, this.bounds, this.zoom, this.font);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(zoom);
    canvas.translate(-bounds.left, -bounds.top);
    final o = object, s = o.style;
    final path = Path();
    if (o.type == 'rectangle') {
      path.addRRect(RRect.fromRectAndRadius(o.rect, const Radius.circular(5)));
    } else if (o.type == 'ellipse') {
      path.addOval(o.rect);
    } else if (o.type == 'pencil') {
      final points = getStroke(
        o.points.map((p) => PointVector(p.dx, p.dy)).toList(),
        options: StrokeOptions(
          size: s.width + 2,
          thinning: 0,
          smoothing: .5,
          streamline: .4,
          simulatePressure: false,
        ),
      );
      if (points.isNotEmpty) {
        path.moveTo(points.first.dx, points.first.dy);
        for (final p in points.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        path.close();
        canvas.drawPath(path, Paint()..color = s.stroke);
        return;
      }
    } else if (o.type == 'line' || o.type == 'arrow') {
      if (o.points.isEmpty) return;
      path.moveTo(o.points.first.dx, o.points.first.dy);
      for (final p in o.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
    } else if (o.type == 'text') {
      final painter = TextPainter(
        text: TextSpan(
          text: o.text,
          style: TextStyle(
            fontFamily: font,
            color: s.stroke,
            fontSize: s.fontSize,
            fontWeight: s.bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: s.align,
      );
      painter.layout(maxWidth: o.rect.width);
      canvas.save();
      canvas.clipRect(o.rect);
      painter.paint(canvas, o.rect.topLeft);
      canvas.restore();
      painter.dispose();
      return;
    }
    if (s.fill.a > 0 && (o.type == 'rectangle' || o.type == 'ellipse')) {
      canvas.drawPath(path, Paint()..color = s.fill);
    }
    final pen = Paint()
      ..color = s.stroke
      ..strokeWidth = s.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (s.dash == BoardDash.solid) {
      canvas.drawPath(path, pen);
    } else {
      final dash = s.dash == BoardDash.dotted ? .1 : s.width * 4;
      for (final metric in path.computeMetrics()) {
        for (
          double distance = 0;
          distance < metric.length;
          distance += dash + s.width * 3
        ) {
          canvas.drawPath(
            metric.extractPath(
              distance,
              math.min(metric.length, distance + dash),
            ),
            pen,
          );
        }
      }
    }
    if (o.type == 'arrow' && o.points.length > 1) {
      final end = o.points.last, delta = end - o.points[o.points.length - 2];
      final angle = math.atan2(delta.dy, delta.dx),
          length = math.max(12, s.width * 4);
      canvas.drawPath(
        Path()
          ..moveTo(
            end.dx - math.cos(angle - .5) * length,
            end.dy - math.sin(angle - .5) * length,
          )
          ..lineTo(end.dx, end.dy)
          ..lineTo(
            end.dx - math.cos(angle + .5) * length,
            end.dy - math.sin(angle + .5) * length,
          ),
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(_ObjectPainter oldDelegate) =>
      oldDelegate.object != object ||
      oldDelegate.zoom != zoom ||
      oldDelegate.font != font;
}
