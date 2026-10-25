import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/remote_browser_link.dart';

void main() {
  test('browser link preserves peer and full localhost web origin', () {
    final url = 'http://localhost:5173/path?q=value#section';
    final link = RemoteBrowserLink.parse(Uri.parse(
        'rustdesk://browser/123456789?url=${Uri.encodeComponent(url)}'));
    expect(link?.peer, '123456789');
    expect(link?.url.toString(), url);
  });

  test('browser link rejects credentials and non-web targets', () {
    for (final target in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'https://user:secret@example.com/'
    ]) {
      expect(
          RemoteBrowserLink.parse(Uri.parse(
              'rustdesk://browser/123?url=${Uri.encodeComponent(target)}')),
          isNull);
    }
    expect(
        RemoteBrowserLink.parse(Uri.parse(
            'rustdesk://browser/123?url=https%3A%2F%2Fexample.com&password=secret')),
        isNull);
  });

  test('browser link rejects missing and ambiguous destination', () {
    for (final text in [
      'rustdesk://browser/?url=https%3A%2F%2Fexample.com',
      'rustdesk://browser/123',
      'rustdesk://browser/%FF?url=http%3A%2F%2Flocalhost',
      'rustdesk://browser/123?url=%FF',
      'https://browser/123?url=https%3A%2F%2Fexample.com',
      'rustdesk://browser/123?url=https%3A%2F%2Fa.com&url=https%3A%2F%2Fb.com'
    ]) {
      expect(RemoteBrowserLink.parse(Uri.parse(text)), isNull);
    }
  });
}
