/// The Dive Profile Builder's dive as a Garmin Descent style FIT activity
/// (Python `parsers/fit_writer.py`), with the builder's mark and the plan
/// in it (`parsers/plan_embed.py`'s FIT form).
///
/// The message set and the fields follow real Mk3i exports closely enough
/// that the Garmin parser reads the file back: `file_id` and
/// `device_info` naming the computer, `dive_settings`, one `dive_gas` per
/// gas, a `record` per sample, a `tank_update` per tank per sample (every
/// tank a tank pod, named by its tank reference in `device_info`'s
/// descriptor), then the summary, session and activity messages with the
/// start in both UTC and local time.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:uwmedia_app/core/plan/dive_computers.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';
import 'package:uwmedia_app/core/plan/fit_encoder.dart';
import 'package:uwmedia_app/core/plan/fit_profile_subset.dart';
import 'package:uwmedia_app/core/plan/log_writers.dart';
import 'package:uwmedia_app/core/plan/plan_embed.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// Tank pod serials the written file reports its tanks under, in the
/// order of `DiveProfilePlan.tankSpecs()`: FIT only knows a tank by its
/// transmitter's serial.
const int tankSensorBase = 100001;

/// `file_creator.software_version` of a FIT the builder wrote (the mark
/// proper is the developer data's application id, [fitApplicationId]).
const int planSoftwareVersion = 800;

/// The FIT `dive_alert` numbers of the rebreather switches.
const int alertSetpointAutoLow = 24;
const int alertSetpointAutoHigh = 25;
const int alertSwitchedToOpenCircuit = 29;
const int alertSwitchedToClosedCircuit = 30;

/// Zlib compression of bytes (`dart:io`'s `zlib.encode` in the app), which
/// the plan in a FIT file goes through.
typedef ZlibStep = List<int> Function(List<int> bytes);

final DateTime _fitEpoch = naive(1989, 12, 31);
final RegExp _digits = RegExp(r'^[0-9]+$');

/// The plan as the text chunks a FIT file carries it in: its JSON,
/// compressed by [deflate], base64-encoded and cut into pieces of
/// [fitChunkBytes] (a FIT field holds 255 bytes at most).
List<String> fitPlanChunks(DiveProfilePlan plan, ZlibStep deflate) {
  final packed = base64.encode(deflate(utf8.encode(planToJson(plan))));
  return [
    for (var i = 0; i < packed.length; i += fitChunkBytes)
      packed.substring(
        i,
        i + fitChunkBytes < packed.length ? i + fitChunkBytes : packed.length,
      ),
  ];
}

/// The dive as a FIT file. [samples] come from `simulate`. [now] is the
/// local time of writing and [utcOffsetMinutes] the machine's UTC offset
/// at the dive's start (the builder has no timezone of its own, so a log
/// is written as if dived where the machine is). [deflate] compresses the
/// embedded plan.
///
/// FIT is Garmin's own format, so the plan's computer must be a Garmin
/// model: throws an [ArgumentError] otherwise, and without samples.
Uint8List fitBytes(
  DiveProfilePlan plan,
  List<SimulatedSample> samples, {
  DateTime? startTime,
  required DateTime now,
  required int utcOffsetMinutes,
  required ZlibStep deflate,
}) {
  if (samples.isEmpty) {
    // Python: "… run utils.dive_plan_engine.simulate() first".
    throw ArgumentError('No samples to write - simulate the plan first');
  }
  final computer = diveComputer(plan.computer);
  if (!computer.isGarmin) {
    throw ArgumentError(
      'FIT files come from Garmin dive computers - ${computer.label} '
      "doesn't write them",
    );
  }
  final startLocal = logStartTime(plan, startTime: startTime, now: now);
  // FIT seconds: since its epoch, in UTC for a timestamp and in local time
  // for the activity's local_timestamp.
  final startFitLocal = startLocal.difference(_fitEpoch).inSeconds;
  final startUtc = startFitLocal - utcOffsetMinutes * 60;
  final serial = _digits.hasMatch(plan.computerSerial)
      ? BigInt.parse(plan.computerSerial).toUnsigned(32).toInt()
      : 0;
  final duration = samples.last.timeSec;
  final endUtc = startUtc + duration;
  final tanks = plan.tankSpecs();
  final sensorOf = {
    for (final (i, t) in tanks.indexed) t.ref: tankSensorBase + i,
  };
  // A sidemount pair is one gas in two tanks.
  final gases = plan.breathedGases();
  final gasIndex = {for (final (i, g) in gases.indexed) g.id: i};

  final encoder = FitEncoder();
  void write(String name, Map<String, Object?> fields) =>
      encoder.writeMesg(fitMesgNums[name]!, fields);

  write('file_id', {
    'type': 'activity',
    'manufacturer': 'garmin',
    'product': computer.fitProduct,
    'serial_number': serial,
    'time_created': startUtc,
  });
  // The builder's mark and the plan itself, as developer data on the
  // file_creator message, so that the builder can open this file again.
  // The developer_data_id and field_description messages have to come
  // before the message that carries the fields.
  write('developer_data_id', {
    'developer_data_index': fitDeveloperDataIndex,
    'application_id': fitApplicationId,
    'application_version': planFormatVersion,
  });
  final planFields = <String, Object?>{};
  for (final (i, chunk) in fitPlanChunks(plan, deflate).indexed) {
    final key = '$fitPlanFieldPrefix$i';
    encoder.addDeveloperField(
      key,
      developerDataIndex: fitDeveloperDataIndex,
      fieldDefinitionNumber: i,
      fitBaseTypeId: fitString,
    );
    write('field_description', {
      'developer_data_index': fitDeveloperDataIndex,
      'field_definition_number': i,
      'fit_base_type_id': fitString,
      'field_name': key,
    });
    planFields[key] = chunk;
  }
  encoder.writeMesg(fitMesgNums['file_creator']!, {
    'software_version': planSoftwareVersion,
  }, developerFields: planFields);
  write('device_info', {
    'timestamp': startUtc,
    'device_index': 'creator',
    'manufacturer': 'garmin',
    'product': computer.fitProduct,
    'serial_number': serial,
    'source_type': 'local',
  });
  for (final (i, tank) in tanks.indexed) {
    write('device_info', {
      'timestamp': startUtc,
      'device_index': i + 1,
      'manufacturer': 'garmin',
      'serial_number': sensorOf[tank.ref],
      'descriptor': tank.ref,
      'source_type': 'antplus',
    });
  }

  write('dive_settings', {
    'timestamp': startUtc,
    'message_index': 0,
    'model': 'zhl_16c',
    'gf_low': plan.gfLow.truncate(),
    'gf_high': plan.gfHigh.truncate(),
    'water_type': 'salt',
    'po2_warn': plan.maxPo2Bottom,
    'po2_critical': plan.maxPo2Deco,
    'po2_deco': plan.maxPo2Deco,
    'safety_stop_enabled': 1,
    'safety_stop_time': 180,
    'ccr_low_setpoint_switch_mode': 'automatic',
    'ccr_low_setpoint': plan.ccrLowSetpoint,
    'ccr_low_setpoint_depth': plan.ccrLowSetpointDepthM,
    'ccr_high_setpoint_switch_mode': 'automatic',
    'ccr_high_setpoint': plan.ccrHighSetpoint,
    'ccr_high_setpoint_depth': plan.ccrHighSetpointDepthM,
  });
  for (final gas in gases) {
    write('dive_gas', {
      'message_index': gasIndex[gas.id],
      'helium_content': pyRound(gas.hePercent),
      'oxygen_content': pyRound(gas.o2Percent),
      'status': 'enabled',
      'mode': plan.onLoop(gas) ? 'closed_circuit_diluent' : 'open_circuit',
    });
  }

  write('event', {
    'timestamp': startUtc,
    'event': 'timer',
    'event_type': 'start',
    'event_group': 0,
  });

  String? lastGas;
  double? lastSetpoint;
  String? lastMode;
  final waterTemp = pyRound(plan.waterTempC);
  for (final (i, s) in samples.indexed) {
    final ts = startUtc + s.timeSec;
    void alert(int data) => write('event', {
      'timestamp': ts,
      'event': 'dive_alert',
      'event_type': 'marker',
      'data': data,
    });
    if (plan.isCcr) {
      // A Descent logs its rebreather switches as dive alerts, as the two
      // real Descent rebreather logs have them.
      if (lastMode != null && s.divemode != lastMode) {
        alert(
          s.divemode == 'opencircuit'
              ? alertSwitchedToOpenCircuit
              : alertSwitchedToClosedCircuit,
        );
      }
      final setpoint = s.setpoint;
      if (setpoint != null &&
          lastSetpoint != null &&
          setpoint != lastSetpoint) {
        alert(
          setpoint > lastSetpoint
              ? alertSetpointAutoHigh
              : alertSetpointAutoLow,
        );
      }
      lastMode = s.divemode;
      lastSetpoint = setpoint ?? lastSetpoint;
    }
    if (s.gasId != lastGas) {
      if (lastGas != null) {
        final index = gasIndex[s.gasId];
        if (index == null) {
          throw ArgumentError.value(
            s.gasId,
            'samples',
            'not a gas of the plan',
          );
        }
        write('event', {
          'timestamp': ts,
          'event': 'dive_gas_switched',
          'event_type': 'marker',
          'data': index,
        });
      }
      lastGas = s.gasId;
    }
    final previous = i > 0 ? samples[i - 1] : s;
    final dt = s.timeSec - previous.timeSec;
    // FIT logs it in m/s, positive when getting shallower.
    final ascentRate = dt > 0 ? (previous.depthM - s.depthM) / dt : 0.0;
    write('record', {
      'timestamp': ts,
      'depth': pyRoundTo(s.depthM, 3),
      'temperature': waterTemp,
      'next_stop_depth': s.ceilingM > 0 ? pyRoundTo(s.stopDepthM, 1) : 0.0,
      'next_stop_time': s.ceilingM > 0 ? s.stopDurationSec : 0,
      'time_to_surface': s.ttsSec,
      'cns_load': s.cnsPct.truncate(),
      'ascent_rate': pyRoundTo(ascentRate, 3),
      // A Descent on a rebreather dive logs no po2 in the record (the
      // setpoint is in the alerts and in dive_settings).
      if (!plan.isCcr) 'po2': pyRoundTo(s.po2, 2),
      // An NDL without a limit is left out, as a Descent leaves it out
      // in the shallows.
      if (s.ndlSec != null) 'ndl_time': s.ndlSec,
    });
    for (final tank in tanks) {
      final pressure = s.tankPressures[tank.ref];
      if (pressure != null) {
        write('tank_update', {
          'timestamp': ts,
          'sensor': sensorOf[tank.ref],
          'pressure': pressure,
        });
      }
    }
  }

  write('event', {
    'timestamp': endUtc,
    'event': 'timer',
    'event_type': 'stop_all',
    'event_group': 0,
  });

  final endPressures = samples.last.tankPressures;
  for (final tank in tanks) {
    final end = endPressures[tank.ref] ?? tank.startPressureBar;
    final used = (tank.startPressureBar - end) * tank.sizeL;
    write('tank_summary', {
      'timestamp': endUtc,
      'sensor': sensorOf[tank.ref],
      'start_pressure': tank.startPressureBar,
      'end_pressure': end,
      'volume_used': used > 0.0 ? used : 0.0,
    });
  }

  final depths = [for (final s in samples) s.depthM];
  final subSport = plan.isCcr
      ? 'ccr_diving'
      : (gases.length > 1 ? 'multi_gas_diving' : 'single_gas_diving');
  final seconds = duration.toDouble();
  write('dive_summary', {
    'timestamp': endUtc,
    'reference_mesg': 'session',
    'reference_index': 0,
    'avg_depth': pyRoundTo(pySum(depths) / depths.length, 3),
    'max_depth': pyRoundTo(depths.reduce((a, b) => a > b ? a : b), 3),
    'start_cns': 0,
    'end_cns': samples.last.cnsPct.truncate(),
    'dive_number': 1,
    'bottom_time': seconds,
  });
  write('lap', {
    'message_index': 0,
    'timestamp': endUtc,
    'event': 'lap',
    'event_type': 'stop',
    'start_time': startUtc,
    'total_elapsed_time': seconds,
    'total_timer_time': seconds,
    'sport': 'diving',
    'sub_sport': subSport,
  });
  // Real Descent files stamp the session and the activity with the dive's
  // start, which is where the Garmin parser reads the start from.
  write('session', {
    'message_index': 0,
    'timestamp': startUtc,
    'event': 'session',
    'event_type': 'stop',
    'start_time': startUtc,
    'total_elapsed_time': seconds,
    'total_timer_time': seconds,
    'sport': 'diving',
    'sub_sport': subSport,
    'first_lap_index': 0,
    'num_laps': 1,
    'trigger': 'activity_end',
    'avg_temperature': waterTemp,
    'max_temperature': waterTemp,
  });
  write('activity', {
    'timestamp': startUtc,
    'total_timer_time': seconds,
    'num_sessions': 1,
    'type': 'manual',
    'event': 'activity',
    'event_type': 'stop',
    'local_timestamp': startFitLocal,
  });

  return encoder.close();
}
