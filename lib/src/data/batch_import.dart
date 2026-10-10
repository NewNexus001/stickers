import 'dart:io';

import 'package:stickers/src/data/sticker_pack.dart';
import 'package:stickers/src/globals.dart';

/// Result of importing a single pack file.
class ImportResult {
  final String fileName;
  final bool success;
  final String? error;
  final StickerPack? pack;

  ImportResult({required this.fileName, required this.success, this.error, this.pack});
}

/// One batch of files that should be split into packs of at most 30 stickers.
class ImportBatch {
  final List<File> files;
  final int maxPerPack;

  ImportBatch({required this.files, this.maxPerPack = 30});

  /// Sequentially split the selected files into packs of `maxPerPack`.
  List<List<File>> split() {
    final chunks = <List<File>>[];
    final current = <File>[];
    for (final f in files) {
      current.add(f);
      if (current.length >= maxPerPack) {
        chunks.add(List<File>.unmodifiable(current));
        current.clear();
      }
    }
    if (current.isNotEmpty) {
      chunks.add(List<File>.unmodifiable(current));
    }
    return chunks;
  }
}

/// Shared state for a multi-pack batch import on the packs screen.
class BatchImportState {
  final List<ImportResult> results = [];
  final List<File> selectedFiles = [];

  bool get hasResults => results.isNotEmpty;

  ImportResult? resultFor(String fileName) {
    return results.firstWhereOrNull((r) => r.fileName == fileName);
  }

  void addResult(ImportResult result) {
    if (resultFor(result.fileName) != null) return;
    results.add(result);
  }

  bool get anyFailed => results.any((r) => !r.success);

  bool get allSuccessful => results.every((r) => r.success);
}

extension _ListExt<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}
