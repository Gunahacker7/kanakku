/// Split bills (Walnut parity, v0.5). A split takes one expense
/// transaction (referenced by its stable entry id) and divides it
/// between named people typed by the user — no contacts permission.
/// The user is represented by the sentinel name [kYou].
library;

import 'dart:convert';

const kYou = 'You';

class SplitShare {
  final String name;
  final double amount; // rupees this person covers
  final bool settled;
  const SplitShare({
    required this.name,
    required this.amount,
    this.settled = false,
  });

  SplitShare copyWith({bool? settled}) =>
      SplitShare(name: name, amount: amount, settled: settled ?? this.settled);

  Map<String, dynamic> toJson() => {
    'name': name,
    'amount': amount,
    'settled': settled,
  };

  factory SplitShare.fromJson(Map<String, dynamic> j) => SplitShare(
    name: j['name']?.toString() ?? '',
    amount: (j['amount'] as num?)?.toDouble() ?? 0,
    settled: j['settled'] == true,
  );
}

class SplitRecord {
  final String id;
  final String entryId; // stable id of the source transaction
  final String label; // transaction label at split time
  final double total; // full transaction amount
  final String payer; // kYou or a participant's name
  final List<SplitShare> shares; // includes the payer's own share
  final int ts; // millis since epoch
  const SplitRecord({
    required this.id,
    required this.entryId,
    required this.label,
    required this.total,
    required this.payer,
    required this.shares,
    required this.ts,
  });

  bool get allSettled => shares.every((s) => s.settled);

  SplitRecord copyWith({List<SplitShare>? shares}) => SplitRecord(
    id: id,
    entryId: entryId,
    label: label,
    total: total,
    payer: payer,
    shares: shares ?? this.shares,
    ts: ts,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'entryId': entryId,
    'label': label,
    'total': total,
    'payer': payer,
    'shares': shares.map((s) => s.toJson()).toList(),
    'ts': ts,
  };

  factory SplitRecord.fromJson(Map<String, dynamic> j) => SplitRecord(
    id: j['id']?.toString() ?? '',
    entryId: j['entryId']?.toString() ?? '',
    label: j['label']?.toString() ?? '',
    total: (j['total'] as num?)?.toDouble() ?? 0,
    payer: j['payer']?.toString() ?? kYou,
    shares: [
      for (final s in (j['shares'] as List<dynamic>? ?? const []))
        SplitShare.fromJson(Map<String, dynamic>.from(s as Map)),
    ],
    ts: (j['ts'] as num?)?.toInt() ?? 0,
  );
}

/// Equal split that is exact to the paise: the total is converted to
/// paise, divided evenly, and the leftover paise go one each to the
/// first shares — so the shares always sum back to [total].
List<double> equalSplit(double total, int n) {
  if (n <= 0) return const [];
  final paise = (total * 100).round();
  final base = paise ~/ n;
  final rem = paise % n;
  return [for (var i = 0; i < n; i++) (base + (i < rem ? 1 : 0)) / 100];
}

/// Net balance per person across all UNSETTLED shares.
/// Positive = the person owes the user; negative = the user owes them.
/// Debts between two non-user participants are not the user's business
/// and are ignored.
Map<String, double> netBalances(List<SplitRecord> splits) {
  final out = <String, double>{};
  void add(String name, double v) {
    if (name == kYou || v == 0) return;
    out[name] = (out[name] ?? 0) + v;
  }

  for (final s in splits) {
    for (final share in s.shares) {
      if (share.settled) continue;
      if (share.name == s.payer) continue; // payer owes nobody for own share
      if (s.payer == kYou) {
        add(share.name, share.amount); // they owe the user
      } else if (share.name == kYou) {
        add(s.payer, -share.amount); // user owes the payer
      }
    }
  }
  return out;
}

String encodeSplits(List<SplitRecord> splits) =>
    jsonEncode(splits.map((s) => s.toJson()).toList());

List<SplitRecord> decodeSplits(String json) {
  try {
    final list = jsonDecode(json) as List<dynamic>;
    return [
      for (final s in list)
        SplitRecord.fromJson(Map<String, dynamic>.from(s as Map)),
    ];
  } catch (_) {
    return const [];
  }
}
