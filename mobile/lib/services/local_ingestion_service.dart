import 'dart:io';

import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/entity.dart';
import 'app_config.dart';
import 'database_service.dart';

class FileIngestionIssue {
  const FileIngestionIssue({required this.path, required this.message});

  final String path;
  final String message;
}

class LocalIngestionResult {
  const LocalIngestionResult({
    required this.filesProcessed,
    required this.entitiesInserted,
    required this.duplicatesSkipped,
    required this.issues,
  });

  final int filesProcessed;
  final int entitiesInserted;
  final int duplicatesSkipped;
  final List<FileIngestionIssue> issues;

  bool get hasInsertedEntities => entitiesInserted > 0;
  bool get hasOnlyDuplicates =>
      entitiesInserted == 0 && duplicatesSkipped > 0 && issues.isEmpty;
}

class LocalIngestionService {
  LocalIngestionService({DatabaseService? database})
    : _database = database ?? DatabaseService.instance;

  final DatabaseService _database;

  Future<LocalIngestionTextResult> extractText(File file) async {
    final fileSize = await file.length();
    if (fileSize > AppConfig.maxAttachmentBytes) {
      return LocalIngestionTextResult(
        text: '',
        issue: FileIngestionIssue(
          path: file.path,
          message: 'File exceeds ${AppConfig.maxAttachmentBytes} bytes.',
        ),
      );
    }

    final lowerPath = file.path.toLowerCase();
    try {
      if (lowerPath.endsWith('.pdf')) {
        final document = PdfDocument(inputBytes: await file.readAsBytes());
        try {
          return LocalIngestionTextResult(
            text: PdfTextExtractor(document).extractText(),
          );
        } finally {
          document.dispose();
        }
      }

      if (lowerPath.endsWith('.txt') ||
          lowerPath.endsWith('.csv') ||
          lowerPath.endsWith('.eml')) {
        return LocalIngestionTextResult(text: await file.readAsString());
      }

      return LocalIngestionTextResult(
        text: '',
        issue: FileIngestionIssue(
          path: file.path,
          message: 'Unsupported file type.',
        ),
      );
    } catch (_) {
      return LocalIngestionTextResult(
        text: '',
        issue: FileIngestionIssue(
          path: file.path,
          message: 'Text extraction failed.',
        ),
      );
    }
  }

  Future<LocalIngestionResult> ingestFiles(
    List<File> files, {
    required String sourceConnector,
  }) async {
    final issues = <FileIngestionIssue>[];
    var entitiesInserted = 0;
    var duplicatesSkipped = 0;
    var filesProcessed = 0;

    for (final file in files) {
      final extracted = await extractText(file);
      if (extracted.issue != null) {
        issues.add(extracted.issue!);
        continue;
      }

      final boundedText = _truncate(
        extracted.text.trim(),
        AppConfig.maxExtractedTextChars,
      );
      if (boundedText.isEmpty) {
        issues.add(
          FileIngestionIssue(
            path: file.path,
            message: 'File contained no text.',
          ),
        );
        continue;
      }

      filesProcessed += 1;
      final chunks = _chunkText(boundedText);
      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i].trim();
        if (chunk.length < 10) continue;

        final now = DateTime.now().millisecondsSinceEpoch;
        final safeName = file.uri.pathSegments.isEmpty
            ? 'document'
            : file.uri.pathSegments.last;
        final contentHash = await _database.stableContentHash(
          sourceConnector: sourceConnector,
          content: chunk,
        );
        final entity = Entity(
          id: 'doc_${now}_${entitiesInserted}_$i',
          entityType: 'document',
          sourceConnector: sourceConnector,
          content: 'File: $safeName\n\n$chunk',
          contentHash: contentHash,
          createdAt: now,
          updatedAt: now,
        );
        final inserted = await _database.insertEntity(entity, queueSync: true);
        if (inserted) {
          entitiesInserted += 1;
        } else {
          duplicatesSkipped += 1;
        }
      }
    }

    return LocalIngestionResult(
      filesProcessed: filesProcessed,
      entitiesInserted: entitiesInserted,
      duplicatesSkipped: duplicatesSkipped,
      issues: issues,
    );
  }

  List<String> _chunkText(String text) {
    final chunks = text
        .split(RegExp(r'\n\s*\n'))
        .where((chunk) => chunk.trim().isNotEmpty)
        .take(AppConfig.maxIngestChunks)
        .toList();
    if (chunks.isEmpty && text.trim().isNotEmpty) return [text.trim()];
    return chunks;
  }

  String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) return value;
    return value.substring(0, maxChars);
  }
}

class LocalIngestionTextResult {
  const LocalIngestionTextResult({required this.text, this.issue});

  final String text;
  final FileIngestionIssue? issue;
}
