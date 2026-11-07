/// Bank-statement CSV import + analysis (v0.7).
///
/// Indian banks export account statements as CSV with a few common
/// layouts (HDFC / ICICI / SBI styles). The parser here is layout-
/// tolerant: it scans the first ~25 lines for a header row, maps the
/// columns it recognises (date, narration, debit, credit, single
/// amount + Dr/Cr indicator, balance), and then reads the data rows.
/// PDF statements are NOT parsed — the UI explains that and asks for
/// the CSV export from the bank app instead.
library;

import 'package:kanakku_parser/categorize.dart';

class StatementRow {
  final DateTime date;
  final String description;
  final double amount; // always positive
  final bool isDebit;
  final double? balanceAfter;
  const StatementRow({
    required this.date,
    required this.description,
    required this.amount,
    required this.isDebit,
    this.balanceAfter,
  });

  @override
  String toString() =>
      'StatementRow($date ${isDebit ? 'Dr' : 'Cr'} ₹$amount "$description")';
}

class StatementParseResult {
  final List<StatementRow> rows;
  const StatementParseResult(this.rows);
  bool get isEmpty => rows.isEmpty;
}

/// Splits one CSV line into cells, honouring double-quoted fields
/// (which may contain commas and "" escapes).
List<String> csvCells(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buf.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  out.add(buf.toString());
  return out;
}

String _normHeader(String h) =>
    h.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');

bool _isDateCol(String h) =>
    h.contains('date'); // txn date / value date / transaction date
bool _isNarrationCol(String h) =>
    h.contains('narration') ||
    h.contains('description') ||
    h.contains('particular') ||
    h.contains('remark') ||
    h.contains('detail');
bool _isDebitCol(String h) =>
    h.contains('debit') ||
    h.contains('withdrawal') ||
    h == 'dr' ||
    h.endsWith('dramount');
bool _isCreditCol(String h) =>
    h.contains('credit') ||
    h.contains('deposit') ||
    h == 'cr' ||
    h.endsWith('cramount');
bool _isBalanceCol(String h) => h.contains('balance') || h == 'bal';
bool _isAmountCol(String h) => h.contains('amount') || h == 'amt';
bool _isIndicatorCol(String h) =>
    h == 'drcr' || h == 'type' || h == 'crdr' || h.contains('indicator');

/// Parses a money cell: strips ₹/Rs/commas/spaces, reads a trailing
/// Dr/Cr marker if present. Returns (amount, marker) with the amount
/// null when the cell is empty or not a number. Zero is returned as
/// 0.0 (caller decides it carries no transaction).
(double?, String?) _money(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return (null, null);
  String? marker;
  final m = RegExp(r'(dr|cr)\.?$', caseSensitive: false).firstMatch(s);
  if (m != null) {
    marker = m.group(1)!.toLowerCase();
    s = s.substring(0, m.start).trim();
  }
  s = s
      .replaceAll(RegExp(r'(₹|rs\.?|inr)', caseSensitive: false), '')
      .replaceAll(',', '')
      .trim();
  if (s.startsWith('(') && s.endsWith(')')) {
    s = s.substring(1, s.length - 1); // (1,000.00) accounting negative
  }
  if (s.isEmpty) return (null, marker);
  return (double.tryParse(s), marker);
}

const _monthNames = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Parses the date formats Indian bank CSVs use:
/// dd/mm/yyyy, dd-mm-yyyy, dd/mm/yy, yyyy-mm-dd, dd MMM yyyy,
/// dd-MMM-yy, dd MMM yy. Returns null when unparseable.
DateTime? parseStatementDate(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  // dd MMM yyyy / dd-MMM-yy / dd MMM yy
  var m = RegExp(r'^(\d{1,2})[\s\-/]([A-Za-z]{3,})[\s\-/](\d{2,4})$')
      .firstMatch(s);
  if (m != null) {
    final mon = _monthNames[m.group(2)!.toLowerCase().substring(0, 3)];
    if (mon == null) return null;
    var year = int.parse(m.group(3)!);
    if (year < 100) year += 2000;
    return DateTime(year, mon, int.parse(m.group(1)!));
  }
  // yyyy-mm-dd
  m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(s);
  if (m != null) {
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
  }
  // dd/mm/yyyy, dd-mm-yyyy, dd/mm/yy, dd-mm-yy (day first — Indian format)
  m = RegExp(r'^(\d{1,2})[/\-](\d{1,2})[/\-](\d{2,4})$').firstMatch(s);
  if (m != null) {
    var year = int.parse(m.group(3)!);
    if (year < 100) year += 2000;
    final day = int.parse(m.group(1)!);
    final mon = int.parse(m.group(2)!);
    if (mon < 1 || mon > 12 || day < 1 || day > 31) return null;
    return DateTime(year, mon, day);
  }
  return null;
}

/// Parses a whole statement CSV. Tolerant of the preamble lines many
/// banks put above the header (account number, name, period, …).
StatementParseResult parseStatementCsv(String text) {
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  // --- locate the header row --------------------------------------
  int? headerIdx;
  int? dateCol, narrCol, debitCol, creditCol, amountCol, indCol, balCol;
  for (var i = 0; i < lines.length && i < 25; i++) {
    if (lines[i].trim().isEmpty) continue;
    final cells = csvCells(lines[i]).map(_normHeader).toList();
    int? d, n, dr, cr, amt, ind, bal;
    for (var c = 0; c < cells.length; c++) {
      final h = cells[c];
      if (h.isEmpty) continue;
      if (d == null && _isDateCol(h)) d = c;
      if (n == null && _isNarrationCol(h)) n = c;
      if (dr == null && _isDebitCol(h)) dr = c;
      if (cr == null && _isCreditCol(h)) cr = c;
      if (bal == null && _isBalanceCol(h)) bal = c;
      if (ind == null && _isIndicatorCol(h)) ind = c;
      if (amt == null &&
          _isAmountCol(h) &&
          !_isDebitCol(h) &&
          !_isCreditCol(h)) {
        amt = c;
      }
    }
    final hasMoney = (dr != null || cr != null) || amt != null;
    if (d != null && hasMoney) {
      headerIdx = i;
      dateCol = d;
      narrCol = n;
      debitCol = dr;
      creditCol = cr;
      amountCol = amt;
      indCol = ind;
      balCol = bal;
      break;
    }
  }
  if (headerIdx == null) return const StatementParseResult([]);

  String cell(List<String> cells, int? idx) =>
      (idx == null || idx >= cells.length) ? '' : cells[idx].trim();

  // --- read the data rows -----------------------------------------
  final rows = <StatementRow>[];
  for (var i = headerIdx + 1; i < lines.length; i++) {
    if (lines[i].trim().isEmpty) continue;
    final cells = csvCells(lines[i]);
    final date = parseStatementDate(cell(cells, dateCol));
    if (date == null) continue; // footers / subtotal lines have no date
    final desc = cell(cells, narrCol);
    double? amount;
    bool? isDebit;
    if (debitCol != null || creditCol != null) {
      final (drAmt, _) = _money(cell(cells, debitCol));
      final (crAmt, _) = _money(cell(cells, creditCol));
      if (drAmt != null && drAmt > 0) {
        amount = drAmt;
        isDebit = true;
      } else if (crAmt != null && crAmt > 0) {
        amount = crAmt;
        isDebit = false;
      }
    }
    if (amount == null && amountCol != null) {
      final (amt, marker) = _money(cell(cells, amountCol));
      if (amt != null && amt > 0) {
        amount = amt;
        final ind = cell(cells, indCol).toLowerCase();
        isDebit = marker != null
            ? marker == 'dr'
            : !(ind.startsWith('cr') || ind.contains('credit'));
      }
    }
    if (amount == null || isDebit == null) continue;
    final (bal, _) = _money(cell(cells, balCol));
    rows.add(
      StatementRow(
        date: date,
        description: desc,
        amount: amount,
        isDebit: isDebit,
        balanceAfter: bal,
      ),
    );
  }
  return StatementParseResult(rows);
}

/// Dedupe key for statement imports: calendar day + amount +
/// direction + a slice of the normalised description. Two rows are
/// "the same transaction" when their keys agree AND one description
/// contains the other (SMS captures shorten merchant names, statement
/// narrations pad them with refs) — see [statementKeyMatches].
String statementDedupeKey(
  DateTime date,
  double amount,
  bool isDebit,
  String description,
) =>
    '${date.year}-${date.month}-${date.day}|'
    '${amount.toStringAsFixed(2)}|${isDebit ? 'D' : 'C'}|'
    '${normalizeDesc(description)}';

String normalizeDesc(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

bool statementKeyMatches(String a, String b) {
  final pa = a.split('|');
  final pb = b.split('|');
  if (pa.length != 4 || pb.length != 4) return a == b;
  if (pa[0] != pb[0] || pa[1] != pb[1] || pa[2] != pb[2]) return false;
  final da = pa[3], db = pb[3];
  if (da.isEmpty || db.isEmpty) return true;
  if (da.length < 4 || db.length < 4) return da == db;
  return da.contains(db) || db.contains(da);
}

/// One transaction in the shape the analysis needs.
class AnalysisTxn {
  final DateTime at;
  final String description;
  final double amount;
  final bool isDebit;
  final String category;
  const AnalysisTxn({
    required this.at,
    required this.description,
    required this.amount,
    required this.isDebit,
    required this.category,
  });
}

class NamedTotal {
  final String name;
  final double amount;
  final double share; // 0..1 of total out (for categories/merchants)
  const NamedTotal(this.name, this.amount, this.share);
}

class StatementAnalysis {
  final DateTime? from;
  final DateTime? to;
  final double totalIn;
  final double totalOut;
  final int count;
  final double avgDailySpend;
  final List<NamedTotal> topCategories; // debits, top 5
  final List<NamedTotal> topMerchants; // debits, top 5 by description
  final List<AnalysisTxn> largestExpenses; // top 3 debits
  const StatementAnalysis({
    required this.from,
    required this.to,
    required this.totalIn,
    required this.totalOut,
    required this.count,
    required this.avgDailySpend,
    required this.topCategories,
    required this.topMerchants,
    required this.largestExpenses,
  });
  double get net => totalIn - totalOut;
}

StatementAnalysis analyzeTransactions(List<AnalysisTxn> txns) {
  var totalIn = 0.0, totalOut = 0.0;
  DateTime? from, to;
  final byCat = <String, double>{};
  final byDesc = <String, double>{};
  final debits = <AnalysisTxn>[];
  for (final t in txns) {
    if (from == null || t.at.isBefore(from)) from = t.at;
    if (to == null || t.at.isAfter(to)) to = t.at;
    if (t.isDebit) {
      totalOut += t.amount;
      debits.add(t);
      final cat = displayCategoryName(t.category);
      byCat[cat] = (byCat[cat] ?? 0) + t.amount;
      final d = t.description.trim().isEmpty ? '—' : t.description.trim();
      byDesc[d] = (byDesc[d] ?? 0) + t.amount;
    } else {
      totalIn += t.amount;
    }
  }
  List<NamedTotal> top(Map<String, double> m) {
    final list = [
      for (final e in m.entries)
        NamedTotal(e.key, e.value, totalOut > 0 ? e.value / totalOut : 0),
    ]..sort((a, b) => b.amount.compareTo(a.amount));
    return list.take(5).toList();
  }

  final largest = [...debits]..sort((a, b) => b.amount.compareTo(a.amount));
  final days = (from != null && to != null)
      ? to.difference(from).inDays + 1
      : 0;
  return StatementAnalysis(
    from: from,
    to: to,
    totalIn: totalIn,
    totalOut: totalOut,
    count: txns.length,
    avgDailySpend: days > 0 ? totalOut / days : totalOut,
    topCategories: top(byCat),
    topMerchants: top(byDesc),
    largestExpenses: largest.take(3).toList(),
  );
}

/// Local copy of the display-grouping rule (kept in step with
/// insights_data.displayCategory) so statement.dart stays free of
/// UI-layer imports.
String displayCategoryName(String raw) => switch (raw) {
  'Utilities' || 'Recharge & Bills' => 'Bills & utilities',
  'Travel' || 'Fuel' => 'Transport',
  'Food Delivery' => 'Food & dining',
  'Uncategorized' => 'Other',
  _ => raw,
};

/// Category for a statement description, through the same merchant
/// rules the SMS path uses.
String categoryForDescription(String description) =>
    categorize(description)?.category ?? 'Uncategorized';
