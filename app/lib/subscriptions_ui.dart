/// Subscriptions screens (v1.2, REDESIGN-SPEC screen mapping 2/4):
/// list, add-grid, form and details in the reference design
/// language — white 24px cards on warm grey, deep-green accents,
/// tinted brand tiles, pill badges. All state changes flow through
/// the [SubscriptionsPage.onApply] callback: the page works on its
/// own copy of the document and hands the whole updated document
/// back, exactly like the Recurring page pattern in main.dart.
library;

import 'package:flutter/material.dart';

import 'money.dart';
import 'recurring.dart' show dateStr, parseDateStr;
import 'subscriptions.dart';
import 'theme.dart';

/// Tinted brand tile: a soft pastel square carrying the brand's
/// icon in its brand colour (drawn in code — no image assets).
class SubBrandTile extends StatelessWidget {
  final SubBrand brand;
  final double size;
  const SubBrandTile({super.key, required this.brand, this.size = 46});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: brand.tint,
      borderRadius: BorderRadius.circular(size * 0.32),
    ),
    child: Icon(brand.icon, color: brand.fg, size: size * 0.52),
  );
}

SubBrand _brandOf(Map<String, dynamic> sub) => brandFor(
  sub['brandKey']?.toString() ?? 'custom',
  fallbackName: sub['name']?.toString() ?? '',
);

/// One subscription list row (reference 02 bottom): tinted tile,
/// name + renewal sub-line, amount (green) + cycle on the right.
class SubscriptionRow extends StatelessWidget {
  final Map<String, dynamic> sub;
  final String today;
  final VoidCallback? onTap;
  const SubscriptionRow({
    super.key,
    required this.sub,
    required this.today,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cancelled = sub['status'] == 'cancelled';
    final brand = _brandOf(sub);
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SubBrandTile(brand: brand),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sub['name']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: cancelled ? KanakkuTheme.inkSoft : KanakkuTheme.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  renewsLabel(sub, today),
                  style: KanakkuTheme.secondary(size: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                KanakkuTheme.inr(
                  rupeesFromPaise((sub['amountPaise'] as num).toInt()),
                ),
                style: KanakkuTheme.amount(
                  size: 16,
                  color: cancelled
                      ? KanakkuTheme.inkSoft
                      : KanakkuTheme.primary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                cycleLabel(sub),
                style: KanakkuTheme.secondary(size: 12),
              ),
            ],
          ),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(onTap: onTap, child: content);
  }
}

// ---------------------------------------------------------------------
// Subscriptions list
// ---------------------------------------------------------------------

class SubscriptionsPage extends StatefulWidget {
  final Map<String, dynamic> doc;
  final List<SubPaymentView> payments;
  final Future<void> Function(Map<String, dynamic>) onApply;
  const SubscriptionsPage({
    super.key,
    required this.doc,
    required this.payments,
    required this.onApply,
  });
  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<SubscriptionsPage> {
  late final Map<String, dynamic> _doc = decodeSubscriptionsStore(
    encodeSubscriptionsStore(widget.doc),
  );

  String get _today => dateStr(DateTime.now());

  Future<void> _persist() async {
    await widget.onApply(_doc);
    if (mounted) setState(() {});
  }

  Future<void> _openAdd() async {
    final draft = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => const AddSubscriptionPage(),
      ),
    );
    if (draft == null || !mounted) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    draft['id'] = newSubscriptionId(_doc, nowMs);
    draft['createdAt'] = nowMs;
    draft['updatedAt'] = nowMs;
    subscriptionsOf(_doc).add(normalizeSubscription(draft));
    await _persist();
  }

  Future<void> _openDetails(Map<String, dynamic> sub) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SubscriptionDetailsPage(
          sub: Map<String, dynamic>.from(sub),
          payments: widget.payments,
          onUpdate: (updated) async {
            final subs = subscriptionsOf(_doc);
            final i = subs.indexWhere((s) => s['id'] == updated['id']);
            if (i >= 0) subs[i] = normalizeSubscription(updated);
            await _persist();
          },
          onDelete: (id) async {
            subscriptionsOf(_doc).removeWhere((s) => s['id'] == id);
            await _persist();
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final today = _today;
    final subs = subscriptionsOf(_doc);
    final active = subs.where((s) => s['status'] != 'cancelled').toList();
    final cancelled = subs.where((s) => s['status'] == 'cancelled').toList();
    final upcoming = upcomingRenewals(_doc, today);
    final byId = {for (final s in subs) s['id'] as String: s};
    final orderedActive = <Map<String, dynamic>>[
      for (final u in upcoming) byId[u.sub['id']]!,
      for (final s in active)
        if (!upcoming.any((u) => u.sub['id'] == s['id'])) s,
    ];
    final due = dueWithin(_doc, today, 30);
    return Scaffold(
      backgroundColor: KanakkuTheme.cream,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                ),
                Expanded(
                  child: Text(
                    'Subscriptions',
                    style: KanakkuTheme.sectionTitle(size: 22),
                  ),
                ),
                Material(
                  color: KanakkuTheme.primary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _openAdd,
                    child: const SizedBox(
                      width: 42,
                      height: 42,
                      child: Icon(Icons.add, color: Colors.white, size: 24),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            KCard(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Due in 30 days',
                          style: KanakkuTheme.secondary(size: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          KanakkuTheme.inr(rupeesFromPaise(due.totalPaise)),
                          style: KanakkuTheme.amount(size: 22),
                        ),
                        const SizedBox(height: 6),
                        PillBadge(
                          label:
                              '${due.count} Payment${due.count == 1 ? '' : 's'}',
                          background: KanakkuTheme.badgeAmberBg,
                          foreground: KanakkuTheme.badgeAmberFg,
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 64,
                    color: KanakkuTheme.dividerColor,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Active',
                          style: KanakkuTheme.secondary(size: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${active.length}',
                          style: KanakkuTheme.amount(size: 22),
                        ),
                        const SizedBox(height: 6),
                        PillBadge(
                          label: '${active.length} Active',
                          background: KanakkuTheme.badgeGreyBg,
                          foreground: KanakkuTheme.badgeGreyFg,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Upcoming',
                    style: KanakkuTheme.sectionTitle(size: 17),
                  ),
                ),
                Icon(
                  Icons.swap_vert,
                  size: 16,
                  color: KanakkuTheme.inkSoft,
                ),
                const SizedBox(width: 4),
                Text(
                  'Soonest first',
                  style: KanakkuTheme.secondary(size: 12.5),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (subs.isEmpty)
              KCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 28,
                ),
                child: Column(
                  children: [
                    SubBrandTile(
                      brand: brandFor('custom'),
                      size: 56,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'No subscriptions yet',
                      style: KanakkuTheme.sectionTitle(size: 16),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Track Spotify, rent, SIPs and every other '
                      'renewal in one place.',
                      textAlign: TextAlign.center,
                      style: KanakkuTheme.secondary(size: 13),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: KanakkuTheme.primary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 12,
                        ),
                      ),
                      onPressed: _openAdd,
                      child: const Text('Add subscription'),
                    ),
                  ],
                ),
              )
            else ...[
              if (orderedActive.isNotEmpty)
                KCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < orderedActive.length; i++) ...[
                        if (i > 0)
                          Divider(height: 1, color: KanakkuTheme.dividerColor),
                        SubscriptionRow(
                          sub: orderedActive[i],
                          today: today,
                          onTap: () => _openDetails(orderedActive[i]),
                        ),
                      ],
                    ],
                  ),
                ),
              if (cancelled.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Cancelled',
                  style: KanakkuTheme.sectionTitle(size: 17),
                ),
                const SizedBox(height: 10),
                KCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < cancelled.length; i++) ...[
                        if (i > 0)
                          Divider(height: 1, color: KanakkuTheme.dividerColor),
                        SubscriptionRow(
                          sub: cancelled[i],
                          today: today,
                          onTap: () => _openDetails(cancelled[i]),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Add grid (reference 03)
// ---------------------------------------------------------------------

class AddSubscriptionPage extends StatefulWidget {
  const AddSubscriptionPage({super.key});
  @override
  State<AddSubscriptionPage> createState() => _AddSubscriptionPageState();
}

class _AddSubscriptionPageState extends State<AddSubscriptionPage> {
  String _chip = 'All';

  Future<void> _pick(SubBrand brand) async {
    final draft = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => SubscriptionFormPage(
          title: 'Add Subscription',
          initial: {
            'name': brand.name,
            'brandKey': brand.key,
            'category': brand.category,
          },
        ),
      ),
    );
    if (draft != null && mounted) Navigator.pop(context, draft);
  }

  Future<void> _pickCustom() async {
    final draft = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => const SubscriptionFormPage(
          title: 'Add Subscription',
          initial: {'brandKey': 'custom'},
        ),
      ),
    );
    if (draft != null && mounted) Navigator.pop(context, draft);
  }

  Widget _grid(List<SubBrand> brands, {bool withCustom = false}) {
    final count = brands.length + (withCustom ? 1 : 0);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.94,
      ),
      itemBuilder: (context, i) {
        if (withCustom && i == count - 1) {
          return _GridTile(
            tile: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: KanakkuTheme.tealSoft,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(
                Icons.add,
                color: KanakkuTheme.primary,
                size: 24,
              ),
            ),
            label: 'Custom',
            onTap: _pickCustom,
          );
        }
        final b = brands[i];
        return _GridTile(
          tile: SubBrandTile(brand: b),
          label: b.name,
          onTap: () => _pick(b),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final popular = _chip == 'All'
        ? popularBrands
        : popularBrands.where((b) => b.category == _chip).toList();
    return Scaffold(
      backgroundColor: KanakkuTheme.cream,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                ),
                Expanded(
                  child: Text(
                    'Add New',
                    style: KanakkuTheme.sectionTitle(size: 22),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final c in ['All', ...subCategories]) ...[
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(c),
                        selected: _chip == c,
                        onSelected: (_) => setState(() => _chip = c),
                        selectedColor: KanakkuTheme.primary,
                        backgroundColor: KanakkuTheme.card,
                        labelStyle: TextStyle(
                          color: _chip == c
                              ? Colors.white
                              : KanakkuTheme.ink,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        side: BorderSide(color: KanakkuTheme.dividerColor),
                        showCheckmark: false,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text('Essentials', style: KanakkuTheme.sectionTitle(size: 17)),
            const SizedBox(height: 12),
            _grid(essentialBrands),
            const SizedBox(height: 20),
            Text('Popular', style: KanakkuTheme.sectionTitle(size: 17)),
            const SizedBox(height: 12),
            if (popular.isEmpty)
              Text(
                'No popular brands in this category yet — use Custom.',
                style: KanakkuTheme.secondary(size: 13),
              )
            else
              _grid(popular, withCustom: true),
          ],
        ),
      ),
    );
  }
}

class _GridTile extends StatelessWidget {
  final Widget tile;
  final String label;
  final VoidCallback onTap;
  const _GridTile({
    required this.tile,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: KanakkuTheme.card,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            tile,
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------
// Add / edit form
// ---------------------------------------------------------------------

class SubscriptionFormPage extends StatefulWidget {
  final String title;

  /// A full subscription (edit) or a partial draft with
  /// name/brandKey/category prefilled (add from the grid).
  final Map<String, dynamic>? initial;
  const SubscriptionFormPage({super.key, required this.title, this.initial});
  @override
  State<SubscriptionFormPage> createState() => _SubscriptionFormPageState();
}

class _SubscriptionFormPageState extends State<SubscriptionFormPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?['name']?.toString() ?? '',
  );
  late final TextEditingController _amount = TextEditingController(
    text: widget.initial?['amountPaise'] != null
        ? rupeesFromPaise(
            (widget.initial!['amountPaise'] as num).toInt(),
          ).toStringAsFixed(0)
        : '',
  );
  late final TextEditingController _customDays = TextEditingController(
    text: (widget.initial?['customDays'] ?? 30).toString(),
  );
  late final TextEditingController _website = TextEditingController(
    text: widget.initial?['website']?.toString() ?? '',
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.initial?['note']?.toString() ?? '',
  );
  late String _cycle = widget.initial?['cycle']?.toString() ?? 'monthly';
  late String _category = widget.initial?['category']?.toString() ?? 'Other';
  late DateTime _firstDate =
      parseDateStr(widget.initial?['firstBillingDate']?.toString() ?? '') ??
      DateTime.now();

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _customDays.dispose();
    _website.dispose();
    _note.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _firstDate,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );
    if (picked != null && mounted) setState(() => _firstDate = picked);
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('Enter a name');
      return;
    }
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', ''));
    if (amount == null || amount <= 0) {
      _toast('Enter a valid amount');
      return;
    }
    var customDays = int.tryParse(_customDays.text.trim()) ?? 30;
    if (customDays < 1) customDays = 1;
    final init = widget.initial ?? const <String, dynamic>{};
    final draft = normalizeSubscription({
      if (init['id'] != null) 'id': init['id'],
      'name': name,
      'brandKey': init['brandKey']?.toString() ?? 'custom',
      'amountPaise': paiseFromRupees(amount),
      'cycle': _cycle,
      'customDays': customDays,
      'firstBillingDate': dateStr(_firstDate),
      'category': _category,
      'status': init['status']?.toString() ?? 'active',
      if (init['cancelledDate'] != null)
        'cancelledDate': init['cancelledDate'],
      'website': _website.text.trim(),
      'note': _note.text.trim(),
      'createdAt': (init['createdAt'] as num?)?.toInt() ?? 0,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    Navigator.pop(context, draft);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KanakkuTheme.cream,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                ),
                Expanded(
                  child: Text(
                    widget.title,
                    style: KanakkuTheme.sectionTitle(size: 22),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            KCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Name'),
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Amount',
                      prefixText: '₹ ',
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Billing cycle',
                    style: KanakkuTheme.secondary(size: 13),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'monthly', label: Text('Monthly')),
                      ButtonSegment(value: 'yearly', label: Text('Yearly')),
                      ButtonSegment(value: 'customDays', label: Text('Custom')),
                    ],
                    selected: {_cycle},
                    onSelectionChanged: (s) =>
                        setState(() => _cycle = s.first),
                  ),
                  if (_cycle == 'customDays') ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _customDays,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Every how many days?',
                        suffixText: 'days',
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  InkWell(
                    onTap: _pickDate,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.calendar_month_outlined,
                            size: 20,
                            color: KanakkuTheme.inkSoft,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'First billing date',
                                  style: KanakkuTheme.secondary(size: 12),
                                ),
                                Text(
                                  fmtSubDate(dateStr(_firstDate)),
                                  style: const TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: KanakkuTheme.inkSoft,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: subCategories.contains(_category)
                        ? _category
                        : 'Other',
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: [
                      for (final c in subCategories)
                        DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged: (v) =>
                        setState(() => _category = v ?? 'Other'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _website,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Website (optional)',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _note,
                    decoration: const InputDecoration(
                      labelText: 'Note (optional)',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: KanakkuTheme.primary,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              onPressed: _save,
              child: const Text(
                'Save subscription',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Details (reference 05)
// ---------------------------------------------------------------------

class SubscriptionDetailsPage extends StatefulWidget {
  final Map<String, dynamic> sub;
  final List<SubPaymentView> payments;
  final Future<void> Function(Map<String, dynamic>) onUpdate;
  final Future<void> Function(String id) onDelete;
  const SubscriptionDetailsPage({
    super.key,
    required this.sub,
    required this.payments,
    required this.onUpdate,
    required this.onDelete,
  });
  @override
  State<SubscriptionDetailsPage> createState() =>
      _SubscriptionDetailsPageState();
}

class _SubscriptionDetailsPageState extends State<SubscriptionDetailsPage> {
  late Map<String, dynamic> _sub = Map<String, dynamic>.from(widget.sub);
  bool _historyOpen = true;

  String get _today => dateStr(DateTime.now());
  bool get _cancelled => _sub['status'] == 'cancelled';

  Future<void> _edit() async {
    final draft = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => SubscriptionFormPage(
          title: 'Edit Subscription',
          initial: _sub,
        ),
      ),
    );
    if (draft == null || !mounted) return;
    await widget.onUpdate(draft);
    if (mounted) setState(() => _sub = draft);
  }

  Future<void> _confirmDelete() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete subscription?'),
        content: Text(
          '"${_sub['name']}" will be removed. Past transactions are '
          'not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: KanakkuTheme.debit,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await widget.onDelete(_sub['id'] as String);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _toggleCancelled() async {
    final updated = Map<String, dynamic>.from(_sub);
    if (_cancelled) {
      updated['status'] = 'active';
      updated.remove('cancelledDate');
    } else {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Mark as cancelled?'),
          content: const Text(
            'Future renewals and reminders stop. You can reactivate '
            'it later.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not yet'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mark cancelled'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
      updated['status'] = 'cancelled';
      updated['cancelledDate'] = _today;
    }
    updated['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    final normalized = normalizeSubscription(updated);
    await widget.onUpdate(normalized);
    if (mounted) setState(() => _sub = normalized);
  }

  Widget _infoRow({
    required IconData icon,
    required String label,
    String? value,
    bool last = false,
  }) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: KanakkuTheme.surfaceAlt,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 18, color: KanakkuTheme.inkSoft),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 15)),
            ),
            if (value != null)
              Text(
                value,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
      if (!last) Divider(height: 1, color: KanakkuTheme.dividerColor),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final today = _today;
    final brand = _brandOf(_sub);
    final amount = KanakkuTheme.inr(
      rupeesFromPaise((_sub['amountPaise'] as num).toInt()),
    );
    final progress = cycleProgress(_sub, today);
    final next = nextRenewalDate(_sub, today);
    final elapsed = elapsedBillingDates(_sub, today);
    final spent = totalSpentPaise(_sub, today);
    final matched = matchedPayments(_sub, widget.payments);
    final firstDate = _sub['firstBillingDate']?.toString() ?? '';
    return Scaffold(
      backgroundColor: KanakkuTheme.cream,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                ),
                Expanded(
                  child: Text(
                    'Details',
                    style: KanakkuTheme.sectionTitle(size: 20),
                  ),
                ),
                TextButton(
                  onPressed: _edit,
                  style: TextButton.styleFrom(
                    backgroundColor: KanakkuTheme.surfaceAlt,
                    foregroundColor: KanakkuTheme.ink,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 9,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  child: const Text(
                    'Edit',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: KanakkuTheme.badgePinkBg,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _confirmDelete,
                    child: SizedBox(
                      width: 38,
                      height: 38,
                      child: Icon(
                        Icons.delete_outline,
                        color: KanakkuTheme.badgePinkFg,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Tinted header (reference 05).
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(KanakkuTheme.cardRadius),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [brand.tint, brand.tint.withValues(alpha: 0.15)],
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 18),
              child: Column(
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Icon(brand.icon, color: brand.fg, size: 40),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _sub['name']?.toString() ?? '',
                    textAlign: TextAlign.center,
                    style: KanakkuTheme.sectionTitle(size: 20),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(amount, style: KanakkuTheme.amount(size: 27)),
                      const SizedBox(width: 6),
                      Text(
                        cycleLabel(_sub),
                        style: KanakkuTheme.secondary(size: 14),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Renewal / status card.
            KCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _cancelled
                              ? 'Cancelled'
                              : next != null
                              ? 'Renews on ${fmtSubDate(next)}'
                              : 'No upcoming renewal',
                          style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (_cancelled)
                        PillBadge(
                          label: 'Cancelled',
                          background: KanakkuTheme.badgePinkBg,
                          foreground: KanakkuTheme.badgePinkFg,
                        )
                      else
                        PillBadge(
                          label: 'Active',
                          background: KanakkuTheme.badgeGreenBg,
                          foreground: KanakkuTheme.badgeGreenFg,
                          icon: Icons.autorenew,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  RoundedProgress(value: progress.fraction, height: 8),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _cancelled &&
                                  _sub['cancelledDate'] != null
                              ? 'Cancelled on ${fmtSubDate(_sub['cancelledDate'] as String)}'
                              : progress.lastBilled != null
                              ? 'Last Billed ${fmtSubDate(progress.lastBilled!)}'
                              : firstDate.isNotEmpty
                              ? 'First bill on ${fmtSubDate(firstDate)}'
                              : '',
                          style: KanakkuTheme.secondary(size: 12.5),
                        ),
                      ),
                      if (progress.dayY > 0)
                        Text(
                          'Day ${progress.dayX} of ${progress.dayY}',
                          style: KanakkuTheme.secondary(size: 12.5),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Total spent card.
            KCard(
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: KanakkuTheme.badgePinkBg,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.trending_up,
                      color: KanakkuTheme.badgePinkFg,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Total Spent',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          firstDate.isNotEmpty
                              ? 'Since ${fmtSubDate(firstDate)}'
                              : '',
                          style: KanakkuTheme.secondary(size: 12.5),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    KanakkuTheme.inr(rupeesFromPaise(spent)),
                    style: KanakkuTheme.amount(size: 19),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Info rows + billing history.
            KCard(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
              child: Column(
                children: [
                  InkWell(
                    onTap: () =>
                        setState(() => _historyOpen = !_historyOpen),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: KanakkuTheme.surfaceAlt,
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Icon(
                              Icons.receipt_long_outlined,
                              size: 18,
                              color: KanakkuTheme.inkSoft,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Billing History',
                              style: TextStyle(fontSize: 15),
                            ),
                          ),
                          Icon(
                            _historyOpen
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            color: KanakkuTheme.inkSoft,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_historyOpen) ...[
                    if (elapsed.isEmpty && matched.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          'No bills yet — the first one lands on '
                          '${firstDate.isNotEmpty ? fmtSubDate(firstDate) : '—'}.',
                          style: KanakkuTheme.secondary(size: 13),
                        ),
                      ),
                    for (final d in elapsed.reversed)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            const SizedBox(width: 48),
                            Expanded(
                              child: Text(
                                fmtSubDate(d),
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            Text(
                              amount,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (matched.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 2),
                        child: Row(
                          children: [
                            const SizedBox(width: 48),
                            Text(
                              'PAID VIA CAPTURES',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                                color: KanakkuTheme.inkSoft,
                              ),
                            ),
                          ],
                        ),
                      ),
                      for (final p in matched)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                            children: [
                              const SizedBox(width: 48),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                    Text(
                                      fmtSubDate(p.date),
                                      style: KanakkuTheme.secondary(
                                        size: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                KanakkuTheme.inr(
                                  rupeesFromPaise(p.amountPaise),
                                ),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                  Divider(height: 1, color: KanakkuTheme.dividerColor),
                  _infoRow(
                    icon: Icons.label_outline,
                    label: 'Category',
                    value: _sub['category']?.toString() ?? 'Other',
                  ),
                  _infoRow(
                    icon: Icons.north_east,
                    label: 'Website',
                    value: _sub['website']?.toString(),
                    last: _sub['note'] == null,
                  ),
                  if (_sub['note'] != null)
                    _infoRow(
                      icon: Icons.sticky_note_2_outlined,
                      label: _sub['note']?.toString() ?? '',
                      last: true,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            Center(
              child: OutlinedButton(
                onPressed: _toggleCancelled,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _cancelled
                      ? KanakkuTheme.primary
                      : KanakkuTheme.debit,
                  side: BorderSide(
                    color: _cancelled
                        ? KanakkuTheme.primary
                        : KanakkuTheme.debit,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 30,
                    vertical: 13,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: Text(
                  _cancelled ? 'Reactivate' : 'Mark as Cancelled',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
