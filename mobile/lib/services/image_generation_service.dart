import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class ImageGenerationResult {
  const ImageGenerationResult({
    required this.answerText,
    this.localPath,
    this.remoteUrl,
    this.handoffRequired = false,
    this.handoffPrompt,
    this.handoffReason,
  });

  final String answerText;
  final String? localPath;
  final String? remoteUrl;
  final bool handoffRequired;
  final String? handoffPrompt;
  final String? handoffReason;
}

class ImageGenerationService {
  ImageGenerationService({
    required this.gatewayUrlProvider,
    required this.headersProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Future<String> Function() gatewayUrlProvider;
  final Future<Map<String, String>> Function() headersProvider;
  final http.Client _client;
  final _uuid = const Uuid();

  bool canHandle(String query) {
    return RegExp(
      r'\b(generate|create|make|draw)\b.*\b(image|picture|photo|art|poster|logo)\b|\bimage\s+of\b',
      caseSensitive: false,
    ).hasMatch(query);
  }

  Future<ImageGenerationResult> generate(String prompt) async {
    final http.Response response;
    try {
      final baseUrl = await gatewayUrlProvider();
      response = await _client
          .post(
            Uri.parse('$baseUrl/images/generate'),
            headers: await headersProvider(),
            body: jsonEncode({'prompt': prompt}),
          )
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      return _handoffRequiredResult(
        prompt,
        reason:
            'PIE could not reach the backend image provider from this phone.',
      );
    }

    final body = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 501) {
      return _handoffRequiredResult(
        prompt,
        reason: 'Backend image generation is not configured.',
      );
    }
    if (response.statusCode != 200) {
      final message = body['message'] ?? body['error'] ?? 'unknown error';
      return _handoffRequiredResult(
        prompt,
        reason: 'Backend image generation failed: $message.',
      );
    }

    final imageUrl = body['image_url']?.toString();
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return ImageGenerationResult(
        remoteUrl: imageUrl,
        answerText: 'Generated image:\n\n![Generated image]($imageUrl)',
      );
    }

    final imageBase64 = body['image_base64']?.toString();
    if (imageBase64 != null && imageBase64.isNotEmpty) {
      final mimeType = body['mime_type']?.toString() ?? 'image/png';
      final ext = mimeType.contains('jpeg') || mimeType.contains('jpg')
          ? 'jpg'
          : 'png';
      final directory = await getApplicationDocumentsDirectory();
      final imageDir = Directory(p.join(directory.path, 'generated_images'));
      if (!await imageDir.exists()) {
        await imageDir.create(recursive: true);
      }
      final file = File(p.join(imageDir.path, '${_uuid.v4()}.$ext'));
      await file.writeAsBytes(base64Decode(imageBase64));
      return ImageGenerationResult(
        localPath: file.path,
        answerText:
            'Generated image saved locally in PIE.\n\nFile: ${p.basename(file.path)}',
      );
    }

    return const ImageGenerationResult(
      answerText:
          'The image provider responded, but no image file was returned. Try a clearer image prompt.',
    );
  }

  ImageGenerationResult _handoffRequiredResult(
    String prompt, {
    required String reason,
  }) {
    return ImageGenerationResult(
      answerText:
          '$reason\n\nChoose Gemini or ChatGPT on this device to continue. PIE will open the selected app with your prompt, but it cannot silently read generated images from another app unless you share or save them back.',
      handoffRequired: true,
      handoffPrompt: prompt,
      handoffReason: reason,
    );
  }
}
