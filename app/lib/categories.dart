/// Categories & personal merchant rules (v1.0). The Categories page
/// lists every category with its Needs/Wants/Savings bucket: the
/// defaults come from the parser's merchant rules, and the user can
/// add their own categories plus keyword → category rules. Personal
/// rules are consulted BEFORE the built-in merchant table, so a
/// correction ("landlord" → Rent) always wins. Persisted natively
/// as one JSON document (categories_store).
library;

import 'dart:convert';

import 'package:kanakku_parser/categorize.dart';

class CategoryDef {
  final String name;
  final Bucket bucket;
  final bool custom; // user-added (deletable); defaults are not
  const CategoryDef({
    required this.name,
    required this.bucket,
    this.custom = false,
  });

  Map<String, dynamic> toJson() => {'name': name, 'bucket': bucket.name};

  factory CategoryDef.fromJson(Map<String, dynamic> j) => CategoryDef(
    name: j['name']?.toString() ?? '',
    bucket: Bucket.values.firstWhere(
      (b) => b.name == j['bucket']?.toString(),
      orElse: () => Bucket.wants,
    ),
    custom: true,
  );
}

/// Default category list: unique categories from the built-in
/// merchant rules (in rule order), plus the Add sheet's subcategory
/// names that no merchant rule produces (Rent, Emergency Fund).
List<CategoryDef> defaultCategoryDefs() {
  final seen = <String>{};
  final out = <CategoryDef>[];
  for (final hit in merchantRules.values) {
    if (seen.add(hit.category)) {
      out.add(CategoryDef(name: hit.category, bucket: hit.bucket));
    }
  }
  for (final extra in const [
    CategoryDef(name: 'Rent', bucket: Bucket.needs),
    CategoryDef(name: 'Emergency Fund', bucket: Bucket.savings),
    CategoryDef(name: 'Other', bucket: Bucket.wants),
  ]) {
    if (seen.add(extra.name)) out.add(extra);
  }
  return out;
}

class PersonalCategories {
  /// User-added categories (defaults are NOT stored, only customs).
  final List<CategoryDef> customDefs;

  /// keyword (lowercase) → category name.
  final Map<String, String> rules;
  const PersonalCategories({this.customDefs = const [], this.rules = const {}});

  bool get isEmpty => customDefs.isEmpty && rules.isEmpty;

  /// Every category the user can pick from: defaults + customs.
  List<CategoryDef> get allDefs {
    final out = defaultCategoryDefs();
    final names = out.map((d) => d.name).toSet();
    for (final d in customDefs) {
      if (names.add(d.name)) out.add(d);
    }
    return out;
  }

  CategoryDef? defFor(String category) {
    for (final d in allDefs) {
      if (d.name == category) return d;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'custom': customDefs.map((d) => d.toJson()).toList(),
    'rules': rules,
  };

  factory PersonalCategories.fromJson(Map<String, dynamic> j) {
    final defs = <CategoryDef>[];
    for (final raw in (j['custom'] as List<dynamic>? ?? const [])) {
      final d = CategoryDef.fromJson(Map<String, dynamic>.from(raw as Map));
      if (d.name.isNotEmpty) defs.add(d);
    }
    final rules = <String, String>{};
    final rawRules = j['rules'];
    if (rawRules is Map) {
      rawRules.forEach((k, v) {
        final key = k.toString().trim().toLowerCase();
        final val = v.toString();
        if (key.isNotEmpty && val.isNotEmpty) rules[key] = val;
      });
    }
    return PersonalCategories(customDefs: defs, rules: rules);
  }
}

String encodeCategories(PersonalCategories p) => jsonEncode(p.toJson());

PersonalCategories decodeCategories(String json) {
  try {
    final map = jsonDecode(json);
    if (map is Map) {
      return PersonalCategories.fromJson(Map<String, dynamic>.from(map));
    }
  } catch (_) {}
  return const PersonalCategories();
}

/// Categorisation with the user's personal rules applied first:
/// a keyword rule that matches the counterparty decides the
/// category (bucket from that category's def, falling back to the
/// built-in table), otherwise the built-in [categorize] runs.
CategoryHit? categorizePersonal(
  String? counterparty,
  PersonalCategories personal,
) {
  if (counterparty != null && personal.rules.isNotEmpty) {
    final p = counterparty.toLowerCase();
    for (final e in personal.rules.entries) {
      if (e.key.isNotEmpty && p.contains(e.key)) {
        final def = personal.defFor(e.value);
        if (def != null) return CategoryHit(def.name, def.bucket);
        final base = categorize(counterparty);
        return CategoryHit(e.value, base?.bucket ?? Bucket.wants);
      }
    }
  }
  return categorize(counterparty);
}
