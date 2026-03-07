import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final reportOnly = args.contains('--report-only');

  if (!reportOnly) {
    print('Running tests with coverage...');
    final coverageDir = Directory('coverage');
    if (coverageDir.existsSync()) {
      coverageDir.deleteSync(recursive: true);
    }
    coverageDir.createSync();

    final testResult = await Process.run(
      'dart',
      ['test', '--coverage=coverage', 'test/'],
    );

    if (testResult.exitCode != 0) {
      print(testResult.stdout);
      print(testResult.stderr);
      exit(testResult.exitCode);
    }

    print('Formatting coverage to lcov...');
    final formatResult = await Process.run(
      'dart',
      [
        'pub',
        'global',
        'run',
        'coverage:format_coverage',
        '--lcov',
        '--in=coverage/test',
        '--out=coverage/lcov.info',
        '--report-on=lib'
      ],
    );

    if (formatResult.exitCode != 0) {
      print('Error formatting coverage. Ensure coverage package is activated:');
      print('dart pub global activate coverage');
      exit(formatResult.exitCode);
    }
  }

  final lcovFile = File('coverage/lcov.info');
  if (!lcovFile.existsSync()) {
    print('Error: coverage/lcov.info not found.');
    exit(1);
  }

  final lines = lcovFile.readAsLinesSync();
  String? currentFile;
  final fileLinesFound = <String, int>{};
  final fileLinesHit = <String, int>{};

  for (final line in lines) {
    if (line.startsWith('SF:')) {
      currentFile = line.substring(3);
    } else if (line.startsWith('LF:')) {
      fileLinesFound[currentFile!] = int.parse(line.substring(3));
    } else if (line.startsWith('LH:')) {
      fileLinesHit[currentFile!] = int.parse(line.substring(3));
    }
  }

  int totalLf = 0;
  int totalLh = 0;
  final results = <Map<String, dynamic>>[];

  for (final file in fileLinesFound.keys) {
    final lf = fileLinesFound[file]!;
    final lh = fileLinesHit[file]!;
    totalLf += lf;
    totalLh += lh;
    if (lf > 0) {
      results.add({
        'file': file,
        'cov': (lh / lf) * 100,
        'missed': lf - lh,
      });
    }
  }

  results.sort((a, b) => (a['cov'] as num).compareTo(b['cov'] as num));

  print('\n--- Coverage per file ---');
  for (final r in results) {
    print(
        '${(r['cov'] as num).toStringAsFixed(1).padLeft(5)}% (${r['missed'].toString().padLeft(3)} missed) - ${r['file']}');
  }
  print('-------------------------');
  if (totalLf > 0) {
    print(
        'Total: ${(totalLh / totalLf * 100).toStringAsFixed(1)}% ($totalLh / $totalLf)');
  }
}
