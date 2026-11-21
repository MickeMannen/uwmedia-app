// The free space on a computer's disk (lib/engine/desktop/free_space.dart,
// spec §10.88): `df`'s output read, and the space of this machine's
// temporary folder.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/engine/desktop/free_space.dart';

void main() {
  test("df's available kilobytes, whatever the names around them", () {
    expect(
      dfAvailableBytes(
        'Filesystem     1024-blocks      Used Available Capacity Mounted on\n'
        '/dev/disk3s5    971350180 612345678 312345678      67% '
        '/System/Volumes/Data\n',
      ),
      312345678 * 1024,
    );
    // A name and a mount with spaces in them (macOS's automounter, an
    // external disk).
    expect(
      dfAvailableBytes(
        'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
        'map auto_home 0 0 0 100% /System/Volumes/Data/home\n',
      ),
      0,
    );
    expect(
      dfAvailableBytes(
        'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
        '/dev/disk5s1 1953513472 1000 1953512472 1% /Volumes/My Passport\n',
      ),
      1953512472 * 1024,
    );
    expect(dfAvailableBytes(''), isNull);
    expect(dfAvailableBytes('df: /nowhere: No such file or directory'), isNull);
  });

  test('the temporary folder has some room, told on this machine', () async {
    final free = await freeBytes(Directory.systemTemp.path);
    expect(free, isNotNull);
    expect(free, greaterThan(0));
  });

  test('sizes for a person', () {
    expect(gigabytesText(1400000000), '1.4 GB');
    expect(gigabytesText(0), '0.0 GB');
  });
}
