import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pie_mobile/services/image_generation_service.dart';

void main() {
  test('returns backend image URL when provider succeeds', () async {
    final service = ImageGenerationService(
      gatewayUrlProvider: () async => 'https://gateway.test',
      headersProvider: () async => {'Content-Type': 'application/json'},
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://gateway.test/images/generate');
        return http.Response(
          '{"image_url":"https://cdn.test/generated.png"}',
          200,
        );
      }),
    );

    final result = await service.generate('generate image of a clean logo');

    expect(result.remoteUrl, 'https://cdn.test/generated.png');
    expect(result.answerText, contains('Generated image'));
    expect(result.handoffRequired, isFalse);
  });

  test(
    'requests installed AI app chooser when backend is not configured',
    () async {
      final service = ImageGenerationService(
        gatewayUrlProvider: () async => 'https://gateway.test',
        headersProvider: () async => {'Content-Type': 'application/json'},
        client: MockClient((request) async {
          return http.Response(
            '{"error":"image_provider_not_configured"}',
            501,
          );
        }),
      );

      final result = await service.generate('create an image of a sales chart');

      expect(result.handoffRequired, isTrue);
      expect(result.handoffPrompt, 'create an image of a sales chart');
      expect(
        result.answerText,
        contains('Backend image generation is not configured'),
      );
      expect(
        result.answerText,
        contains('cannot silently read generated images'),
      );
    },
  );

  test('requests installed AI app chooser when backend fails', () async {
    final service = ImageGenerationService(
      gatewayUrlProvider: () async => 'https://gateway.test',
      headersProvider: () async => {'Content-Type': 'application/json'},
      client: MockClient((request) async {
        return http.Response('{"error":"provider_timeout"}', 504);
      }),
    );

    final result = await service.generate('generate image of a dashboard');

    expect(result.handoffRequired, isTrue);
    expect(result.handoffPrompt, 'generate image of a dashboard');
    expect(result.answerText, contains('Backend image generation failed'));
  });
}
