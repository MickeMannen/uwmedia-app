/// A CSV reader with the rules of Python's `csv` module in its default
/// ("excel") dialect, which the reference parsers read their files with.
library;

/// Python's `csv.field_size_limit()`.
const int pyCsvFieldLimit = 131072;

/// Python `csv.reader(text)`: the records of [text], each a list of fields.
///
/// A comma separates fields and a double quote at the start of a field
/// quotes it (a doubled quote inside is one quote, line breaks inside are
/// kept). A quote elsewhere is an ordinary character. An empty line is an
/// empty record. Lines end with `\n`, `\r\n` or `\r`.
///
/// Throws a [FormatException] for a field longer than [pyCsvFieldLimit], as
/// Python's reader does (a stray opening quote swallows the rest of a
/// file).
List<List<String>> pyCsvRows(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  // 0 start of record, 1 start of field, 2 in field, 3 in quoted field,
  // 4 after a quote inside a quoted field.
  var state = 0;

  void endField() {
    if (field.length > pyCsvFieldLimit) {
      throw const FormatException('CSV field larger than the field limit');
    }
    row.add(field.toString());
    field.clear();
  }

  void endRecord() {
    rows.add(row);
    row = <String>[];
    state = 0;
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    final newline = c == '\n' || c == '\r';
    if (newline && state != 3) {
      if (state != 0) {
        endField();
      }
      endRecord();
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
        i += 1;
      }
      continue;
    }
    switch (state) {
      case 0 || 1:
        if (c == '"') {
          state = 3;
        } else if (c == ',') {
          endField();
          state = 1;
        } else {
          field.write(c);
          state = 2;
        }
      case 2:
        if (c == ',') {
          endField();
          state = 1;
        } else {
          field.write(c);
        }
      case 3:
        if (c == '"') {
          state = 4;
        } else {
          field.write(c);
        }
      case 4:
        if (c == '"') {
          field.write(c);
          state = 3;
        } else if (c == ',') {
          endField();
          state = 1;
        } else {
          field.write(c);
          state = 2;
        }
    }
  }
  if (state != 0) {
    endField();
    rows.add(row);
  }
  return rows;
}

/// Python `csv.DictReader(text)`: the first record names the columns, an
/// empty record is skipped, and each other record maps column to value.
/// A column the record is too short for is `null`; of two columns with one
/// name the later value wins; values beyond the named columns are dropped
/// (Python keeps them under the key `None`, which no parser reads).
class PyDictReader {
  PyDictReader(String text) {
    final all = pyCsvRows(text);
    fieldnames = all.isEmpty ? const [] : all.first;
    rows = [
      for (final record in all.skip(1))
        if (record.isNotEmpty)
          {
            for (var i = 0; i < fieldnames.length; i++)
              fieldnames[i]: i < record.length ? record[i] : null,
          },
    ];
  }

  late final List<String> fieldnames;
  late final List<Map<String, String?>> rows;
}
