class RemoteBrowserLink {
  const RemoteBrowserLink(this.peer, this.url);

  final String peer;
  final Uri url;

  static RemoteBrowserLink? parse(Uri link, {String scheme = 'rustdesk'}) {
    try {
      return _parse(link, scheme);
    } on FormatException {
      return null;
    }
  }

  static RemoteBrowserLink? _parse(Uri link, String scheme) {
    if (link.scheme != scheme) return null;
    if (link.host != 'browser' ||
        link.userInfo.isNotEmpty ||
        link.hasPort ||
        link.fragment.isNotEmpty ||
        !link.path.startsWith('/')) return null;
    final peer = Uri.decodeComponent(link.path.substring(1));
    if (peer.isEmpty ||
        peer.length > 512 ||
        RegExp(r'[\s\x00-\x1f?#]').hasMatch(peer)) return null;
    if (link.queryParametersAll.keys.any((key) => key != 'url')) return null;
    final urls = link.queryParametersAll['url'];
    if (urls == null || urls.length != 1) return null;
    final url = Uri.tryParse(urls.single);
    if (url == null ||
        !const ['http', 'https'].contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) return null;
    return RemoteBrowserLink(peer, url);
  }
}
