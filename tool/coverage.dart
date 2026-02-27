import 'dart:io';

Future<void> main() async {
  print('Running tests with coverage...');

  // Create coverage directory
  final coverageDir = Directory('coverage');
  if (!coverageDir.existsSync()) {
    coverageDir.createSync();
  }

  // Run tests with coverage
  final result = await Process.run(
    'dart',
    ['test', '--coverage=coverage', 'test/'],
  );

  if (result.exitCode != 0) {
    print(result.stdout);
    print(result.stderr);
    exit(result.exitCode);
  }

  // Format to lcov
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
    // Try running without 'pub global run' if coverage is activated globally
    final localFormat = await Process.run('format_coverage', [
      '--lcov',
      '--in=coverage/test',
      '--out=coverage/lcov.info',
      '--report-on=lib'
    ]);
    if (localFormat.exitCode != 0) {
      print('Error formatting coverage:');
      print(formatResult.stderr);
      print(localFormat.stderr);
      print('Ensure `coverage` package is activated: '
          'dart pub global activate coverage');
    } else {
      print('Coverage report generated at coverage/lcov.info');
    }
  } else {
    print('Coverage report generated at coverage/lcov.info');
  }
}
