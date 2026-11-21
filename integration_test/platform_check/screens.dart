// The two screens of the platform check that wait for the person running
// it: picking the perf clip on a phone, and the summary at the end with a
// Copy button. Real taps reach them (the binding passes the device's pointer
// events on while they show).
import 'dart:async';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shows [screen] and pumps frames until [done] completes or [timeout]
/// passes; gives [done]'s value, or [onTimeout]'s.
Future<T> waitOnScreen<T>(
  WidgetTester tester,
  Widget screen,
  Completer<T> done, {
  required Duration timeout,
  required T Function() onTimeout,
}) async {
  final binding = tester.binding as LiveTestWidgetsFlutterBinding;
  final propagate = binding.shouldPropagateDevicePointerEvents;
  binding.shouldPropagateDevicePointerEvents = true;
  try {
    await tester.pumpWidget(MaterialApp(home: screen));
    final watch = Stopwatch()..start();
    while (!done.isCompleted && watch.elapsed < timeout) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return done.isCompleted ? await done.future : onTimeout();
  } finally {
    binding.shouldPropagateDevicePointerEvents = propagate;
    await tester.pumpWidget(const SizedBox.shrink());
  }
}

/// "Pick perf_clip.mp4": completes [done] with the picked file's path, or
/// `null` for Skip.
class PickClipScreen extends StatelessWidget {
  const PickClipScreen(this.done, {required this.fileName, super.key});

  final Completer<String?> done;
  final String fileName;

  Future<void> _pick() async {
    final file = await fs.openFile(
      acceptedTypeGroups: const [
        fs.XTypeGroup(
          label: 'MP4 video',
          extensions: ['mp4'],
          mimeTypes: ['video/mp4'],
          uniformTypeIdentifiers: ['public.mpeg-4'],
        ),
      ],
    );
    if (file != null && !done.isCompleted) {
      done.complete(file.path);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Platform check')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pick $fileName for the timed runs (copy it to the phone from '
            'integration_test/platform_check/ once, by AirDrop, Files or '
            'USB). Skip leaves the timed runs out.',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton(onPressed: _pick, child: Text('Pick $fileName')),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () {
                  if (!done.isCompleted) {
                    done.complete(null);
                  }
                },
                child: const Text('Skip'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// The summary as selectable monospace text, with Copy and Done; Done
/// completes [done].
class SummaryScreen extends StatelessWidget {
  const SummaryScreen(this.text, this.done, {super.key});

  final String text;
  final Completer<void> done;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Platform check summary')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: const TextStyle(
                      fontFamily: 'RobotoMono-Regular',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () {
                    if (!done.isCompleted) {
                      done.complete();
                    }
                  },
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
