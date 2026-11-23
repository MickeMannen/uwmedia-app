// The desktop engine's ffmpeg command lines, probe reading, layer logic
// and progress against the Python app: the parity fixture made by
// tool/python_reference/ffmpeg_fixture.py (commands recorded from the
// Python classes with the probes stood in for; nothing was encoded).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/hud_layers.dart';
import 'package:uwmedia_app/core/engine/progress.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';

import '../../helpers/python_reference.dart';

EngineOs osOf(Object? name) => switch (name) {
  'Darwin' => EngineOs.macos,
  'Windows' => EngineOs.windows,
  _ => EngineOs.linux,
};

/// The encoder Python picks for a case: only NVENC is known to it.
String encoderOf(Map<String, dynamic> c) => chooseEncoder(
  hwAccel: c['hw_accel'] as bool,
  os: osOf(c['os']),
  available: {if (c['nvenc'] as bool) encoderNvenc},
);

void main() {
  final reference = jsonDecode(
    utf8.decode(
      gzip.decode(
        File('test/fixtures/python_reference/engine/ffmpeg_cases.json.gz')
            .readAsBytesSync(),
      ),
    ),
  ) as Map<String, dynamic>;
  final taken = naive(2026, 5, 2, 10, 6, 59);

  group('encoders', () {
    test('the encoder and its quality flags, as Python picks them', () {
      for (final c in jsonObjects(reference['encoders'])) {
        expect(encoderOf(c), c['encoder'], reason: '$c');
        expect(qualityArgs(encoderOf(c)), c['quality_args'], reason: '$c');
      }
    });

    test('Windows falls back to AMF, then QuickSync (spec §10.1)', () {
      String pick(Set<String> available) => chooseEncoder(
        hwAccel: true,
        os: EngineOs.windows,
        available: available,
      );
      expect(pick({encoderAmf, encoderQsv}), encoderAmf);
      expect(pick({encoderQsv}), encoderQsv);
      expect(pick({encoderNvenc, encoderAmf}), encoderNvenc);
      expect(pick({}), encoderSoftware);
      expect(qualityArgs(encoderAmf), isNotEmpty);
      expect(qualityArgs(encoderQsv), isNotEmpty);
      expect(
        encoderProbeArgs(encoderAmf),
        containsAllInOrder(['-c:v', encoderAmf]),
      );
      // Elsewhere what is available changes nothing.
      expect(
        chooseEncoder(
          hwAccel: true,
          os: EngineOs.linux,
          available: {encoderNvenc},
        ),
        encoderSoftware,
      );
    });
  });

  test('convert and passthrough commands', () {
    final cases = jsonObjects(reference['process_video']);
    expect(cases.length, 88);
    for (final c in cases) {
      final kwargs = c['kwargs'] as Map<String, dynamic>;
      final size = kwargs['target_resolution'] as List<dynamic>?;
      final run = processVideoArgs(
        input: '/media/in put/C0012.MP4',
        output: '/media/out/C0012 1080p.mp4',
        creationDate: naive(2026, 5, 2, 10, 6, 59, 123, 456),
        duration: 12.5,
        encoder: encoderOf(c),
        colorCorrect: kwargs['color_correct'] as bool? ?? false,
        tzOffsetMins: kwargs['tz_offset_mins'] as int?,
        targetResolution: size == null
            ? null
            : (size[0] as int, size[1] as int),
        bitrate: kwargs['bitrate'] as String?,
        sourceBitrate: c['source_bitrate'] as int?,
      );
      final ran = (c['ran'] as List<dynamic>).single as Map<String, dynamic>;
      expect(run.args, ran['args'], reason: '$kwargs ${c['os']}');
      expect(run.duration, ran['duration']);
    }
  });

  test('ffprobe: the commands and how the answers are read', () {
    const path = '/media/a b.mp4';
    final args = {
      'get_video_duration': [probeDurationArgs(path)],
      'get_video_bitrate': [
        probeStreamBitrateArgs(path),
        probeFormatBitrateArgs(path),
      ],
      'get_video_dimensions': [probeDimensionsArgs(path)],
      'get_video_frame_count': [
        probeFrameCountArgs(path),
        probeDurationArgs(path),
      ],
      'get_video_pix_fmt': [probePixFmtArgs(path)],
      'hw_decodable': [probeCodecArgs(path)],
    };
    final cases = jsonObjects(reference['probes']);
    expect(cases.length, 37);
    for (final c in cases) {
      final method = c['method'] as String;
      final outputs = (c['outputs'] as List<dynamic>).cast<String?>();
      final [status, want] = c['result'] as List<dynamic>;
      final calls = (c['calls'] as List<dynamic>).cast<List<dynamic>>();
      for (final (i, call) in calls.indexed) {
        expect(call.sublist(1), args[method]![i], reason: '$method call $i');
      }
      final reason = '$method $outputs';
      switch (method) {
        case 'get_video_duration':
          expect(
            parseDuration(outputs[0]!),
            want is num ? want : isNull,
            reason: reason,
          );
          expect(status == 'raise', parseDuration(outputs[0]!) == null);
        case 'get_video_bitrate':
          final again = bitrateNeedsFormat(outputs[0]!);
          expect(calls.length, again ? 2 : 1, reason: reason);
          expect(
            parseBitrate(again ? outputs[1]! : outputs[0]!),
            want,
            reason: reason,
          );
        case 'get_video_dimensions':
          final got = parseDimensions(outputs[0]!);
          // Python gives whatever numbers there are; two are needed.
          final usable = want is List && want.length >= 2;
          expect(
            got == null ? null : [got.$1, got.$2],
            usable ? want.sublist(0, 2) : isNull,
            reason: reason,
          );
        case 'get_video_frame_count':
          final counted = parseFrameCount(outputs[0]);
          expect(calls.length, counted == null ? 2 : 1, reason: reason);
          expect(
            counted ??
                framesFromDuration(
                  outputs[1] == null ? null : parseDuration(outputs[1]!),
                ),
            want,
            reason: reason,
          );
        case 'get_video_pix_fmt':
          expect(outputs[0]!.pyStrip(), want);
        case 'hw_decodable':
          expect(hwDecodable(outputs[0]), want, reason: reason);
      }
    }
  });

  test('on a Mac a Sony camera\'s H.264 is not decoded by hardware (spec '
      '§10.73)', () {
    const h264 = 'codec_name=h264\npix_fmt=yuv420p\n';
    const hevc = 'codec_name=hevc\npix_fmt=yuv420p10le\n';
    expect(hwDecodable(h264), isTrue);
    expect(hwDecodable(h264, os: EngineOs.macos), isTrue);
    expect(hwDecodable(h264, os: EngineOs.macos, brand: 'isom'), isTrue);
    expect(hwDecodable(h264, os: EngineOs.macos, brand: 'XAVC\n'), isFalse);
    expect(hwDecodable(h264, os: EngineOs.windows, brand: 'XAVC'), isTrue);
    expect(hwDecodable(hevc, os: EngineOs.macos, brand: 'XAVC'), isTrue);
    // A probe that failed: not risked on a Mac.
    expect(hwDecodable(null, os: EngineOs.macos), isFalse);
    expect(hwDecodable(null, os: EngineOs.linux), isTrue);
    expect(probeBrandArgs('a.mp4').last, 'a.mp4');
  });

  test('Resize and the copies for sharing: the source decoded by hardware '
      'when asked for, never for a plain copy', () {
    final date = naive(2026, 3, 14, 9, 30);
    List<String> convert(EngineOs? os, {(int, int)? size}) => processVideoArgs(
      input: 'in.mp4',
      output: 'out.mp4',
      creationDate: date,
      duration: 10,
      encoder: encoderVideoToolbox,
      targetResolution: size,
      hwDecode: os,
    ).args;
    final mac = convert(EngineOs.macos, size: (1920, 1080));
    expect(mac.sublist(0, 5), [
      '-y',
      '-hwaccel',
      'videotoolbox',
      '-i',
      'in.mp4',
    ]);
    // Windows is asked for Direct3D 11 by name, never `auto` (spec
    // §10.99); Linux as before.
    expect(convert(EngineOs.windows, size: (1920, 1080)).sublist(1, 3), [
      '-hwaccel',
      'd3d11va',
    ]);
    expect(convert(EngineOs.linux, size: (1920, 1080)).sublist(1, 3), [
      '-hwaccel',
      'auto',
    ]);
    expect(hwAccelName(EngineOs.macos), 'videotoolbox');
    expect(withoutHwDecode(mac), ['-y', ...mac.sublist(3)]);
    expect(withoutHwDecode(convert(null, size: (1920, 1080))), isNull);
    expect(convert(null, size: (1920, 1080)), isNot(contains('-hwaccel')));
    expect(convert(EngineOs.macos), isNot(contains('-hwaccel')));
    final share = shareVideoArgs(
      input: 'in.mp4',
      output: 'out.mp4',
      creationDate: date,
      duration: 10,
      encoder: 'h264_videotoolbox',
      frame: (crop: null, width: 1280, height: 720, bitrate: 3000000),
      sourceWidth: 3840,
      sourceHeight: 2160,
      hwDecode: EngineOs.macos,
    ).args;
    expect(share.sublist(0, 5), [
      '-y',
      '-hwaccel',
      'videotoolbox',
      '-i',
      'in.mp4',
    ]);
  });

  test('which pixel formats keep 10 bits', () {
    for (final [pixFmt as String, want]
        in (reference['ten_bit'] as List<dynamic>).cast<List<dynamic>>()) {
      if (pixFmt == 'nv12') {
        // 8-bit; Python takes the "12" in its name for a bit depth.
        expect(want, isTrue);
        expect(isTenBit(pixFmt), isFalse);
      } else {
        expect(isTenBit(pixFmt), want, reason: pixFmt);
      }
    }
  });

  test('the frames sampled for the colour analysis', () {
    for (final c in jsonObjects(reference['sample_frames'])) {
      final frames = sampleFrames(
        (c['fps'] as num).toDouble(),
        c['total_frames'] as int,
      );
      expect(frames, c['frames'], reason: '$c');
      expect(frames.length, c['n']);
    }
  });

  test("the lut3d filter: Python's for one LUT, a colour table for each "
      'step of several (spec §10.56, §10.66), each fading into the next '
      '(§10.60)', () {
    String graph(String dir, int step, String fps) =>
        'format=rgb24|rgb48le[lm];'
        "movie=filename='$dir/lut_tables.raw':f=rawvideo:"
        r"format_opts='video_size=512x512\:pixel_format=rgb24\:framerate=1',"
        'format=gbrp16le,fps=$step,split[la][lb];'
        '[lb]trim=start_frame=$step,setpts=PTS-STARTPTS[ld];'
        'color=s=16x16:r=$step,format=gbrp16le,'
        "geq=r='65535*mod(N,$step)/$step':g='65535*mod(N,$step)/$step':"
        "b='65535*mod(N,$step)/$step',scale=512:512:flags=neighbor[lw];"
        '[la][ld][lw]maskedmerge,'
        'settb=1/1000000,setpts=(N-0.5)/($fps*TB),format=rgb48le[lt];'
        '[lm][lt]haldclut=interp=trilinear:shortest=1';
    final cases = jsonObjects(reference['lut_filters']);
    expect(cases.length, 12);
    var several = 0;
    for (final c in cases) {
      final fps = (c['fps'] as num).toDouble();
      final result = lut3dFilter(
        frameIndices: (c['indices'] as List<dynamic>).cast<int>(),
        filters: [
          for (final f in (c['filters'] as List<dynamic>).cast<List<dynamic>>())
            Float32List.fromList([for (final v in f) (v as num).toDouble()]),
        ],
        fps: fps,
        lutDir: c['lut_dir'] as String,
      );
      final what = '${c['name']} $fps';
      final sendcmd = c['sendcmd'] as String?;
      if (sendcmd == null) {
        expect(result.luts, hasLength(1), reason: what);
        expect(result.vf, c['vf'], reason: what);
        expect(result.tables, isNull, reason: what);
        continue;
      }
      several++;
      // The same LUTs from the same frames as Python's sendcmd list
      // names; none of them is named in the filter.
      final lines = const LineSplitter().convert(sendcmd);
      expect(result.luts, hasLength(lines.length), reason: what);
      for (final (i, line) in lines.indexed) {
        final frame = result.luts[i].$1;
        expect(line, startsWith('${(frame / fps).toStringAsFixed(3)} '));
      }
      final step = sampleStep(fps);
      expect(result.vf, graph(c['lut_dir'] as String, step, '$fps'));
      // A table for every step up to the last LUT's: each LUT from the
      // step of its frame (the next one, for a frame between two) until
      // the next LUT's.
      final tables = result.tables!;
      final at = [
        0,
        for (final (frame, _) in result.luts.skip(1)) (frame / step).ceil(),
      ];
      // (the last twice: ffmpeg's `fps` gives the last picture no time).
      expect(tables, hasLength(at.last + 2), reason: what);
      expect(tables.last, result.luts.length - 1, reason: what);
      for (final (k, lut) in tables.take(at.last + 1).indexed) {
        expect(lut, at.lastIndexWhere((first) => first <= k), reason: what);
      }
    }
    expect(several, greaterThan(0));
    ({List<(int, Float32List)> luts, String vf, List<int>? tables}) plan(
      List<int> frames,
    ) => lut3dFilter(
      frameIndices: frames,
      filters: [
        for (var i = 0; i < frames.length; i++)
          Float32List.fromList(List.filled(11, 0.1 + 0.5 * i)),
      ],
      fps: 30,
      lutDir: '/w',
    );
    final three = plan([0, 60, 120]);
    expect(three.vf, graph('/w', 60, '30.0'));
    // The table the fade is mixed on has the LUT's own points, and a
    // LUT's bytes are its picture.
    expect(haldLevel * haldLevel, lutSize);
    expect(
      haldLevel * haldLevel * haldLevel * haldLevel * haldLevel * haldLevel,
      lutSize * lutSize * lutSize,
    );
    // A table a step: each LUT turns into the next over the two seconds
    // before that one's frame.
    expect(three.tables, [0, 1, 2, 2]);
    // A LUT kept for a long time stands at every step of its time, so it
    // turns into the next over the last step before it only.
    expect(plan([0, 300]).tables, [0, 0, 0, 0, 0, 1, 1]);
    // The last frame's LUT, nearer than a step: at the step after, which
    // the clip ends on its way to.
    expect(plan([0, 60, 75]).tables, [0, 1, 2, 2]);
    expect(plan([0, 1]).tables, [0, 1, 1]);
    // The first LUT is on from the start, whatever frame it was made from.
    expect(plan([30, 60]).tables, [0, 1, 1]);
    // Two LUTs that would stand at the same step: the later one does.
    expect(plan([0, 70, 80]).tables, [0, 0, 2, 2]);
    // The filter is as long for many LUTs as for two (Windows' limit on
    // a command's length).
    expect(
      plan([for (var i = 0; i < 500; i++) i * 60]).vf,
      hasLength(three.vf.length),
    );
    // A Windows folder: forward slashes, the drive's colon escaped.
    final windows = lut3dFilter(
      frameIndices: [0],
      filters: [Float32List(11)],
      fps: 30,
      lutDir: r'C:\Temp\uwmedia_lut_1',
      separator: r'\',
    );
    expect(
      windows.vf,
      r"lut3d=file='C\:/Temp/uwmedia_lut_1/lut_0000.cube':interp=trilinear",
    );
    expect(lutFileName(12), 'lut_0012.cube');
  });

  test('input and output arguments of the colour runs', () {
    final cases = jsonObjects(reference['color_args']);
    expect(cases.length, 112);
    var windowsCases = 0;
    for (final c in cases) {
      final got = c['what'] == 'input'
          ? colorInputArgs(
              debug: c['debug'] as bool,
              hwAccel: c['hw_accel'] as bool,
              sourceHwDecodable: c['hw_decodable'] as bool,
              os: osOf(c['os']),
            )
          : colorOutputArgs(
              output: '/out/a color.mp4',
              creationDate: taken,
              encoder: encoderOf(c),
              tenBit: c['ten_bit'] as bool,
              sourceBitrate: c['source_bitrate'] as int?,
              tzOffsetMins: c['tz'] as int?,
            );
      // Python has Windows decode by hardware (`-hwaccel auto`); here a
      // colour or overlay run on Windows never does (spec §10.99).
      final want = (c['args'] as List<dynamic>).cast<String>();
      final windowsHw =
          c['what'] == 'input' &&
          want.contains('-hwaccel') &&
          osOf(c['os']) == EngineOs.windows;
      if (windowsHw) {
        windowsCases++;
        expect(want.sublist(want.indexOf('-hwaccel')), ['-hwaccel', 'auto']);
      }
      expect(got, windowsHw ? withoutHwDecode(want) : want, reason: '$c');
    }
    expect(windowsCases, 4);
  });

  test('the overlay filter graph', () {
    for (final c in jsonObjects(reference['overlay_graphs'])) {
      final (graph, label) = overlayFilterComplex(c['color_vf'] as String?, [
        for (final p in (c['positions'] as List<dynamic>).cast<List<dynamic>>())
          (p[0] as int, p[1] as int),
      ], tenBit: c['ten_bit'] as bool);
      expect(graph, c['graph']);
      expect(label, c['label']);
    }
  });

  test('the whole colour and overlay commands', () {
    final cases = jsonObjects(reference['full_commands']);
    expect(cases.length, 24);
    var windowsHw = 0;
    for (final c in cases) {
      final method = c['method'] as String;
      final tenBit = isTenBit(c['pix_fmt'] as String);
      final filters = c['filters'] as int;
      final lut = lut3dFilter(
        frameIndices: [0, 50].sublist(0, filters),
        filters: [
          for (var i = 0; i < filters; i++)
            Float32List.fromList(List.filled(11, 0.1 + 0.5 * i)),
        ],
        fps: 25,
        lutDir: '/WORK',
      );
      final inputArgs = colorInputArgs(
        debug: false,
        hwAccel: c['hw_accel'] as bool,
        sourceHwDecodable: true,
        os: osOf(c['os']),
      );
      final outputArgs = colorOutputArgs(
        output: '/out/C0012_color.mp4',
        creationDate: taken,
        encoder: encoderOf(c),
        tenBit: tenBit,
        sourceBitrate: 45000000,
        tzOffsetMins: 480,
      );
      final args = method == 'process_video_lut'
          ? lutCommandArgs(
              input: '/media/C0012.MP4',
              vf: lut.vf,
              inputArgs: inputArgs,
              outputArgs: outputArgs,
            )
          : overlayCommandArgs(
              input: '/media/C0012.MP4',
              layers: const [],
              colorVf: method == 'process_video' ? lut.vf : null,
              tenBit: tenBit,
              inputArgs: inputArgs,
              outputArgs: outputArgs,
            );
      final ran = (c['ran'] as List<dynamic>).single as Map<String, dynamic>;
      // Python's command with its sendcmd filter (which never changes the
      // LUT, spec §10.56) replaced by the colour tables.
      const pythonVf =
          "sendcmd=f='/WORK/sendcmd.txt',"
          "lut3d=file='/WORK/lut_0000.cube':interp=trilinear";
      final want = [
        for (final arg in (ran['args'] as List<dynamic>).cast<String>())
          arg.replaceAll(pythonVf, lut.vf),
      ];
      if (filters == 2 && method != 'process_video_no_color') {
        expect(ran['args'].toString(), contains(pythonVf));
        expect(lut.vf, contains("'/WORK/$lutTablesFileName'"));
      }
      // Python's `-hwaccel auto` on Windows is not asked for here (spec
      // §10.99).
      final plain = osOf(c['os']) == EngineOs.windows
          ? withoutHwDecode(want)
          : null;
      if (plain != null) {
        windowsHw++;
        expect(want, containsAllInOrder(['-hwaccel', 'auto', '-i']));
      }
      expect(args, plain ?? want, reason: '$method ${c['os']} ${c['pix_fmt']}');
      expect(ran['range'], [
        method == 'process_video_lut' ? analysisProgressEnd : hudProgressEnd,
        100.0,
      ]);
    }
    expect(windowsHw, 12);
    // With layers: one concat input and one overlay each.
    final args = overlayCommandArgs(
      input: 'in.mp4',
      layers: const [('/w/hud0.ffconcat', 16, 603), ('/w/hud1.ffconcat', 0, 0)],
      colorVf: null,
      tenBit: true,
      inputArgs: const ['-y'],
      outputArgs: const ['out.mp4'],
    );
    expect(args, [
      '-y', '-i', 'in.mp4', //
      '-f', 'concat', '-safe', '0', '-i', '/w/hud0.ffconcat',
      '-f', 'concat', '-safe', '0', '-i', '/w/hud1.ffconcat',
      '-filter_complex',
      '[0:v]null[v0];[1:v]format=rgba[h1];'
          '[v0][h1]overlay=x=16:y=603:eof_action=repeat:format=yuv420p10[v1];'
          '[2:v]format=rgba[h2];'
          '[v1][h2]overlay=x=0:y=0:eof_action=repeat:format=yuv420p10[v2]',
      '-map', '[v2]', '-map', '0:a?', 'out.mp4',
    ]);
  });

  test('a comparison: the picture twice, merged by the mask, the line', () {
    // Spec §10.94: the mask and the line are read after the layers.
    final args = overlayCommandArgs(
      input: 'in.mp4',
      layers: const [('/w/hud0.ffconcat', 16, 603)],
      colorVf: compareLink(
        colorVf: "lut3d=file='/w/lut_0000.cube':interp=trilinear",
        maskInput: 2,
        lineInput: 3,
      ),
      tenBit: false,
      inputArgs: const ['-y'],
      outputArgs: const ['out.mp4'],
      before: 'crop=608:1080:656:0',
      pictures: const ['/w/compare_mask.png', '/w/compare_line.png'],
    );
    expect(args, [
      '-y', '-i', 'in.mp4', //
      '-f', 'concat', '-safe', '0', '-i', '/w/hud0.ffconcat',
      '-i', '/w/compare_mask.png', '-i', '/w/compare_line.png',
      '-filter_complex',
      '[0:v]crop=608:1080:656:0,split[cmo][cmc];'
          "[cmc]lut3d=file='/w/lut_0000.cube':interp=trilinear,"
          'format=gbrp[cmd];'
          '[cmo]format=gbrp[cme];[2:v]format=gbrp[cmm];'
          '[cme][cmd][cmm]maskedmerge[cmx];'
          '[3:v]format=rgba[cml];[cmx][cml]overlay=eof_action=repeat[v0];'
          '[1:v]format=rgba[h1];'
          '[v0][h1]overlay=x=16:y=603:eof_action=repeat[v1]',
      '-map', '[v1]', '-map', '0:a?', 'out.mp4',
    ]);
    // A 10-bit source is merged and blended in 10 bits.
    final deep = compareLink(
      colorVf: 'lut3d=x',
      maskInput: 1,
      lineInput: 2,
      tenBit: true,
    );
    expect(deep, contains('[cmc]lut3d=x,format=gbrp10le[cmd]'));
    expect(deep, contains('[1:v]format=gbrp10le[cmm]'));
    expect(deep, endsWith('overlay=eof_action=repeat:format=yuv420p10'));
  });

  test('the frame sink of a telemetry-only video', () {
    final cases = jsonObjects(reference['sinks']);
    expect(cases.length, 29);
    for (final c in cases) {
      final size = c['size'] as List<dynamic>? ?? [1920, 1080];
      final command = (c['command'] as List<dynamic>).cast<String>();
      expect(command.first, reference['ffmpeg']);
      expect(
        frameSinkArgs(
          format: c['format'] as String,
          width: size[0] as int,
          height: size[1] as int,
          fps: (c['fps'] as num? ?? 30.0).toDouble(),
          target: c['target'] as String? ?? '/out/dive overlay.mov',
          encoder: encoderOf(c),
          debug: c['debug'] as bool,
        ),
        command.sublist(1),
        reason: '$c',
      );
    }
    expect(
      () => frameSinkArgs(
        format: 'png',
        width: 1,
        height: 1,
        fps: 30,
        target: 'x',
        encoder: encoderSoftware,
      ),
      throwsArgumentError,
    );
    expect(frameFileName(1), 'frame_000001.png');
  });

  group('layers', () {
    test('the runs of frames of one dive sample', () {
      final dive = buildDummyDive();
      final cases = jsonObjects(reference['segments']);
      expect(cases.length, 6);
      for (final c in cases) {
        final segments = hudSegments(
          dive,
          pyFromIsoformatNaive(c['start'] as String)!,
          (c['fps'] as num).toDouble(),
          c['frames'] as int,
        );
        expect(
          [
            for (final (wp, first, count) in segments)
              [wp!.timeSinceStart, first, count],
          ],
          c['segments'],
          reason: '${c['start']} ${c['fps']}',
        );
      }
    });

    test('test_hud_segments_group_frames_showing_the_same_sample', () {
      final start = naive(2025, 1, 1, 10);
      final waypoints = [
        for (var s = 0; s < 50; s += 5)
          Waypoint(
            timestamp: start.add(Duration(seconds: s)),
            depth: 5 + s * 0.5,
            temp: 24.0,
            timeSinceStart: s,
          ),
      ];
      final dive = Dive(
        startTime: start,
        endTime: waypoints.last.timestamp,
        waypoints: waypoints,
      );
      // 12 s of video over samples every 5 s.
      const fps = 10.0;
      const total = 120;
      final segments = hudSegments(dive, start, fps, total);
      expect(segments.fold(0, (sum, s) => sum + s.$3), total);
      expect([for (final s in segments) s.$1!.timeSinceStart], [0, 5, 10]);
      for (final (wp, first, count) in segments) {
        for (final i in [first, first + count - 1]) {
          final at = start.add(Duration(microseconds: (i / fps * 1e6).round()));
          expect(identical(dive.getWaypointAt(at), wp), isTrue, reason: '$i');
        }
      }
    });

    test('frames away from the dive have no sample (spec §10.10)', () {
      final start = naive(2025, 1, 1, 10);
      final dive = Dive(
        startTime: start,
        endTime: start.add(const Duration(seconds: 10)),
        waypoints: [
          for (final s in [0, 10])
            Waypoint(
              timestamp: start.add(Duration(seconds: s)),
              depth: 5,
              timeSinceStart: s,
            ),
        ],
      );
      // A clip from 62 s before the dive: two seconds with no sample,
      // then the first one.
      final segments = hudSegments(
        dive,
        start.subtract(const Duration(seconds: 62)),
        1,
        5,
      );
      expect(
        [for (final (wp, first, count) in segments) (wp, first, count)],
        [(null, 0, 2), (dive.waypoints.first, 2, 3)],
      );
    });

    test('a flashing sample by the half seconds of the clip (spec §10 '
        'issue 9)', () {
      final calm = Waypoint(
        timestamp: naive(2025, 1, 1, 10),
        timeSinceStart: 0,
      );
      final alarm = Waypoint(
        timestamp: naive(2025, 1, 1, 10, 0, 1),
        timeSinceStart: 1,
      );
      final segments = <HudSegment>[(calm, 0, 20), (alarm, 20, 40)];
      // At 20 fps a half second is 10 frames, counted from the clip's
      // start: the alarm's run begins in the first half of a second.
      expect(flashSegments(segments, 20, (wp) => identical(wp, alarm)), [
        (calm, 0, 20, null),
        (alarm, 20, 10, flashOn),
        (alarm, 30, 10, flashOff),
        (alarm, 40, 10, flashOn),
        (alarm, 50, 10, flashOff),
      ]);
      // A run that starts in the middle of a half second.
      expect(flashSegments([(alarm, 5, 10)], 20, (_) => true), [
        (alarm, 5, 5, flashOn),
        (alarm, 10, 5, flashOff),
      ]);
      // Nothing flashes: the runs as they were.
      expect(flashSegments(segments, 20, (_) => false), [
        (calm, 0, 20, null),
        (alarm, 20, 40, null),
      ]);
      // 29.97 fps over 100 s: every frame in one piece or another, none
      // lost, a half second now and then a frame shorter.
      final odd = flashSegments([(alarm, 0, 3000)], 29.97, (_) => true);
      expect(odd.fold(0, (sum, s) => sum + s.$3), 3000);
      // (The last one ends with the clip.)
      expect(odd.take(odd.length - 1).map((s) => s.$3).toSet(), {15, 14});
      expect([for (final s in odd) s.$4].take(4), [
        flashOn,
        flashOff,
        flashOn,
        flashOff,
      ]);
    });

    test('alpha from a drawing on black and on white', () {
      for (final c in jsonObjects(reference['mattes'])) {
        expect(
          matte(
            base64.decode(c['black'] as String),
            base64.decode(c['white'] as String),
          ),
          base64.decode(c['bgra'] as String),
          reason: '${c['shape']}',
        );
      }
    });

    test('the canvas of a layer, and widening it', () {
      final canvas = reference['canvas'] as Map<String, dynamic>;
      expect(canvasPads, canvas['pads']);
      for (final c in jsonObjects(canvas['layers'])) {
        final skin = c['skin_size'] as List<dynamic>?;
        final frame = c['frame'] as List<dynamic>;
        final layer = HudLayerCanvas(
          jsonDecode(jsonEncode(c['layout'])) as Map<String, dynamic>,
          frameW: frame[0] as int,
          frameH: frame[1] as int,
          resolved: !(c['not_resolved'] as bool? ?? false),
          skinSize: skin == null ? null : (skin[0] as int, skin[1] as int),
        );
        for (final (i, step) in jsonObjects(c['steps']).indexed) {
          final reason = '${c['layout']} on $frame, step $i';
          final (x0, y0, x1, y1) = layer.region;
          expect([x0, y0, x1, y1], step['region'], reason: reason);
          final skinNow =
              layer.canvasLayout['hud_skin'] as Map<String, dynamic>? ??
              const {};
          expect(
            layer.canvasLayout['design_width'],
            step['design_width'],
            reason: reason,
          );
          expect(skinNow['ref_offset_x'], step['ref_offset_x'], reason: reason);
          expect(skinNow['ref_offset_y'], step['ref_offset_y'], reason: reason);
          expect(layer.padIndex, step['pad_index']);
          expect(
            layer.isFullFrame,
            (x0, y0, x1, y1) == (0, 0, frame[0], frame[1]),
          );
          layer.widen();
        }
      }
      for (final [_, canvasW as int, resScale as num, want]
          in (canvas['design_widths'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(canvasDesignWidth(canvasW, resScale.toDouble()), want);
      }
    });

    test('a drawing that reaches the edge of its canvas', () {
      final canvas = reference['canvas'] as Map<String, dynamic>;
      for (final [region as List<dynamic>, where as String, want]
          in (canvas['edges'] as List<dynamic>).cast<List<dynamic>>()) {
        final [x0 as int, y0 as int, x1 as int, y1 as int] = region;
        final w = x1 - x0;
        final h = y1 - y0;
        final bgra = Uint8List(w * h * 4);
        final at = switch (where) {
          'left' => (2, 0),
          'top' => (0, 3),
          'right' => (1, w - 1),
          'bottom' => (h - 1, 2),
          'middle' => (2, 2),
          _ => null,
        };
        if (at != null) {
          bgra[(at.$1 * w + at.$2) * 4 + 3] = 9;
        }
        final layer = HudLayerCanvas(
          {'hud_skin': <String, dynamic>{}},
          frameW: 8,
          frameH: 6,
          resolved: false,
        )..region = (x0, y0, x1, y1);
        expect(layer.reachesCanvasEdge(bgra), want, reason: '$region $where');
      }
    });

    test('the pictures of a layer and its concat list', () {
      final cases = jsonObjects(reference['concat']);
      expect(cases.length, 15);
      for (final c in cases) {
        final values = (c['values'] as List<dynamic>).cast<int>();
        final frames = (c['frames'] as List<dynamic>).cast<int>();
        final entries = layerEntries([
          for (final value in values)
            Uint8List(4 * 6 * 4)..setAll(
              (1 * 6 + 2) * 4,
              value == 0 ? [0, 0, 0, 0] : [value, value, value, 255],
            ),
        ], frames);
        final folder = c['folder'] as String;
        if (c['stream'] == null) {
          expect(entries, isEmpty, reason: '${c['name']}');
          continue;
        }
        expect(entries.length, (c['pngs'] as List<dynamic>).length);
        expect([
          for (var i = 0; i < entries.length; i++) layerPngName(3, i),
        ], c['pngs']);
        expect(
          ffconcatText([
            for (final (i, (_, shown)) in entries.indexed)
              ('$folder/${layerPngName(3, i)}', shown),
          ], (c['fps'] as num).toDouble()),
          c['concat'],
          reason: '${c['name']} ${c['fps']}',
        );
        expect(
          '$folder/${layerConcatName(3)}',
          (c['stream'] as List<dynamic>)[0],
        );
      }
    });
  });

  group('progress', () {
    final progress = reference['progress'] as Map<String, dynamic>;

    test('the constants', () {
      expect(analysisProgressEnd, progress['analysis_end']);
      expect(hudProgressEnd, progress['hud_end']);
      expect(sampleSeconds, progress['sample_seconds']);
    });

    test('lines out of a process\'s output', () {
      for (final run in jsonObjects(progress['buffers'])) {
        final buffer = LineBuffer();
        final chunks = (run['chunks'] as List<dynamic>).cast<String>();
        expect([
          for (final chunk in chunks) buffer.feed(base64.decode(chunk)),
        ], run['fed']);
        expect(buffer.flush(), run['flushed']);
        expect(buffer.flush(), run['flushed_again']);
      }
    });

    test('the status when a run has ended', () {
      for (final [code as int, crashed as bool, text]
          in (progress['finished'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(finishedText(code, crashed: crashed), text);
      }
    });

    test('ffmpeg\'s progress lines as percentages of the file\'s run', () {
      final cases = jsonObjects(reference['run_progress']);
      expect(cases.length, 25);
      for (final c in cases) {
        final range = (c['range'] as List<dynamic>).cast<num>();
        final label = c['label'] as String?;
        final encode = EncodeProgress(
          duration: (c['duration'] as num?)?.toDouble(),
          rangeStart: range[0].toDouble(),
          rangeEnd: range[1].toDouble(),
        );
        final printed = [
          for (final line in (c['lines'] as List<dynamic>).cast<String>())
            if (encode.onLine(line) case final double pct)
              progressLine(pct, label),
          if (encode.onDone() case final double pct) progressLine(pct, label),
        ];
        expect(
          printed,
          c['printed'],
          reason: '${c['name']} ${c['duration']} $label',
        );
      }
    });

    test('the phases before the encode report once a percent', () {
      final file = FileProgress('a.mp4');
      expect([0.0, 0.4, 1.0, 1.9, 2.0, 10.0].map(file.report).toList(), [
        0.0,
        null,
        1.0,
        null,
        2.0,
        10.0,
      ]);
      expect(FileProgress(null).report(50), isNull);
    });

    test('after a restart the lower percentages are reported', () {
      final file = FileProgress('a.mp4');
      expect([10.0, 47.0, 5.0].map(file.report).toList(), [10.0, 47.0, null]);
      file.restart();
      expect([3.0, 3.5, 20.0].map(file.report).toList(), [3.0, null, 20.0]);
    });
  });

  // ffprobe 9 lists a stream again for each stream group it is in (a DJI
  // camera's video): `v:0` answers twice (spec §10.53).
  test('a stream listed twice by ffprobe 9 gives its first answer', () {
    expect(parseDimensions('3840x2160\n\n3840x2160\n'), (3840, 2160));
    expect(bitrateNeedsFormat('89799441\n89799441\n'), isFalse);
    expect(parseBitrate('89799441\n89799441\n'), 89799441);
    expect(parseFrameCount('48333\n48333\n'), 48333);
    expect(firstProbeLine('yuv420p10le\nyuv420p10le\n'), 'yuv420p10le');
    expect(firstProbeLine('\n'), '');
    expect(firstProbeLine(null), '');
  });

  test('a long command reads its filters from files (spec §10.79)', () {
    expect(readsOptionFiles('ffmpeg version n8.1.2 Copyright (c)'), isTrue);
    expect(readsOptionFiles('ffmpeg version 9.0.2 Copyright (c)'), isTrue);
    expect(
      readsOptionFiles('ffmpeg version 7.1-full_build-www.gyan.dev'),
      isTrue,
    );
    expect(
      readsOptionFiles('ffmpeg version 6.1.1-3ubuntu5 Copyright'),
      isFalse,
    );
    expect(readsOptionFiles('ffmpeg version N-118000-g1234abcd'), isTrue);

    final written = <String>[];
    String write(String graph) {
      written.add(graph);
      return '/work/filter_${written.length - 1}.txt';
    }

    const short = ['-i', 'in.mp4', '-vf', 'scale=640:360', 'out.mp4'];
    expect(filtersFromFiles(short, write, optionFiles: true), short);
    expect(written, isEmpty);

    final graph = List.filled(2000, 'null').join(',');
    final long = [
      '-i', 'in.mp4', '-i', 'mark.png', //
      '-filter_complex', graph, '-map', '[v]',
      '-af', 'volume=1', 'out.mp4',
    ];
    expect(commandChars(long), greaterThan(maxCommandChars));
    expect(filtersFromFiles(long, write, optionFiles: true), [
      '-i', 'in.mp4', '-i', 'mark.png', //
      '-/filter_complex', '/work/filter_0.txt', '-map', '[v]',
      '-/af', '/work/filter_1.txt', 'out.mp4',
    ]);
    expect(written, [graph, 'volume=1']);
    // An ffmpeg before 7.0: the older options.
    expect(
      filtersFromFiles(['-vf', graph, 'out.mp4'], write, optionFiles: false),
      ['-filter_script:v', '/work/filter_2.txt', 'out.mp4'],
    );
  });
}
