import 'dart:async';
import 'dart:html' as html;

Future<void> downloadTextFile(String filename, String contents) async {
  final isText = filename.toLowerCase().endsWith('.txt');
  final mimeType = isText ? 'text/plain;charset=utf-8' : 'application/json;charset=utf-8';
  final blob = html.Blob([contents], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  html.Url.revokeObjectUrl(url);
}

Future<String?> pickTextFile() async {
  final input = html.FileUploadInputElement()..accept = '.json,application/json';
  input.style.display = 'none';
  html.document.body?.append(input);
  final selected = Completer<html.File?>();

  void completeFromInput() {
    if (selected.isCompleted) return;
    final files = input.files;
    selected.complete(files == null || files.isEmpty ? null : files.first);
  }

  final changeSubscription = input.onChange.listen((_) => completeFromInput());
  // Si l'utilisateur ferme le sélecteur sans choisir de fichier, Chrome rend
  // le focus à la fenêtre : on traite cela comme une annulation, pas comme un
  // chargement qui resterait indéfiniment bloqué.
  final focusSubscription = html.window.onFocus.listen((_) {
    Future<void>.delayed(const Duration(milliseconds: 350), completeFromInput);
  });
  input.click();

  final file = await selected.future.timeout(
    const Duration(minutes: 2),
    onTimeout: () => null,
  );
  await changeSubscription.cancel();
  await focusSubscription.cancel();
  input.remove();
  if (file == null) return null;

  final reader = html.FileReader();
  final result = Completer<String>();
  reader.onLoad.listen((_) {
    if (!result.isCompleted) result.complete(reader.result?.toString() ?? '');
  });
  reader.onError.listen((_) {
    if (!result.isCompleted) result.completeError(StateError('Le fichier n’a pas pu être lu.'));
  });
  reader.readAsText(file);
  return result.future;
}
