import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/item_progress.dart';
import 'data_service.dart';

/// How many never-studied items to introduce per day, on top of whatever
/// is genuinely due for review. Reviews are never capped -- only new-item
/// introduction is -- otherwise day one would dump all ~1,069 items into
/// a single overwhelming queue. 20/day is the same default Anki ships with.
const int kNewItemsPerDay = 20;

/// A stable identity for a vocab word or kanji, used as the progress-map
/// key. Vocab and kanji sometimes share characters (a kanji and a vocab
/// word can both be "食"), so both are prefixed to stay unambiguous.
String vocabItemId(String jp) => 'vocab:$jp';
String kanjiItemId(String kanji) => 'kanji:$kanji';

class ProgressService extends ChangeNotifier {
  static const _kProgressMap = 'srs_progress_v1';

  final Map<String, ItemProgress> _progress = {};
  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kProgressMap);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          _progress[entry.key] =
              ItemProgress.fromJson(entry.value as Map<String, dynamic>);
        }
      }
    } catch (e) {
      // A corrupted or unreadable prefs blob shouldn't take the app down --
      // worst case, progress resets, which is far better than a crash loop.
      debugPrint('ProgressService.load failed, starting fresh: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(
        _progress.map((key, value) => MapEntry(key, value.toJson())),
      );
      await prefs.setString(_kProgressMap, encoded);
    } catch (e) {
      debugPrint('ProgressService.save failed (progress kept in memory): $e');
    }
  }

  ItemProgress? progressFor(String itemId) => _progress[itemId];

  bool hasBeenStudied(String itemId) => _progress.containsKey(itemId);

  /// Records a rating for an item, creating its progress record on first
  /// review. Persists immediately -- review volume is human-paced (button
  /// taps), so there's no performance reason to batch writes, and immediate
  /// persistence is what makes "is progress saved reliably" actually true.
  Future<void> rate(String itemId, Rating rating) async {
    final item = _progress[itemId] ?? ItemProgress();
    item.apply(rating);
    _progress[itemId] = item;
    notifyListeners();
    await _save();
  }

  /// All vocab + kanji item IDs currently known to the app (used to find
  /// which ones are "new", i.e. absent from the progress map).
  List<String> _allItemIds() {
    final ds = DataService.instance;
    return [
      ...ds.vocab.map((v) => vocabItemId(v.jp)),
      ...ds.kanjiEntries.map((k) => kanjiItemId(k.kanji)),
    ];
  }

  int get dueCount {
    final now = DateTime.now();
    return _progress.values.where((p) => !p.dueDate.isAfter(now)).length;
  }

  int get newAvailableCount {
    final known = _progress.keys.toSet();
    return _allItemIds().where((id) => !known.contains(id)).length;
  }

  /// How many items today's queue will contain, without actually building
  /// (and shuffling) it -- cheap enough to call from the home screen badge.
  int get todayQueueSize {
    final due = dueCount;
    final newAvail = newAvailableCount;
    return due + (newAvail < kNewItemsPerDay ? newAvail : kNewItemsPerDay);
  }

  /// Today's review queue: every item genuinely due, plus up to
  /// [kNewItemsPerDay] never-studied items, shuffled together.
  List<String> buildDailyQueue({int newItemCap = kNewItemsPerDay}) {
    final now = DateTime.now();
    final due = <String>[];
    final fresh = <String>[];

    for (final id in _allItemIds()) {
      final p = _progress[id];
      if (p == null) {
        fresh.add(id);
      } else if (!p.dueDate.isAfter(now)) {
        due.add(id);
      }
    }

    fresh.shuffle();
    final newBatch = fresh.take(newItemCap).toList();
    final queue = [...due, ...newBatch];
    queue.shuffle();
    return queue;
  }

  /// Resolves an item ID back to its displayable vocab/kanji entry. Returns
  /// null if the ID doesn't match anything currently loaded (defensive --
  /// e.g. app data changed between sessions).
  dynamic resolveItem(String itemId) {
    final ds = DataService.instance;
    if (itemId.startsWith('vocab:')) {
      final jp = itemId.substring('vocab:'.length);
      for (final v in ds.vocab) {
        if (v.jp == jp) return v;
      }
    } else if (itemId.startsWith('kanji:')) {
      final k = itemId.substring('kanji:'.length);
      for (final entry in ds.kanjiEntries) {
        if (entry.kanji == k) return entry;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Dashboard/reporting helpers. All read-only and derived from the same
  // `_progress` map the SRS engine already maintains -- nothing new is
  // tracked here, so these are as accurate as the review history itself.
  // ---------------------------------------------------------------------

  /// How many items with the given id prefix ('vocab:' or 'kanji:') have
  /// ever been reviewed at least once -- i.e. "coverage" of that category,
  /// out of however many exist in total (caller supplies the denominator
  /// from DataService, since this service doesn't own the content lists).
  int countByPrefix(String prefix) =>
      _progress.keys.where((k) => k.startsWith(prefix)).length;

  /// How many items with the given id prefix are currently due, without
  /// pulling in "new" (never-studied) items the way [buildDailyQueue] does
  /// -- used for the due-count breakdown on the review summary screen.
  int dueCountByPrefix(String prefix) {
    final now = DateTime.now();
    return _progress.entries
        .where((e) => e.key.startsWith(prefix) && !e.value.dueDate.isAfter(now))
        .length;
  }

  /// Reviews completed *today*, read straight from each item's real
  /// [ItemProgress.lastReviewed] timestamp -- this was already being
  /// persisted for the SRS algorithm's own use, so it's exact and, unlike a
  /// freshly-added counter, correct even for review sessions that happened
  /// before this stat existed.
  int get reviewedTodayCount {
    final now = DateTime.now();
    return _progress.values.where((p) {
      final last = p.lastReviewed;
      return last != null &&
          last.year == now.year &&
          last.month == now.month &&
          last.day == now.day;
    }).length;
  }

  /// The [count] items with the most lapses (times rated "Again"), as
  /// `(itemId, lapses)` pairs, highest first. Only items with at least one
  /// lapse are included, so a clean history returns an empty list rather
  /// than padding with items that aren't actually weak.
  List<MapEntry<String, int>> weakestItemIds({int count = 5}) {
    final withLapses = _progress.entries
        .where((e) => e.value.lapses > 0)
        .map((e) => MapEntry(e.key, e.value.lapses))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return withLapses.take(count).toList();
  }

  /// The [count] most recently reviewed items, most recent first -- for a
  /// "recent activity" list. Items with no review yet (no `lastReviewed`)
  /// can't have one, so they're excluded rather than sorted arbitrarily.
  List<MapEntry<String, ItemProgress>> recentlyReviewed({int count = 5}) {
    final reviewed = _progress.entries
        .where((e) => e.value.lastReviewed != null)
        .toList()
      ..sort((a, b) => b.value.lastReviewed!.compareTo(a.value.lastReviewed!));
    return reviewed.take(count).toList();
  }
}
