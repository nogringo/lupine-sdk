import 'dart:io';

Future<String> getAvailableFilePath(String desiredPath) async {
  final file = File(desiredPath);
  if (!await file.exists()) {
    return desiredPath;
  }

  final directory = file.parent;
  final fileName = file.uri.pathSegments.last;
  final dotIndex = fileName.lastIndexOf('.');
  
  String baseName;
  String extension;
  
  if (dotIndex == -1) {
    baseName = fileName;
    extension = '';
  } else {
    baseName = fileName.substring(0, dotIndex);
    extension = fileName.substring(dotIndex);
  }

  // Expression régulière pour trouver les numéros existants
  final regex = RegExp(r'^(.+) \((\d+)\)$');
  final match = regex.firstMatch(baseName);
  
  String pureBaseName;
  
  if (match != null) {
    pureBaseName = match.group(1)!;
  } else {
    pureBaseName = baseName;
  }

  // Trouver tous les fichiers similaires existants
  final existingFiles = await directory.list()
    .where((entity) => entity is File)
    .map((file) => (file as File).uri.pathSegments.last)
    .toList();

  // Trouver le numéro le plus élevé existant
  int maxNumber = 0;
  final pattern = RegExp('^${RegExp.escape(pureBaseName)} \\((\\d+)\\)${RegExp.escape(extension)}\$');

  for (final existingFile in existingFiles) {
    final match = pattern.firstMatch(existingFile);
    if (match != null) {
      final number = int.tryParse(match.group(1)!);
      if (number != null && number > maxNumber) {
        maxNumber = number;
      }
    }
  }

  // Si le fichier original existe mais aucun avec numéro, on commence à 1
  if (maxNumber == 0 && await file.exists()) {
    maxNumber = 1;
  } else {
    maxNumber++;
  }

  // Construire le nouveau chemin
  return '${directory.path}/$pureBaseName ($maxNumber)$extension';
}