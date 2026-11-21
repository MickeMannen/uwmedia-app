/// Joining two Garmin FIT dive logs into one (Python
/// `parsers/fit_merge.py`; the Log Viewer's "Merge dives", for a dive the
/// computer split in two: a short surface stop ended the first log and
/// started a second one).
///
/// The merged file is the first log with the second one's samples added,
/// written at the record level like `fit_time.dart`: every message of the
/// first file is copied byte for byte (GPS, heart rate, Garmin's own
/// undocumented messages included), so the result stays as close to a
/// native Descent file as it can be, for Garmin Connect as much as for
/// this app.
///
/// Two ways to deal with the surface interval between the logs:
/// - keep the clock: the second dive's samples keep their real timestamps
///   and the gap is filled with copies of the first dive's last sample,
///   one per logging interval. Photos and videos from both dives still
///   line up with the log;
/// - close the gap: every timestamp of the second log moves back so that
///   its first sample follows the first dive's last one. The result is one
///   continuous dive; media from the second dive no longer matches it.
///
/// Either way the merged dive starts when the first did and ends when the
/// second did. What is taken from the second file: its records, tank
/// updates, events, GPS and the other messages logged between its first
/// and last sample; its gases (added to the first file's list when they
/// are new, with the gas-switch events pointing at the merged list); tank
/// pods and tank summaries for sensors the first file does not have. Its
/// file_id, settings and summary messages are dropped and the first file's
/// summaries are patched instead: session, lap and activity timer times,
/// dive_summary depths, bottom time and end tissue values, tank_summary
/// end pressures. The timer stop at the end of the first log and the
/// timer start of the second are dropped, so that the join does not read
/// as a pause.
///
/// Garmin Connect takes a file with the first dive's start and the
/// device's serial for that dive, so the two original activities have to
/// be deleted there before the merged one is uploaded.
library;

import 'dart:typed_data';

import 'package:uwmedia_app/core/parsers/fit_records.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// Dives further apart than this are two dives, not one that was split.
const int maxMergeGapSeconds = 2 * 3600;

// Message numbers of the FIT profile.
const int _fileId = 0;
const int _fileCreator = 49;
const int _activity = 34;
const int _session = 18;
const int _lap = 19;
const int _record = 20;
const int _event = 21;
const int _deviceInfo = 23;
const int _tankUpdate = 319;
const int _tankSummary = 323;
const int _diveGas = 259;
const int _diveSummary = 268;
const int _gpsMetadata = 160;
const int _developerDataId = 207;
const int _fieldDescription = 206;

/// Second-file messages that describe the file or the dive as a whole: the
/// first file's are kept instead (file_id, file_creator, activity,
/// session, lap, dive_summary, time_in_zone, timestamp_correlation,
/// device_settings, user_profile, sport, training_settings, zones_target,
/// dive_settings, dive_alarm).
const Set<int> fitMergeSkippedFromSecond = {
  _fileId, _fileCreator, _activity, _session, _lap, _diveSummary, //
  216, 162, 2, 3, 12, 13, 7, 258, 262,
};

/// Second-file messages that are samples, wherever they lie in the file
/// (record, event, tank_update, gps_metadata, hr, hrv). Anything else
/// unknown is kept only when logged between its first and last record, so
/// that Garmin's undocumented per-sample messages come along while its
/// settings-like ones stay behind.
const Set<int> fitMergeStreamFromSecond = {
  _record,
  _event,
  _tankUpdate,
  _gpsMetadata,
  132,
  78,
};

const int _messageIndex = 254;
// event
const int _fEvent = 0;
const int _fEventType = 1;
const int _fEventData = 3;
const int _eventTimer = 0;
const int _eventGasSwitched = 57;
const int _eventTypeStart = 0;
const int _eventTypeMarker = 3;
const Set<int> _eventTypeStops = {1, 4};
// dive_gas
const int _fGasHe = 0;
const int _fGasO2 = 1;
const int _fGasMode = 3;
// device_info
const int _fSerial = 3;
// tank_summary
const int _fSensor = 0;
const int _fEndPressure = 2;
const int _fVolumeUsed = 3;
// record
const int _fDepth = 92;
// session and lap
const int _fStartTime = 2;
const int _fElapsed = 7;
const int _fTimer = 8;
const int _fEndLat = 38;
const int _fEndLong = 39;
// activity
const int _fActivityTimer = 0;
// dive_summary
const int _fAvgDepth = 2;
const int _fMaxDepth = 3;
const int _fBottomTime = 11;
const int _fEndCns = 6;
const int _fEndN2 = 8;
const int _fO2Tox = 9;
// gps_metadata
const int _fGpsUtc = 6;

/// The numbers above by the names the Python module gives them, for the
/// parity test.
const Map<String, Object> fitMergeConstants = {
  'ACTIVITY': _activity,
  'DATE_TIME_FIELDS': [
    [_gpsMetadata, _fGpsUtc],
  ],
  'DEVELOPER_DATA_ID': _developerDataId,
  'DEVICE_INFO': _deviceInfo,
  'DIVE_GAS': _diveGas,
  'DIVE_SUMMARY': _diveSummary,
  'EVENT': _event,
  'EVENT_GAS_SWITCHED': _eventGasSwitched,
  'EVENT_TIMER': _eventTimer,
  'EVENT_TYPE_MARKER': _eventTypeMarker,
  'EVENT_TYPE_START': _eventTypeStart,
  'EVENT_TYPE_STOPS': [1, 4],
  'FIELD_DESCRIPTION': _fieldDescription,
  'FILE_CREATOR': _fileCreator,
  'FILE_ID': _fileId,
  'F_ACTIVITY_TIMER': _fActivityTimer,
  'F_AVG_DEPTH': _fAvgDepth,
  'F_BOTTOM_TIME': _fBottomTime,
  'F_DEPTH': _fDepth,
  'F_ELAPSED': _fElapsed,
  'F_END_CNS': _fEndCns,
  'F_END_LAT': _fEndLat,
  'F_END_LONG': _fEndLong,
  'F_END_N2': _fEndN2,
  'F_END_PRESSURE': _fEndPressure,
  'F_EVENT': _fEvent,
  'F_EVENT_DATA': _fEventData,
  'F_EVENT_TYPE': _fEventType,
  'F_GAS_HE': _fGasHe,
  'F_GAS_MODE': _fGasMode,
  'F_GAS_O2': _fGasO2,
  'F_GPS_UTC': _fGpsUtc,
  'F_MAX_DEPTH': _fMaxDepth,
  'F_O2_TOX': _fO2Tox,
  'F_SENSOR': _fSensor,
  'F_SERIAL': _fSerial,
  'F_START_TIME': _fStartTime,
  'F_TIMER': _fTimer,
  'F_VOLUME_USED': _fVolumeUsed,
  'GPS_METADATA': _gpsMetadata,
  'INVALID_UINT32': fitInvalidUint32,
  'LAP': _lap,
  'MAX_GAP_SECONDS': maxMergeGapSeconds,
  'MESSAGE_INDEX': _messageIndex,
  'MIN_DATE_TIME': fitMinDateTime,
  'RECORD': _record,
  'SESSION': _session,
  'TANK_SUMMARY': _tankSummary,
  'TANK_UPDATE': _tankUpdate,
  'TIMESTAMP_FIELD': fitTimestampField,
};

// FIT whole-number base types (low 5 bits): size in bytes, whether signed
// and the value that means "not set".
const Map<int, (int, bool, int)> _intTypes = {
  0: (1, false, 0xFF),
  1: (1, true, 0x7F),
  2: (1, false, 0xFF),
  3: (2, true, 0x7FFF),
  4: (2, false, 0xFFFF),
  5: (4, true, 0x7FFFFFFF),
  6: (4, false, 0xFFFFFFFF),
  10: (1, false, 0),
  11: (2, false, 0),
  12: (4, false, 0),
  14: (8, true, 0x7FFFFFFFFFFFFFFF),
  // An unsigned 64-bit number past the signed range reads as negative
  // here; "not set" (all bits) is -1.
  15: (8, false, -1),
  16: (8, false, 0),
};

/// What a merge did.
typedef FitMergeResult = ({
  /// Between the first dive's last sample and the second's first, as
  /// logged.
  int gapSeconds,

  /// Applied to the second log's timestamps (0 when the clock is kept).
  int shiftSeconds,

  /// Samples added to bridge the gap (0 when it was closed).
  int filledSamples,

  /// Gases the second log had that the first did not.
  int gasesAdded,
});

class _Msg {
  _Msg(
    this.definition,
    this.body,
    this.compressed,
    this.header,
    this.timestamp,
  );

  final FitDefinition definition;

  /// The fields, without the header byte.
  final Uint8List body;
  bool compressed;
  int header;

  /// FIT date_time (seconds since the FIT epoch); `null` when the message
  /// has none.
  int? timestamp;

  int get mesgNum => definition.mesgNum;

  (int, int, bool, int)? _locate(int num) {
    var offset = 0;
    for (final field in definition.fields) {
      if (field.num == num) {
        final type = _intTypes[field.base & 0x1F];
        return type == null || type.$1 != field.size
            ? null
            : (offset, type.$1, type.$2, type.$3);
      }
      offset += field.size;
    }
    return null;
  }

  /// A whole-number field's value; `null` when the message lacks it or it
  /// is not set.
  int? get(int num) {
    final found = _locate(num);
    if (found == null) {
      return null;
    }
    final (offset, size, signed, invalid) = found;
    final data = ByteData.sublistView(body);
    final endian = definition.endian;
    final value = switch ((size, signed)) {
      (1, true) => data.getInt8(offset),
      (1, false) => data.getUint8(offset),
      (2, true) => data.getInt16(offset, endian),
      (2, false) => data.getUint16(offset, endian),
      (4, true) => data.getInt32(offset, endian),
      (4, false) => data.getUint32(offset, endian),
      _ => data.getInt64(offset, endian),
    };
    return value == invalid ? null : value;
  }

  /// Sets a whole-number field, kept inside the type's range; false when
  /// the message lacks the field.
  bool set(int num, num? value) {
    final found = _locate(num);
    if (found == null) {
      return false;
    }
    if (value == null) {
      // Python fails here too (a gas of the first file without an index).
      throw const FormatException('The FIT file lists a gas without an index');
    }
    final (offset, size, signed, invalid) = found;
    final bits = 8 * size;
    // An unsigned 64-bit field is kept inside the signed range.
    final low = signed ? -(1 << (bits - 1)) : 0;
    final high = signed || size == 8 ? (1 << (bits - 1)) - 1 : (1 << bits) - 1;
    var whole = value is int ? value : pyRound(value.toDouble());
    whole = whole < low ? low : (whole > high ? high : whole);
    if (whole == invalid && invalid != 0) {
      whole -= 1; // the type's top value means "not set"
    }
    final data = ByteData.sublistView(body);
    final endian = definition.endian;
    switch (size) {
      case 1:
        data.setUint8(offset, whole & 0xFF);
      case 2:
        data.setUint16(offset, whole & 0xFFFF, endian);
      case 4:
        data.setUint32(offset, whole & 0xFFFFFFFF, endian);
      default:
        data.setInt64(offset, whole, endian);
    }
    return true;
  }

  _Msg copy() =>
      _Msg(definition, Uint8List.fromList(body), compressed, header, timestamp);
}

List<_Msg> _readMessages(Uint8List data) {
  final messages = <_Msg>[];
  int? last;
  walkFit(data, (definition, start, header, compressed) {
    final msg = _Msg(
      definition,
      Uint8List.fromList(
        Uint8List.sublistView(data, start, start + definition.size),
      ),
      compressed,
      data[header],
      null,
    );
    if (compressed) {
      final before = last;
      if (before != null) {
        final ts = (before & ~0x1F) | (data[header] & 0x1F);
        msg.timestamp = ts < before ? ts + 0x20 : ts;
      }
    } else {
      final ts = msg.get(fitTimestampField);
      if (ts != null && ts >= fitMinDateTime) {
        msg.timestamp = ts;
      }
    }
    last = msg.timestamp ?? last;
    messages.add(msg);
  });
  return messages;
}

/// Writes data messages, with a definition before each message whose
/// definition is not in one of the 16 local message slots (0-3 for
/// messages with a compressed timestamp, which can only name those).
class _Writer {
  final BytesBuilder out = BytesBuilder();
  final List<String?> _slots = List.filled(16, null);
  final List<int> _used = List.filled(16, 0);
  int _tick = 0;
  bool developerFields = false;

  int _slot(FitDefinition definition, bool compressed) {
    final content = Uint8List.sublistView(definition.raw, 1);
    final key = String.fromCharCodes(content);
    final limit = compressed ? 4 : 16;
    var slot = -1;
    for (var i = 0; i < limit; i++) {
      if (_slots[i] == key) {
        slot = i;
        break;
      }
    }
    if (slot < 0) {
      // The slot that was used longest ago.
      slot = 0;
      for (var i = 1; i < limit; i++) {
        if (_used[i] < _used[slot]) {
          slot = i;
        }
      }
      final devFlag = definition.raw[0] & 0x20;
      developerFields = developerFields || devFlag != 0;
      out
        ..addByte(0x40 | devFlag | slot)
        ..add(content);
      _slots[slot] = key;
    }
    _tick++;
    _used[slot] = _tick;
    return slot;
  }

  void write(_Msg msg) {
    final slot = _slot(msg.definition, msg.compressed);
    out
      ..addByte(
        msg.compressed ? 0x80 | (slot << 5) | (msg.header & 0x1F) : slot,
      )
      ..add(msg.body);
  }
}

List<_Msg> _records(Iterable<_Msg> messages) => [
  for (final m in messages)
    if (m.mesgNum == _record && m.timestamp != null) m,
];

/// The commonest step between two samples; of several, the one seen
/// first.
int _interval(List<_Msg> records) {
  final counts = <int, int>{};
  for (var i = 1; i < records.length; i++) {
    final step = records[i].timestamp! - records[i - 1].timestamp!;
    if (step > 0) {
      counts[step] = (counts[step] ?? 0) + 1;
    }
  }
  var best = 1;
  var bestCount = 0;
  counts.forEach((step, count) {
    if (count > bestCount) {
      best = step;
      bestCount = count;
    }
  });
  return best;
}

(int?, int?, int?) _gasKey(_Msg msg) =>
    (msg.get(_fGasO2), msg.get(_fGasHe), msg.get(_fGasMode));

/// Moves the message's timestamp fields by [delta] seconds, in place.
void _shift(_Msg msg, int delta) {
  if (delta == 0) {
    return;
  }
  final stamp = msg.timestamp;
  if (msg.compressed) {
    if (stamp != null) {
      msg.header = (msg.header & 0xE0) | ((stamp + delta) & 0x1F);
    }
  } else {
    final ts = msg.get(fitTimestampField);
    if (ts != null && ts >= fitMinDateTime) {
      msg.set(fitTimestampField, ts + delta);
    }
  }
  // The other date_time field of the second file that moves along.
  if (msg.mesgNum == _gpsMetadata) {
    final value = msg.get(_fGpsUtc);
    if (value != null && value >= fitMinDateTime) {
      msg.set(_fGpsUtc, value + delta);
    }
  }
  if (stamp != null) {
    msg.timestamp = stamp + delta;
  }
}

bool _isTimer(_Msg msg, Set<int> eventTypes) =>
    msg.mesgNum == _event &&
    msg.get(_fEvent) == _eventTimer &&
    eventTypes.contains(msg.get(_fEventType));

// An event message of the merge's own: timestamp, event, event_type, data.
final FitDefinition _eventDefinition = FitDefinition.of(_event, const [
  (num: fitTimestampField, size: 4, base: 0x86),
  (num: _fEvent, size: 1, base: 0x00),
  (num: _fEventType, size: 1, base: 0x00),
  (num: _fEventData, size: 4, base: 0x86),
]);

/// [first] and [second] (Garmin FIT dive logs, [second] logged after
/// [first], within [maxMergeGapSeconds]) as one dive: the merged file and
/// what was done. With [closeGap] the second dive moves back to follow the
/// first; without, the gap is filled and the clock kept. [firstName] names
/// the first file in a message. Throws a [FormatException] with the
/// reason when the files are not FIT dive logs or are not close enough.
({Uint8List bytes, FitMergeResult result}) mergeFitDives(
  Uint8List first,
  Uint8List second, {
  required bool closeGap,
  String firstName = 'The first file',
  String secondName = 'The second file',
}) {
  final msgs1 = _readMessages(first);
  final msgs2 = _readMessages(second);
  final records1 = _records(msgs1);
  final records2 = _records(msgs2);
  if (records1.isEmpty) {
    throw FormatException('$firstName has no samples');
  }
  if (records2.isEmpty) {
    throw FormatException('$secondName has no samples');
  }
  final last1 = records1.last.timestamp!;
  final first2 = records2.first.timestamp!;
  final gap = first2 - last1;
  if (gap <= 0) {
    throw const FormatException(
      'The second dive starts before the first one ends; merge them the '
      'other way round',
    );
  }
  if (gap > maxMergeGapSeconds) {
    throw FormatException(
      'The dives are ${pyFormatFixed(gap / 3600, 1)} hours apart; only '
      'dives within ${maxMergeGapSeconds ~/ 3600} hours of each other can '
      'be merged',
    );
  }

  final interval = _interval(records1);
  final delta = closeGap ? (last1 + interval) - first2 : 0;

  // Gases: the first file's list, plus the second's new ones.
  final gases1 = [
    for (final m in msgs1)
      if (m.mesgNum == _diveGas) m,
  ];
  final gasIndex = <(int?, int?, int?), int?>{
    for (final m in gases1.reversed) _gasKey(m): m.get(_messageIndex),
  };
  var nextIndex = -1;
  for (final m in gases1) {
    final index = m.get(_messageIndex) ?? 0;
    nextIndex = index > nextIndex ? index : nextIndex;
  }
  nextIndex++;
  final gasMap = <int, int?>{};
  final newGases = <_Msg>[];
  for (final gas in msgs2.where((m) => m.mesgNum == _diveGas)) {
    final old = gas.get(_messageIndex);
    if (old == null) {
      continue;
    }
    final key = _gasKey(gas);
    if (!gasIndex.containsKey(key)) {
      newGases.add(gas.copy()..set(_messageIndex, nextIndex));
      gasIndex[key] = nextIndex;
      nextIndex++;
    }
    gasMap[old] = gasIndex[key];
  }

  // Tank pods and tank summaries the first file does not have.
  final serials1 = {
    for (final m in msgs1)
      if (m.mesgNum == _deviceInfo) m.get(_fSerial),
  }..remove(null);
  final newPods = [
    for (final m in msgs2)
      if (m.mesgNum == _deviceInfo &&
          m.get(_fSerial) != null &&
          !serials1.contains(m.get(_fSerial)))
        m,
  ];
  final sensors1 = {
    for (final m in msgs1)
      if (m.mesgNum == _tankSummary) m.get(_fSensor),
  };
  final summaries2 = {
    for (final m in msgs2)
      if (m.mesgNum == _tankSummary) m.get(_fSensor): m,
  };

  // The second file's samples, in its order.
  final firstRecord2 = msgs2.indexWhere((m) => m.mesgNum == _record);
  final lastRecord2 = msgs2.lastIndexWhere((m) => m.mesgNum == _record);
  final stream2 = <_Msg>[];
  for (final (i, original) in msgs2.indexed) {
    final num = original.mesgNum;
    if (fitMergeSkippedFromSecond.contains(num) ||
        num == _diveGas ||
        num == _deviceInfo) {
      continue;
    }
    if (num == _tankSummary && sensors1.contains(original.get(_fSensor))) {
      continue;
    }
    if (!fitMergeStreamFromSecond.contains(num) &&
        num != _tankSummary &&
        num != _developerDataId &&
        num != _fieldDescription &&
        (i < firstRecord2 || i > lastRecord2)) {
      continue;
    }
    final stamp = original.timestamp;
    if (_isTimer(original, const {_eventTypeStart}) &&
        (stamp == null || stamp <= first2)) {
      // The second log's timer start: the merged dive's timer is already
      // running.
      continue;
    }
    final msg = original.copy();
    if (num == _event && msg.get(_fEvent) == _eventGasSwitched) {
      final data = msg.get(_fEventData);
      if (data != null && gasMap.containsKey(data)) {
        msg.set(_fEventData, gasMap[data]);
      }
    }
    _shift(msg, delta);
    stream2.add(msg);
  }
  // A dive that starts on another gas than the first one ended on, without
  // a switch event of its own to say so (Garmin logs one at the start of
  // every dive; other writers may not): the switch is recorded at the
  // join.
  final switches1 = [
    for (final m in msgs1)
      if (m.mesgNum == _event && m.get(_fEvent) == _eventGasSwitched)
        m.get(_fEventData),
  ];
  final gasBefore = switches1.isEmpty ? 0 : switches1.last;
  final switchedAtStart = msgs2.any(
    (m) =>
        m.mesgNum == _event &&
        m.get(_fEvent) == _eventGasSwitched &&
        m.timestamp != null &&
        m.timestamp! <= first2,
  );
  final gasAfter = gasMap.containsKey(0) ? gasMap[0] : gasBefore;
  if (!switchedAtStart && gasAfter != gasBefore) {
    final switchMsg =
        _Msg(
            _eventDefinition,
            Uint8List(_eventDefinition.size),
            false,
            0,
            first2 + delta,
          )
          ..set(fitTimestampField, first2 + delta)
          ..set(_fEvent, _eventGasSwitched)
          ..set(_fEventType, _eventTypeMarker)
          ..set(_fEventData, gasAfter);
    stream2.insert(0, switchMsg);
  }

  // The second file's new gases and tank pods, in the first file's
  // preamble.
  final additions = [
    ...newGases,
    for (final pod in newPods) pod.copy().._shiftBy(delta),
  ];

  // Bridge the gap with the first dive's last sample.
  final filler = <_Msg>[];
  if (!closeGap) {
    final template = records1.reversed.where((m) => !m.compressed).firstOrNull;
    if (template == null) {
      throw FormatException(
        '$firstName logs its samples without full timestamps; the gap '
        "can't be filled",
      );
    }
    for (var ts = last1 + interval; ts < first2; ts += interval) {
      filler.add(
        template.copy()
          ..set(fitTimestampField, ts)
          ..timestamp = ts,
      );
    }
  }

  // The first file's summaries now describe the merged dive.
  _Msg? firstOf(List<_Msg> messages, int mesgNum) =>
      messages.where((m) => m.mesgNum == mesgNum).firstOrNull;
  // Python's `a or b`: 0 counts as nothing.
  int orElse(int? value, int fallback) =>
      value == null || value == 0 ? fallback : value;
  final session1 = firstOf(msgs1, _session);
  final session2 = firstOf(msgs2, _session);
  final start1 = orElse(session1?.get(_fStartTime), records1.first.timestamp!);
  final start2 = orElse(session2?.get(_fStartTime), first2);
  final timer2 = session2?.get(_fTimer);
  final end2 =
      (start2 + delta) +
      (timer2 != null
          ? timer2 / 1000
          : (records2.last.timestamp! - start2).toDouble());
  final totalMs = pyRound((end2 - start1) * 1000);
  final depths = [
    for (final m in [...records1, ...filler, ...records2]) m.get(_fDepth),
  ].nonNulls.toList();
  final summary2 = firstOf(msgs2, _diveSummary);
  for (final msg in msgs1) {
    switch (msg.mesgNum) {
      case _session || _lap:
        msg
          ..set(_fElapsed, totalMs)
          ..set(_fTimer, totalMs);
        if (msg.mesgNum == _session && session2 != null) {
          for (final num in const [_fEndLat, _fEndLong]) {
            final value = session2.get(num);
            if (value != null) {
              msg.set(num, value);
            }
          }
        }
      case _activity:
        msg.set(_fActivityTimer, totalMs);
      case _diveSummary:
        if (depths.isNotEmpty) {
          msg
            ..set(_fAvgDepth, depths.reduce((a, b) => a + b) / depths.length)
            ..set(_fMaxDepth, depths.reduce((a, b) => a > b ? a : b));
        }
        if (summary2 != null) {
          for (final num in const [_fBottomTime, _fO2Tox]) {
            final a = msg.get(num);
            final b = summary2.get(num);
            if (a != null && b != null) {
              msg.set(num, a + b);
            }
          }
          for (final num in const [_fEndCns, _fEndN2]) {
            final value = summary2.get(num);
            if (value != null) {
              msg.set(num, value);
            }
          }
        }
      case _tankSummary:
        final other = summaries2[msg.get(_fSensor)];
        if (other != null) {
          final end = other.get(_fEndPressure);
          if (end != null) {
            msg.set(_fEndPressure, end);
          }
          final a = msg.get(_fVolumeUsed);
          final b = other.get(_fVolumeUsed);
          if (a != null && b != null) {
            msg.set(_fVolumeUsed, a + b);
          }
        }
    }
  }

  final writer = _Writer();
  // Where the second file's gases and pods go: after the first file's last
  // gas, or before its first sample when it lists none.
  final insertAfter = msgs1.lastIndexWhere((m) => m.mesgNum == _diveGas);
  final firstRecord = msgs1.indexWhere((m) => m.mesgNum == _record);
  for (final (i, msg) in msgs1.indexed) {
    if (insertAfter < 0 && i == firstRecord) {
      additions.forEach(writer.write);
    }
    final stamp = msg.timestamp;
    if (_isTimer(msg, _eventTypeStops) && (stamp == null || stamp >= last1)) {
      continue; // the first log's timer stop: the dive goes on
    }
    writer.write(msg);
    if (i == insertAfter) {
      additions.forEach(writer.write);
    }
  }
  filler.forEach(writer.write);
  stream2.forEach(writer.write);

  final records = writer.out.takeBytes();
  final header = Uint8List.fromList(Uint8List.sublistView(first, 0, first[0]));
  final headerView = ByteData.sublistView(header)
    ..setUint32(4, records.length, Endian.little);
  if (writer.developerFields && header[1] < 0x20) {
    header[1] = 0x20; // developer fields need protocol 2.0
  }
  if (header.length == 14) {
    headerView.setUint16(
      12,
      fitCrc(Uint8List.sublistView(header, 0, 12)),
      Endian.little,
    );
  }
  final data =
      (BytesBuilder()
            ..add(header)
            ..add(records))
          .takeBytes();
  final crc = fitCrc(data);
  return (
    bytes:
        (BytesBuilder()
              ..add(data)
              ..addByte(crc & 0xFF)
              ..addByte(crc >> 8))
            .takeBytes(),
    result: (
      gapSeconds: gap,
      shiftSeconds: delta,
      filledSamples: filler.length,
      gasesAdded: newGases.length,
    ),
  );
}

extension on _Msg {
  void _shiftBy(int delta) => _shift(this, delta);
}
