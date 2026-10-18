import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
  StickerLayer(this.bytes, {this.name = 'Sticker', this.x = 35, this.y = 35,
    this.size = 130, this.angle = 0});
  final Uint8List bytes;
  final String name;
  double x;
  double y;
  double size;
  double angle;

  Map<String, dynamic> toJson() => {
    'bytes': base64Encode(bytes), 'name': name, 'x': x, 'y': y,
    'size': size, 'angle': angle,
  };
  factory StickerLayer.fromJson(Map<String, dynamic> json) => StickerLayer(
    base64Decode(json['bytes'] as String),
    name: json['name'] as String? ?? 'Sticker',
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    size: (json['size'] as num).toDouble(),
    angle: (json['angle'] as num).toDouble(),
  );
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
  final focus = FocusNode();
  Color background = const Color(0xFF232323);
  Color textColor = Colors.white;
  int? selected;
  String? projectName;
  StreamSubscription<html.Event>? pasteSubscription;
  static const storageKey = 'sticker_meme_projects_v1';
  static const stickerLibraryKey = 'sticker_meme_library_v1';

  @override
  void initState() {
    super.initState();
    pasteSubscription = html.window.onPaste.listen((event) {
      final clipboard = (event as html.ClipboardEvent).clipboardData;
      if (clipboard == null) return;
      for (final file in clipboard.files) {
        if (file.type.startsWith('image/')) {
          _readFile(file);
          event.preventDefault();
          break;
        }
      }
    });
  }

  void message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _readFile(html.File file) async {
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    await reader.onLoad.first;
    final result = reader.result;
    if (result is ByteBuffer) addSticker(result.asUint8List(), file.name, saveToLibrary: true);
    else if (result is Uint8List) addSticker(result, file.name, saveToLibrary: true);
  }

  void addSticker(Uint8List bytes, String name, {bool saveToLibrary = false}) {
    if (bytes.lengthInBytes > 12 * 1024 * 1024) {
      message('Sticker exceeds 12 MB limit');
      return;
    }
    if (saveToLibrary) saveStickerToLibrary(bytes, name);
    setState(() {
      layers.add(StickerLayer(bytes, name: name));
      selected = layers.length - 1;
    });
  }

  Future<void> importSticker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
      withData: true,
      allowMultiple: true,
    );
    if (result == null) return;
    for (final file in result.files) {
      if (file.bytes != null) addSticker(file.bytes!, file.name, saveToLibrary: true);
    }
  }


  List<Map<String, dynamic>> libraryItems() {
    try {
      final items = jsonDecode(html.window.localStorage[stickerLibraryKey] ?? '[]') as List;
      return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  void saveStickerToLibrary(Uint8List bytes, String name) {
    try {
      final items = libraryItems();
      final encoded = base64Encode(bytes);
      if (items.any((item) => item['bytes'] == encoded)) return;
      items.insert(0, {
        'id': DateTime.now().microsecondsSinceEpoch.toString(),
        'name': name,
        'bytes': encoded,
      });
      html.window.localStorage[stickerLibraryKey] = jsonEncode(items);
    } catch (_) {
      message('Sticker added to canvas, but browser library storage is full.');
    }
  }

  void showStickerLibrary() {
    final items = libraryItems();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.7,
          child: Column(children: [
            const ListTile(
              title: Text('My stickers'),
              subtitle: Text('Saved in this browser. Tap to reuse.'),
            ),
            Expanded(child: items.isEmpty
              ? const Center(child: Text('No stickers yet. Paste or import an image.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130, mainAxisSpacing: 10, crossAxisSpacing: 10),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final bytes = base64Decode(item['bytes'] as String);
                    return Stack(children: [
                      Positioned.fill(child: InkWell(
                        onTap: () {
                          Navigator.pop(sheetContext);
                          addSticker(bytes, item['name'] as String? ?? 'Sticker');
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white10,
                            borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.all(12),
                          child: Image.memory(bytes, fit: BoxFit.contain),
                        ),
                      )),
                      Positioned(top: 0, right: 0, child: IconButton(
                        tooltip: 'Delete sticker',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          items.removeAt(index);
                          html.window.localStorage[stickerLibraryKey] = jsonEncode(items);
                          Navigator.pop(sheetContext);
                          showStickerLibrary();
                        },
                      )),
                    ]);
                  },
                )),
          ]),
        ),
      ),
    );
  }

  void pasteSticker() {
    message('Copy an image, then press Ctrl+V (or Cmd+V). On iPhone, use Add sticker.');
  }

  void download(Uint8List bytes, String name, String mime) {
    final blob = html.Blob([bytes], mime);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)..download = name..click();
    Future<void>.delayed(const Duration(seconds: 2), () => html.Url.revokeObjectUrl(url));
  }

  Future<void> exportPng() async {
    try {
      setState(() => selected = null);
      await WidgetsBinding.instance.endOfFrame;
      final render = boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (render == null) return;
      final image = await render.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data != null) download(data.buffer.asUint8List(), 'sticker-meme.png', 'image/png');
    } catch (e) {
      message('Unable to export image: $e');
    }
  }

  Map<String, dynamic> snapshot() => {
    'caption': caption.text,
    'background': background.value,
    'textColor': textColor.value,
    'layers': layers.map((layer) => layer.toJson()).toList(),
  };

  Map<String, dynamic> allProjects() {
    try {
      return Map<String, dynamic>.from(jsonDecode(html.window.localStorage[storageKey] ?? '{}') as Map);
    } catch (_) {
      return {};
    }
  }

  void saveProject() {
    final name = projectName ?? 'Meme ${DateTime.now().toLocal().toString().substring(0, 16)}';
    try {
      final projects = allProjects();
      projects[name] = snapshot();
      html.window.localStorage[storageKey] = jsonEncode(projects);
      setState(() => projectName = name);
      message('Saved "$name" on this browser');
    } catch (_) {
      message('Browser storage full. Try fewer or smaller stickers.');
    }
  }

  void loadProject(String name) {
    final data = Map<String, dynamic>.from(allProjects()[name] as Map);
    setState(() {
      layers..clear()..addAll((data['layers'] as List).map(
        (e) => StickerLayer.fromJson(Map<String, dynamic>.from(e as Map))));
      caption.text = data['caption'] as String? ?? '';
      background = Color(data['background'] as int);
      textColor = Color(data['textColor'] as int);
      projectName = name;
      selected = null;
    });
  }

  void showProjects() {
    final projects = allProjects();
    showModalBottomSheet<void>(context: context, builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Saved projects')),
        if (projects.isEmpty) const ListTile(title: Text('No saved projects')),
        for (final name in projects.keys)
          ListTile(title: Text(name), leading: const Icon(Icons.folder),
            onTap: () { Navigator.pop(context); loadProject(name); },
            trailing: IconButton(icon: const Icon(Icons.delete_outline),
              onPressed: () {
                projects.remove(name);
                html.window.localStorage[storageKey] = jsonEncode(projects);
                Navigator.pop(context);
                showProjects();
              })),
      ]),
    ));
  }

  void newProject() => setState(() {
    layers.clear();
    caption.clear();
    projectName = null;
    selected = null;
  });

  @override
  void dispose() {
    pasteSubscription?.cancel();
    caption.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(projectName ?? 'Sticker Meme Maker'), actions: [
      IconButton(tooltip: 'My stickers', onPressed: showStickerLibrary,
        icon: const Icon(Icons.collections_bookmark)),
      IconButton(tooltip: 'New meme', onPressed: newProject, icon: const Icon(Icons.add)),
      IconButton(tooltip: 'Open saved', onPressed: showProjects, icon: const Icon(Icons.folder_open)),
      IconButton(tooltip: 'Save project', onPressed: saveProject, icon: const Icon(Icons.save)),
    ]),
    body: SafeArea(child: Column(children: [
      Expanded(child: Center(child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(builder: (context, constraints) =>
          RepaintBoundary(key: boundary, child: Container(
            color: background,
            child: Stack(clipBehavior: Clip.hardEdge, children: [
              for (var i = 0; i < layers.length; i++)
                Positioned(
                  left: layers[i].x, top: layers[i].y,
                  child: GestureDetector(
                    onTap: () => setState(() => selected = i),
                    onPanUpdate: (details) => setState(() {
                      layers[i].x = (layers[i].x + details.delta.dx).clamp(0, math.max(0, constraints.maxWidth - 30));
                      layers[i].y = (layers[i].y + details.delta.dy).clamp(0, math.max(0, constraints.maxHeight - 30));
                    }),
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(
                        color: selected == i ? Colors.lightGreenAccent : Colors.transparent,
                      )),
                      child: Transform.rotate(
                        angle: layers[i].angle,
                        child: Image.memory(layers[i].bytes, width: layers[i].size,
                          height: layers[i].size, gaplessPlayback: true),
                      ),
                    ),
                  ),
                ),
              Positioned(left: 12, right: 12, bottom: 20, child: IgnorePointer(
                child: Text(caption.text, textAlign: TextAlign.center,
                  style: TextStyle(color: textColor, fontSize: 28,
                    fontWeight: FontWeight.w900,
                    shadows: const [Shadow(blurRadius: 5, color: Colors.black)])),
              )),
            ]),
          )),
        ),
      ))),
      Padding(padding: const EdgeInsets.all(12), child: Column(children: [
        TextField(controller: caption, focusNode: focus,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Meme caption',
            border: OutlineInputBorder())),
        const SizedBox(height: 10),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          FilledButton.icon(onPressed: importSticker,
            icon: const Icon(Icons.add_photo_alternate), label: const Text('Add sticker')),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: pasteSticker, child: const Text('Paste')),
          OutlinedButton(onPressed: showStickerLibrary, child: const Text('My stickers')),
          OutlinedButton(onPressed: selected == null ? null : () => setState(() => layers[selected!].size += 20), child: const Text('Larger')),
          OutlinedButton(onPressed: selected == null ? null : () => setState(() => layers[selected!].size = (layers[selected!].size - 20).clamp(40, 500)), child: const Text('Smaller')),
          OutlinedButton(onPressed: selected == null ? null : () => setState(() => layers[selected!].angle += math.pi / 8), child: const Text('Rotate')),
          OutlinedButton(onPressed: selected == null ? null : () => setState(() {
            final source = layers[selected!];
            layers.add(StickerLayer(source.bytes, name: source.name,
              x: source.x + 15, y: source.y + 15,
              size: source.size, angle: source.angle));
            selected = layers.length - 1;
          }), child: const Text('Duplicate')),
          OutlinedButton(onPressed: () => setState(() => background =
            background == Colors.white ? const Color(0xFF232323) : Colors.white),
            child: const Text('Background')),
          OutlinedButton(onPressed: () => setState(() => textColor =
            textColor == Colors.white ? Colors.black : Colors.white),
            child: const Text('Text colour')),
          OutlinedButton(onPressed: selected == null ? null : () => setState(() {
            layers.removeAt(selected!);
            selected = null;
          }), child: const Text('Delete')),
          FilledButton(onPressed: exportPng, child: const Text('Download PNG')),
        ])),
      ])),
    ])),
  );
}
