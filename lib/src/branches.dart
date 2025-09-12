import 'dart:async';

import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

part 'branches/recv_branch.dart';
part 'branches/future_branch.dart';
part 'branches/stream_branch.dart';
part 'branches/timer_branch.dart';

/// Function to cancel an async operation.
typedef Canceller = void Function();

/// Function to register a canceller with the selection system.
typedef RegisterCanceller = void Function(Canceller);

/// Function to resolve a branch with a result.
/// Called when a branch completes to signal the selection winner.
typedef Resolve<R> = FutureOr<void> Function(
  int index,
  Object? tag,
  FutureOr<R> result,
);

/// Contract for a selectable branch in XSelect operations.
///
/// Each branch type (Future, Stream, Channel, Timer) implements this interface
/// to participate in async racing with proper cancellation support.
abstract class SelectBranch<R> {
  bool attachSync({
    required int index,
    required Resolve<R> resolve,
  });

  void attach({
    required int index,
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
  });
}
