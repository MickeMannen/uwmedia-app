import 'package:flutter/material.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// The Progress card of the pages that run a batch: the bar with its
/// count while running, the elapsed and remaining time, the status line
/// and Start / Stop.
class RunProgressCard extends StatelessWidget {
  const RunProgressCard({
    super.key,
    required this.running,
    required this.known,
    required this.fraction,
    required this.fractionText,
    required this.timingText,
    required this.statusText,
    required this.onStartStop,
    this.busyElsewhere,
    this.button = true,
  });

  final bool running;
  final bool known;
  final double fraction;
  final String fractionText;
  final String timingText;
  final String statusText;
  final VoidCallback onStartStop;

  /// Why Start cannot be pressed now: another page's batch is running.
  final String? busyElsewhere;

  /// Whether Start and Stop are in the card; not where a [RunStartBar]
  /// under the page has them.
  final bool button;

  @override
  Widget build(BuildContext context) {
    final startStop = StartStopButton(
      running: running,
      onStartStop: onStartStop,
      busyElsewhere: busyElsewhere,
    );
    return SectionCard(
      title: 'Progress',
      children: [
        if (running)
          Row(
            spacing: 6,
            children: [
              Expanded(
                child: LinearProgressIndicator(value: known ? fraction : null),
              ),
              SizedBox(
                width: 80,
                child: Text(
                  fractionText,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        if (timingText.isNotEmpty) MutedText(timingText, size: 11),
        MutedText(statusText),
        if (button) startStop,
      ],
    );
  }
}

/// Start, or Stop while a run goes.
class StartStopButton extends StatelessWidget {
  const StartStopButton({
    super.key,
    required this.running,
    required this.onStartStop,
    this.busyElsewhere,
    this.height = 40,
  });

  final bool running;
  final VoidCallback onStartStop;

  /// Why Start cannot be pressed now: another page's batch is running.
  final String? busyElsewhere;
  final double height;

  @override
  Widget build(BuildContext context) {
    final blocked = !running && busyElsewhere != null;
    final button = SizedBox(
      height: height,
      child: FilledButton.icon(
        icon: Icon(running ? Icons.stop : Icons.play_arrow),
        label: Text(running ? 'Stop' : 'Start'),
        onPressed: blocked ? null : onStartStop,
      ),
    );
    return blocked ? Tooltip(message: busyElsewhere, child: button) : button;
  }
}

/// Start and Stop under a phone's page, in reach wherever the page is
/// scrolled to, with how the last run ended ([lines], the empty ones left
/// out) above the button while none goes.
class RunStartBar extends StatelessWidget {
  const RunStartBar({
    super.key,
    required this.running,
    required this.onStartStop,
    this.lines = const [],
    this.busyElsewhere,
  });

  final bool running;
  final VoidCallback onStartStop;
  final List<String> lines;
  final String? busyElsewhere;

  @override
  Widget build(BuildContext context) => Material(
    elevation: 8,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            if (!running)
              for (final line in lines)
                if (line.isNotEmpty)
                  Text(
                    line,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: mutedText, fontSize: 12),
                  ),
            StartStopButton(
              running: running,
              onStartStop: onStartStop,
              busyElsewhere: busyElsewhere,
              height: 44,
            ),
          ],
        ),
      ),
    ),
  );
}
