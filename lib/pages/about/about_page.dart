/// The About page (Python `backends/about_backend.py`, `qml/AboutPage.qml`):
/// the version, the update check, the licence, the external tools in use,
/// the open-source licences and the links.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/diagnostics/report.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/engine/file_picks.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

const authorName = 'Mikael Christersson';
const githubRepo = 'MickeMannen/uwmedia-app';
const githubUrl = 'https://github.com/$githubRepo';
const youtubeUrl = 'https://www.youtube.com/@MickeMannen8';
const copyReportLabel = 'Copy report';

/// The fonts the overlays are drawn with, and their licence files.
const fontLicenses = {
  'DejaVu Sans': 'DEJAVU_FONT_LICENSE.txt',
  'DSEG7 Classic': 'DSEG_FONT_LICENSE.txt',
  'Liberation Sans': 'LIBERATION_FONT_LICENSE.txt',
  'Roboto': 'ROBOTO_FONT_LICENSE.txt',
  'Roboto Condensed': 'ROBOTO_CONDENSED_FONT_LICENSE.txt',
  'Roboto Mono': 'ROBOTO_MONO_FONT_LICENSE.txt',
};

/// The overlay fonts' licences in Flutter's licence list, once.
void registerFontLicenses() {
  if (_registered) {
    return;
  }
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    for (final MapEntry(key: font, value: file) in fontLicenses.entries) {
      yield LicenseEntryWithLineBreaks([
        font,
      ], await rootBundle.loadString('assets/licenses/$file'));
    }
  });
}

bool _registered = false;

/// The app's own licence, `LICENSE` at the repo's root, bundled as an
/// asset (pubspec.yaml).
const appLicense = 'LICENSE';

/// UWMedia's own MIT licence in Flutter's licence list, once.
void registerAppLicense() {
  if (_appRegistered) {
    return;
  }
  _appRegistered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'UWMedia',
    ], await rootBundle.loadString(appLicense));
  });
}

bool _appRegistered = false;

/// The licence files of the tools a desktop build ships with (spec
/// §13.2), and the record of which builds they are.
const toolLicenses = {
  'FFmpeg': 'FFMPEG_LICENSE.txt',
  'ExifTool': 'EXIFTOOL_LICENSE.txt',
  'GNU General Public License v3': 'GPLV3_LICENSE.txt',
};
const toolManifest = 'assets/licenses/BINARY_MANIFEST.json';

/// The shipped tools' licences in Flutter's licence list, once: for a
/// build that has them inside.
void registerToolLicenses() {
  if (_toolsRegistered) {
    return;
  }
  _toolsRegistered = true;
  LicenseRegistry.addLicense(() async* {
    for (final MapEntry(key: tool, value: file) in toolLicenses.entries) {
      yield LicenseEntryWithLineBreaks([
        tool,
      ], await rootBundle.loadString('assets/licenses/$file'));
    }
  });
}

bool _toolsRegistered = false;

/// The version of [tool] (`ffmpeg`, `exiftool`) shipped for [os], from
/// the manifest's text; `null` when it does not say.
String? shippedVersion(String manifest, String tool, EngineOs os) {
  try {
    final platforms = ((jsonDecode(manifest) as Map)[tool] as Map)['platforms'];
    final version = ((platforms as Map)[os.name] as Map)['version'];
    return version is String ? version : null;
  } on Object {
    return null;
  }
}

/// What the page says of a tool: the shipped one with its version, the
/// machine's own with its place, or that there is none.
String toolLine(
  String name,
  String? path, {
  required bool shipped,
  String? version,
}) => path == null
    ? '$name — not found'
    : shipped
    ? '$name${version == null ? '' : ' $version'} — packaged with this app'
    : '$name — using local install ($path)';

/// `1.2.3` as `[1, 2, 3]`, up to the first part that is not a number
/// (Python `_version_tuple`); a leading `v` is dropped.
List<int> versionParts(String value) {
  final parts = <int>[];
  for (final chunk
      in value.replaceFirst(RegExp('^[vV]+'), '').split(RegExp(r'[.\-+]'))) {
    final n = int.tryParse(chunk);
    if (n == null) {
      break;
    }
    parts.add(n);
  }
  return parts;
}

/// Whether [a] is a later version than [b], part by part (Python's tuple
/// comparison: a longer equal prefix is later).
bool isNewer(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) {
      return a[i] > b[i];
    }
  }
  return a.length > b.length;
}

/// What the update check says: the text, and whether it is news.
typedef UpdateNote = ({String text, Color color});

const _muted = Color(0xFF9AA0A6);

/// The update check's answer for the [latest] release tag (`null` when
/// there is none) against the [current] version.
UpdateNote updateNote(String? latest, String current) {
  if (latest == null || latest.isEmpty) {
    return (text: 'No releases found on GitHub yet.', color: _muted);
  }
  if (isNewer(versionParts(latest), versionParts(current))) {
    return (
      text: 'A new version is available: $latest (you have $current)',
      color: const Color(0xFFF59E0B),
    );
  }
  return (
    text: "You're up to date ($current).",
    color: const Color(0xFF22C55E),
  );
}

/// The tag of the app's latest release on GitHub (`null` when there is
/// none); throws when it cannot be asked.
Future<String?> latestReleaseTag() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(
      Uri.parse('https://api.github.com/repos/$githubRepo/releases/latest'),
    );
    request.headers.set('Accept', 'application/vnd.github+json');
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    final body = await response.transform(utf8.decoder).join();
    final data = jsonDecode(body);
    return data is Map && data['tag_name'] is String
        ? data['tag_name'] as String
        : null;
  } finally {
    client.close();
  }
}

class AboutPage extends StatefulWidget {
  const AboutPage({
    super.key,
    required this.services,
    this.version,
    this.build,
    this.latestTag = latestReleaseTag,
    this.finder,
    this.log,
  });

  /// The build's number, for a test; with [version] given and this left
  /// out, none is shown.
  final String? build;

  /// The log a report is made of; by default the running app's.
  final AppLog? log;

  final AppServices services;

  /// The app's version; by default the build's own.
  final String? version;

  /// Asks GitHub for the latest release.
  final Future<String?> Function() latestTag;

  /// Finds the tools on the desktop; by default on this machine.
  final ToolFinder Function()? finder;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';
  // The build's number: what tells two builds of one version apart (the
  // store's uploads, spec §10.114).
  String _build = '';
  UpdateNote? _update;
  final Map<String, String> _tools = {};

  @override
  void initState() {
    super.initState();
    registerAppLicense();
    registerFontLicenses();
    if (widget.version != null) {
      _version = widget.version!;
      _build = widget.build ?? '';
    } else {
      PackageInfo.fromPlatform()
          .then((info) {
            if (mounted) {
              setState(() {
                _version = info.version;
                _build = info.buildNumber;
              });
            }
          })
          .catchError((Object _) {
            if (mounted) {
              setState(() => _version = 'dev');
            }
          });
    }
    if (_usesTools) {
      _findTools();
    }
  }

  // Whether this build runs ffmpeg and exiftool: a computer's, but not the
  // Mac App Store's, which has neither (spec §10.74). Without them there
  // is nothing to say of them.
  bool get _usesTools =>
      widget.services.capabilities.desktop &&
      widget.services.capabilities.externalTools;

  Future<void> _findTools() async {
    final finder = (widget.finder ?? ToolFinder.forThisMachine)();
    final found = await finder.findAll(widget.services.config.settings());
    if (!mounted) {
      return;
    }
    final bundled = finder.bundledBinDir;
    var manifest = '';
    try {
      manifest = await rootBundle.loadString(toolManifest);
    } on Object {
      manifest = '';
    }
    if (!mounted) {
      return;
    }
    setState(() {
      for (final (name, tool, key) in const [
        ('FFmpeg', toolFfmpeg, 'ffmpeg'),
        ('ExifTool', toolExiftool, 'exiftool'),
      ]) {
        final path = found[tool];
        final shipped =
            path != null && bundled != null && p.isWithin(bundled, path);
        if (shipped) {
          registerToolLicenses();
        }
        _tools[name] = toolLine(
          name,
          path,
          shipped: shipped,
          version: shippedVersion(manifest, key, finder.os),
        );
      }
    });
  }

  Future<void> _check() async {
    setState(() => _update = (text: 'Checking for updates…', color: _muted));
    UpdateNote note;
    try {
      note = updateNote(
        await widget.latestTag(),
        _version.isEmpty ? '0.0.0' : _version,
      );
    } on Object {
      note = (
        text: "Couldn't check for updates (no connection?).",
        color: _muted,
      );
    }
    if (mounted) {
      setState(() => _update = note);
    }
  }

  String _reportNote = '';

  /// The report as it is now (spec §10.76).
  String _report() {
    final services = widget.services;
    final caps = services.capabilities;
    return reportText({
      'Version': _version.isEmpty
          ? 'unknown'
          : _build.isEmpty
          ? _version
          : '$_version (build $_build)',
      'System':
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'Language': Platform.localeName,
      'Processors': '${Platform.numberOfProcessors}',
      'Build': [
        kReleaseMode ? 'release' : 'debug',
        if (caps.desktop) 'desktop' else 'phone',
        if (!caps.externalTools && caps.desktop) 'no external tools',
      ].join(', '),
      if (caps.desktop && caps.externalTools)
        'Video engine':
            '${services.config.settings()[videoEngineKey] ?? videoEngineFfmpeg}',
      for (final MapEntry(:key, :value) in _tools.entries) key: value,
    }, (widget.log ?? AppLog.instance)?.tail() ?? const []);
  }

  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: _report()));
    if (mounted) {
      setState(
        () => _reportNote =
            'Copied. Paste it into a mail or an issue, and read it first.',
      );
    }
  }

  Future<void> _saveReport() async {
    final place = await getSaveLocation(suggestedName: 'uwmedia-report.txt');
    if (place == null) {
      return;
    }
    String note;
    try {
      File(place.path).writeAsStringSync(_report());
      note = 'Saved as ${place.path}';
    } on FileSystemException catch (e) {
      note = 'Could not save the report: ${e.message}';
    }
    if (mounted) {
      setState(() => _reportNote = note);
    }
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url));
    } on Object {
      // Nothing to open it with.
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'About',
    children: [
      SectionCard(
        title: 'UWMedia',
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: _build.isEmpty ? '' : 'Build $_build',
              child: Text(
                'Version $_version',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const Text(
            'Underwater media processor - color correction and dive telemetry '
            'overlays for videos and photos.',
          ),
        ],
      ),
      if (widget.services.capabilities.updateCheck)
        SectionCard(
          title: 'Updates',
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: _check,
                child: const Text('Check for updates'),
              ),
            ),
            if (_update != null)
              Text(_update!.text, style: TextStyle(color: _update!.color)),
          ],
        ),
      const SectionCard(
        title: 'License',
        children: [
          Text('MIT License', style: TextStyle(fontWeight: FontWeight.bold)),
          Text(
            'Copyright (c) 2025 $authorName. The full text is under '
            'UWMedia in "Open-source licenses" below.',
          ),
        ],
      ),
      SectionCard(
        title: 'Third-Party Licenses',
        children: [
          if (_usesTools) ...[
            const MutedText(
              'UWMedia invokes these as separate external programs, not '
              "linked libraries - this does not affect UWMedia's own MIT "
              'license above.',
            ),
            for (final line in _tools.values) Text(line),
          ],
          Text('The overlay fonts: ${fontLicenses.keys.join(', ')}.'),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'UWMedia',
                applicationVersion: _version,
              ),
              child: const Text('Open-source licenses'),
            ),
          ),
        ],
      ),
      SectionCard(
        title: 'Report a problem',
        children: [
          const Text(
            'When something goes wrong, the report says what the app and '
            'this device are and what the last runs said: the files\' '
            'names, sizes and frame rates, and the messages. No picture, '
            'no dive log. Nothing is sent by the app; read the report and '
            'send it yourself, with what you did and what you expected.',
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton(
                onPressed: _copyReport,
                child: const Text(copyReportLabel),
              ),
              if (widget.services.capabilities.desktop)
                OutlinedButton(
                  onPressed: _saveReport,
                  child: const Text('Save report…'),
                ),
              OutlinedButton(
                onPressed: () => _open('$githubUrl/issues'),
                child: const Text('Issues on GitHub'),
              ),
            ],
          ),
          if (_reportNote.isNotEmpty) MutedText(_reportNote),
        ],
      ),
      SectionCard(
        title: 'Links',
        children: [
          const Text('By $authorName'),
          Row(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => _open(githubUrl),
                child: const Text('GitHub'),
              ),
              OutlinedButton(
                onPressed: () => _open(youtubeUrl),
                child: const Text('YouTube'),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
