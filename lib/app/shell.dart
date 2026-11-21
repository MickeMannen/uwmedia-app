/// The app's frame (Python `qml/main.qml`): the pages in a rail on the
/// left on a wide window, behind a menu on a narrow one, each page kept
/// alive while another is shown so that a running batch goes on.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/engine/opened_files.dart';
import 'package:uwmedia_app/pages/about/about_page.dart';
import 'package:uwmedia_app/pages/advanced/advanced_page.dart';
import 'package:uwmedia_app/pages/color/color_page.dart';
import 'package:uwmedia_app/pages/color_tuning/color_tuning_page.dart';
import 'package:uwmedia_app/pages/convertion/convertion_page.dart';
import 'package:uwmedia_app/pages/dive_logs/dive_logs_page.dart';
import 'package:uwmedia_app/pages/dive_profile/dive_profile_page.dart';
import 'package:uwmedia_app/pages/log_viewer/log_viewer_page.dart';
import 'package:uwmedia_app/pages/overlay_designer/overlay_designer_page.dart';
import 'package:uwmedia_app/pages/overlay_generator/overlay_generator_page.dart';
import 'package:uwmedia_app/pages/settings/settings_page.dart';
import 'package:uwmedia_app/pages/shared/phone_files.dart';
import 'package:uwmedia_app/pages/tag_editor/tag_editor_page.dart';
import 'package:uwmedia_app/pages/tag_editor_lite/tag_editor_lite_page.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// One entry of the page list.
class AppPage {
  const AppPage({
    required this.title,
    required this.icon,
    required this.build,
    this.desktop = true,
    this.mobile = true,
  });

  final String title;
  final IconData icon;
  final bool desktop;
  final bool mobile;
  final Widget Function(AppServices services) build;
}

Widget _notYet(String title) => PageFrame(
  title: title,
  children: const [
    MutedText('This page is not in this version of the app yet.', size: 14),
  ],
);

/// Every page in the Python app's order, with where it exists (spec §0).
final List<AppPage> allPages = [
  AppPage(
    title: 'Color',
    icon: Icons.palette_outlined,
    // A phone's page takes the media from the library and saves into an
    // album (spec §9.2); it needs the phone's media engine.
    build: (services) => services.capabilities.desktop
        ? ColorPage(services: services)
        : services.capabilities.mobileEngine
        ? ColorPage(services: services, phone: true, setup: phoneColorSetup)
        : _notYet('Color'),
  ),
  AppPage(
    title: 'Overlay Generator',
    icon: Icons.layers_outlined,
    mobile: false,
    build: (services) => OverlayGeneratorPage(services: services),
  ),
  AppPage(
    title: 'Resize',
    icon: Icons.movie_outlined,
    // On a phone the video comes from the library and the results go
    // into an album (spec §9.2); it needs the phone's media engine.
    build: (services) => services.capabilities.desktop
        ? ConvertionPage(services: services)
        : services.capabilities.mobileEngine
        ? ConvertionPage(
            services: services,
            phone: true,
            dialogs: const PhoneConvertionDialogs(),
          )
        : _notYet('Resize'),
  ),
  AppPage(
    title: 'Color Tuning',
    icon: Icons.tune,
    // The lite page of spec §9.3 on a phone: a photo as the sample, or a
    // video's frame where the phone's media engine is.
    build: (services) => services.capabilities.desktop
        ? ColorTuningPage(services: services)
        : ColorTuningPage(
            services: services,
            lite: true,
            pickImage: services.capabilities.mobileEngine
                ? pickSampleFromLibrary(services.tempDir)
                : pickFromLibrary,
            // Or from the phone's files, as the Color page's pick.
            pickFile: services.capabilities.mobileEngine
                ? pickSampleFromLibrary(
                    services.tempDir,
                    pickMedia: () async =>
                        (await pickFromFiles(multiple: false)).firstOrNull,
                  )
                : null,
          ),
  ),
  AppPage(
    title: 'Tag Editor',
    icon: Icons.sell_outlined,
    // The lite page of spec §9.1 on a phone.
    // The full editor is exiftool's; a build without it has the lite one.
    build: (services) =>
        services.capabilities.desktop && services.capabilities.externalTools
        ? TagEditorPage(services: services)
        : TagEditorLitePage(services: services),
  ),
  AppPage(
    title: 'Log Viewer',
    icon: Icons.description_outlined,
    mobile: false,
    build: (services) => LogViewerPage(services: services),
  ),
  AppPage(
    title: 'Overlay Designer',
    icon: Icons.edit_outlined,
    mobile: false,
    build: (services) => OverlayDesignerPage(services: services),
  ),
  AppPage(
    title: 'Dive Profile Builder',
    icon: Icons.show_chart,
    mobile: false,
    build: (services) => DiveProfilePage(services: services),
  ),
  AppPage(
    title: diveLogsTitle,
    icon: Icons.scuba_diving_outlined,
    // The logs kept in the app (§12.3): a phone has no logs folder, and
    // the desktop reads its optional one with them (§10.57).
    build: (services) => DiveLogsPage(services: services),
  ),
  AppPage(
    title: 'Settings',
    icon: Icons.settings_outlined,
    mobile: false,
    build: (services) => AdvancedPage(services: services),
  ),
  AppPage(
    title: 'Settings',
    icon: Icons.settings_outlined,
    desktop: false,
    build: (services) => SettingsPage(services: services),
  ),
  AppPage(
    title: 'About',
    icon: Icons.info_outline,
    build: (services) => AboutPage(services: services),
  ),
];

/// The pages that exist with [capabilities].
List<AppPage> pagesFor(Capabilities capabilities) => [
  for (final page in allPages)
    if (capabilities.desktop ? page.desktop : page.mobile) page,
];

/// Below this width the rail gives way to a menu.
const railMinWidth = 720.0;

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.services,
    this.pages,
    this.openedFiles,
  });

  final AppServices services;

  /// The pages to offer; by default [pagesFor] the device.
  final List<AppPage>? pages;

  /// The dive logs opened with UWMedia (a phone's; none on the desktop):
  /// kept, and the Dive Logs page shown.
  final OpenedFiles? openedFiles;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final List<AppPage> pages =
      widget.pages ?? pagesFor(widget.services.capabilities);
  late final List<Widget?> _built = List.filled(pages.length, null);
  int current = 0;

  // The stack moves between the wide and the narrow frame; the key keeps
  // its pages (and a running batch) alive when the window is resized.
  final _stackKey = GlobalKey();

  // A page is built the first time it is shown and kept from then on.
  Widget _page(int index) =>
      _built[index] ??= pages[index].build(widget.services);

  @override
  void initState() {
    super.initState();
    widget.openedFiles?.listen(_opened);
    widget.services.pageAsked.addListener(_pageAsked);
  }

  @override
  void dispose() {
    widget.services.pageAsked.removeListener(_pageAsked);
    super.dispose();
  }

  // A page asked for another one (a page's "Dive Logs…" button).
  void _pageAsked() {
    final asked = widget.services.pageAsked.value;
    if (asked == null) {
      return;
    }
    widget.services.pageAsked.value = null;
    final index = pages.indexWhere((page) => page.title == asked);
    if (index >= 0 && mounted) {
      setState(() => current = index);
    }
  }

  // An overlay page zip goes to the user's templates, and is said; the
  // other files are dive logs, shown on their page.
  Future<void> _opened(List<String> paths) async {
    final received = await widget.services.receiveFiles(paths);
    unawaited(widget.openedFiles?.done(paths));
    if (!mounted) {
      return;
    }
    final said = receivedOverlaysText(received);
    if (said.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
    }
    final logs = pages.indexWhere((page) => page.title == diveLogsTitle);
    if (logs >= 0 && received.logs > 0) {
      setState(() => current = logs);
    }
  }

  Widget _stack() => IndexedStack(
    key: _stackKey,
    index: current,
    children: [
      for (var i = 0; i < pages.length; i++)
        _built[i] != null || i == current ? _page(i) : const SizedBox(),
    ],
  );

  Widget _list({VoidCallback? then}) => ListView(
    padding: const EdgeInsets.all(4),
    children: [
      for (var i = 0; i < pages.length; i++)
        ListTile(
          dense: true,
          leading: Icon(pages[i].icon),
          title: Text(
            pages[i].title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: i == current ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          selected: i == current,
          selectedColor: accent,
          onTap: () {
            setState(() => current = i);
            then?.call();
          },
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= railMinWidth) {
        return Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 220,
                child: Material(color: navBackground, child: _list()),
              ),
              Expanded(child: _stack()),
            ],
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: Text(pages[current].title)),
        drawer: Builder(
          builder: (context) => Drawer(
            backgroundColor: navBackground,
            child: SafeArea(
              child: _list(then: () => Navigator.of(context).pop()),
            ),
          ),
        ),
        body: _stack(),
      );
    },
  );
}
