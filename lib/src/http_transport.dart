import 'dart:convert';
import 'dart:io';

/// One HTTP response: the status code and the body as text.
class HttpResult {
  const HttpResult(this.status, this.body);
  final int status;
  final String body;
}

/// The one way the tool talks to the network, so tests can serve recorded
/// responses instead.
// The seam is an interface with one method on purpose.
// ignore: one_member_abstracts
abstract interface class HttpTransport {
  Future<HttpResult> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  });
}

/// The real transport, on dart:io's HttpClient.
class IoHttpTransport implements HttpTransport {
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

  @override
  Future<HttpResult> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final request = await _client.openUrl(method, url);
    headers.forEach(request.headers.set);
    if (body != null) {
      final bytes = utf8.encode(body);
      request
        ..contentLength = bytes.length
        ..add(bytes);
    }
    final response = await request.close().timeout(
      const Duration(seconds: 60),
    );
    final text = await response.transform(utf8.decoder).join();
    return HttpResult(response.statusCode, text);
  }

  void close() => _client.close();
}
