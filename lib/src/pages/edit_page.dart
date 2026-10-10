import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_editor/image_editor.dart';
import 'package:matrix_gesture_detector/matrix_gesture_detector.dart';
import 'package:stickers/generated/intl/app_localizations.dart';
import 'package:stickers/src/checker_painter.dart';
import 'package:stickers/src/constants.dart';
import 'package:stickers/src/data/load_store.dart';
import 'package:stickers/src/data/sticker_pack.dart';
import 'package:stickers/src/dialogs/confirm_leave_dialog.dart';
import 'package:stickers/src/dialogs/edit_text_dialog.dart';
import 'package:stickers/src/dialogs/error_dialog.dart';
import 'package:stickers/src/dialogs/eyedropper_dialog.dart';
import 'package:stickers/src/fonts_api/fonts_registry.dart';
import 'package:stickers/src/globals.dart';
import 'package:stickers/src/pages/crop_page.dart';
import 'package:stickers/src/pages/default_page.dart';
import 'package:stickers/src/util.dart';
import 'package:stickers/src/video/common.dart';
import 'package:stickers/src/video/overlay_encode.dart';
import 'package:stickers/src/widgets/draw_layer.dart';
import 'package:stickers/src/widgets/text_layer.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;
import 'package:video_player/video_player.dart';

class EditPage extends StatefulWidget {
  /// Path of the temporary image to edit
  final String imagePath;
  final StickerPack pack;
  final int index;

  const EditPage(this.pack, this.index, this.imagePath, this.mediaType, {super.key});

  static const routeName = "/edit";

  final MediaType mediaType;

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final File _source;
  Size imageSize = const Size(0, 0);
  bool _drawing = false;
  Color _brushColor = Colors.white;
  double _brushSize = 15;
  Offset _brushPos = Offset(0, 0);
  Color? _pickedColor;
  final Curve _curve = Curves.ease;
  final List<UndoEntry> _undo = [];
  final double maxWidth = 200;
  String? _message;
  double? _exportProgress;

  /// The sticker is 512x512 as opposed to the canvas, which is why we need a scale factor
  double scaleFactor = 0;
  final List<EditorText> _texts = [];
  final List<EditorLayer> _layers = [];
  final _webpSizeLock = Lock();

  TextLayer? _currentTextLayer;

  @override
  void initState() {
    super.initState();
    _source = File(widget.imagePath);
    if (widget.mediaType == MediaType.video) {
      _controller = VideoPlayerController.file(
        _source,
        viewType: VideoViewType.textureView,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _controller.setLooping(true);
      _controller.setVolume(0);
      _controller.initialize().then((_) {
        _controller.play();
        setState(() {});
      });
    }
    //_sticker = _pack.stickers[widget.index];
  }

  final GlobalKey _rbKey = GlobalKey();
  bool _exporting = false;
  late VideoPlayerController _controller;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          return;
        }
        bool shouldPop = await showDialog<bool>(
              context: context,
              builder: (builderContext) => ConfirmLeaveDialog(),
            ) ??
            false;
        if (shouldPop && context.mounted) Navigator.of(context).pop();
      },
      child: DefaultActivity(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text(AppLocalizations.of(context)!.editYourSticker),
        ),
        child: SafeArea(
          child: LayoutBuilder(builder: (context, constraints) {
            final isHorizontal = constraints.maxWidth > constraints.maxHeight;
            final double buttonSize = isHorizontal
                ? (min(constraints.maxHeight - 48, 500 - 12)) / (colors.length / 2)
                : min(constraints.maxWidth - 48, 500) / (colors.length / 2);

            final colorButtons = AnimatedCrossFade(
                sizeCurve: _curve,
                firstCurve: _curve,
                secondCurve: _curve,
                firstChild: Container(),
                secondChild: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: colors.getRange(0, (colors.length / 2).floor()).map((c) {
                        return ColorButton(
                          c,
                          size: buttonSize,
                          onTap: () => _setColor(c),
                          active: c == _brushColor,
                        );
                      }).toList(),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: colors
                          .getRange((colors.length / 2).floor() + 1, colors.length)
                          .map((c) => ColorButton(
                                c,
                                size: buttonSize,
                                onTap: () => _setColor(c),
                                active: c == _brushColor,
                              )))
                          .toList(),
                    ),
                    SizedBox(
                      height: 10,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Container(
                            decoration: BoxDecoration(color: _brushColor, borderRadius: BorderRadius.circular(10)),
                            height: 7,
                            width: 7,
                          ),
                          Expanded(
                            child: Slider(
                                activeColor: _brushColor,
                                min: 7,
                                max: 150,
                                value: _brushSize,
                                onChanged: (value) {
                                  setState(() {
                                    _brushSize = value;
                                  });
                                }),
                          ),
                          Container(
                            decoration: BoxDecoration(color: _brushColor, borderRadius: BorderRadius.circular(25)),
                            height: 25,
                            width: 25,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                crossFadeState: _drawing ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                duration: Duration(milliseconds: 200));

            final drawButton = AnimatedCrossFade(
                firstChild: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () {
                        setState(() {
                          _drawing = true;
                        });
                      },
                      label: Text(AppLocalizations.of(context)!.draw),
                      icon: Icon(Icons.draw),
                    ),
                  ],
                ),
                secondChild: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Theme(
                      data: ThemeData(
                        colorScheme:
                            ColorScheme.fromSeed(seedColor: Colors.green, brightness: Theme.of(context).brightness),
                      ),
                      child: FilledButton.icon(
                        onPressed: () {
                          setState(() {
                            _drawing = false;
                          });
                        },
                        label: Text(AppLocalizations.of(context)!.done),
                        icon: Icon(Icons.check),
                      ),
                    ),
                  ],
                ),
                crossFadeState: _drawing ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                duration: Duration(milliseconds: 200));

            var editButtons = Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        _drawing = false;
                        EditorText text = EditorText(
                          outlineWidth: 10,
                          outlineColor: Colors.transparent,
                          text: "",
                          transform: Matrix4.identity(),
                          fontSize: 40,
                          textColor: Colors.white,
                        );
                        _texts.add(text);
                        _layers.add(TextLayer(
                          text,
                          rbKey: _rbKey,
                          onDelete: (layer) {
                            _layers.remove(layer);
                            if (_currentTextLayer == layer) _currentTextLayer = null;
                            setState(() {});
                          },
                        ));

                        setState(() {});
                      },
                      label: Text(AppLocalizations.of(context)!.addText),
                      icon: Icon(Icons.format_size),
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: drawButton,
                  ),
                ],
              ),
            );

            // --- Feature 1 "Skip / Direct Add" button ---
            final skipButton = Container(
              margin: const EdgeInsets.only(bottom: 4),
              child: FilledButton.icon(
                onPressed: _openSkipDirectAdd,
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                icon: const Icon(Icons.short_text, size: 20),
                label: Text(
                  AppLocalizations.of(context)!.skipDirectAdd,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            );

            final imageDisplay = Container(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(24)),
              clipBehavior: Clip.antiAlias,
              child: RepaintBoundary(
                key: _rbKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      color: Colors.black,
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: CustomPaint(
                          painter: CheckerPainter(context, sizeCallback: (size) {
                            if (imageSize != size) {
                              imageSize = size;
                              scaleFactor = size.width / 512;
                              if (size.aspectRatio != 1) {
                                // That should never happen
                                print("Aspect ratio of sticker should be 1");
                              }
                              WidgetsBinding.instance.addPostFrameCallback(
                                (timeStamp) => setState(() {}),
                              );
                            }
                          }),
                          child: MatrixGestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onGestureStart: onGestureStart,
                            onMatrixUpdate: (_, translationDeltaMatrix, scaleDeltaMatrix, rotationDeltaMatrix) =>
                                onMatrixUpdate(translationDeltaMatrix, scaleDeltaMatrix, rotationDeltaMatrix),
                            child: Stack(children: [
                              if (widget.mediaType == MediaType.picture)
                                Image.file(_source)
                              else
                                Center(
                                  child: AspectRatio(
                                    aspectRatio: _controller.value.aspectRatio,
                                    child: VideoPlayer(_controller),
                                  ),
                                ),
                              ..._layers.map(
                                (e) => Positioned(
                                  top: 0,
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  child: e,
                                ),
                              ),
                              if (_message != null)
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  child: Container(
                                    color: Theme.of(context).colorScheme.surface.withAlpha(200),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      children: [
                                        Text(
                                          AppLocalizations.of(context)!.exporting,
                                          style: Theme.of(context).textTheme.displaySmall,
                                        ),
                                        SizedBox(
                                          height: 12,
                                        ),
                                        SizedBox(
                                          height: 64,
                                          width: 64,
                                          child: CircularProgressIndicator(
                                            year2023: false,
                                            value: _exportProgress,
                                          ),
                                        ),
                                        Text(
                                          _message ?? "",
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );

            final undoButtons = AnimatedCrossFade(
              sizeCurve: _curve,
              firstCurve: _curve,
              secondCurve: _curve,
              firstChild: Container(),
              secondChild: Padding(
                padding: isHorizontal ? EdgeInsets.zero : EdgeInsets.only(top: 12),
                child: Row(children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _layers
                              .whereType<DrawLayer>()
                              .where((layer) => layer.painter.strokes.isNotEmpty)
                              .isEmpty
                          ? null
                          : () {
                              final layer =
                                  _layers.whereType<DrawLayer>().lastWhere((layer) => layer.painter.strokes.isNotEmpty);
                              _undo.add(UndoEntry(layer.painter.strokes.removeLast(), layer.painter));
                              setState(() {});
                            },
                      label: Text(AppLocalizations.of(context)!.undo),
                      icon: Icon(Icons.undo),
                    ),
                  ),
                  SizedBox(
                    width: 12,
                  ),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _undo.isEmpty
                          ? null
                          : () {
                              setState(() {
                                final entry = _undo.removeLast();
                                entry.painter.strokes.add(entry.stroke);
                              });
                            },
                      label: Text(AppLocalizations.of(context)!.redo),
                      icon: Icon(Icons.redo),
                    ),
                  ),
                ]),
              ),
              crossFadeState: _drawing ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: Duration(milliseconds: 200),
            );

            var doneButton = FilledButton.icon(
              icon: Icon(Icons.done),
              onPressed: _exporting
                  ? null
                  : () async {
                      await onDone(context);
                    },
              label: Text(AppLocalizations.of(context)!.addToPack),
            );
            if (isHorizontal) {
              final double halfWidth = min(constraints.maxHeight - 16, min(500, constraints.maxWidth / 2 - 16));
              return Padding(
                padding: const EdgeInsets.all(8.0),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 1024),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: halfWidth),
                          child: imageDisplay,
                        ),
                        SizedBox(
                          width: 12,
                        ),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: halfWidth),
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  editButtons,
                                  colorButtons,
                                  undoButtons,
                                  skipButton,
                                  if (_drawing) SizedBox(height: 12),
                                  doneButton,
                                ],
                              ),
                            ),
                          ),
                        )
                      ],
                    ),
                  ),
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(12.0),
              child: Center(
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 512),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        editButtons,
                        colorButtons,
                        skipButton,
                        imageDisplay,
                        undoButtons,
                        SizedBox(height: 12),
                        doneButton,
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Feature 1 - "Skip / Direct Add" (instant raw add, no crop/edit)
  // ---------------------------------------------------------------------------

  Future<void> _openSkipDirectAdd() async {
    final picker = ImagePicker();
    final XFile? raw = await picker.pickImage(source: ImageSource.gallery);
    if (raw == null) return;
    if (!context.mounted) return;

    final tempFile = await _resizeTo512TransparentWebP(File(raw.path));
    if (tempFile == null) return;
    if (!context.mounted) return;

    addToPack(widget.pack, widget.index + 1, await File(tempFile.path).readAsBytes());
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Skipped: added directly to pack."), duration: Duration(seconds: 2)),
      );
    }
    Navigator.of(context).pop();
  }

  Future<File?> _resizeTo512TransparentWebP(File raw) async {
    if (!raw.existsSync()) return null;

    final lock = _webpSizeLock;
    await lock.acquire();
    try {
      final bytes = raw.readAsBytesSync();
      final img = await decodeImageFromList(bytes);
      if (img == null) return null;

      // Build a clean 1:1, 512x512, transparent-alpha backing store.
      final channelBuffer = Float32List(512 * 512 * 4);
      for (int y = 0; y < 512; y++) {
        for (int x = 0; x < 512; x++) {
          final sx = (x / 512 * img.width).toInt().clamp(0, img.width - 1);
          final sy = (y / 512 * img.height).toInt().clamp(0, img.height - 1);
          final idx = (sy * img.width + sx) * 4;
          channelBuffer[(y * 512 + x) * 4 + 0] = bytes[idx] / 255.0;
          channelBuffer[(y * 512 + x) * 4 + 1] = bytes[idx + 1] / 255.0;
          channelBuffer[(y * 512 + x) * 4 + 2] = bytes[idx + 2] / 255.0;
          channelBuffer[(y * 512 + x) * 4 + 3] = 255; // opaque
        }
      }

      // Progressive re-encode until it is strictly under 100 KB.
      const targetBytes = 100 * 1024;
      const maxAttempts = 8;
      int quality = 90;
      for (int attempt = 0; attempt < maxAttempts; attempt++) {
        final outFile = await _encode512WebPRaw(channelBuffer, quality);
        if (outFile != null && outFile.lengthSync() < targetBytes) {
          return outFile;
        }
        quality = quality > 10 ? quality - 15 : 10;
      }

      final fallback = await _encode512WebPRaw(channelBuffer, 10);
      if (fallback != null && fallback.lengthSync() < targetBytes) return fallback;

      final pngFile = File("$mediaCacheDir/skip_${DateTime.now().millisecondsSinceEpoch}.png");
      pngFile.parent.createSync(recursive: true);
      pngFile.writeAsBytesSync(await encodePNG(bytes, width: img.width.toInt(), height: img.height.toInt()));
      return pngFile;
    } finally {
      lock.release();
    }
  }

  Future<File?> _encode512WebPRaw(Float32List pixels, int quality) async {
    final outFile = File("$mediaCacheDir/skip_${DateTime.now().millisecondsSinceEpoch}.webp");
    outFile.parent.createSync(recursive: true);

    try {
      final option = ImageEditorOption()
        ..outputFormat = const OutputFormat.webp_lossy(quality)
        ..addOption(const ScaleOption(512, 512))
        ..addOption(const ClipOption.rectangle(const Offset(0, 0), const Size(512, 512)));
      return await ImageEditor.editImageAndGetFile(
        image: MemoryImageSource.fromBytes(bytes: pixels.buffer.asUint8List()),
        imageEditorOption: option,
      );
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Feature 4 - Queue-based "Add All to WhatsApp"
  // ---------------------------------------------------------------------------

  Future<void> _runWhatsAppQueue() async {
    final targetPacks = packs.toList();
    if (targetPacks.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No packs to add to WhatsApp.")),
        );
      }
      return;
    }

    await runWhatsAppQueue(targetPacks, context, onUpdate: (p) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("${p.status} (${p.current}/${p.total})"),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Global error surface
  // ---------------------------------------------------------------------------

  void _reportBug() {
    _openWhatsAppUrl("https://wa.me/2349067716806?text=Bug+report%2C+please+help%20me%20fix%20it.", context);
  }

  void _openWhatsAppUrl(String url, BuildContext context) {
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}
