/// PDF export (Walnut parity, v0.5) — a minimal, valid PDF 1.4 built
/// by hand: header, catalog, page tree, one content stream per page,
/// base-14 Helvetica (no embedded font, no libraries). Amounts use
/// "Rs." because the rupee sign is not in WinAnsi encoding.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'csv_export.dart';

const int _rowsPerPage = 44;
const double _pageW = 595, _pageH = 842; // A4 points
const double _margin = 40;

String _pdfMoney(double v) {
  final neg = v < 0;
  final s = v.abs().toStringAsFixed(2);
  final parts = s.split('.');
  var whole = parts[0];
  if (whole.length > 3) {
    final tail = whole.substring(whole.length - 3);
    var head = whole.substring(0, whole.length - 3);
    final buf = <String>[];
    while (head.length > 2) {
      buf.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) buf.insert(0, head);
    whole = '${buf.join(',')},$tail';
  }
  return '${neg ? '-' : ''}Rs.$whole.${parts[1]}';
}

/// Escape a string for a PDF literal: backslash-escape the structural
/// characters and octal-escape anything outside printable ASCII, so
/// arbitrary merchant names cannot corrupt the file.
String _escPdf(String v) {
  final b = StringBuffer();
  for (final c in v.codeUnits) {
    if (c == 0x5C) {
      b.write(r'\\');
    } else if (c == 0x28) {
      b.write(r'\(');
    } else if (c == 0x29) {
      b.write(r'\)');
    } else if (c >= 0x20 && c <= 0x7E) {
      b.writeCharCode(c);
    } else if (c <= 0xFF) {
      b.write('\\${c.toRadixString(8).padLeft(3, '0')}');
    } else {
      b.write('?');
    }
  }
  return b.toString();
}

String _clip(String v, int max) =>
    v.length <= max ? v : '${v.substring(0, max - 1)}…';

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// One text run: absolute-positioned, so columns never drift.
String _text(String t, double x, double y, {int size = 9, bool bold = false}) =>
    'BT /${bold ? 'F2' : 'F1'} $size Tf 1 0 0 1 '
    '${x.toStringAsFixed(1)} ${y.toStringAsFixed(1)} Tm (${_escPdf(t)}) Tj ET';

int pdfPageCount(int rowCount) =>
    rowCount <= 0 ? 1 : ((rowCount + _rowsPerPage - 1) ~/ _rowsPerPage);

Uint8List buildTransactionsPdf(
  List<CsvTxnRow> rows, {
  required DateTime generatedAt,
}) {
  var debit = 0.0, credit = 0.0;
  for (final r in rows) {
    if (r.direction == 'credit') {
      credit += r.amount;
    } else {
      debit += r.amount;
    }
  }
  final pages = pdfPageCount(rows.length);

  // ---- content streams, one per page --------------------------------
  final streams = <String>[];
  for (var p = 0; p < pages; p++) {
    final b = StringBuffer();
    var y = _pageH - 48;
    if (p == 0) {
      b.writeln(
        _text('Kanakku - Transactions', _margin, y, size: 16, bold: true),
      );
      y -= 18;
      b.writeln(
        _text(
          'Generated ${_dateStr(generatedAt)} · ${rows.length} transactions · '
          'Money out ${_pdfMoney(debit)} · Money in ${_pdfMoney(credit)}',
          _margin,
          y,
          size: 9,
        ),
      );
      y -= 12;
    } else {
      b.writeln(
        _text(
          'Kanakku - Transactions (page ${p + 1})',
          _margin,
          y,
          size: 11,
          bold: true,
        ),
      );
      y -= 8;
    }
    y -= 14;
    b.writeln(_text('Date', _margin, y, bold: true));
    b.writeln(_text('Description', 110, y, bold: true));
    b.writeln(_text('Category', 320, y, bold: true));
    b.writeln(_text('Amount', 480, y, bold: true));
    y -= 6;
    b.writeln(
      '0.85 g $_margin ${y.toStringAsFixed(1)} m '
      '${(_pageW - _margin).toStringAsFixed(1)} ${y.toStringAsFixed(1)} l S 1 g',
    );
    final start = p * _rowsPerPage;
    final end = (start + _rowsPerPage).clamp(0, rows.length);
    for (var i = start; i < end; i++) {
      final r = rows[i];
      y -= 15;
      final sign = r.direction == 'credit' ? '+' : '-';
      b.writeln(_text(_dateStr(r.date), _margin, y));
      b.writeln(_text(_clip(r.label, 34), 110, y));
      b.writeln(_text(_clip(r.category, 22), 320, y));
      b.writeln(_text('$sign${_pdfMoney(r.amount)}', 480, y));
    }
    y -= 20;
    b.writeln(_text('Page ${p + 1} of $pages', _margin, y, size: 8));
    streams.add(b.toString());
  }

  // ---- assemble objects with exact byte offsets ----------------------
  // Object ids: 1 catalog, 2 page tree, 3/4 fonts, then per page
  // (page object, content object) pairs.
  final objects = <int, String>{};
  final kids = [for (var p = 0; p < pages; p++) '${5 + p * 2} 0 R'];
  objects[1] = '<< /Type /Catalog /Pages 2 0 R >>';
  objects[2] = '<< /Type /Pages /Kids [${kids.join(' ')}] /Count $pages >>';
  objects[3] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>';
  objects[4] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>';
  for (var p = 0; p < pages; p++) {
    final pageId = 5 + p * 2, contentId = pageId + 1;
    objects[pageId] =
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $_pageW $_pageH] '
        '/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents $contentId 0 R >>';
    final stream = streams[p];
    objects[contentId] =
        '<< /Length ${latin1.encode(stream).length} >>\nstream\n$stream\nendstream';
  }

  final out = StringBuffer('%PDF-1.4\n');
  var bytes = latin1.encode(out.toString()).length;
  final offsets = <int, int>{};
  final ids = objects.keys.toList()..sort();
  for (final id in ids) {
    offsets[id] = bytes;
    final chunk = '$id 0 obj\n${objects[id]}\nendobj\n';
    out.write(chunk);
    bytes += latin1.encode(chunk).length;
  }
  final xrefPos = bytes;
  final maxId = ids.last;
  out.write('xref\n0 ${maxId + 1}\n');
  out.write('0000000000 65535 f \n');
  for (var i = 1; i <= maxId; i++) {
    out.write('${(offsets[i] ?? 0).toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${maxId + 1} /Root 1 0 R >>\nstartxref\n$xrefPos\n%%EOF\n',
  );
  return latin1.encode(out.toString());
}
