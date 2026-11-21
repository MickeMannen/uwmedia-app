// UWMedia mobile engine spike (option B, spec §11): the phone's own media
// engines (Media3 Transformer on Android, AVFoundation on iOS) measured on
// the work the app will give them. Pick a video, run the tests, then copy
// the results and send them back.
//
//   F0  the video's facts (size, length, frame rate)
//   F1  a frame grab
//   F3  a 1080p downscale
//   F4  a colour pass through a 3D LUT made by the app's colour engine
//       from the grabbed frame
//   F5  an overlay sequence (one picture a second, as the dive samples
//       come) drawn over the video at its own size
//   F6  the last output saved into a new album in the photo library
//   F7  photos picked from the library: their format and whether their
//       EXIF dates came through the picker (the app's own readers)
//   F8  a copy of the first picked photo, its dates moved an hour by the
//       app's own writers, saved into the album; the original untouched
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/metadata/heic_exif.dart';
import 'package:uwmedia_app/core/metadata/jpeg_exif.dart';
import 'package:uwmedia_app/core/metadata/mp4_dates.dart';
import 'package:uwmedia_app/core/metadata/tag_editor.dart';
import 'package:uwmedia_app/engine/mp4_file.dart';

const _engine = MethodChannel('uwmedia.spike/engine');
const _album = 'UWMedia Spike';

void main() => runApp(const SpikeApp());

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'UWMedia engine spike',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF00A6ED),
        brightness: Brightness.dark,
      ),
    ),
    home: const SpikePage(),
  );
}

class SpikePage extends StatefulWidget {
  const SpikePage({super.key});

  @override
  State<SpikePage> createState() => _SpikePageState();
}

class _SpikePageState extends State<SpikePage> {
  final _lines = <String>[];
  String? _video;
  Map<String, Object?>? _facts;
  Uint8List? _frame;
  String? _lastOutput;
  List<XFile> _photos = const [];
  bool _busy = false;
  String _running = '';

  @override
  void initState() {
    super.initState();
    _deviceInfo();
  }

  void _log(String line) => setState(() => _lines.add(line));

  Future<void> _deviceInfo() async {
    try {
      final info = await _engine.invokeMapMethod<String, Object?>('deviceInfo');
      _log('Device: ${info?['model']} · ${info?['system']}');
    } on PlatformException catch (e) {
      _log('Device: ? (${e.message})');
    }
  }

  Future<String> _outPath(String name) async {
    final dir = await getTemporaryDirectory();
    return p.join(dir.path, name);
  }

  Future<void> _step(String name, Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _running = name;
    });
    try {
      await body();
    } on PlatformException catch (e) {
      _log('$name FAILED: ${e.code} ${e.message ?? ''}');
    } on Object catch (e) {
      _log('$name FAILED: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _running = '';
        });
      }
    }
  }

  double get _seconds => ((_facts?['durationMs'] as num?) ?? 0) / 1000;

  String _speed(int ms) {
    final realtime = ms > 0 ? _seconds * 1000 / ms : 0;
    return '${(ms / 1000).toStringAsFixed(1)} s for a '
        '${_seconds.toStringAsFixed(1)} s clip '
        '(${realtime.toStringAsFixed(2)}x realtime)';
  }

  String _mb(Object? bytes) =>
      '${(((bytes as num?) ?? 0) / 1e6).toStringAsFixed(1)} MB';

  Future<void> _pick() async {
    final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) {
      return;
    }
    setState(() {
      _video = picked.path;
      _frame = null;
      _lastOutput = null;
    });
    await _step('F0 facts', () async {
      final facts = await _engine.invokeMapMethod<String, Object?>(
        'videoInfo',
        {'path': picked.path},
      );
      _facts = facts;
      _log(
        'F0 video: ${facts?['width']}x${facts?['height']}, '
        '${((facts?['durationMs'] as num? ?? 0) / 1000).toStringAsFixed(1)} s, '
        '${(facts?['fps'] as num?)?.toStringAsFixed(2)} fps, '
        '${facts?['mime'] ?? '?'}, ${_mb(await File(picked.path).length())}',
      );
      // The video's own dates, read by the app's MP4 reader: did the
      // picker keep them?
      final file = File(picked.path).openSync();
      try {
        final movie = Mp4Movie.read(FileBytes(file));
        _log('F0 video dates: ${movie.tags}');
      } on Object catch (e) {
        _log('F0 video dates: not read ($e)');
      } finally {
        file.closeSync();
      }
    });
  }

  Future<void> _grab() => _step('F1 frame grab', () async {
    final watch = Stopwatch()..start();
    final png = await _engine.invokeMethod<Uint8List>('frameAt', {
      'path': _video,
      'seconds': math.min(10.0, _seconds / 2),
    });
    final ms = watch.elapsedMilliseconds;
    setState(() => _frame = png);
    _log('F1 frame grab: $ms ms, ${png?.length ?? 0} bytes PNG');
  });

  Future<void> _downscale() => _step('F3 downscale', () async {
    final out = await _outPath('f3_1080p.mp4');
    final result = await _engine.invokeMapMethod<String, Object?>('transcode', {
      'path': _video,
      'out': out,
      'height': 1080,
    });
    _lastOutput = out;
    _log(
      'F3 1080p: ${_speed(result?['ms'] as int? ?? 0)}, '
      '${_mb(result?['bytes'])}, ${result?['mime'] ?? ''}',
    );
  });

  // The app's colour engine on the grabbed frame: its analysis, then the
  // 64³ LUT the desktop hands to ffmpeg.
  Future<Uint8List> _lut() async {
    final png =
        _frame ??
        await _engine.invokeMethod<Uint8List>('frameAt', {
          'path': _video,
          'seconds': math.min(10.0, _seconds / 2),
        });
    final codec = await ui.instantiateImageCodec(png!, targetWidth: 640);
    final image = (await codec.getNextFrame()).image;
    final data = (await image.toByteData())!.buffer.asUint8List();
    final rgb = Uint8List(image.width * image.height * 3);
    for (var i = 0, o = 0; i < data.length; i += 4) {
      rgb[o++] = data[i];
      rgb[o++] = data[i + 1];
      rgb[o++] = data[i + 2];
    }
    final engine = ColorEngine(const ColorProfile());
    final filter = engine
        .analyze(RgbImage(image.width, image.height, rgb))
        .filter;
    image.dispose();
    return engine.lut3d(filter);
  }

  Future<void> _colour() => _step('F4 LUT', () async {
    final watch = Stopwatch()..start();
    final lut = await _lut();
    final lutMs = watch.elapsedMilliseconds;
    final out = await _outPath('f4_lut.mp4');
    final result = await _engine.invokeMapMethod<String, Object?>('transcode', {
      'path': _video,
      'out': out,
      'lut': lut,
      'lutSize': lutSize,
    });
    _lastOutput = out;
    _log(
      'F4 LUT (made in $lutMs ms): ${_speed(result?['ms'] as int? ?? 0)}, '
      '${_mb(result?['bytes'])}, ${result?['mime'] ?? ''}',
    );
  });

  // One overlay picture a second, as the dive samples come: a box with a
  // depth and a time, a third of the frame wide.
  Future<(String, int, int, int)> _overlays() async {
    final dir = Directory(await _outPath('overlays'));
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);
    final width = (((_facts?['width'] as num?) ?? 1920) / 3).round();
    final height = (width * 0.45).round();
    final count = math.max(1, _seconds.ceil());
    for (var s = 0; s < count; s++) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final box = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(height * 0.08)),
        Paint()..color = const Color(0x99000000),
      );
      final depth = 12 + 6 * math.sin(s / 20);
      final text = TextPainter(
        text: TextSpan(
          style: TextStyle(color: Colors.white, fontSize: height * 0.28),
          children: [
            TextSpan(text: '${depth.toStringAsFixed(1)} m\n'),
            TextSpan(
              text:
                  '${(s ~/ 60).toString().padLeft(2, '0')}:'
                  '${(s % 60).toString().padLeft(2, '0')}',
              style: TextStyle(
                color: const Color(0xFF00A6ED),
                fontSize: height * 0.22,
              ),
            ),
          ],
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width * 0.9);
      text.paint(canvas, Offset(width * 0.06, height * 0.08));
      final image = await recorder.endRecording().toImage(width, height);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File(p.join(dir.path, 'o_${s.toString().padLeft(5, '0')}.png'))
          .writeAsBytesSync(png!.buffer.asUint8List());
    }
    return (dir.path, count, width, height);
  }

  Future<void> _overlay() => _step('F5 overlay', () async {
    final watch = Stopwatch()..start();
    final (dir, count, w, h) = await _overlays();
    final drawMs = watch.elapsedMilliseconds;
    final out = await _outPath('f5_overlay.mp4');
    final result = await _engine.invokeMapMethod<String, Object?>('transcode', {
      'path': _video,
      'out': out,
      'overlayDir': dir,
      'overlayCount': count,
      // Bottom left, 4 % in from the edges.
      'overlayX': 0.04,
      'overlayY': 0.04,
    });
    _lastOutput = out;
    _log(
      'F5 overlay ($count pictures of ${w}x$h drawn in $drawMs ms): '
      '${_speed(result?['ms'] as int? ?? 0)}, ${_mb(result?['bytes'])}, '
      '${result?['mime'] ?? ''}',
    );
  });

  Future<void> _save() => _step('F6 album', () async {
    final watch = Stopwatch()..start();
    await _engine.invokeMethod<void>('saveToAlbum', {
      'path': _lastOutput,
      'album': _album,
    });
    _log(
      'F6 saved ${p.basename(_lastOutput!)} into album "$_album": '
      '${watch.elapsedMilliseconds} ms',
    );
  });

  Map<String, String> _photoDates(String path, Uint8List bytes) {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.heic' || ext == '.heif') {
      return readHeicDates(bytes);
    }
    return readJpegDates(bytes);
  }

  Future<void> _pickPhotos() => _step('F7 photos', () async {
    final picked = await ImagePicker().pickMultiImage(
      requestFullMetadata: true,
    );
    _photos = picked;
    for (final photo in picked) {
      final bytes = await File(photo.path).readAsBytes();
      String dates;
      try {
        final found = _photoDates(photo.path, bytes);
        dates = found.isEmpty ? 'NO EXIF dates' : '$found';
      } on FormatException catch (e) {
        dates = 'not read (${e.message})';
      }
      _log(
        'F7 ${p.basename(photo.path)} (${p.extension(photo.path)}, '
        '${_mb(bytes.length)}): $dates',
      );
    }
    if (picked.isEmpty) {
      _log('F7 no photo picked');
    }
    setState(() {});
  });

  Future<void> _shiftedCopy() => _step('F8 shifted copy', () async {
    final photo = _photos.first;
    final bytes = await File(photo.path).readAsBytes();
    final before = _photoDates(photo.path, bytes);
    final updates = shiftUpdates(
      meta: before,
      path: photo.path,
      shiftMinutes: 60,
    );
    if (updates == null) {
      _log('F8 no date to shift in ${p.basename(photo.path)}');
      return;
    }
    final ext = p.extension(photo.path).toLowerCase();
    final watch = Stopwatch()..start();
    final written = ext == '.heic' || ext == '.heif'
        ? writeHeicDates(bytes, updates)
        : writeJpegDates(bytes, updates);
    final copy = await _outPath(
      '${p.basenameWithoutExtension(photo.path)}_shifted$ext',
    );
    await File(copy).writeAsBytes(written);
    final writeMs = watch.elapsedMilliseconds;
    await _engine.invokeMethod<void>('saveToAlbum', {
      'path': copy,
      'album': _album,
    });
    _log(
      'F8 ${p.basename(copy)}: written in $writeMs ms, now '
      '${_photoDates(copy, written)}; saved into "$_album" '
      '(original: ${before['EXIF:DateTimeOriginal']})',
    );
  });

  Future<void> _all() async {
    await _grab();
    await _downscale();
    await _colour();
    await _overlay();
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _video != null && _facts != null && !_busy;
    Widget button(
      String label,
      Future<void> Function() run, {
      bool on = true,
    }) => FilledButton.tonal(
      onPressed: ready && on ? run : null,
      child: Text(label),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('UWMedia engine spike (option B)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton(
            onPressed: _busy ? null : _pick,
            child: Text(_video == null ? 'Pick a video' : 'Pick another video'),
          ),
          if (_video != null) Text(p.basename(_video!)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              button('F1 Frame', _grab),
              button('F3 1080p', _downscale),
              button('F4 LUT', _colour),
              button('F5 Overlay', _overlay),
              button('F6 Save to album', _save, on: _lastOutput != null),
              FilledButton.tonal(
                onPressed: _busy ? null : _pickPhotos,
                child: const Text('F7 Pick photos'),
              ),
              FilledButton.tonal(
                onPressed: !_busy && _photos.isNotEmpty ? _shiftedCopy : null,
                child: const Text('F8 Shifted copy'),
              ),
              FilledButton(
                onPressed: ready ? _all : null,
                child: const Text('Run all'),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            Text('Running $_running…'),
            const LinearProgressIndicator(),
          ],
          if (_frame != null) ...[
            const SizedBox(height: 12),
            Image.memory(_frame!, height: 160, fit: BoxFit.contain),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(child: Text('Results')),
              TextButton.icon(
                onPressed: _lines.isEmpty
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(text: _lines.join('\n')),
                      ),
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ],
          ),
          for (final line in _lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SelectableText(line, style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}
