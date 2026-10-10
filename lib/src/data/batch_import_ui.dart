import 'dart:io';

import 'package:flutter/material.dart';
import 'package:stickers/src/data/batch_import.dart';

/// Widget that renders one imported pack tile with a green success or red
/// error badge next to it.
class BatchImportStatusBadge extends StatelessWidget {
  final String fileName;
  final bool success;

  const BatchImportStatusBadge({super.key, required this.fileName, required this.success});

  @override
  Widget build(BuildContext context) {
    final color = success
        ? Colors.green.shade600
        : Theme.of(context).colorScheme.error;
    final label = success
        ? "Imported"
        : "Failed";

    return Container(
      margin: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            "$label: $fileName",
            style: TextStyle(color: color, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Simple list that shows a per-file success/error badge for a batch import.
class BatchImportStatusList extends StatelessWidget {
  final List<ImportResult> results;

  const BatchImportStatusList({super.key, required this.results});

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: results.map((r) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: BatchImportStatusBadge(
            fileName: r.fileName,
            success: r.success,
          ),
        );
      }).toList(),
    );
  }
}
