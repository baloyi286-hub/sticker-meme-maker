import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
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

class MemeTextLayer {
  MemeTextLayer({String text = '', this.x = 40, this.y = 40,
    this.width = 200, this.fontSize = 28, this.angle = 0, this.font = 'Arial',
    this.color = 0xff000000, this.align = 'left', this.bold = false,
    this.italic = false, this.underline = false})
      : controller = TextEditingController(text: text);
  final TextEditingController controller;
  double x, y, width, fontSize, angle;
  String font, align;
  int color;
  bool bold, italic, underline;
  Map<String, dynamic> toJson() => {
    'text': controller.text, 'x': x, 'y': y,
    'width': width, 'fontSize': fontSize, 'angle': angle,
    'font': font, 'color': color, 'align': align,
    'bold': bold, 'italic': italic, 'underline': underline,
  };
  factory MemeTextLayer.fromJson(Map<String, dynamic> json) => MemeTextLayer(
    text: json['text'] as String? ?? '',
    x: (json['x'] as num?)?.toDouble() ?? 40,
    y: (json['y'] as num?)?.toDouble() ?? 40,
    width: (json['width'] as num?)?.toDouble() ?? 200,
    fontSize: (json['fontSize'] as num?)?.toDouble() ?? 28,
    angle: (json['angle'] as num?)?.toDouble() ?? 0,
    font: json['font'] as String? ?? 'Arial',
    color: (json['color'] as num?)?.toInt() ?? 0xff000000,
    align: json['align'] as String? ?? 'left',
    bold: json['bold'] == true, italic: json['italic'] == true,
    underline: json['underline'] == true,
  );
  void dispose() => controller.dispose();
}

class MemeEditor extends StatefulWidget {
  const MemeEditor({super.key});
  @override
  State<MemeEditor> createState() => _MemeEditorState();
}

class _MemeEditorState extends State<MemeEditor> {
  final layers = <StickerLayer>[];
  final textLayers = <MemeTextLayer>[];
  int? selectedText;
  bool editingText = false;
  final textFocus = FocusNode();
  TextStyle memeFontStyle(MemeTextLayer layer) {
    final style = TextStyle(
      color: Color(layer.color), fontSize: layer.fontSize,
      fontWeight: layer.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: layer.italic ? FontStyle.italic : FontStyle.normal,
      decoration: layer.underline ? TextDecoration.underline : TextDecoration.none);
    // These are browser/system fonts, not substitutes for Google Fonts.
    if (const ['Arial', 'Georgia', 'Courier New', 'Times New Roman']
        .contains(layer.font)) {
      return style.copyWith(fontFamily: layer.font);
    }
    return GoogleFonts.getFont(layer.font,
      color: style.color, fontSize: style.fontSize,
      fontWeight: style.fontWeight, fontStyle: style.fontStyle,
      decoration: style.decoration);
  }

  void finishTextEditing() {
    textFocus.unfocus();
    setState(() {
      editingText = false;
      if (selectedText != null && textLayers[selectedText!].controller.text.trim().isEmpty) {
        textLayers.removeAt(selectedText!).dispose();
      }
      selectedText = null;
      selected = null;
    });
  }
  final caption = TextEditingController();
  final boundary = GlobalKey();
  final focus = FocusNode();
  Color background = Colors.white;
  double captionX = 12, captionY = 40, captionSize = 28, captionWidth = 240;
  TextAlign captionAlign = TextAlign.left;
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
      selectedText = null;
      editingText = false;
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
              setState(() {
                textColor = color;
                if (selectedText != null) textLayers[selectedText!].color = color.toARGB32();
              });
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
      setState(() { selected = null; selectedText = null; editingText = false; });
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
    'captionWidth': captionWidth, 'captionAlign': captionAlign.name,
    'layers': layers.map((layer) => layer.toJson()).toList(),
    'textLayers': textLayers.map((layer) => layer.toJson()).toList(),
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
      for (final layer in textLayers) { layer.dispose(); }
      textLayers.clear();
      if (data['textLayers'] is List) {
        textLayers.addAll((data['textLayers'] as List).map((e) =>
          MemeTextLayer.fromJson(Map<String, dynamic>.from(e as Map))));
      } else if ((data['caption'] as String? ?? '').isNotEmpty) {
        textLayers.add(MemeTextLayer(text: data['caption'] as String,
          x: (data['captionX'] as num?)?.toDouble() ?? 12,
          y: (data['captionY'] as num?)?.toDouble() ?? 40,
          fontSize: (data['captionSize'] as num?)?.toDouble() ?? 28));
      }
      selectedText = null;
      editingText = false;
      caption.text = '';
      background = Color(data['background'] as int);
      textColor = Color(data['textColor'] as int);
      captionX = (data['captionX'] as num?)?.toDouble() ?? 12;
      captionY = (data['captionY'] as num?)?.toDouble() ?? 300;
      captionSize = (data['captionSize'] as num?)?.toDouble() ?? 28;
      captionFont = data['captionFont'] as String? ?? 'Arial';
      captionWidth = (data['captionWidth'] as num?)?.toDouble() ?? 240;
      captionAlign = TextAlign.values.firstWhere(
        (a) => a.name == data['captionAlign'], orElse: () => TextAlign.left);
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
    for (final layer in textLayers) { layer.dispose(); }
    textLayers.clear();
    selectedText = null;
    editingText = false;
    caption.clear();
    projectName = null;
    selected = null;
    background = Colors.white;
    textColor = Colors.black;
    captionX = 12;
    captionY = 40;
    captionWidth = 240;
    captionAlign = TextAlign.left;
    captionSize = 28;
    captionFont = 'Arial';
  });

  @override
  void dispose() {
    pasteSubscription?.cancel();
    for (final layer in textLayers) { layer.dispose(); }
    caption.dispose();
    focus.dispose();
    textFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(projectName ?? 'Sticker Meme Maker'), actions: [
      IconButton(tooltip: 'Paste sticker', onPressed: pasteSticker,
        icon: const Icon(Icons.content_paste)),
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
              Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque,
                onTap: finishTextEditing)),
              for (var i = 0; i < layers.length; i++)
                Positioned(
                  left: layers[i].x, top: layers[i].y,
                  child: GestureDetector(
                    onTap: () => setState(() { selected = i; selectedText = null; editingText = false; }),
                    onPanStart: (_) => setState(() { selected = i; selectedText = null; editingText = false; }),
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
              for (var i = 0; i < textLayers.length; i++)
                Positioned(
                  left: textLayers[i].x, top: textLayers[i].y,
                  child: Transform.rotate(
                    angle: textLayers[i].angle,
                    child: Container(
                      width: textLayers[i].width,
                      decoration: BoxDecoration(border: Border.all(
                        color: selectedText == i ? Colors.purpleAccent : Colors.transparent)),
                      child: Stack(clipBehavior: Clip.none, children: [
                        Padding(padding: EdgeInsets.only(left: 8,
                          top: 22, right: 8, bottom: 10),
                          child: editingText && selectedText == i
                            ? TextField(
                                controller: textLayers[i].controller,
                                focusNode: textFocus,
                                onChanged: (_) => setState(() {}),
                                keyboardType: TextInputType.multiline,
                                maxLines: null,
                                textAlign: TextAlign.values.firstWhere(
                                  (a) => a.name == textLayers[i].align,
                                  orElse: () => TextAlign.left),
                                style: memeFontStyle(textLayers[i]),
                                decoration: const InputDecoration(isDense: true,
                                  border: InputBorder.none, hintText: 'Type text...'))
                            : GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => setState(() {
                                  selectedText = i; selected = null; editingText = true;
                                }),
                                child: Text(textLayers[i].controller.text,
                                  textAlign: TextAlign.values.firstWhere(
                                    (a) => a.name == textLayers[i].align,
                                    orElse: () => TextAlign.left),
                                  style: memeFontStyle(textLayers[i])))),
                        if (selectedText == i)
                          Positioned(top: 0, left: 0, right: 0,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanUpdate: (d) => setState(() {
                                textLayers[i].x = (textLayers[i].x + d.delta.dx)
                                  .clamp(0, math.max(0, constraints.maxWidth - 40));
                                textLayers[i].y = (textLayers[i].y + d.delta.dy)
                                  .clamp(0, math.max(0, constraints.maxHeight - 40));
                              }),
                              child: Container(height: 20,
                                color: Colors.purpleAccent.withValues(alpha: 0.18),
                                child: const Icon(Icons.drag_indicator, size: 15)))),
                        if (selectedText == i)
                          Positioned(right: -7, bottom: -7,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanUpdate: (d) => setState(() {
                                final oldWidth = textLayers[i].width;
                                textLayers[i].width = (oldWidth + d.delta.dx)
                                  .clamp(70, math.max(70, constraints.maxWidth - textLayers[i].x));
                                textLayers[i].fontSize = (textLayers[i].fontSize *
                                  textLayers[i].width / oldWidth).clamp(10, 120);
                              }),
                              child: Container(width: 28, height: 28,
                                color: Colors.purpleAccent,
                                child: const Icon(Icons.open_in_full, size: 17)))),
                      ]),
                    ),
                  ),
                ),
            ]),
          ));
        }),
      ))),
      Padding(padding: const EdgeInsets.all(8), child: Column(children: [
        SizedBox(height: 48, child: selectedText == null
          ? const SizedBox.shrink()
          : SingleChildScrollView(scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final alignment in ['left', 'center', 'right'])
                IconButton(
                  tooltip: 'Align $alignment',
                  onPressed: () => setState(() => textLayers[selectedText!].align = alignment),
                  icon: Icon(alignment == 'left' ? Icons.format_align_left :
                    alignment == 'center' ? Icons.format_align_center : Icons.format_align_right),
                  color: textLayers[selectedText!].align == alignment
                    ? Colors.purpleAccent : null),
              IconButton(tooltip: 'Text colour', onPressed: chooseTextColor,
                icon: const Icon(Icons.format_color_text)),
              DropdownButton<String>(
                value: textLayers[selectedText!].font,
                items: const ['Roboto', 'Arial', 'Georgia', 'Courier New', 'Times New Roman', 'Open Sans', 'Lora', 'Roboto Mono', 'Merriweather']
                  .map((font) => DropdownMenuItem(value: font, child: Text(font))).toList(),
                onChanged: (font) { if (font != null) setState(() =>
                  textLayers[selectedText!].font = font); }),
              IconButton(tooltip: 'Bold', icon: const Icon(Icons.format_bold),
                color: textLayers[selectedText!].bold ? Colors.purpleAccent : null,
                onPressed: () => setState(() =>
                  textLayers[selectedText!].bold = !textLayers[selectedText!].bold)),
              IconButton(tooltip: 'Italic', icon: const Icon(Icons.format_italic),
                color: textLayers[selectedText!].italic ? Colors.purpleAccent : null,
                onPressed: () => setState(() =>
                  textLayers[selectedText!].italic = !textLayers[selectedText!].italic)),
              IconButton(tooltip: 'Underline', icon: const Icon(Icons.format_underline),
                color: textLayers[selectedText!].underline ? Colors.purpleAccent : null,
                onPressed: () => setState(() =>
                  textLayers[selectedText!].underline = !textLayers[selectedText!].underline)),
            ]))),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          FilledButton.icon(onPressed: importSticker,
            icon: const Icon(Icons.add_photo_alternate), label: const Text('Add sticker')),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: () => setState(() {
            textLayers.add(MemeTextLayer(x: 35, y: 35,
              width: math.min(220, canvasWidth - 35)));
            selectedText = textLayers.length - 1;
            selected = null;
            editingText = true;
          }), icon: const Icon(Icons.text_fields), label: const Text('Add text')),
          const SizedBox(width: 8),
          FilledButton(onPressed: exportPng, child: const Text('Download As Image')),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: exportingMp4 ? null : exportAnimatedMp4,
            icon: exportingMp4 ? const SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.movie),
            label: const Text('Download As Animation')),
        ])),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          OutlinedButton(onPressed: selected == null && selectedText == null ? null :
            () => setState(() {
              if (selected != null) layers[selected!].angle += math.pi / 8;
              if (selectedText != null) textLayers[selectedText!].angle += math.pi / 8;
            }), child: const Text('Rotate')),
          OutlinedButton(onPressed: selected == null && selectedText == null ? null :
            () => setState(() {
              if (selected != null) {
                final source = layers[selected!];
                layers.add(StickerLayer(source.bytes, name: source.name,
                  x: source.x + 15, y: source.y + 15,
                  size: source.size, angle: source.angle));
                selected = layers.length - 1;
              } else if (selectedText != null) {
                final source = textLayers[selectedText!];
                textLayers.add(MemeTextLayer(text: source.controller.text,
                  x: source.x + 15, y: source.y + 15, width: source.width,
                  fontSize: source.fontSize, angle: source.angle,
                  font: source.font, color: source.color, align: source.align,
                  bold: source.bold, italic: source.italic, underline: source.underline));
                selectedText = textLayers.length - 1;
              }
            }), child: const Text('Duplicate')),
          OutlinedButton(onPressed: selected == null && selectedText == null ? null :
            () => setState(() {
              if (selected != null) { layers.removeAt(selected!); selected = null; }
              if (selectedText != null) {
                textLayers.removeAt(selectedText!).dispose();
                selectedText = null;
                editingText = false;
              }
            }), child: const Text('Delete')),
          OutlinedButton(onPressed: () => setState(() =>
            background = background == Colors.white ? Colors.black : Colors.white),
            child: const Text('Black / White BG')),
        ])),
      ])),
    ])),
  );
}
