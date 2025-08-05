/// Event emitted when drive state changes
class DriveChangeEvent {
  final String type; // 'added', 'updated', 'deleted'
  final String? path;
  final DateTime timestamp;

  DriveChangeEvent({
    required this.type,
    this.path,
  }) : timestamp = DateTime.now();
}