import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_editor/image_editor.dart';
import 'package:path_provider/path_provider.dart';
import 'package:stickers/generated/intl/app_localizations.dart';
import 'package:stickers/src/data/sticker_pack.dart';
import 'package:stickers/src/dialogs/error_dialog.dart';
import 'package:stickers/src/globals.dart';
import 'package:whatsapp_stickers_plus/exceptions.dart';

bool isValidURL(String input) {
  final url = Uri.tryParse(input);
  if (url == null) return false;
  if (url.scheme != "http" && url.scheme != "https") return false;
  if (url.host.isEmpty) return false;
  return url.isAbsolute;
}

String? titleValidator(String? value, BuildContext context) {
  if (value == null || value.isEmpty) {
    return AppLocalizations.of(context)!.pleaseEnterTitle;
  }
  return null;
}

String? authorValidator(String? value, BuildContext context) {
  if (value == null || value.isEmpty) {
    return AppLocalizations.of(context)!.pleaseEnterAuthor;
  }
  return null;
}

Future<void> sendToWhatsappWithErrorHandling(StickerPack pack, BuildContext context) async {
  try {
    await pack.sendToWhatsapp();
  } on WhatsappStickersAlreadyAddedException catch (_) {
  } on WhatsappStickersException catch (e) {
    showDialog(
      context: navigatorKey.currentContext!,
      builder: (_) => ErrorDialog(
        title: AppLocalizations.of(context)!.couldnTAddStickerPack,
        message: e.cause ?? e.runtimeType.toString(),
      ),
    );
  } on PlatformException catch (e) {
    if (e.message == "WhatsApp is not installed on target device!") {
      showDialog(
          context: navigatorKey.currentContext!,
          builder: (_) => ErrorDialog(
              title: AppLocalizations.of(context)!.couldnTAddStickerPack,
              message: AppLocalizations.of(context)!.whatsappNotInstalled)));
    } else {
      showDialog(
          context: navigatorKey.currentContext!,
          builder: (_) =>
              ErrorDialog(title: AppLocalizations.of(context)!.couldnTAddStickerPack, message: e.message ?? "")));
    }
  } on Exception catch (e) {
    showDialog(
        context: navigatorKey.currentContext!,
        builder: (_) => ErrorDialog(title: AppLocalizations.of(context)!.couldnTAddStickerPack, message: e.toString())));
  }
}

int colCount(double width) {
  if (width < 500) {
    return 3;
  } else if (width < 800) {
    return 6;
  } else {
    return 9;
  }
}

// ---------------------------------------------------------------------------
// Static sticker file-size cap (<100 KB, WhatsApp strict limit)
// ---------------------------------------------------------------------------

/// Encodes a raw image to a strictly-under-100 KB transparent 512x512 WebP.
///
/// Uses the same encoding pipeline as sticker export, but starts from a much
/// higher quality and steps down to a small size as a fallback so the result
/// is guaranteed to sit below the strict 100 KB WhatsApp static limit.
Future<File?> encodeStaticSticker(File raw, {int maxSizeBytes = 100 * 1024}) async {
  if (!raw.existsSync()) return null;

  final bytes = raw.readAsBytesSync();
  final img = await decodeImageFromList(bytes);
  if (img == null) return null;

  // Nearest-sample 512x512 -> sRGB + full alpha.
  final pixels = Float32List(512 * 512 * 4);
  for (int y = 0; y < 512; y++) {
    for (int x = 0; x < 512; x++) {
      final sx = (x / 512 * img.width).toInt().clamp(0, img.width - 1);
      final sy = (y / 512 * img.height).toInt().clamp(0, img.height - 1);
      final idx = (sy * img.width + sx) * 4;
      pixels[(y * 512 + x) * 4 + 0] = bytes[idx] / 255.0;
      pixels[(y * 512 + x) * 4 + 1] = bytes[idx + 1] / 255.0;
      pixels[(y * 512 + x) * 4 + 2] = bytes[idx + 2] / 255.0;
      pixels[(y * 512 + x) * 4 + 3] = 255;
    }
  }

  final target = maxSizeBytes as int;
  int quality = 92;
  const maxAttempts = 10;

  for (int attempt = 0; attempt < maxAttempts; attempt++) {
    final file = await _encode512WebPRaw(bytes: pixels.buffer.asUint8List(), quality: quality);
    if (file != null && file.lengthSync() < target) {
      return file;
    }
    quality = quality > 10 ? quality - 14 : 10;
  }

  // Last resort: lossless PNG (still a valid WhatsApp static sticker, but
  // usually smaller for hard-to-compress raw images).
  final fallback = File("$mediaCacheDir/static_${DateTime.now().millisecondsSinceEpoch}.png");
  fallback.parent.createSync(recursive: true);
  fallback.writeAsBytesSync(await encodePNG(bytes, width: img.width.toInt(), height: img.height.toInt()));
  return fallback;
}

Future<File?> _encode512WebPRaw({required Uint8List bytes, required int quality}) async {
  final outFile = File("$mediaCacheDir/static_${DateTime.now().millisecondsSinceEpoch}.webp");
  outFile.parent.createSync(recursive: true);

  try {
    return await ImageEditor.editImageAndGetFile(
      image: MemoryImageSource.fromBytes(bytes: bytes),
      imageEditorOption: ImageEditorOption()
        ..outputFormat = const OutputFormat.webp_lossy(quality)
        ..addOption(const ScaleOption(512, 512))
        ..addOption(const ClipOption.rectangle(const Offset(0, 0), const Size(512, 512))),
    );
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Feature 4 - Queue-based "Add All to WhatsApp"
// ---------------------------------------------------------------------------

class QueueProgress {
  final int current;
  final int total;
  final String status;

  QueueProgress({required this.current, required this.total, required this.status});

  double get progress => total > 0 ? current / total : 0.0;

  @override
  String toString() => "QueueProgress(current: $current, total: $total, status: $status)";
}

/// Sequentially adds every pack in [packs] to WhatsApp with a safe await flow.
///
/// Each pack awaits the platform-channel [sendToWhatsApp] result before the
/// next pack starts. Rejections are surfaced as a snackbar instead of crashing.
Future<void> runWhatsAppQueue(
  List<StickerPack> packs,
  BuildContext context, {
  required Function(QueueProgress) onUpdate,
}) async {
  if (packs.isEmpty) return;

  onUpdate(QueueProgress(current: 0, total: packs.length, status: AppLocalizations.of(context)!.addToWhatsapp));

  for (int i = 0; i < packs.length; i++) {
    final pack = packs[i];
    final label = i == packs.length - 1
        ? "${AppLocalizations.of(context)!.addToWhatsapp} ${pack.title} (last)"
        : "${AppLocalizations.of(context)!.addToWhatsapp} ${pack.title} (${i + 1}/${packs.length})";
    onUpdate(QueueProgress(current: i + 1, total: packs.length, status: label));

    // Await the platform sendToWhatsApp result before moving on.
    await sendToWhatsappWithErrorHandling(pack, context);

    // Give the dialog/snackbar time to settle before triggering the next pack.
    if (i + 1 < packs.length) {
      await Future.delayed(const Duration(milliseconds: 250));
      await Future.delayed(const Duration(milliseconds: 0));
    }
  }

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("${AppLocalizations.of(context)!.addToWhatsapp} ${packs.length} pack(s)."),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(label: AppLocalizations.of(context)!.ok, onPressed: () {}),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Support / issue reporting
// ---------------------------------------------------------------------------

/// WhatsApp deep-link used by every support button in the app.
const String _bethelWhatsAppUrl = "https://wa.me/2349067716806?text=Bug+report%2C+please+help+me%20fix+this+application.%0a%0a--%0aReported+via+Bethels+Sticker+App";

/// Launches WhatsApp with pre-filled, bug-prefixed text targeting Bethel's
/// WhatsApp number `09067716806`.
void launchWhatsAppSupport(BuildContext context) {
  launchUrl(Uri.parse(_bethelWhatsAppUrl), mode: LaunchMode.externalApplication);
}

/// Simple dialog + Continue button that opens the support deep link directly.
void showSupportDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text("Having problems with my app?"),
      content: const Text(
        "Clicking Continue opens WhatsApp right away with the bug text pre-filled for Bethel (09067716806).",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            launchWhatsAppSupport(context);
          },
          child: const Text("Continue"),
        ),
      ],
    ),
  );
}

/// "Don't know how to use the app? Click here to learn" step-by-step modal.
void showTutorialDialog(BuildContext context) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text("How to use Bethels Sticker App"),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.add_photo_alternate),
              title: Text("Batch pick 1,000 photos"),
              subtitle: Text("Select many images at once; they're split automatically into 30-sticker packs."),
            ),
            const ListTile(
              leading: Icon(Icons.radio_button_unchecked),
              title: Text("Skip / Direct Add"),
              subtitle: Text('Press the "Skip / Direct Add" button to drop any photo straight into your pack at 512x512.'),
            ),
            const ListTile(
              leading: Icon(Icons.upload_file),
              title: Text("Import .wastickers / .zip"),
              subtitle: Text("Pick files to import; green = ok, red = failed."),
            ),
            const ListTile(
              leading: Icon(Icons.queue),
              title: Text("Add All to WhatsApp"),
              subtitle: Text("Send every pack to WhatsApp one by one, in line."),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text("Got it"),
        ),
      ],
    ),
  );
}

/// Global unhandled-error surface.
void setupGlobalErrorHandling(BuildContext appContext) {
  FlutterError.onError = (details) {
    // Surface the error to the user's support line in a styled dialog.
    if (appContext.mounted) {
      ScaffoldMessenger.of(appContext).showDialog(
        context: appContext,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.red.shade50,
          title: const Row(
            children: [
              Icon(Icons.bug_report, color: Colors.red),
              SizedBox(width: 12),
              Text("Error occurred"),
            ],
          ),
          content: const Text("An error occurred! Report bug to Bethel so he can update and fix this application."),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("OK"),
            ),
            ElevatedButton(
              onPressed: () => launchWhatsAppSupport(ctx),
              style: ElevatedButton.styleFrom(foregroundColor: Colors.red),
              child: const Text("Report bug"),
            ),
          ],
        ),
      );
    }
    // Also log to the system so crashes keep showing up in the logs.
    FlutterError.dumpErrorToConsole(details);
  };
}
