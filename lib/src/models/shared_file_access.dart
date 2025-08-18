class SharedFileAccess {
  final String eventId;
  final List<String> relays;
  final String author;
  final int kind;
  final String encodedPrivateKey;
  final bool isPasswordProtected;
  final String nevent;

  SharedFileAccess({
    required this.eventId,
    required this.relays,
    required this.author,
    required this.kind,
    required this.encodedPrivateKey,
    required this.isPasswordProtected,
    required this.nevent,
  });

  factory SharedFileAccess.fromJson(Map<String, dynamic> json) {
    return SharedFileAccess(
      eventId: json['eventId'] as String,
      relays: List<String>.from(json['relays'] as List),
      author: json['author'] as String,
      kind: json['kind'] as int,
      encodedPrivateKey: json['encodedPrivateKey'] as String,
      isPasswordProtected: json['isPasswordProtected'] as bool,
      nevent: json['nevent'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'eventId': eventId,
      'relays': relays,
      'author': author,
      'kind': kind,
      'encodedPrivateKey': encodedPrivateKey,
      'isPasswordProtected': isPasswordProtected,
      'nevent': nevent,
    };
  }
}
