import 'dart:convert';

import 'package:fldraw/board.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(home: EmbeddedBoardExample()));

/// Standalone host: no account, database, webview, or application framework.
class EmbeddedBoardExample extends StatefulWidget {
  const EmbeddedBoardExample({super.key});
  @override
  State<EmbeddedBoardExample> createState() => _EmbeddedBoardExampleState();
}

class _EmbeddedBoardExampleState extends State<EmbeddedBoardExample> {
  final board = GlobalKey<BoardViewState>();
  final controller = BoardController(
    document: BoardDocument(
      objects: [
        BoardObject(
          id: 'host-card',
          type: 'custom',
          rect: const Rect.fromLTWH(60, 60, 280, 300),
          style: const BoardStyle(fill: Colors.white),
          data: {'title': 'Custom Flutter content'},
        ),
      ],
    ),
  );
  Future<void> inspect() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: BoardInspector(controller: controller),
      ),
    ),
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('fldraw embedded board'),
      actions: [
        IconButton(
          tooltip: 'PNG',
          icon: const Icon(Icons.image_outlined),
          onPressed: () async {
            final bytes = await board.currentState!.capturePng();
            if (!context.mounted) return;
            await showDialog<void>(
              context: context,
              builder: (_) => Dialog(child: Image.memory(bytes)),
            );
          },
        ),
      ],
    ),
    body: Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final tool in BoardTool.values)
                IconButton(
                  tooltip: tool.name,
                  onPressed: () => controller.setTool(tool),
                  icon: Icon(switch (tool) {
                    BoardTool.select => Icons.near_me_outlined,
                    BoardTool.pencil => Icons.draw_outlined,
                    BoardTool.eraser => Icons.auto_fix_normal,
                    BoardTool.rectangle => Icons.rectangle_outlined,
                    BoardTool.ellipse => Icons.circle_outlined,
                    BoardTool.line => Icons.horizontal_rule,
                    BoardTool.arrow => Icons.north_east,
                    BoardTool.text => Icons.text_fields,
                  }),
                ),
              IconButton(
                tooltip: 'SVG image',
                icon: const Icon(Icons.add_photo_alternate_outlined),
                onPressed: () => controller.add(
                  BoardObject(
                    id: controller.createId(),
                    type: 'image',
                    rect: const Rect.fromLTWH(380, 100, 160, 100),
                    data: {
                      'mime': 'image/svg+xml',
                      'bytes': base64Encode(
                        utf8.encode(
                          '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="100"><rect width="160" height="100" fill="#5894f5"/></svg>',
                        ),
                      ),
                    },
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Inspector',
                icon: const Icon(Icons.tune),
                onPressed: inspect,
              ),
              IconButton(
                tooltip: 'Undo',
                icon: const Icon(Icons.undo),
                onPressed: controller.undo,
              ),
              IconButton(
                tooltip: 'Redo',
                icon: const Icon(Icons.redo),
                onPressed: controller.redo,
              ),
            ],
          ),
        ),
        Expanded(
          child: BoardView(
            key: board,
            controller: controller,
            onInspect: inspect,
            nodeBuilder: (context, object, exporting) => Column(
              children: [
                SizedBox(
                  height: 40,
                  child: Center(child: Text(object.data['title'] as String)),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (var i = 0; i < 40; i++)
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text('Host paragraph $i'),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
