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
// Feature 3 - Smart 30-sticker batch splitter
// ---------------------------------------------------------------------------

class BatchSplitResult {
  final List<List<File>> batches;
  final int stickersPerPack;

  BatchSplitResult({required this.batches, this.stickersPerPack = 30});

  int get totalPacks => batches.length;
  int get totalStickers => batches.fold(0, (sum, batch) => sum + batch.length);
}

/// Split `files` into sequential packs of at most `stickersPerPack` stickers.
BatchSplitResult splitIntoBatchPacks(List<File> files, {int stickersPerPack = 30}) {
  final batches = <List<File>>[];
  final current = <File>[];

  for (final f in files) {
    current.add(f);
    if (current.length >= stickersPerPack) {
      batches.add(List<File>.unmodifiable(current));
      current.clear();
    }
  }
  if (current.isNotEmpty) {
    batches.add(List<File>.unmodifiable(current));
  }

  return BatchSplitResult(batches: batches, stickersPerPack: stickersPerPack);
}

/// Build pack objects from a pre-split `BatchSplitResult`.
///
/// Each pack is named systematically as `Bethel Pack 1`, `Bethel Pack 2`, ...
/// and stored under `$packsDir/<title>/`.
List<StickerPack> buildBatchPacks(BatchSplitResult result) {
  final packs = <StickerPack>[];

  for (int i = 0; i < result.batches.length; i++) {
    final batch = result.batches[i];
    final title = "Bethel Pack ${i + 1}";
    final dir = Directory("$packsDir/$title");
    dir.createSync(recursive: true);

    final stickers = <Sticker>[];
    for (int j = 0; j < batch.length; j++) {
      final stickerFile = File("${dir.path}/sticker_$j.webp");
      batch[j].copySync(stickerFile.path);
      stickers.add(Sticker(stickerFile.path, ["❤"]));
    }

    packs.add(StickerPack(
      title,
      "auto-generated",
      "pack_${DateTime.now().millisecondsSinceEpoch}_$i",
      stickers,
      "0",
      false,
    ));
  }

  return packs;
}

// ---------------------------------------------------------------------------
// Feature 4 - Queue-based "Add All to WhatsApp" flow
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

/// Process one pack at a time: send to WhatsApp, wait for the UI to settle,
/// then trigger the next pack automatically.
///
/// The [onUpdate] callback is invoked after every step so the UI can show a
/// progress bar and the current pack name.
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

    await sendToWhatsappWithErrorHandling(pack, context);

    // Give the dialog/snackbar that reported the previous result time to
    // settle before we kick off the next pack.
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
