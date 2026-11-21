/// A file's own times as the date logic takes them (plain `dart:io`, on
/// every platform).
library;

import 'dart:io';

import 'package:uwmedia_app/core/util/naive_time.dart';

/// The time the file at [path] was last changed, in local time as a naive
/// timestamp (the last fallback of a file's creation date); `null` when it
/// cannot be read.
DateTime? fileModified(String path) {
  try {
    final time = File(path).lastModifiedSync();
    return naive(
      time.year,
      time.month,
      time.day,
      time.hour,
      time.minute,
      time.second,
      time.millisecond,
      time.microsecond,
    );
  } on FileSystemException {
    return null;
  }
}
