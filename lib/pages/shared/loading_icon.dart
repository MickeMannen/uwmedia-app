/// The app's icon, breathing, while a picture is being read (owner,
/// 2026-11-19: a first photo or video takes its time to show).
library;

import 'package:flutter/material.dart';

/// The icon's file among the app's assets.
const appIconAsset = 'assets/icon/app_icon.png';

class LoadingIcon extends StatefulWidget {
  const LoadingIcon({super.key, this.size = 72});

  final double size;

  @override
  State<LoadingIcon> createState() => _LoadingIconState();
}

class _LoadingIconState extends State<LoadingIcon>
    with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);
  late final _eased = CurvedAnimation(parent: _turn, curve: Curves.easeInOut);

  @override
  void dispose() {
    _eased.dispose();
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading',
    child: FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(_eased),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.82, end: 1).animate(_eased),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.size * 0.22),
          child: Image.asset(
            appIconAsset,
            width: widget.size,
            height: widget.size,
            // A build without the asset (a test's bundle) shows the
            // usual ring.
            errorBuilder: (_, _, _) => SizedBox.square(
              dimension: widget.size / 2,
              child: const CircularProgressIndicator(strokeWidth: 3),
            ),
          ),
        ),
      ),
    ),
  );
}
