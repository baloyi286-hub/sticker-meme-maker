import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Non-destructive preview editor. Apply creates a new transparent PNG.
class StickerImageEditor extends StatefulWidget {
  const StickerImageEditor({super.key, required this.source});
  final Uint8List source;
  @override
  State<StickerImageEditor> createState() => _StickerImageEditorState();
}

class _StickerImageEditorState extends State<StickerImageEditor> {
  double left = 0, top = 0, right = 0, bottom = 0;
  double tolerance = 42;
  bool removeBackground = false;
  bool processing = false;

  Uint8List process() {
    final decoded = img.decodeImage(widget.source);
    if (decoded == null) throw const FormatException('Unsupported image format');
    final x = (left * decoded.width).round();
    final y = (top * decoded.height).round();
    final width = (decoded.width - x - (right * decoded.width).round()).clamp(1, decoded.width);
    final height = (decoded.height - y - (bottom * decoded.height).round()).clamp(1, decoded.height);
    final output = img.copyCrop(decoded, x: x, y: y, width: width, height: height);
    if (removeBackground) {
      // Remove only border-connected pixels close to the top-left colour.
      // This avoids deleting similarly coloured enclosed details.
      final reference = output.getPixel(0, 0);
      final rr = reference.r.toDouble(), gg = reference.g.toDouble(), bb = reference.b.toDouble();
      final visited = Uint8List(width * height);
      final queue = <int>[];
      void enqueue(int px, int py) {
        if (px < 0 || py < 0 || px >= width || py >= height) return;
        final idx = py * width + px;
        if (visited[idx] != 0) return;
        visited[idx] = 1;
        final pixel = output.getPixel(px, py);
        final distance = (pixel.r - rr).abs() + (pixel.g - gg).abs() + (pixel.b - bb).abs();
        if (distance <= tolerance * 3) queue.add(idx);
      }
      for (var x = 0; x < width; x++) { enqueue(x, 0); enqueue(x, height - 1); }
      for (var y = 0; y < height; y++) { enqueue(0, y); enqueue(width - 1, y); }
      for (var i = 0; i < queue.length; i++) {
        final idx = queue[i], px = idx % width, py = idx ~/ width;
        output.setPixelRgba(px, py, 0, 0, 0, 0);
        enqueue(px - 1, py); enqueue(px + 1, py);
        enqueue(px, py - 1); enqueue(px, py + 1);
      }
    }
    return Uint8List.fromList(img.encodePng(output));
  }

  Widget control(String name, double value, ValueChanged<double> update, double max) =>
      Row(children: [
        SizedBox(width: 65, child: Text(name)),
        Expanded(child: Slider(value: value, max: max, divisions: 20,
          label: '${(value * (max == 1 ? 100 : 1)).round()}',
          onChanged: (v) => setState(() => update(v)))),
      ]);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Edit sticker'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(height: 180, width: double.infinity, color: Colors.black26,
          child: Image.memory(widget.source, fit: BoxFit.contain)),
        const SizedBox(height: 8),
        const Text('Crop edges before adding'),
        control('Left', left, (v) => left = v, 0.45),
        control('Right', right, (v) => right = v, 0.45),
        control('Top', top, (v) => top = v, 0.45),
        control('Bottom', bottom, (v) => bottom = v, 0.45),
        SwitchListTile(title: const Text('Remove solid background'),
          subtitle: const Text('Uses the top-left colour; best for plain backgrounds'),
          value: removeBackground,
          onChanged: (v) => setState(() => removeBackground = v)),
        if (removeBackground) control('Tolerance', tolerance,
          (v) => tolerance = v, 120),
      ],
    ))),
    actions: [
      TextButton(onPressed: processing ? null : () => Navigator.pop(context),
        child: const Text('Cancel')),
      FilledButton(onPressed: processing ? null : () async {
        setState(() => processing = true);
        try {
          final result = process();
          if (context.mounted) Navigator.pop(context, result);
        } catch (e) {
          if (context.mounted) {
            setState(() => processing = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Unable to edit sticker: $e')));
          }
        }
      }, child: const Text('Add sticker')),
    ],
  );
}
