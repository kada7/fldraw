import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'model.dart';

/// A pointer gesture is one transaction. Pointer cancellation rolls it back;
/// view/selection changes never leak into document undo history.
class BoardController extends ChangeNotifier {
  BoardDocument _document;
  final _undo = <BoardDocument>[], _redo = <BoardDocument>[];
  BoardDocument? _gesture;
  Set<String> _selection = {};
  BoardTool tool = BoardTool.select;
  BoardStyle defaults;
  bool multiSelect = false;

  /// View pointer transactions let hosts avoid serializing embedded images
  /// on every pointer sample merely to compute an unsaved indicator.
  bool interacting = false;
  String? _fingerprint;
  List<BoardObject> _clipboard = [];
  BoardController({BoardDocument? document, this.defaults = const BoardStyle()})
    : _document = document ?? BoardDocument();
  BoardDocument get document => _document;
  Set<String> get selection => Set.unmodifiable(_selection);
  List<BoardObject> get selected =>
      _document.objects.where((o) => _selection.contains(o.id)).toList();
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String get fingerprint => _fingerprint ??= jsonEncode(_document.toJson());
  String createId() => const Uuid().v4();
  void setTool(BoardTool value) {
    cancelGesture();
    interacting = false;
    tool = value;
    notifyListeners();
  }

  void select(Iterable<String> ids, {bool toggle = false}) {
    final incoming = ids.toSet();
    _selection = toggle
        ? ((_selection.union(incoming))
            ..removeAll(_selection.intersection(incoming)))
        : incoming;
    notifyListeners();
  }

  void setMultiSelect(bool value) {
    multiSelect = value;
    notifyListeners();
  }

  void beginGesture() {
    _gesture ??= _document;
  }

  void finishGesture() {
    final before = _gesture;
    _gesture = null;
    if (before != null && jsonEncode(before.toJson()) != fingerprint) {
      _remember(before);
    }
    notifyListeners();
  }

  void cancelGesture() {
    if (_gesture == null) return;
    _document = _gesture!;
    _fingerprint = null;
    _gesture = null;
    notifyListeners();
  }

  void _remember(BoardDocument before) {
    _undo.add(before);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
  }

  void replaceObjects(List<BoardObject> objects, {bool transient = false}) {
    final before = _document;
    _document = _document.copyWith(objects: objects);
    _fingerprint = null;
    if (!transient && _gesture == null) _remember(before);
    _selection.removeWhere((id) => !objects.any((o) => o.id == id));
    notifyListeners();
  }

  void add(BoardObject object) {
    replaceObjects([..._document.objects, object]);
    select([object.id]);
  }

  void removeSelected() => replaceObjects(
    _document.objects.where((o) => !_selection.contains(o.id)).toList(),
  );
  void setViewport(Offset offset, double zoom) {
    _document = _document.copyWith(offset: offset, zoom: zoom.clamp(.05, 16));
    _fingerprint = null;
    notifyListeners();
  }

  void undo() {
    cancelGesture();
    if (_undo.isEmpty) return;
    _redo.add(_document);
    _document = _undo.removeLast();
    _fingerprint = null;
    _selection.clear();
    notifyListeners();
  }

  void redo() {
    cancelGesture();
    if (_redo.isEmpty) return;
    _undo.add(_document);
    _document = _redo.removeLast();
    _fingerprint = null;
    _selection.clear();
    notifyListeners();
  }

  void style(BoardStyle Function(BoardStyle) change) {
    if (_selection.isEmpty) {
      defaults = change(defaults);
      notifyListeners();
      return;
    }
    replaceObjects([
      for (final o in _document.objects)
        if (_selection.contains(o.id))
          o.copyWith(style: change(o.style))
        else
          o,
    ]);
  }

  void copy() {
    _clipboard = selected;
  }

  void paste() {
    if (_clipboard.isEmpty) return;
    final ids = {for (final o in _clipboard) o.id: createId()};
    BoardAnchor? remap(BoardAnchor? anchor) =>
        anchor == null || !ids.containsKey(anchor.objectId)
        ? null
        : BoardAnchor(ids[anchor.objectId]!, anchor.relative);
    final copied = [
      for (final o in _clipboard)
        BoardObject(
          id: ids[o.id]!,
          type: o.type,
          rect: o.rect,
          points: o.points,
          data: o.data,
          text: o.text,
          style: o.style,
          start: remap(o.start),
          end: remap(o.end),
        ).transformed(o.rect.shift(const Offset(24, 24))),
    ];
    replaceObjects([..._document.objects, ...copied]);
    select(copied.map((o) => o.id));
    _clipboard = copied;
  }

  BoardObject? hit(Offset point, {double tolerance = 8}) {
    for (final original in _document.objects.reversed) {
      final o = _document.resolved(original);
      if (!o.rect.inflate(tolerance).contains(point)) continue;
      if (['pencil', 'line', 'arrow'].contains(o.type)) {
        if (o.points.length == 1 &&
            (point - o.points.first).distance < tolerance) {
          return original;
        }
        for (var i = 1; i < o.points.length; i++) {
          final a = o.points[i - 1], delta = o.points[i] - a;
          final length = delta.distanceSquared;
          final t = length == 0
              ? 0.0
              : (((point - a).dx * delta.dx + (point - a).dy * delta.dy) /
                        length)
                    .clamp(0.0, 1.0);
          if ((point - (a + delta * t)).distance <=
              tolerance + o.style.width / 2) {
            return original;
          }
        }
      } else {
        return original;
      }
    }
    return null;
  }

  BoardAnchor? anchorAt(Offset point) {
    final object = hit(point, tolerance: 14);
    if (object == null || ['pencil', 'line', 'arrow'].contains(object.type)) {
      return null;
    }
    final r = object.rect;
    final sides = [
      Offset(r.left, point.dy.clamp(r.top, r.bottom)),
      Offset(r.right, point.dy.clamp(r.top, r.bottom)),
      Offset(point.dx.clamp(r.left, r.right), r.top),
      Offset(point.dx.clamp(r.left, r.right), r.bottom),
    ]..sort((a, b) => (a - point).distance.compareTo((b - point).distance));
    final p = sides.first;
    return BoardAnchor(
      object.id,
      Offset((p.dx - r.left) / r.width, (p.dy - r.top) / r.height),
    );
  }
}
