import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fldraw/board.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BoardObject shape(String id, double x, {String type = 'rectangle'}) =>
    BoardObject(id: id, type: type, rect: Rect.fromLTWH(x, 50, 180, 180));

void main() {
  test(
    'mixed transactions, cancellation, style and serialization preserve custom identities',
    () {
      final c = BoardController();
      addTearDown(c.dispose);
      c.add(shape('a', 10));
      c.add(
        BoardObject(
          id: 'card',
          type: 'custom',
          rect: const Rect.fromLTWH(220, 50, 240, 300),
          data: {'target': 'notes/stable.md'},
        ),
      );
      final saved = c.fingerprint;
      c.beginGesture();
      c.replaceObjects([
        for (final o in c.document.objects)
          o.transformed(o.rect.shift(const Offset(40, 20))),
      ], transient: true);
      c.cancelGesture();
      expect(c.fingerprint, saved);
      c.select(['a', 'card']);
      c.beginGesture();
      c.style((s) => s.copyWith(stroke: Colors.red));
      c.style((s) => s.copyWith(width: 5));
      c.finishGesture();
      c.undo();
      expect(c.fingerprint, saved);
      c.redo();
      expect(c.document.objects.every((o) => o.style.width == 5), isTrue);
      final restored = BoardDocument.fromJson(
        jsonDecode(jsonEncode(c.document.toJson())),
      );
      expect(restored.objects.last.data['target'], 'notes/stable.md');
      c.select(c.document.objects.map((o) => o.id));
      c.copy();
      c.paste();
      expect(c.document.objects.length, 4);
      expect(c.document.objects.map((o) => o.id).toSet().length, 4);
      expect(c.document.objects.last.data['target'], 'notes/stable.md');
      c.undo();
      expect(c.document.objects.length, 2);
    },
  );
  test(
    'attached lines follow moved objects and copied connections remap identities',
    () {
      final c = BoardController(
        document: BoardDocument(
          objects: [
            shape('a', 0),
            shape('b', 300),
            BoardObject(
              id: 'edge',
              type: 'arrow',
              rect: const Rect.fromLTWH(180, 140, 120, 1),
              points: const [Offset(180, 140), Offset(300, 140)],
              start: const BoardAnchor('a', Offset(1, .5)),
              end: const BoardAnchor('b', Offset(0, .5)),
            ),
          ],
        ),
      );
      addTearDown(c.dispose);
      c.replaceObjects([
        for (final o in c.document.objects)
          if (o.id == 'a')
            o.transformed(o.rect.shift(const Offset(30, 40)))
          else
            o,
      ]);
      expect(
        c.document.resolved(c.document.objects.last).points.first,
        const Offset(210, 180),
      );
      c.select(c.document.objects.map((o) => o.id));
      c.copy();
      c.paste();
      final edge = c.document.objects.last;
      expect(edge.start!.objectId, isNot('a'));
      expect(
        c.document.objects.any((o) => o.id == edge.start!.objectId),
        isTrue,
      );
    },
  );
  testWidgets('mixed selection exposes only common editable properties', (
    t,
  ) async {
    final c = BoardController(
      document: BoardDocument(
        objects: [
          shape(
            'a',
            0,
          ).copyWith(style: const BoardStyle(width: 2, stroke: Colors.black)),
          shape(
            'b',
            300,
          ).copyWith(style: const BoardStyle(width: 8, stroke: Colors.red)),
        ],
      ),
    );
    addTearDown(c.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BoardInspector(controller: c)),
      ),
    );
    c.select(['a', 'b']);
    await t.pump();
    expect(find.text('描边粗细 多项'), findsOneWidget);
    expect(find.text('描边粗细 2'), findsNothing);
    expect(find.text('描边粗细 8'), findsNothing);
    expect(find.text('字号 20'), findsNothing);
    await t.drag(find.byType(Slider).first, const Offset(100, 0));
    await t.pump();
    expect(c.document.objects.map((o) => o.style.width).toSet().length, 1);
  });
  test('untrusted geometry and duplicate identities are rejected', () {
    final source = BoardDocument(objects: [shape('a', 0)]).toJson();
    source['objects'] = [shape('a', 0).toJson(), shape('a', 20).toJson()];
    expect(() => BoardDocument.fromJson(source), throwsFormatException);
    source['objects'] = [
      {
        ...shape('a', 0).toJson(),
        'rect': [0, 0, -1, 10],
      },
    ];
    expect(() => BoardDocument.fromJson(source), throwsFormatException);
  });
  testWidgets(
    'two finger transition cancels ink and leaves a usable one finger drawing session',
    (t) async {
      final c = BoardController();
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BoardView(controller: c)),
        ),
      );
      c.setTool(BoardTool.pencil);
      await t.pump();
      final p = await t.startGesture(
        const Offset(100, 100),
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      await p.moveTo(const Offset(140, 130));
      await t.pump();
      final q = await t.startGesture(
        const Offset(240, 150),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      await q.moveTo(const Offset(280, 170));
      await t.pump();
      await p.up();
      await q.up();
      await t.pump();
      expect(c.document.objects, isEmpty);
      expect(c.document.zoom, isNot(1));
      await t.dragFrom(const Offset(150, 250), const Offset(100, 55));
      await t.pump();
      expect(c.document.objects, hasLength(1));
      expect(c.document.objects.single.type, 'pencil');
      c.undo();
      expect(c.document.objects, isEmpty);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'custom body scroll is not a document edit; header drag is one undo',
    (t) async {
      final c = BoardController(
        document: BoardDocument(
          objects: [
            shape('card', 40, type: 'custom').copyWith(
              rect: const Rect.fromLTWH(40, 40, 260, 330),
              data: {'target': 'stable'},
            ),
          ],
        ),
      );
      final scroll = ScrollController();
      addTearDown(c.dispose);
      addTearDown(scroll.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BoardView(
              controller: c,
              nodeBuilder: (context, o, exporting) => Column(
                children: [
                  const SizedBox(height: 40, child: Text('Header')),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scroll,
                      child: Column(
                        children: [
                          for (var i = 0; i < 100; i++) Text('Line $i'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final before = c.fingerprint;
      await t.dragFrom(const Offset(170, 250), const Offset(0, -100));
      await t.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(c.fingerprint, before);
      await t.dragFrom(const Offset(160, 55), const Offset(70, 40));
      await t.pumpAndSettle();
      expect(c.document.objects.single.rect.left, 110);
      c.undo();
      expect(c.fingerprint, before);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'PNG captures offscreen custom nodes and their current clipped content',
    (t) async {
      final c = BoardController(
        document: BoardDocument(
          objects: [
            shape('visible', 20),
            shape(
              'offscreen',
              1200,
              type: 'custom',
            ).copyWith(rect: const Rect.fromLTWH(1200, 50, 200, 200)),
          ],
        ),
      );
      addTearDown(c.dispose);
      final key = GlobalKey<BoardViewState>();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BoardView(
              key: key,
              controller: c,
              nodeBuilder: (context, o, exporting) => const ColoredBox(
                color: Colors.red,
                child: Text('Offscreen Markdown'),
              ),
            ),
          ),
        ),
      );
      final future = key.currentState!.capturePng();
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      final bytes = await t.runAsync(() => future);
      expect(bytes, isNotNull);
      final image = await t.runAsync(() async {
        final codec = await ui.instantiateImageCodec(bytes!);
        final frame = await codec.getNextFrame();
        codec.dispose();
        return frame.image;
      });
      expect(image!.width, greaterThan(1400));
      final rgba = await t.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      final raw = rgba!.buffer.asUint8List();
      var red = 0;
      for (var i = 0; i < raw.length; i += 4) {
        if (raw[i] > 200 && raw[i + 1] < 70 && raw[i + 2] < 70) red++;
      }
      expect(red, greaterThan(10000));
      image.dispose();
      await t.pumpWidget(const SizedBox());
    },
  );
  test(
    'SVG originals are locally rasterized and external resources are rejected',
    () async {
      final bytes = utf8.encode(
        '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="80"><rect width="160" height="80" fill="red"/></svg>',
      );
      expect(
        await boardImageSize(Uint8List.fromList(bytes), mime: 'image/svg+xml'),
        const Size(160, 80),
      );
      final external = Uint8List.fromList(
        utf8.encode('<svg><image href="https://example.com/x.png"/></svg>'),
      );
      await expectLater(
        boardImageSize(external, mime: 'image/svg+xml'),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'image resize stays proportional at minimum size and custom cards have usable bounds',
    (t) async {
      final c = BoardController(
        document: BoardDocument(
          objects: [
            BoardObject(
              id: 'image',
              type: 'image',
              rect: const Rect.fromLTWH(40, 40, 240, 60),
              data: {'bytes': ''},
            ),
            shape(
              'card',
              340,
              type: 'custom',
            ).copyWith(rect: const Rect.fromLTWH(340, 40, 260, 300)),
          ],
        ),
      );
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BoardView(controller: c)),
        ),
      );
      c.select(['image']);
      await t.pump();
      await t.dragFrom(const Offset(280, 100), const Offset(-210, -35));
      await t.pump();
      final image = c.document.objects.first.rect;
      expect(image.width / image.height, closeTo(4, .001));
      expect(image.height, greaterThanOrEqualTo(20));
      c.select(['card']);
      await t.pump();
      await t.dragFrom(const Offset(600, 340), const Offset(-240, -260));
      await t.pump();
      final card = c.document.objects.last.rect;
      expect(card.width, greaterThanOrEqualTo(160));
      expect(card.height, greaterThanOrEqualTo(120));
      await t.pumpWidget(const SizedBox());
    },
  );
}
