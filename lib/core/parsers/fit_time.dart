/// Correcting the clock of a Garmin FIT dive log (Python
/// `parsers/fit_time.py`; the Log Viewer's "Adjust time", for a dive
/// computer whose clock was wrong before the dive): every timestamp in the
/// file moves by the same amount and the time zone is set, and every other
/// byte stays as it was.
///
/// The file is rewritten at the record level, not decoded and encoded
/// again, so fields, developer data and messages the SDK does not know
/// survive. Shifted: every message's timestamp (field 253) and the other
/// date_time fields Garmin dive files carry (`file_id.time_created`,
/// `session.start_time`, `lap.start_time`); `activity.local_timestamp` is
/// set to the new activity timestamp plus the new UTC offset, which is
/// where the Garmin parser reads the dive's time zone from. Records with a
/// compressed timestamp get their 5-bit offset shifted along. The file's
/// checksum is worked out again.
library;

import 'dart:typed_data';

import 'package:uwmedia_app/core/parsers/fit_records.dart';
import 'package:uwmedia_app/core/parsers/garmin.dart' show fitEpochS;
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// Global message number and field number of the other date_time fields:
/// `file_id.time_created`, `session.start_time`, `lap.start_time`.
const Set<(int, int)> fitDateTimeFields = {(0, 4), (18, 2), (19, 2)};
const int fitActivityMesg = 34;
const int fitActivityLocalTimestamp = 5;
const int _uint32 = 0x06;

/// The activity message's time in FIT seconds, and its local time when
/// the file has one.
({int utc, int? local}) _activitySeconds(Uint8List data) {
  final view = ByteData.sublistView(data);
  int? utc;
  int? local;
  walkFit(data, (definition, start, _, _) {
    if (definition.mesgNum != fitActivityMesg || utc != null) {
      return;
    }
    var offset = start;
    for (final field in definition.fields) {
      if (field.size == 4 && field.num == fitTimestampField) {
        utc = view.getUint32(offset, definition.endian);
      } else if (field.size == 4 && field.num == fitActivityLocalTimestamp) {
        local = view.getUint32(offset, definition.endian);
      }
      offset += field.size;
    }
  });
  final found = utc;
  if (found == null || found == fitInvalidUint32) {
    throw const FormatException('The FIT file has no activity time to adjust');
  }
  return (utc: found, local: local);
}

/// The activity message's timestamp of the FIT file in [data], as the UTC
/// instant it is, and its UTC offset in minutes (`null` when the file has
/// no local timestamp). Throws a [FormatException] for a file that is not
/// FIT or has no activity time.
({DateTime utc, int? utcOffsetMinutes}) fitActivityTime(Uint8List data) {
  final (:utc, :local) = _activitySeconds(data);
  return (
    utc: DateTime.fromMillisecondsSinceEpoch(
      (utc + fitEpochS) * 1000,
      isUtc: true,
    ),
    utcOffsetMinutes: local == null || local == fitInvalidUint32
        ? null
        : pyRound((local - utc) / 60),
  );
}

/// The FIT file in [source] with its activity starting at [localStart]
/// (naive: the dive site's local time) at [utcOffsetMinutes] from UTC, and
/// the shift applied to every timestamp, in seconds. [source] is not
/// changed. Throws a [FormatException] for a file that is not FIT, has no
/// activity time, or whose times would leave the range FIT can hold.
({Uint8List bytes, int shiftSeconds}) adjustFitTime(
  Uint8List source,
  DateTime localStart,
  int utcOffsetMinutes,
) {
  assert(localStart.isUtc, naiveTimeMessage);
  final oldUtc = _activitySeconds(source).utc;
  final newUtcMicros =
      localStart.microsecondsSinceEpoch -
      utcOffsetMinutes * Duration.microsecondsPerMinute;
  final oldUtcMicros = (oldUtc + fitEpochS) * Duration.microsecondsPerSecond;
  // Python's int(): towards zero.
  final delta = (newUtcMicros - oldUtcMicros) ~/ Duration.microsecondsPerSecond;
  final data = Uint8List.fromList(source);
  final view = ByteData.sublistView(data);

  int? shift(int offset, Endian endian) {
    var value = view.getUint32(offset, endian);
    if (value == fitInvalidUint32 || value < fitMinDateTime) {
      return null;
    }
    value += delta;
    if (value < fitMinDateTime || value >= fitInvalidUint32) {
      throw const FormatException(
        "The adjusted time is out of the FIT file's range",
      );
    }
    view.setUint32(offset, value, endian);
    return value;
  }

  walkFit(data, (definition, start, header, compressed) {
    if (compressed) {
      // The 5-bit time offset is relative to the last full timestamp,
      // which moves by the same amount.
      data[header] = (data[header] & 0xE0) | ((data[header] + delta) & 0x1F);
    }
    int? newTimestamp;
    int? localOffset;
    var offset = start;
    for (final field in definition.fields) {
      final at = offset;
      offset += field.size;
      if (field.size != 4 || field.base & 0x1F != _uint32) {
        continue;
      }
      if (field.num == fitTimestampField) {
        newTimestamp = shift(at, definition.endian);
      } else if (fitDateTimeFields.contains((definition.mesgNum, field.num))) {
        shift(at, definition.endian);
      } else if (definition.mesgNum == fitActivityMesg &&
          field.num == fitActivityLocalTimestamp) {
        localOffset = at;
      }
    }
    if (localOffset != null && newTimestamp != null) {
      view.setUint32(
        localOffset,
        (newTimestamp + utcOffsetMinutes * 60) & 0xFFFFFFFF,
        definition.endian,
      );
    }
  });

  // Each chained file's checksum, over its header and records.
  var pos = 0;
  while (pos < data.length) {
    final end = pos + data[pos] + view.getUint32(pos + 4, Endian.little);
    view.setUint16(
      end,
      fitCrc(Uint8List.sublistView(data, pos, end)),
      Endian.little,
    );
    pos = end + 2;
  }
  return (bytes: data, shiftSeconds: delta);
}
