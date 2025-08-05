import 'package:path/path.dart' as p;

abstract class DriveItem {
  String get path;
  DateTime get createdAt;
  String? get eventId;
  String get type;

  Map<String, dynamic> toJson();

  String get name => path == '/' ? 'Root' : p.basename(path);

  String get parentPath => p.dirname(path);

  bool get isFile => type == 'file';
  bool get isFolder => type == 'folder';
}
