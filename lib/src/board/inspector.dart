import 'package:flutter/material.dart';

import 'controller.dart';
import 'model.dart';

/// Material inspector inherits the embedding application's theme.
class BoardInspector extends StatelessWidget {
  final BoardController controller;
  const BoardInspector({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final selected = controller.selected;
      T? common<T>(T Function(BoardStyle style) read) {
        if (selected.isEmpty) return read(controller.defaults);
        final values = selected.map((object) => read(object.style)).toList();
        return values.every((value) => value == values.first)
            ? values.first
            : null;
      }

      final text = selected.isEmpty || selected.every((o) => o.type == 'text');
      final supportsFill =
          selected.isEmpty ||
          selected.every(
            (o) => ['rectangle', 'ellipse', 'custom', 'image'].contains(o.type),
          );
      final stroke = common((style) => style.stroke);
      final fillColor = common((style) => style.fill);
      final width = common((style) => style.width);
      final fontSize = common((style) => style.fontSize);
      final dash = common((style) => style.dash);
      final bold = common((style) => style.bold);
      final italic = common((style) => style.italic);
      final commonAlign = common((style) => style.align);
      return SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                selected.isEmpty ? '新对象样式' : '选中 ${selected.length} 个对象',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              _color(
                context,
                '描边 / 文字颜色',
                stroke,
                (color) => controller.style((s) => s.copyWith(stroke: color)),
              ),
              if (supportsFill)
                _color(
                  context,
                  '填充颜色',
                  fillColor,
                  (color) => controller.style((s) => s.copyWith(fill: color)),
                ),
              Text(width == null ? '描边粗细 多项' : '描边粗细 ${width.round()}'),
              Slider(
                min: 1,
                max: 20,
                divisions: 19,
                value: (width ?? controller.defaults.width).clamp(1, 20),
                onChangeStart: (_) => controller.beginGesture(),
                onChanged: (v) => controller.style((s) => s.copyWith(width: v)),
                onChangeEnd: (_) => controller.finishGesture(),
              ),
              if (selected.isEmpty ||
                  selected.every(
                    (o) => [
                      'rectangle',
                      'ellipse',
                      'line',
                      'arrow',
                    ].contains(o.type),
                  ))
                DropdownButtonFormField<BoardDash>(
                  initialValue: dash,
                  hint: dash == null ? const Text('线型 多项') : null,
                  decoration: const InputDecoration(labelText: '线型'),
                  items: [
                    for (final dash in BoardDash.values)
                      DropdownMenuItem(
                        value: dash,
                        child: Text(switch (dash) {
                          BoardDash.solid => '实线',
                          BoardDash.dashed => '虚线',
                          BoardDash.dotted => '点线',
                        }),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) controller.style((s) => s.copyWith(dash: v));
                  },
                ),
              if (text) ...[
                const SizedBox(height: 12),
                Text(fontSize == null ? '字号 多项' : '字号 ${fontSize.round()}'),
                Slider(
                  min: 8,
                  max: 96,
                  divisions: 88,
                  value: (fontSize ?? controller.defaults.fontSize).clamp(
                    8,
                    96,
                  ),
                  onChangeStart: (_) => controller.beginGesture(),
                  onChanged: (v) =>
                      controller.style((s) => s.copyWith(fontSize: v)),
                  onChangeEnd: (_) => controller.finishGesture(),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('粗体'),
                      selected: bold == true,
                      onSelected: (v) =>
                          controller.style((s) => s.copyWith(bold: v)),
                    ),
                    FilterChip(
                      label: const Text('斜体'),
                      selected: italic == true,
                      onSelected: (v) =>
                          controller.style((s) => s.copyWith(italic: v)),
                    ),
                    for (final align in [
                      TextAlign.left,
                      TextAlign.center,
                      TextAlign.right,
                    ])
                      IconButton(
                        tooltip: switch (align) {
                          TextAlign.center => '居中',
                          TextAlign.right => '右对齐',
                          _ => '左对齐',
                        },
                        isSelected: commonAlign == align,
                        onPressed: () =>
                            controller.style((s) => s.copyWith(align: align)),
                        icon: Icon(switch (align) {
                          TextAlign.center => Icons.format_align_center,
                          TextAlign.right => Icons.format_align_right,
                          _ => Icons.format_align_left,
                        }),
                      ),
                  ],
                ),
              ],
              if (selected.length == 1) ...[
                const SizedBox(height: 12),
                Text(
                  '尺寸 ${selected.single.rect.width.round()} × ${selected.single.rect.height.round()}',
                ),
                const Text('拖动右下角控制点调整尺寸'),
              ],
            ],
          ),
        ),
      );
    },
  );
  Widget _color(
    BuildContext context,
    String label,
    Color? color,
    ValueChanged<Color> change,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    trailing: Container(
      width: color == null ? 44 : 28,
      height: 28,
      alignment: Alignment.center,
      decoration: color == null
          ? BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(4),
            )
          : BoxDecoration(
              color: color,
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(4),
            ),
      child: color == null ? const Text('多项') : null,
    ),
    onTap: () async {
      final input = TextEditingController(
        text: (color ?? controller.defaults.fill)
            .toARGB32()
            .toRadixString(16)
            .padLeft(8, '0')
            .substring(2),
      );
      final chosen = await showDialog<Color>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(label),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in [
                    Colors.black,
                    Colors.white,
                    Colors.red,
                    Colors.orange,
                    Colors.amber,
                    Colors.green,
                    Colors.blue,
                    Colors.purple,
                    Colors.transparent,
                  ])
                    InkWell(
                      onTap: () => Navigator.pop(context, value),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: value,
                              border: Border.all(
                                color: Theme.of(context).dividerColor,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: value == Colors.transparent
                                ? const Icon(Icons.block, size: 20)
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: input,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: '自定义颜色',
                  prefixText: '#',
                  hintText: '六位十六进制',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final raw = input.text.trim();
                if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(raw)) {
                  Navigator.pop(
                    context,
                    Color(0xff000000 | int.parse(raw, radix: 16)),
                  );
                }
              },
              child: const Text('确定'),
            ),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      input.dispose();
      if (chosen != null) change(chosen);
    },
  );
}
