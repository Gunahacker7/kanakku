/// CSV export of the transaction list (Walnut parity, v0.4).
/// Pure string building — no file IO here; the native side writes the
/// file and opens the share sheet.
library;

class CsvTxnRow {
  final DateTime date;
  final String label;
  final String category;
  final String bucket;
  final String direction; // 'debit' | 'credit'
  final double amount;
  final String bank;
  final String accountLast4;
  final String source;

  const CsvTxnRow({
    required this.date,
    required this.label,
    required this.category,
    required this.bucket,
    required this.direction,
    required this.amount,
    required this.bank,
    required this.accountLast4,
    required this.source,
  });
}

String _esc(String v) {
  // CSV formula injection (v1.0.4, audit F9): a cell starting with
  // =, +, -, @, tab or CR is evaluated as a formula by Excel /
  // Sheets. Labels can come from imported statement narrations, so
  // neutralise the leading character with a single quote.
  var s = v;
  if (s.isNotEmpty && '=+-@\t\r'.contains(s[0])) {
    s = "'$s";
  }
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String transactionsCsv(List<CsvTxnRow> rows) {
  final b = StringBuffer()
    ..writeln(
      'Date,Label,Category,Bucket,Direction,Amount (INR),Bank,Account,Source',
    );
  for (final r in rows) {
    b.writeln(
      [
        _date(r.date),
        _esc(r.label),
        _esc(r.category),
        _esc(r.bucket),
        r.direction,
        r.amount.toStringAsFixed(2),
        _esc(r.bank),
        _esc(r.accountLast4),
        r.source,
      ].join(','),
    );
  }
  return b.toString();
}
