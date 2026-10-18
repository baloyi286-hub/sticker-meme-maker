import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

@JS('uploadSharedSticker')
external JSPromise<JSString> uploadSharedSticker(JSString base64);
@JS('listSharedStickers')
external JSPromise<JSString> listSharedStickers(JSString cursor);
@JS('exportAnimatedMeme')
external JSPromise<JSAny?> exportAnimatedMemeJs(JSString json);

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
  Color background = Colors.white;
  double captionX = 12, captionY = 300, captionSize = 28;
  String captionFont = 'Arial';
  Color textColor = Colors.black;
  int? selected;
  bool exportingMp4 = false;
  double canvasWidth = 400;
  String? projectName;
  StreamSubscription<html.Event>? pasteSubscription;
  static const storageKey = 'sticker_meme_projects_v1';
  static const stickerLibraryKey = 'sticker_meme_library_v1';

  @override
  void initState() {
    super.initState();
    pasteSubscription = html.document.on['paste'].listen((event) {
      final clipboard = (event as html.ClipboardEvent).clipboardData;
      if (clipboard == null) return;
      for (final file in clipboard.files ?? <html.File>[]) {
        if (file.type.startsWith('image/')) {
          _readFile(file);
          event.preventDefault();
          break;
        }
      }
    });
    unawaited(syncLocalStickers());
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
    if (result is ByteBuffer) {
      addSticker(result.asUint8List(), file.name, saveToLibrary: true);
    } else if (result is Uint8List) {
      addSticker(result, file.name, saveToLibrary: true);
    }
  }

  void addSticker(Uint8List bytes, String name, {bool saveToLibrary = false}) {
    if (bytes.lengthInBytes > 12 * 1024 * 1024) {
      message('Sticker exceeds 12 MB limit');
      return;
    }
    if (saveToLibrary) {
      saveStickerToLibrary(bytes, name);
      unawaited(uploadStickerToBlob(bytes, name));
    }
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

  Future<void> syncLocalStickers() async {
    final pending = libraryItems();
    if (pending.isEmpty) return;
    final remaining = <Map<String, dynamic>>[];
    for (final item in pending) {
      try {
        await uploadSharedSticker((item['bytes'] as String).toJS).toDart;
      } catch (_) {
        remaining.add(item);
      }
    }
    try {
      html.window.localStorage[stickerLibraryKey] = jsonEncode(remaining);
    } catch (_) {
      // Local storage may be unavailable in private browsing.
    }
  }

  Future<void> uploadStickerToBlob(Uint8List bytes, String name) async {
    try {
      await uploadSharedSticker(base64Encode(bytes).toJS).toDart;
      final encoded = base64Encode(bytes);
      final remaining = libraryItems()..removeWhere((item) => item['bytes'] == encoded);
      html.window.localStorage[stickerLibraryKey] = jsonEncode(remaining);
      message('Sticker saved to shared gallery.');
    } catch (error) {
      message('Cloud upload failed; sticker kept locally for retry: $error');
    }
  }

  Future<List<Map<String, dynamic>>> sharedStickers() async {
    await syncLocalStickers();
    final items = <Map<String, dynamic>>[];
    String cursor = '';
    do {
      final result = (await listSharedStickers(cursor.toJS).toDart).toDart;
      final page = jsonDecode(result) as Map<String, dynamic>;
      items.addAll((page['stickers'] as List)
        .map((item) => Map<String, dynamic>.from(item as Map)));
      cursor = page['hasMore'] == true ? (page['cursor'] as String? ?? '') : '';
    } while (cursor.isNotEmpty);
    items.sort((a, b) => (b['uploadedAt']?.toString() ?? '')
      .compareTo(a['uploadedAt']?.toString() ?? ''));
    return items;
  }

  Future<void> addSharedSticker(String url, String name) async {
    try {
      final request = await html.HttpRequest.request(url, responseType: 'arraybuffer');
      final result = request.response;
      if (result is ByteBuffer) {
        addSticker(result.asUint8List(), name);
      } else if (result is Uint8List) {
        addSticker(result, name);
      } else {
        throw StateError('Unable to read sticker image.');
      }
    } catch (error) {
      message('Unable to load shared sticker: $error');
    }
  }

  void showStickerLibrary() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.7,
          child: Column(children: [
            const ListTile(
              title: Text('Shared stickers'),
              subtitle: Text('Everyone can reuse stickers saved in Vercel Blob.'),
            ),
            Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(
              future: sharedStickers(),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('Unable to load shared stickers: ${snapshot.error}')));
                }
                final items = snapshot.data ?? [];
                if (items.isEmpty) {
                  return const Center(child: Text('No shared stickers yet. Add one!'));
                }
                return GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130, mainAxisSpacing: 10, crossAxisSpacing: 10),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final url = item['url'] as String;
                    final name = (item['pathname'] as String).split('/').last;
                    return InkWell(
                      onTap: () {
                        Navigator.pop(sheetContext);
                        unawaited(addSharedSticker(url, name));
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.all(12),
                        child: Image.network(url, fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image)),
                      ),
                    );
                  },
                );
              },
            )),
          ]),
        ),
      ),
    );
  }

  void chooseTextColor() {
    const colors = <Color>[
      Colors.black, Colors.white, Colors.red, Colors.orange,
      Colors.yellow, Colors.green, Colors.blue, Colors.purple, Colors.pink,
    ];
    showModalBottomSheet<void>(context: context, builder: (sheetContext) =>
      SafeArea(child: Padding(padding: const EdgeInsets.all(20),
        child: Wrap(spacing: 14, runSpacing: 14, children: [
          for (final color in colors)
            InkWell(onTap: () {
              setState(() => textColor = color);
              Navigator.pop(sheetContext);
            }, child: CircleAvatar(backgroundColor: color, radius: 22,
              child: textColor == color ? const Icon(Icons.check, color: Colors.grey) : null)),
        ]))));
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

  Future<void> exportAnimatedMp4() async {
    if (exportingMp4) return;
    setState(() => exportingMp4 = true);
    try {
      final data = snapshot()..['canvasWidth'] = canvasWidth;
      await exportAnimatedMemeJs(jsonEncode(data).toJS).toDart;
      message('MP4 downloaded. Ready for WhatsApp Status.');
    } catch (error) {
      message('Unable to export MP4: $error');
    } finally {
      if (mounted) setState(() => exportingMp4 = false);
    }
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
    'background': background.toARGB32(),
    'textColor': textColor.toARGB32(),
    'captionX': captionX, 'captionY': captionY,
    'captionSize': captionSize, 'captionFont': captionFont,
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
      captionX = (data['captionX'] as num?)?.toDouble() ?? 12;
      captionY = (data['captionY'] as num?)?.toDouble() ?? 300;
      captionSize = (data['captionSize'] as num?)?.toDouble() ?? 28;
      captionFont = data['captionFont'] as String? ?? 'Arial';
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
    background = Colors.white;
    textColor = Colors.black;
    captionX = 12;
    captionY = 300;
    captionSize = 28;
    captionFont = 'Arial';
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
        child: LayoutBuilder(builder: (context, constraints) {
          canvasWidth = constraints.maxWidth;
          return RepaintBoundary(key: boundary, child: Container(
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
              Positioned(
                left: captionX.clamp(0, math.max(0, constraints.maxWidth - 40)),
                top: captionY.clamp(0, math.max(0, constraints.maxHeight - 40)),
                child: GestureDetector(
                  onPanUpdate: (details) => setState(() {
                    captionX = (captionX + details.delta.dx).clamp(0, math.max(0, constraints.maxWidth - 40));
                    captionY = (captionY + details.delta.dy).clamp(0, math.max(0, constraints.maxHeight - 40));
                  }),
                  child: SizedBox(
                    width: math.max(40, constraints.maxWidth - captionX),
                    child: Text(caption.text, textAlign: TextAlign.center,
                      style: TextStyle(color: textColor, fontSize: captionSize,
                        fontFamily: captionFont, fontWeight: captionFont == 'Arial' ? FontWeight.w400 : FontWeight.w900)),
                  ),
                ),
              ),
            ]),
          ));
        }),
      ))),
      Padding(padding: const EdgeInsets.all(12), child: Column(children: [
        TextField(controller: caption, focusNode: focus,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Meme caption',
            border: OutlineInputBorder())),
        Row(children: [
          const Text('Font size'),
          Expanded(child: Slider(min: 12, max: 72, value: captionSize,
            onChanged: (value) => setState(() => captionSize = value))),
          Text(captionSize.round().toString()),
          const SizedBox(width: 8),
          DropdownButton<String>(value: captionFont,
            items: const ['Roboto', 'Arial', 'Georgia', 'Courier New', 'Times New Roman']
              .map((font) => DropdownMenuItem(value: font, child: Text(font))).toList(),
            onChanged: (font) { if (font != null) setState(() => captionFont = font); }),
        ]),
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
            background == Colors.white ? Colors.black : Colors.white),
            child: const Text('Black / White BG')),
          OutlinedButton(onPressed: chooseTextColor,
            child: const Text('Text colour')),
          OutlinedButton(onPressed: selected == null ? null : () => setState(() {
            layers.removeAt(selected!);
            selected = null;
          }), child: const Text('Delete')),
          FilledButton(onPressed: exportPng, child: const Text('Download PNG')),
          FilledButton.icon(onPressed: exportingMp4 ? null : exportAnimatedMp4,
            icon: exportingMp4 ? const SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.movie),
            label: Text(exportingMp4 ? 'Exporting MP4...' : 'Export Animated Meme → MP4')),
        ])),
      ])),
    ])),
  );
}
