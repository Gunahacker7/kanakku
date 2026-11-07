/// Merchant → category rules + Needs/Wants/Savings bucketing.
/// Rules are data, not code: the app can update this table remotely
/// and users' corrections add personal rules on top.
library kanakku_categorize;

enum Bucket { needs, wants, savings }

class CategoryHit {
  final String category;
  final Bucket bucket;
  const CategoryHit(this.category, this.bucket);
}

/// pattern (lowercase substring) → (category, bucket)
const Map<String, CategoryHit> merchantRules = {
  // Food & delivery — wants (eating out), groceries — needs
  'swiggy': CategoryHit('Food Delivery', Bucket.wants),
  'zomato': CategoryHit('Food Delivery', Bucket.wants),
  'dominos': CategoryHit('Food Delivery', Bucket.wants),
  'mcdonald': CategoryHit('Food Delivery', Bucket.wants),
  'kfc': CategoryHit('Food Delivery', Bucket.wants),
  'blinkit': CategoryHit('Groceries', Bucket.needs),
  'bigbasket': CategoryHit('Groceries', Bucket.needs),
  'zepto': CategoryHit('Groceries', Bucket.needs),
  'dunzo': CategoryHit('Groceries', Bucket.needs),
  'reliance fresh': CategoryHit('Groceries', Bucket.needs),
  'dmart': CategoryHit('Groceries', Bucket.needs),
  // Travel
  'uber': CategoryHit('Travel', Bucket.needs),
  'ola': CategoryHit('Travel', Bucket.needs),
  'rapido': CategoryHit('Travel', Bucket.needs),
  'irctc': CategoryHit('Travel', Bucket.needs),
  'redbus': CategoryHit('Travel', Bucket.needs),
  'indian oil': CategoryHit('Fuel', Bucket.needs),
  'bharat petroleum': CategoryHit('Fuel', Bucket.needs),
  'hp petrol': CategoryHit('Fuel', Bucket.needs),
  // Shopping
  'amazon': CategoryHit('Shopping', Bucket.wants),
  'flipkart': CategoryHit('Shopping', Bucket.wants),
  'myntra': CategoryHit('Shopping', Bucket.wants),
  'ajio': CategoryHit('Shopping', Bucket.wants),
  'meesho': CategoryHit('Shopping', Bucket.wants),
  'zudio': CategoryHit('Shopping', Bucket.wants),
  // Bills & utilities — needs
  'electricity': CategoryHit('Utilities', Bucket.needs),
  'tneb': CategoryHit('Utilities', Bucket.needs),
  'bescom': CategoryHit('Utilities', Bucket.needs),
  'airtel': CategoryHit('Recharge & Bills', Bucket.needs),
  'jio': CategoryHit('Recharge & Bills', Bucket.needs),
  'vodafone': CategoryHit('Recharge & Bills', Bucket.needs),
  'bsnl': CategoryHit('Recharge & Bills', Bucket.needs),
  'broadband': CategoryHit('Utilities', Bucket.needs),
  // Entertainment — wants
  'netflix': CategoryHit('Subscriptions', Bucket.wants),
  'spotify': CategoryHit('Subscriptions', Bucket.wants),
  'prime video': CategoryHit('Subscriptions', Bucket.wants),
  'hotstar': CategoryHit('Subscriptions', Bucket.wants),
  'bookmyshow': CategoryHit('Entertainment', Bucket.wants),
  // Health — needs
  'apollo': CategoryHit('Health', Bucket.needs),
  'pharmacy': CategoryHit('Health', Bucket.needs),
  'hospital': CategoryHit('Health', Bucket.needs),
  'netmeds': CategoryHit('Health', Bucket.needs),
  // Money in / savings
  'salary': CategoryHit('Salary', Bucket.savings),
  'mutual fund': CategoryHit('Investments', Bucket.savings),
  'zerodha': CategoryHit('Investments', Bucket.savings),
  'groww': CategoryHit('Investments', Bucket.savings),
  'sip': CategoryHit('Investments', Bucket.savings),
};

/// Returns the best hit for a counterparty string, or null (→ Uncategorized,
/// bucketed as Wants until the user teaches it once).
CategoryHit? categorize(String? counterparty) {
  if (counterparty == null) return null;
  final p = counterparty.toLowerCase();
  for (final e in merchantRules.entries) {
    if (p.contains(e.key)) return e.value;
  }
  return null;
}
