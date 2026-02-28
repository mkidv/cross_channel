import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Error: Provide an example file path as an argument.');
    exit(1);
  }

  final filePath = args[0];
  final file = File(filePath);

  if (!file.existsSync()) {
    stderr.writeln('Error: Snippet file "$filePath" not found.');
    exit(1);
  }

  // DartDoc injects whatever is printed here directly into the generated HTML.
  // We wrap the code in a standard Markdown Dart block to get syntax highlighting.
  print('```dart');
  print(file.readAsStringSync().trim());
  print('```');
}
