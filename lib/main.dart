import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;

void main() => runApp(const MemeApp());

class MemeApp extends StatelessWidget {
  const MemeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Sticker Meme Maker',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const MemeEditor(),
  );
}

class StickerLayer {
  StickerLayer(this.bytes, {this.x = 40, this.y = 40, this.size = 130});
  final Uint8List bytes;
  double x;
  double y;
  double size;
}

class MemeEditor extends StatefulWidget {
  const MemeEditor({super.key});
  @override
  State<MemeEditor> createState() => _MemeEditorState();
}

class _MemeEditorState extends State<MemeEditor> {
  final layers = <StickerLayer>[];
  final caption = TextEditingController();
  final boundary = GlobalKey();
  Color background = const Color(0xFF232323);
  int? selected;

  Future<void> importSticker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
      withData: true,
      allowMultiple: true,
    );
    if (result == null) return;
    setState(() {
      for (final file in result.files) {
        if (file.bytes != null) layers.add(StickerLayer(file.bytes!));
      }
      selected = layers.isEmpty ? null : layers.length - 1;
    });
  }

  Future<void> exportPng() async {
    final render = boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (render == null) return;
    final image = await render.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || !mounted) return;
    // Export bytes are ready; platform-specific save/share will be added next.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PNG rendered. File download is not wired yet.')),
    );
  }

  @override
  void dispose() {
    caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sticker Meme Maker')),
    body: SafeArea(child: Column(children: [
      Expanded(child: Center(child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(builder: (context, constraints) =>
          RepaintBoundary(key: boundary, child: Container(
            color: background,
            child: Stack(children: [
              for (var i = 0; i < layers.length; i++)
                Positioned(
                  left: layers[i].x, top: layers[i].y,
                  child: GestureDetector(
                    onTap: () => setState(() => selected = i),
                    onPanUpdate: (details) => setState(() {
                      layers[i].x = (layers[i].x + details.delta.dx).clamp(0, constraints.maxWidth - 30);
                      layers[i].y = (layers[i].y + details.delta.dy).clamp(0, constraints.maxHeight - 30);
                    }),
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(
                        color: selected == i ? Colors.lightGreenAccent : Colors.transparent,
                      )),
                      child: Image.memory(layers[i].bytes, width: layers[i].size, height: layers[i].size),
                    ),
                  ),
                ),
              Positioned(left: 12, right: 12, bottom: 20, child: Text(
                caption.text, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900,
                  shadows: [Shadow(blurRadius: 5, color: Colors.black)]),
              )),
            ]),
          )),
        ),
      ))),
      Padding(padding: const EdgeInsets.all(12), child: Column(children: [
        TextField(controller: caption, onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Meme caption', border: OutlineInputBorder())),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          FilledButton.icon(onPressed: importSticker, icon: const Icon(Icons.add_photo_alternate), label: const Text('Add sticker')),
          OutlinedButton(onPressed: selected == null ? null : () => setState(() => layers[selected!].size += 20), child: const Text('Larger')),
          OutlinedButton(onPressed: selected == null ? null : () => setState(() => layers[selected!].size = (layers[selected!].size - 20).clamp(40, 500)), child: const Text('Smaller')),
          OutlinedButton(onPressed: selected == null ? null : () => setState(() { layers.removeAt(selected!); selected = null; }), child: const Text('Delete')),
          FilledButton(onPressed: exportPng, child: const Text('Render PNG')),
        ]),
      ])),
    ])),
  );
}
