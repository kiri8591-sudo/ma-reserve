import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backup_io_stub.dart' if (dart.library.html) 'backup_io_web.dart' as backup_io;

// Version affichée dans l'interface et version applicative Flutter.
// Le champ JSON `version` reste dédié au format des données (schéma 4).
const String appVersionName = '2.1.0';
const String appVersionLabel = 'V2.1';
const int dataSchemaVersion = 4;

const Color ink = Color(0xFF26382D);
const Color muted = Color(0xFF718078);
const Color green = Color(0xFF496A52);
const Color greenDark = Color(0xFF365641);
const Color greenSoft = Color(0xFFE8F0E7);
const Color cream = Color(0xFFF5F6F0);
const Color amber = Color(0xFFB47A2D);
const Color amberSoft = Color(0xFFFFF2DD);
const Color red = Color(0xFFB44E45);
const Color redSoft = Color(0xFFFBEAE7);
const Color blue = Color(0xFF50758A);
const Color blueSoft = Color(0xFFEAF2F6);

// Anciens totaux globaux conservés lors de la mise à jour afin de ne perdre
// aucune quantité déjà saisie. Ils restent consultables mais ne doublonnent
// pas les nouveaux produits détaillés dans les calculs de progression.
const Set<String> legacySummaryIds = {
  'em-veg', 'em-fish', 'em-meat', 'em-fruit', 'em-biscuits', 'em-dried', 'em-starch', 'em-bars',
  'res-veg', 'res-protein', 'res-ready', 'res-starch', 'res-breakfast',
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = ReserveController();
  await controller.load();
  runApp(MaReserveApp(controller: controller));
}

class StockHistoryEntry {
  StockHistoryEntry({required this.at, required this.label, this.oldStock, this.newStock, this.oldZone, this.newZone});

  final DateTime at;
  final String label;
  final double? oldStock;
  final double? newStock;
  final String? oldZone;
  final String? newZone;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(), 'label': label, 'oldStock': oldStock,
        'newStock': newStock, 'oldZone': oldZone, 'newZone': newZone,
      };

  factory StockHistoryEntry.fromJson(Map<String, dynamic> json) => StockHistoryEntry(
        at: DateTime.tryParse((json['at'] ?? '').toString()) ?? DateTime.now(),
        label: (json['label'] ?? 'Modification').toString(),
        oldStock: ReserveItem._toDouble(json['oldStock']),
        newStock: ReserveItem._toDouble(json['newStock']),
        oldZone: json['oldZone']?.toString(),
        newZone: json['newZone']?.toString(),
      );
}

class StockLot {
  StockLot({
    required this.id,
    required this.quantity,
    this.batchDate,
    this.expiryDate,
    this.dateType = 'DDM',
    this.notes = '',
  });

  final String id;
  double? quantity;
  DateTime? batchDate;
  DateTime? expiryDate;
  String dateType;
  String notes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'quantity': quantity,
        'batchDate': batchDate?.toIso8601String(),
        'expiryDate': expiryDate?.toIso8601String(),
        'dateType': dateType,
        'notes': notes,
      };

  factory StockLot.fromJson(Map<String, dynamic> json) => StockLot(
        id: (json['id'] ?? 'lot-${DateTime.now().microsecondsSinceEpoch}').toString(),
        quantity: ReserveItem._toDouble(json['quantity'] ?? json['qty']),
        batchDate: ReserveItem._toDate(json['batchDate'] ?? json['purchaseDate']),
        expiryDate: ReserveItem._toDate(json['expiryDate'] ?? json['expiry']),
        dateType: (json['dateType'] ?? 'DDM').toString(),
        notes: (json['notes'] ?? '').toString(),
      );

  StockLot copy() => StockLot.fromJson(toJson());
}

class DatedLot {
  const DatedLot({required this.item, required this.lot});
  final ReserveItem item;
  final StockLot lot;
}

class ReserveItem {
  ReserveItem({
    required this.id,
    required this.name,
    required this.category,
    required this.zone,
    required this.target,
    required this.unit,
    this.stock,
    this.perPerson = true,
    this.purchaseDate,
    this.expiryDate,
    this.dateType = 'DDM',
    this.notes = '',
    this.isLegacySummary = false,
    this.emoji = '',
    List<StockHistoryEntry>? history,
    List<StockLot>? lots,
  })  : history = history ?? [],
        lots = lots ?? (stock != null
            ? [StockLot(
                id: 'lot-legacy-$id',
                quantity: stock,
                batchDate: purchaseDate,
                expiryDate: expiryDate,
                dateType: dateType,
                notes: 'Lot migré depuis la version précédente.',
              )]
            : ((expiryDate != null || purchaseDate != null)
                ? [StockLot(
                    id: 'lot-legacy-$id',
                    quantity: null,
                    batchDate: purchaseDate,
                    expiryDate: expiryDate,
                    dateType: dateType,
                    notes: 'Date migrée depuis la version précédente ; quantité à renseigner.',
                  )]
                : <StockLot>[])) {
    syncLotSummary();
  }

  final String id;
  String name;
  String category;
  String zone;
  double? stock;
  double target;
  String unit;
  bool perPerson;
  DateTime? purchaseDate;
  DateTime? expiryDate;
  String dateType;
  String notes;
  bool isLegacySummary;
  String emoji;
  List<StockHistoryEntry> history;
  List<StockLot> lots;

  String get displayEmoji => emoji.isNotEmpty ? emoji : foodEmoji(name, category);
  List<StockLot> get activeDatedLots => lots.where((lot) => lot.expiryDate != null && (lot.quantity == null || lot.quantity! > 0)).toList();

  /// Recalcule le stock agrégé et conserve la date du lot le plus proche
  /// pour compatibilité avec les anciennes versions de l'interface.
  void syncLotSummary() {
    if (lots.isEmpty) {
      stock = null;
      purchaseDate = null;
      expiryDate = null;
      dateType = 'DDM';
      return;
    }
    if (lots.any((lot) => lot.quantity == null)) {
      stock = null;
    } else {
      stock = lots.fold<double>(0, (total, lot) => total + (lot.quantity ?? 0));
    }
    final batchDates = lots.where((lot) => lot.batchDate != null).map((lot) => lot.batchDate!).toList()
      ..sort((a, b) => a.compareTo(b));
    purchaseDate = batchDates.isEmpty ? null : batchDates.first;
    final dated = lots.where((lot) => lot.expiryDate != null && (lot.quantity == null || lot.quantity! > 0)).toList()
      ..sort((a, b) => a.expiryDate!.compareTo(b.expiryDate!));
    if (dated.isNotEmpty) {
      expiryDate = dated.first.expiryDate;
      dateType = dated.first.dateType;
    } else {
      expiryDate = null;
      dateType = 'DDM';
    }
  }

  double targetFor(int people) => target * (perPerson ? people : 1);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'zone': zone,
        'stock': stock,
        'target': target,
        'unit': unit,
        'perPerson': perPerson,
        'purchaseDate': purchaseDate?.toIso8601String(),
        'expiryDate': expiryDate?.toIso8601String(),
        'dateType': dateType,
        'notes': notes,
        'isLegacySummary': isLegacySummary,
        'emoji': displayEmoji,
        'history': history.map((entry) => entry.toJson()).toList(),
        'lots': lots.map((lot) => lot.toJson()).toList(),
      };

  factory ReserveItem.fromJson(Map<String, dynamic> json) {
    return ReserveItem(
      id: (json['id'] ?? 'item-${DateTime.now().microsecondsSinceEpoch}').toString(),
      name: (json['name'] ?? 'Produit').toString(),
      category: (json['category'] ?? 'other').toString(),
      zone: (json['zone'] ?? 'reserve').toString(),
      stock: _toDouble(json['stock'] ?? json['qty']),
      target: _toDouble(json['target']) ?? _toDouble(json['min']) ?? 1,
      unit: (json['unit'] ?? 'unités').toString(),
      perPerson: json['perPerson'] != false,
      purchaseDate: _toDate(json['purchaseDate'] ?? json['bought']),
      expiryDate: _toDate(json['expiryDate'] ?? json['expiry']),
      dateType: (json['dateType'] ?? 'DDM').toString(),
      notes: (json['notes'] ?? '').toString(),
      isLegacySummary: json['isLegacySummary'] == true || legacySummaryIds.contains((json['id'] ?? '').toString()),
      emoji: (json['emoji'] ?? '').toString().isNotEmpty
          ? (json['emoji'] ?? '').toString()
          : foodEmoji((json['name'] ?? 'Produit').toString(), (json['category'] ?? 'other').toString()),
      history: json['history'] is List
          ? (json['history'] as List).whereType<Map>().map((entry) => StockHistoryEntry.fromJson(Map<String, dynamic>.from(entry))).toList()
          : <StockHistoryEntry>[],
      lots: json.containsKey('lots') && json['lots'] is List
          ? (json['lots'] as List).whereType<Map>().map((entry) => StockLot.fromJson(Map<String, dynamic>.from(entry))).toList()
          : null,
    );
  }

  static double? _toDouble(dynamic value) {
    if (value == null || value == '') return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().replaceAll(',', '.'));
  }

  static DateTime? _toDate(dynamic value) {
    if (value == null || value == '') return null;
    return DateTime.tryParse(value.toString());
  }
}

class BackupPreview {
  const BackupPreview({
    required this.productCount,
    required this.lotCount,
    required this.customProductCount,
    required this.people,
    required this.exportedAt,
    required this.sourceVersion,
  });

  final int productCount;
  final int lotCount;
  final int customProductCount;
  final int people;
  final String? exportedAt;
  final String? sourceVersion;
}

class ReserveController extends ChangeNotifier {
  static const String storageKey = 'ma_reserve_flutter_v1';
  static const String safetySnapshotKey = 'ma_reserve_flutter_v1_safety_snapshot';
  static const String recoverySnapshotKey = 'ma_reserve_flutter_v1_recovery_snapshot';
  SharedPreferences? _preferences;
  Future<void> _writeQueue = Future<void>.value();

  int people = 1;
  List<ReserveItem> items = [];
  Map<String, Map<String, bool>> checks = {};
  List<FoodTemplate> customCatalog = [];
  String? storageWarning;
  DateTime? lastSavedAt;

  Future<void> load() async {
    _preferences = await SharedPreferences.getInstance();
    final raw = _preferences!.getString(storageKey);
    if (raw == null || raw.isEmpty) {
      items = _seedItems();
      await _persist(notify: false);
      return;
    }
    try {
      final decoded = _decodeBackup(raw);
      _applyDecodedData(decoded);
      final savedAtText = decoded['savedAt']?.toString() ?? decoded['exportedAt']?.toString();
      lastSavedAt = DateTime.tryParse(savedAtText ?? '');
      // Add newly introduced default products without overwriting the user's inventory.
      for (final seed in _seedItems()) {
        final alreadyPresent = items.any((item) => item.id == seed.id ||
            (!item.isLegacySummary && item.zone == seed.zone && item.name.trim().toLowerCase() == seed.name.trim().toLowerCase()));
        if (!alreadyPresent) items.add(seed);
      }
    } catch (error) {
      // Ne jamais écraser silencieusement une sauvegarde locale illisible.
      // Une copie brute est conservée pour diagnostic/récupération manuelle.
      await _preferences!.setString(recoverySnapshotKey, raw);
      people = 1;
      items = _seedItems();
      customCatalog = [];
      checks = {};
      storageWarning = 'Les données locales sont illisibles. Une copie de secours a été conservée ; restaure une sauvegarde ou récupère le fichier de secours avant de continuer.';
    }
    await _persist(notify: false);
  }

  Map<String, dynamic> _decodeBackup(String source) {
    dynamic root;
    try {
      root = jsonDecode(source);
    } catch (_) {
      throw const FormatException('Le fichier ne contient pas un JSON valide.');
    }
    if (root is! Map) throw const FormatException('Le fichier ne contient pas une sauvegarde Ma Réserve.');
    final decoded = Map<String, dynamic>.from(root);
    final rawItems = decoded['items'];
    if (rawItems is! List) throw const FormatException('La liste des produits est absente.');
    final schema = (decoded['schemaVersion'] as num?)?.toInt() ?? (decoded['version'] as num?)?.toInt() ?? 1;
    if (schema > dataSchemaVersion) {
      throw FormatException('Cette sauvegarde utilise un format plus récent (schéma $schema). Mets Ma Réserve à jour avant de la restaurer.');
    }
    final ids = <String>{};
    for (final entry in rawItems) {
      if (entry is! Map) throw const FormatException('Un produit de la sauvegarde est illisible.');
      final item = Map<String, dynamic>.from(entry);
      final id = (item['id'] ?? '').toString().trim();
      final name = (item['name'] ?? '').toString().trim();
      if (id.isEmpty || name.isEmpty) throw const FormatException('Un produit n’a pas de nom ou d’identifiant.');
      if (!ids.add(id)) throw FormatException('Identifiant de produit en double : $id.');
      if (item['lots'] != null && item['lots'] is! List) throw FormatException('Les lots du produit « $name » sont illisibles.');
      if (item['history'] != null && item['history'] is! List) throw FormatException('L’historique du produit « $name » est illisible.');
    }
    if (decoded['customCatalog'] != null && decoded['customCatalog'] is! List) {
      throw const FormatException('Le catalogue personnel est illisible.');
    }
    if (decoded['checks'] != null && decoded['checks'] is! Map) {
      throw const FormatException('Les contrôles mensuels sont illisibles.');
    }
    return decoded;
  }

  void _applyDecodedData(Map<String, dynamic> decoded) {
    final rawCatalog = decoded['customCatalog'];
    var nextCatalog = rawCatalog is List
        ? rawCatalog.whereType<Map>().map((entry) => FoodTemplate.fromJson(Map<String, dynamic>.from(entry))).toList()
        : <FoodTemplate>[];
    final restoredVersion = (decoded['version'] as num?)?.toInt() ?? (decoded['schemaVersion'] as num?)?.toInt() ?? 1;
    if (restoredVersion < 3) {
      nextCatalog = nextCatalog.map((entry) => FoodTemplate(
        name: entry.name, category: entry.category, target: entry.target,
        unit: entry.unit, notes: entry.notes, emoji: foodEmoji(entry.name, entry.category),
      )).toList();
    }
    final rawItems = decoded['items'] as List;
    final nextItems = rawItems
        .whereType<Map>()
        .map((entry) => ReserveItem.fromJson(Map<String, dynamic>.from(entry)))
        .toList();
    for (final seed in _seedItems()) {
      final alreadyPresent = nextItems.any((item) => item.id == seed.id ||
          (!item.isLegacySummary && item.zone == seed.zone && item.name.trim().toLowerCase() == seed.name.trim().toLowerCase()));
      if (!alreadyPresent) nextItems.add(seed);
    }
    final savedPeople = (decoded['people'] as num?)?.toInt() ?? 1;
    final nextChecks = <String, Map<String, bool>>{};
    final rawChecks = decoded['checks'];
    if (rawChecks is Map) {
      for (final entry in rawChecks.entries) {
        if (entry.value is Map) {
          nextChecks[entry.key.toString()] = Map<String, bool>.from(
            (entry.value as Map).map((key, value) => MapEntry(key.toString(), value == true)),
          );
        }
      }
    }
    people = savedPeople.clamp(1, 20).toInt();
    items = nextItems;
    customCatalog = nextCatalog;
    checks = nextChecks;
  }

  BackupPreview previewBackup(String source) {
    final decoded = _decodeBackup(source);
    final rawItems = decoded['items'] as List;
    final products = rawItems.whereType<Map>().toList();
    var lots = 0;
    for (final entry in products) {
      final value = entry['lots'];
      if (value is List) lots += value.whereType<Map>().length;
    }
    final catalog = decoded['customCatalog'];
    return BackupPreview(
      productCount: products.length,
      lotCount: lots,
      customProductCount: catalog is List ? catalog.length : 0,
      people: ((decoded['people'] as num?)?.toInt() ?? 1).clamp(1, 20).toInt(),
      exportedAt: decoded['exportedAt']?.toString(),
      sourceVersion: decoded['appVersion']?.toString(),
    );
  }

  List<ReserveItem> _seedItems() => [
        // KIT D'URGENCE 72 H — aliments prêts à consommer sans cuisson.
        ReserveItem(id: 'em-water', name: 'Eau potable', category: 'water', zone: 'emergency', target: 6, unit: 'L', notes: 'Minimum 6 litres par personne pour 72 h.'),
        ReserveItem(id: 'em-veg-beans', name: 'Haricots verts en conserve', category: 'vegetables', zone: 'emergency', target: 1, unit: 'boîte', notes: 'À consommer froid si nécessaire.'),
        ReserveItem(id: 'em-veg-peas', name: 'Petits pois en conserve', category: 'vegetables', zone: 'emergency', target: 1, unit: 'boîte', notes: 'Prêts à consommer.'),
        ReserveItem(id: 'em-veg-corn', name: 'Maïs en conserve', category: 'vegetables', zone: 'emergency', target: 1, unit: 'boîte', notes: 'Prêt à consommer.'),
        ReserveItem(id: 'em-fish-tuna', name: 'Thon en conserve', category: 'fish', zone: 'emergency', target: 1, unit: 'boîte'),
        ReserveItem(id: 'em-fish-sardines', name: 'Sardines en conserve', category: 'fish', zone: 'emergency', target: 1, unit: 'boîte'),
        ReserveItem(id: 'em-fish-mackerel', name: 'Maquereaux en conserve', category: 'fish', zone: 'emergency', target: 1, unit: 'boîte'),
        ReserveItem(id: 'em-protein-chicken', name: 'Volaille en conserve', category: 'protein', zone: 'emergency', target: 1, unit: 'boîte', notes: 'Choisir une préparation consommable froide.'),
        ReserveItem(id: 'em-protein-pate', name: 'Pâté ou terrine en conserve', category: 'protein', zone: 'emergency', target: 1, unit: 'boîte'),
        ReserveItem(id: 'em-protein-meal', name: 'Plat cuisiné en conserve', category: 'protein', zone: 'emergency', target: 1, unit: 'boîte', notes: 'Vérifier qu’il peut être consommé froid.'),
        ReserveItem(id: 'em-fruit-applesauce', name: 'Compotes de pommes', category: 'breakfast', zone: 'emergency', target: 2, unit: 'portions'),
        ReserveItem(id: 'em-fruit-syrup', name: 'Fruits au sirop', category: 'breakfast', zone: 'emergency', target: 1, unit: 'portion'),
        ReserveItem(id: 'em-biscuits-crackers', name: 'Biscuits salés longue conservation', category: 'starch', zone: 'emergency', target: 1, unit: 'paquet'),
        ReserveItem(id: 'em-biscuits-bread', name: 'Pain longue conservation / pain croustillant', category: 'starch', zone: 'emergency', target: 1, unit: 'paquet'),
        ReserveItem(id: 'em-dried-mix', name: 'Mélange de fruits secs', category: 'snacks', zone: 'emergency', target: 200, unit: 'g'),
        ReserveItem(id: 'em-starch-rice', name: 'Riz précuit en portion', category: 'starch', zone: 'emergency', target: 2, unit: 'portions', notes: 'Prêt à consommer, sans cuisson.'),
        ReserveItem(id: 'em-starch-couscous', name: 'Taboulé ou semoule préparée', category: 'starch', zone: 'emergency', target: 1, unit: 'portion', notes: 'Choisir une version prête à consommer.'),
        ReserveItem(id: 'em-bars-cereal', name: 'Barres céréalières', category: 'snacks', zone: 'emergency', target: 3, unit: 'unités', notes: 'Fourchette indicative : 3 à 6 unités.'),
        ReserveItem(id: 'em-opener', name: 'Ouvre-boîte manuel', category: 'other', zone: 'emergency', target: 1, unit: 'unité', perPerson: false, notes: 'À garder avec le kit ; un par foyer.'),

        // RÉSERVE 15 JOURS — répartition détaillée des objectifs indicatifs.
        // Légumes et légumineuses : 12 boîtes au total.
        ReserveItem(id: 'res-veg-greenbeans', name: 'Haricots verts', category: 'vegetables', zone: 'reserve', target: 2, unit: 'boîtes'),
        ReserveItem(id: 'res-veg-peas', name: 'Petits pois', category: 'vegetables', zone: 'reserve', target: 2, unit: 'boîtes'),
        ReserveItem(id: 'res-veg-corn', name: 'Maïs doux', category: 'vegetables', zone: 'reserve', target: 1, unit: 'boîte'),
        ReserveItem(id: 'res-veg-carrots', name: 'Carottes', category: 'vegetables', zone: 'reserve', target: 1, unit: 'boîte'),
        ReserveItem(id: 'res-veg-ratatouille', name: 'Ratatouille', category: 'vegetables', zone: 'reserve', target: 2, unit: 'boîtes'),
        ReserveItem(id: 'res-leg-lentils', name: 'Lentilles cuisinées', category: 'legumes', zone: 'reserve', target: 1, unit: 'boîte'),
        ReserveItem(id: 'res-leg-chickpeas', name: 'Pois chiches', category: 'legumes', zone: 'reserve', target: 1, unit: 'boîte'),
        ReserveItem(id: 'res-leg-redbeans', name: 'Haricots rouges', category: 'legumes', zone: 'reserve', target: 1, unit: 'boîte'),
        ReserveItem(id: 'res-leg-whitebeans', name: 'Haricots blancs', category: 'legumes', zone: 'reserve', target: 1, unit: 'boîte'),

        // Poissons et protéines : 11 portions au total.
        ReserveItem(id: 'res-fish-tuna', name: 'Thon au naturel', category: 'fish', zone: 'reserve', target: 3, unit: 'portions'),
        ReserveItem(id: 'res-fish-sardines', name: 'Sardines à l’huile', category: 'fish', zone: 'reserve', target: 2, unit: 'portions'),
        ReserveItem(id: 'res-fish-mackerel', name: 'Maquereaux en conserve', category: 'fish', zone: 'reserve', target: 2, unit: 'portions'),
        ReserveItem(id: 'res-protein-chicken', name: 'Volaille en conserve', category: 'protein', zone: 'reserve', target: 2, unit: 'portions'),
        ReserveItem(id: 'res-protein-pate', name: 'Pâté / terrine', category: 'protein', zone: 'reserve', target: 2, unit: 'portions'),

        // Plats préparés et bases de cuisine : 9 unités au total.
        ReserveItem(id: 'res-ready-soup', name: 'Soupes en brique ou conserve', category: 'ready', zone: 'reserve', target: 2, unit: 'unités'),
        ReserveItem(id: 'res-ready-tomatoes', name: 'Tomates pelées', category: 'ready', zone: 'reserve', target: 2, unit: 'boîtes'),
        ReserveItem(id: 'res-ready-sauce', name: 'Sauce tomate', category: 'ready', zone: 'reserve', target: 2, unit: 'bocaux'),
        ReserveItem(id: 'res-ready-ravioli', name: 'Ravioli en conserve', category: 'ready', zone: 'reserve', target: 1, unit: 'boîte'),
        ReserveItem(id: 'res-ready-cassoulet', name: 'Cassoulet en conserve', category: 'ready', zone: 'reserve', target: 1, unit: 'boîte'),
        ReserveItem(id: 'res-ready-chili', name: 'Chili aux haricots', category: 'ready', zone: 'reserve', target: 1, unit: 'boîte'),

        // Féculents et produits secs : 6 kg au total.
        ReserveItem(id: 'res-starch-rice', name: 'Riz', category: 'starch', zone: 'reserve', target: 2, unit: 'kg'),
        ReserveItem(id: 'res-starch-pasta', name: 'Pâtes', category: 'starch', zone: 'reserve', target: 1.5, unit: 'kg'),
        ReserveItem(id: 'res-starch-couscous', name: 'Semoule / couscous', category: 'starch', zone: 'reserve', target: 1, unit: 'kg'),
        ReserveItem(id: 'res-starch-mash', name: 'Purée en flocons', category: 'starch', zone: 'reserve', target: .5, unit: 'kg'),
        ReserveItem(id: 'res-starch-flour', name: 'Farine', category: 'starch', zone: 'reserve', target: .5, unit: 'kg'),
        ReserveItem(id: 'res-starch-oats', name: 'Flocons d’avoine', category: 'starch', zone: 'reserve', target: .5, unit: 'kg'),

        // Petits-déjeuners et énergie : 12 portions variées.
        ReserveItem(id: 'res-breakfast-compote', name: 'Compotes', category: 'breakfast', zone: 'reserve', target: 3, unit: 'portions'),
        ReserveItem(id: 'res-breakfast-honey', name: 'Miel', category: 'breakfast', zone: 'reserve', target: 1, unit: 'portion'),
        ReserveItem(id: 'res-breakfast-dried', name: 'Fruits secs', category: 'snacks', zone: 'reserve', target: 2, unit: 'portions'),
        ReserveItem(id: 'res-breakfast-nuts', name: 'Noix et amandes', category: 'snacks', zone: 'reserve', target: 2, unit: 'portions'),
        ReserveItem(id: 'res-breakfast-biscuits', name: 'Biscuits secs', category: 'breakfast', zone: 'reserve', target: 2, unit: 'portions'),
        ReserveItem(id: 'res-breakfast-chocolate', name: 'Chocolat noir', category: 'breakfast', zone: 'reserve', target: 2, unit: 'portions'),

        // GARDE-MANGER — produits du quotidien, séparés des réserves de sécurité.
        // Stocks volontairement inconnus à la première ouverture : l'utilisateur les compte.
        ReserveItem(id: 'daily-olive-oil', name: 'Huile d’olive', category: 'condiments', zone: 'daily', target: 1, unit: 'bouteille', perPerson: false),
        ReserveItem(id: 'daily-vinegar', name: 'Vinaigre', category: 'condiments', zone: 'daily', target: 1, unit: 'bouteille', perPerson: false),
        ReserveItem(id: 'daily-salt', name: 'Sel', category: 'condiments', zone: 'daily', target: 1, unit: 'paquet', perPerson: false),
        ReserveItem(id: 'daily-sugar', name: 'Sucre', category: 'condiments', zone: 'daily', target: 1, unit: 'kg', perPerson: false),
        ReserveItem(id: 'daily-mustard', name: 'Moutarde', category: 'condiments', zone: 'daily', target: 1, unit: 'pot', perPerson: false),
        ReserveItem(id: 'daily-coffee', name: 'Café', category: 'breakfast', zone: 'daily', target: 1, unit: 'paquet', perPerson: false),
        ReserveItem(id: 'daily-tea', name: 'Thé et infusions', category: 'breakfast', zone: 'daily', target: 1, unit: 'boîte', perPerson: false),
        ReserveItem(id: 'daily-uht-milk', name: 'Lait UHT', category: 'breakfast', zone: 'daily', target: 3, unit: 'briques', perPerson: false),

      ];

  Map<String, dynamic> toJson() => {
        'app': 'Ma Réserve Flutter',
        'appVersion': appVersionName,
        'backupFormat': 'ma-reserve-backup',
        'backupFormatVersion': 1,
        'schemaVersion': dataSchemaVersion,
        'savedAt': (lastSavedAt ?? DateTime.now()).toIso8601String(),
        // Conserver `version` pour la compatibilité avec les exports antérieurs.
        'version': dataSchemaVersion,
        'exportedAt': DateTime.now().toIso8601String(),
        'people': people,
        'items': items.map((item) => item.toJson()).toList(),
        'customCatalog': customCatalog.map((item) => item.toJson()).toList(),
        'checks': checks,
      };

  Future<void> _persist({bool notify = true}) {
    // L'interface est rafraîchie dès la modification. Les écritures sont
    // ensuite sérialisées : une sauvegarde lente ne peut plus écraser une
    // sauvegarde plus récente (cas possible avec plusieurs actions rapides).
    final previousWarning = storageWarning;
    if (notify) notifyListeners();

    final nextWrite = _writeQueue.then((_) async {
      try {
        // Construire le JSON au moment réel de l'écriture pour toujours
        // sauvegarder l'état le plus récent du contrôleur.
        lastSavedAt = DateTime.now();
        final encoded = jsonEncode(toJson());
        final preferences = _preferences;
        if (preferences == null) {
          storageWarning = 'Le stockage local n’est pas encore initialisé.';
        } else {
          final saved = await preferences.setString(storageKey, encoded);
          storageWarning = saved ? null : 'La sauvegarde locale a été refusée par l’appareil.';
        }
      } catch (_) {
        storageWarning = 'La sauvegarde locale a échoué. Utilise « Sauvegarder / restaurer » pour conserver une copie.';
      }
      if (notify && storageWarning != previousWarning) notifyListeners();
    });
    _writeQueue = nextWrite;
    return nextWrite;
  }

  void _save() {
    unawaited(_persist());
  }

  double targetFor(ReserveItem item) => item.targetFor(people);

  List<ReserveItem> inZone(String zone) => items.where((item) => item.zone == zone && !item.isLegacySummary).toList();

  List<ReserveItem> get activeItems => items.where((item) => !item.isLegacySummary).toList();
  List<ReserveItem> get legacySummaryItems => items.where((item) => item.isLegacySummary).toList();
  List<ReserveItem> get unknownItems => activeItems.where((item) => item.stock == null).toList();

  List<ReserveItem> get lowItems => activeItems
      .where((item) => item.stock != null && item.stock! < targetFor(item))
      .toList();

  /// Besoins d'achat calculés séparément pour chaque espace de rangement.
  /// Les stocks du kit 72 h et de la réserve 15 jours ne sont jamais fusionnés.
  List<ReserveItem> lowItemsInZone(String zone) => inZone(zone)
      .where((item) => item.stock != null && item.stock! < targetFor(item))
      .toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Produits à compter avant de pouvoir calculer un besoin d'achat.
  List<ReserveItem> unknownItemsInZone(String zone) => inZone(zone)
      .where((item) => item.stock == null)
      .toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  int get shoppingNeedCount =>
      lowItemsInZone('emergency').length +
      lowItemsInZone('reserve').length +
      lowItemsInZone('daily').length;

  /// Chaque échéance appartient à un lot, pas à toute la référence produit.
  List<DatedLot> get datedLots {
    final values = <DatedLot>[];
    for (final item in activeItems) {
      for (final lot in item.lots) {
        if (lot.expiryDate != null && (lot.quantity == null || lot.quantity! > 0)) {
          values.add(DatedLot(item: item, lot: lot));
        }
      }
    }
    values.sort((a, b) => a.lot.expiryDate!.compareTo(b.lot.expiryDate!));
    return values;
  }

  List<DatedLot> get soonLots => datedLots.where((entry) => daysUntil(entry.lot.expiryDate!) <= 65).toList();

  int get completedCount => activeItems.where((item) {
        return item.stock != null && item.stock! >= targetFor(item);
      }).length;

  int completedInZone(String zone) => inZone(zone).where((item) {
        return item.stock != null && item.stock! >= targetFor(item);
      }).length;

  double progressInZone(String zone) {
    final zoneItems = inZone(zone);
    if (zoneItems.isEmpty) return 0;
    return completedInZone(zone) / zoneItems.length;
  }

  int get thisMonthDone {
    final values = checks[monthKey] ?? {};
    return monthlyChecks.where((entry) => values[entry.id] == true).length;
  }

  void setPeople(int value) {
    people = value.clamp(1, 20).toInt();
    _save();
  }

  List<FoodTemplate> get catalogTemplates {
    final combined = <String, FoodTemplate>{};
    for (final template in [...foodCatalog, ...customCatalog]) {
      final key = '${template.category}|${template.name.trim().toLowerCase()}';
      combined[key] = template;
    }
    final result = combined.values.toList()
      ..sort((a, b) {
        final categoryOrder = a.category.compareTo(b.category);
        return categoryOrder != 0 ? categoryOrder : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return result;
  }

  void _registerInCatalog(ReserveItem item, {ReserveItem? previous}) {
    if (item.isLegacySummary || item.name.trim().isEmpty) return;
    final template = FoodTemplate(
      name: item.name.trim(),
      category: item.category,
      target: item.target,
      unit: item.unit,
      notes: item.notes,
      emoji: item.displayEmoji,
      sourceItemId: item.id,
    );
    final currentKey = '${template.category}|${template.name.toLowerCase()}';
    final previousKey = previous == null
        ? null
        : '${previous.category}|${previous.name.trim().toLowerCase()}';
    final anotherItemUsesPreviousKey = previous != null && items.any((entry) =>
        entry.id != item.id && !entry.isLegacySummary &&
        '${entry.category}|${entry.name.trim().toLowerCase()}' == previousKey);

    customCatalog.removeWhere((entry) {
      final entryKey = '${entry.category}|${entry.name.trim().toLowerCase()}';
      if (entry.sourceItemId == item.id || entryKey == currentKey) return true;
      // Nettoyer l'ancien nom lorsqu'une fiche a été renommée, sauf si une
      // autre fiche utilise encore ce produit.
      return previousKey != null && entryKey == previousKey && !anotherItemUsesPreviousKey;
    });
    customCatalog.add(template);
  }

  Future<bool> saveItem(ReserveItem item) async {
    item.syncLotSummary();
    final index = items.indexWhere((entry) => entry.id == item.id);
    ReserveItem? previous;

    if (index < 0) {
      final duplicate = items.any((entry) => !entry.isLegacySummary &&
          entry.zone == item.zone &&
          entry.name.trim().toLowerCase() == item.name.trim().toLowerCase());
      if (duplicate) return false;
      item.history.add(StockHistoryEntry(
        at: DateTime.now(),
        label: item.stock == null
            ? 'Produit créé'
            : 'Produit créé avec un stock de ${formatNumber(item.stock!)} ${item.unit}',
        newStock: item.stock,
        newZone: item.zone,
      ));
      items.add(item);
    } else {
      // Copier l'ancien état avant remplacement : la détection des changements
      // et l'historique ne doivent jamais comparer deux références au même objet.
      previous = ReserveItem.fromJson(items[index].toJson());
      final duplicateInDestination = items.any((entry) =>
          entry.id != item.id && !entry.isLegacySummary &&
          entry.zone == item.zone &&
          entry.name.trim().toLowerCase() == item.name.trim().toLowerCase());
      if (duplicateInDestination) return false;

      if (item.history.isEmpty && previous.history.isNotEmpty) {
        item.history = List<StockHistoryEntry>.from(previous.history);
      }

      final changes = <String>[];
      if (previous.name != item.name) changes.add('Nom : ${previous.name} → ${item.name}');
      if (previous.category != item.category) changes.add('Catégorie modifiée');
      if (previous.stock != item.stock) {
        final oldText = previous.stock == null ? 'non renseigné' : '${formatNumber(previous.stock!)} ${previous.unit}';
        final newText = item.stock == null ? 'non renseigné' : '${formatNumber(item.stock!)} ${item.unit}';
        changes.add('Stock : $oldText → $newText');
      }
      if (previous.target != item.target || previous.perPerson != item.perPerson) {
        changes.add('Objectif : ${formatNumber(previous.target)} → ${formatNumber(item.target)} ${item.unit}');
      }
      if (previous.unit != item.unit) changes.add('Unité : ${previous.unit} → ${item.unit}');
      if (previous.purchaseDate != item.purchaseDate) changes.add('Date d’achat modifiée');
      if (previous.expiryDate != item.expiryDate || previous.dateType != item.dateType) changes.add('Date de conservation modifiée');
      if (jsonEncode(previous.lots.map((lot) => lot.toJson()).toList()) != jsonEncode(item.lots.map((lot) => lot.toJson()).toList())) {
        changes.add('Lots modifiés : ${previous.lots.length} → ${item.lots.length} lot(s)');
      }
      if (previous.notes != item.notes) changes.add('Notes modifiées');
      if (previous.emoji != item.emoji) changes.add('Icône modifiée');
      if (previous.zone != item.zone) changes.add('Déplacement : ${zoneName(previous.zone)} → ${zoneName(item.zone)}');

      if (changes.isNotEmpty) {
        item.history.add(StockHistoryEntry(
          at: DateTime.now(),
          label: changes.join(' · '),
          oldStock: previous.stock,
          newStock: item.stock,
          oldZone: previous.zone,
          newZone: item.zone,
        ));
      }
      items[index] = item;
    }

    _registerInCatalog(item, previous: previous);
    await _persist();
    return true;
  }

  /// Déplace une référence existante sans la recréer : le stock, les dates,
  /// les notes, l'icône et l'historique restent attachés au même produit.
  Future<bool> moveItem(String id, String destinationZone) async {
    final index = items.indexWhere((entry) => entry.id == id);
    if (index < 0) return false;
    final item = items[index];
    if (item.zone == destinationZone) return true;
    final duplicate = items.any((entry) =>
        entry.id != id && !entry.isLegacySummary && entry.zone == destinationZone &&
        entry.name.trim().toLowerCase() == item.name.trim().toLowerCase());
    if (duplicate) return false;
    final oldZone = item.zone;
    item.zone = destinationZone;
    item.history.add(StockHistoryEntry(
      at: DateTime.now(),
      label: 'Déplacement : ${zoneName(oldZone)} → ${zoneName(destinationZone)}',
      oldStock: item.stock, newStock: item.stock,
      oldZone: oldZone, newZone: destinationZone,
    ));
    _registerInCatalog(item);
    await _persist();
    return true;
  }

  /// Retire une quantité sur un lot précis. Les lots de la page FEFO sont
  /// triés par date croissante afin de guider la sortie du plus ancien en premier.
  Future<bool> removeFromLot(String itemId, String lotId, double quantity) async {
    if (quantity <= 0) return false;
    final itemIndex = items.indexWhere((entry) => entry.id == itemId);
    if (itemIndex < 0) return false;
    final item = items[itemIndex];
    final lotIndex = item.lots.indexWhere((entry) => entry.id == lotId);
    if (lotIndex < 0) return false;
    final lot = item.lots[lotIndex];
    final available = lot.quantity;
    if (available == null || quantity > available + 0.000001) return false;
    final oldTotal = item.stock;
    final dateText = lot.expiryDate == null ? 'sans date de conservation' : '${lot.dateType} du ${formatDate(lot.expiryDate!)}';
    final newQuantity = available - quantity;
    // Conserver le lot à zéro pour que le stock agrégé reste bien à 0 (et
    // non « inconnu ») après consommation complète. Il sort des alertes FEFO.
    lot.quantity = newQuantity <= 0.000001 ? 0 : newQuantity;
    item.syncLotSummary();
    item.history.add(StockHistoryEntry(
      at: DateTime.now(),
      label: '${formatNumber(quantity)} ${item.unit} sortis du lot ($dateText)',
      oldStock: oldTotal,
      newStock: item.stock,
      oldZone: item.zone,
      newZone: item.zone,
    ));
    _registerInCatalog(item);
    await _persist();
    return true;
  }

  Future<void> deleteItem(String id) async {
    items.removeWhere((item) => item.id == id);
    customCatalog.removeWhere((template) => template.sourceItemId == id);
    await _persist();
  }

  void setMonthlyCheck(String id, bool checked) {
    checks.putIfAbsent(monthKey, () => {});
    checks[monthKey]![id] = checked;
    _save();
  }

  void resetMonthlyChecks() {
    checks.remove(monthKey);
    _save();
  }

  Future<void> _createSafetySnapshot(String reason) async {
    await _writeQueue;
    final preferences = _preferences;
    if (preferences == null) throw StateError('Le stockage local n’est pas initialisé.');
    final snapshot = toJson();
    snapshot['safetySnapshotReason'] = reason;
    snapshot['safetySnapshotAt'] = DateTime.now().toIso8601String();
    final saved = await preferences.setString(safetySnapshotKey, jsonEncode(snapshot));
    if (!saved) throw StateError('Impossible de créer la copie de sécurité avant cette opération.');
  }

  bool get canRestoreSafetySnapshot => _preferences?.getString(safetySnapshotKey)?.isNotEmpty == true;
  bool get hasRecoverySnapshot => _preferences?.getString(recoverySnapshotKey)?.isNotEmpty == true;
  String? get recoverySnapshotText => _preferences?.getString(recoverySnapshotKey);

  Future<void> restoreJson(String source, {bool createSafetySnapshot = true}) async {
    // Tout est analysé et validé avant de toucher aux données actuellement chargées.
    final decoded = _decodeBackup(source);
    final previousItems = items;
    final previousCatalog = customCatalog;
    final previousChecks = checks;
    final previousPeople = people;
    final previousLastSavedAt = lastSavedAt;
    if (createSafetySnapshot) await _createSafetySnapshot('Avant restauration d’une sauvegarde');

    _applyDecodedData(decoded);
    final importedSavedAt = decoded['savedAt']?.toString() ?? decoded['exportedAt']?.toString();
    lastSavedAt = DateTime.tryParse(importedSavedAt ?? '');
    storageWarning = null;
    await _persist();
    if (storageWarning != null) {
      final failure = storageWarning!;
      items = previousItems;
      customCatalog = previousCatalog;
      checks = previousChecks;
      people = previousPeople;
      lastSavedAt = previousLastSavedAt;
      notifyListeners();
      throw StateError('La restauration n’a pas été enregistrée : $failure');
    }
  }

  Future<void> restoreSafetySnapshot() async {
    final raw = _preferences?.getString(safetySnapshotKey);
    if (raw == null || raw.isEmpty) throw StateError('Aucune copie de sécurité disponible.');
    await restoreJson(raw, createSafetySnapshot: false);
    await _preferences!.remove(safetySnapshotKey);
  }


  Future<void> resetAllData() async {
    final previousItems = items;
    final previousCatalog = customCatalog;
    final previousChecks = checks;
    final previousPeople = people;
    final previousLastSavedAt = lastSavedAt;
    await _createSafetySnapshot('Avant remise à zéro complète');

    people = 1;
    items = _seedItems();
    customCatalog = [];
    checks = {};
    storageWarning = null;
    await _persist();
    if (storageWarning != null) {
      final failure = storageWarning!;
      items = previousItems;
      customCatalog = previousCatalog;
      checks = previousChecks;
      people = previousPeople;
      lastSavedAt = previousLastSavedAt;
      notifyListeners();
      throw StateError('La remise à zéro n’a pas été enregistrée : $failure');
    }
  }


  static String get monthKey {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }
}

class _BackupManagerDialog extends StatefulWidget {
  const _BackupManagerDialog({required this.controller});
  final ReserveController controller;

  @override
  State<_BackupManagerDialog> createState() => _BackupManagerDialogState();
}

class _BackupManagerDialogState extends State<_BackupManagerDialog> {
  bool busy = false;

  void _message(String value, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: error ? red : greenDark,
      content: Text(value),
    ));
  }

  String _fileName() {
    final now = DateTime.now();
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    return 'ma-reserve-sauvegarde-$stamp.json';
  }

  Future<void> _downloadBackup() async {
    setState(() => busy = true);
    try {
      final data = const JsonEncoder.withIndent('  ').convert(widget.controller.toJson());
      try {
        await backup_io.downloadTextFile(_fileName(), data);
        _message('Fichier de sauvegarde téléchargé. Conserve-le aussi sur un autre support.');
      } on UnsupportedError {
        await Clipboard.setData(ClipboardData(text: data));
        _message('Téléchargement indisponible sur cet appareil : le JSON a été copié.');
      }
    } catch (error) {
      _message('Sauvegarde impossible : $error', error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _copyBackup() async {
    try {
      final data = const JsonEncoder.withIndent('  ').convert(widget.controller.toJson());
      await Clipboard.setData(ClipboardData(text: data));
      _message('Copie JSON réalisée. Tu peux la conserver dans Notes ou un fichier texte.');
    } catch (error) {
      _message('Copie impossible : $error', error: true);
    }
  }

  Future<void> _importFile() async {
    setState(() => busy = true);
    try {
      final source = await backup_io.pickTextFile();
      if (source == null) return;
      if (mounted) setState(() => busy = false);
      await _confirmAndRestore(source);
    } on UnsupportedError {
      _message('La sélection de fichier n’est pas disponible ici. Utilise « Restaurer depuis un texte JSON ».', error: true);
    } catch (error) {
      _message('Lecture du fichier impossible : $error', error: true);
    } finally {
      if (mounted && busy) setState(() => busy = false);
    }
  }

  Future<void> _pasteAndRestore() async {
    final sourceController = TextEditingController();
    final source = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restaurer depuis un texte JSON'),
        content: SizedBox(
          width: 620,
          child: TextField(
            controller: sourceController,
            minLines: 8,
            maxLines: 14,
            decoration: const InputDecoration(hintText: 'Colle ici le contenu du fichier de sauvegarde .json'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, sourceController.text), child: const Text('Vérifier la sauvegarde')),
        ],
      ),
    );
    sourceController.dispose();
    if (source == null || source.trim().isEmpty || !mounted) return;
    await _confirmAndRestore(source);
  }

  Future<void> _confirmAndRestore(String source) async {
    BackupPreview preview;
    try {
      preview = widget.controller.previewBackup(source);
    } catch (error) {
      _message('Sauvegarde refusée : $error', error: true);
      return;
    }
    final date = DateTime.tryParse(preview.exportedAt ?? '');
    final dateLabel = date == null ? 'Date non indiquée' : 'Export du ${formatDate(date)}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirmer la restauration'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Cette opération remplacera les données actuellement ouvertes. Une copie de sécurité sera créée automatiquement avant le remplacement.'),
          const SizedBox(height: 12),
          _backupInfoLine(Icons.inventory_2_outlined, '${preview.productCount} produits · ${preview.lotCount} lots'),
          _backupInfoLine(Icons.menu_book_outlined, '${preview.customProductCount} entrées de catalogue personnel'),
          _backupInfoLine(Icons.people_outline, '${preview.people} personne(s)'),
          _backupInfoLine(Icons.event_outlined, dateLabel),
          if (preview.sourceVersion != null) _backupInfoLine(Icons.info_outline, 'Version source ${preview.sourceVersion}'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Restaurer cette sauvegarde')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.controller.restoreJson(source);
      _message('Sauvegarde restaurée. Une copie de sécurité précédente est disponible dans ce menu.');
      if (mounted) setState(() {});
    } catch (error) {
      _message('Restauration annulée : $error', error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _restoreSafetySnapshot() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revenir à la copie de sécurité ?'),
        content: const Text('Les données actuelles seront remplacées par la dernière copie créée avant une restauration ou une remise à zéro.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Revenir en arrière')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.controller.restoreSafetySnapshot();
      _message('Copie de sécurité restaurée.');
      if (mounted) setState(() {});
    } catch (error) {
      _message('Récupération impossible : $error', error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _resetAll() async {
    final phraseController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: red), SizedBox(width: 8), Text('Remise à zéro complète')]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Cette opération efface les produits personnels, les stocks et lots saisis, les dates, les historiques, le catalogue personnel et les contrôles mensuels.'),
          const SizedBox(height: 10),
          const Text('Les produits de base seront recréés avec des stocks vides. Le nombre de personnes reviendra à 1.', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          const Text('Une copie de sécurité automatique sera créée avant la remise à zéro : tu pourras revenir en arrière depuis ce menu.'),
          const SizedBox(height: 12),
          TextField(controller: phraseController, decoration: const InputDecoration(labelText: 'Tape RAZ pour confirmer')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: red),
            onPressed: () => Navigator.pop(dialogContext, phraseController.text.trim().toUpperCase() == 'RAZ'),
            child: const Text('Effacer et réinitialiser'),
          ),
        ],
      ),
    );
    phraseController.dispose();
    if (confirmed != true || !mounted) {
      if (confirmed == false && mounted) _message('Confirmation incorrecte ou remise à zéro annulée.', error: true);
      return;
    }
    setState(() => busy = true);
    try {
      await widget.controller.resetAllData();
      _message('Remise à zéro effectuée. Les produits de base sont recréés sans stock saisi.');
      if (mounted) setState(() {});
    } catch (error) {
      _message('Remise à zéro impossible : $error', error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _backupInfoLine(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(children: [Icon(icon, size: 17, color: green), const SizedBox(width: 8), Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: ink)))]),
  );

  Widget _actionButton({required IconData icon, required String title, required String subtitle, required VoidCallback? onPressed, bool primary = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton.icon(
        onPressed: busy ? null : onPressed,
        icon: Icon(icon, size: 19),
        label: SizedBox(width: double.infinity, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
          Text(subtitle, style: const TextStyle(fontWeight: FontWeight.w400, fontSize: 10, color: muted)),
        ])),
        style: OutlinedButton.styleFrom(
          foregroundColor: primary ? greenDark : ink,
          backgroundColor: primary ? greenSoft : Colors.white,
          side: BorderSide(color: primary ? const Color(0xFFC8D9C5) : const Color(0xFFE1E7DF)),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final lotCount = controller.activeItems.fold<int>(0, (sum, item) => sum + item.lots.length);
    return AlertDialog(
      title: Row(children: [const Icon(Icons.shield_outlined, color: greenDark), const SizedBox(width: 9), const Expanded(child: Text('Sauvegarde & données')), if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))]),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cream, borderRadius: BorderRadius.circular(13)),
            child: Row(children: [
              const Icon(Icons.inventory_2_outlined, color: greenDark, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${controller.activeItems.length} références · $lotCount lots', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: ink)),
                Text('${controller.customCatalog.length} produits personnels · ${controller.people} personne(s)', style: const TextStyle(fontSize: 10, color: muted)),
                if (controller.lastSavedAt != null) Text('Dernier enregistrement : ${formatDateTime(controller.lastSavedAt!)}', style: const TextStyle(fontSize: 10, color: muted)),
              ])),
            ]),
          ),
          const SizedBox(height: 14),
          const Text('SAUVEGARDER', style: TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1)),
          const SizedBox(height: 8),
          _actionButton(icon: Icons.download_rounded, title: 'Télécharger un fichier .json', subtitle: 'À conserver sur ton PC, une clé USB ou un espace cloud.', onPressed: _downloadBackup, primary: true),
          _actionButton(icon: Icons.copy_rounded, title: 'Copier la sauvegarde', subtitle: 'Copier le contenu JSON dans le presse-papiers.', onPressed: _copyBackup),
          const SizedBox(height: 5),
          const Text('RESTAURER', style: TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1)),
          const SizedBox(height: 8),
          _actionButton(icon: Icons.upload_file_rounded, title: 'Restaurer depuis un fichier .json', subtitle: 'Choisir un fichier de sauvegarde sur ton ordinateur.', onPressed: _importFile),
          _actionButton(icon: Icons.paste_rounded, title: 'Restaurer depuis un texte JSON', subtitle: 'Solution de secours si tu as copié le contenu JSON.', onPressed: _pasteAndRestore),
          if (controller.canRestoreSafetySnapshot) ...[
            const SizedBox(height: 8),
            _actionButton(icon: Icons.undo_rounded, title: 'Annuler la dernière opération', subtitle: 'Revenir à la copie automatique créée avant restauration ou RAZ.', onPressed: _restoreSafetySnapshot, primary: true),
          ],
          if (controller.hasRecoverySnapshot) ...[
            _actionButton(icon: Icons.healing_outlined, title: 'Exporter la copie locale brute', subtitle: 'Conserver le contenu qui était présent avant la détection d’une erreur.', onPressed: () async {
              final raw = controller.recoverySnapshotText;
              if (raw == null) return;
              try {
                await backup_io.downloadTextFile('ma-reserve-copie-locale-brute.txt', raw);
                _message('Copie locale brute téléchargée. Elle peut nécessiter une récupération technique.');
              } on UnsupportedError {
                await Clipboard.setData(ClipboardData(text: raw));
                _message('Copie brute copiée dans le presse-papiers.');
              } catch (error) {
                _message('Export de la copie brute impossible : $error', error: true);
              }
            }),
          ],
          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 4),
          const Text('REMISE À ZÉRO', style: TextStyle(color: red, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1)),
          const SizedBox(height: 5),
          const Text('Recrée les produits de base et efface les données personnelles. Une copie de sécurité est créée automatiquement avant l’opération.', style: TextStyle(fontSize: 11, color: muted, height: 1.35)),
          const SizedBox(height: 8),
          _actionButton(icon: Icons.delete_sweep_outlined, title: 'Remise à zéro complète', subtitle: 'Stocks vides, lots, historiques, produits personnels et contrôles effacés.', onPressed: _resetAll),
        ])),
      ),
      actions: [TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Fermer'))],
    );
  }
}

class MonthlyCheck {
  const MonthlyCheck(this.id, this.title, this.description, this.icon);
  final String id;
  final String title;
  final String description;
  final IconData icon;
}

const List<MonthlyCheck> monthlyChecks = [
  MonthlyCheck('water', 'Eau et kit d’urgence de 72 heures',
      'Vérifier l’eau, les aliments prêts à consommer sans cuisson et la présence d’un ouvre-boîte manuel.', Icons.water_drop_outlined),
  MonthlyCheck('stocks', 'Quantités de la réserve',
      'Compter conserves, légumineuses, féculents et produits secs ; comparer aux objectifs du foyer.', Icons.inventory_2_outlined),
  MonthlyCheck('dates', 'Dates et rotation FEFO',
      'Repérer les DLC/DDM proches. Placer devant les produits dont la date arrive le plus tôt.', Icons.event_outlined),
  MonthlyCheck('packaging', 'État des emballages',
      'Écarter les boîtes bombées, fuyantes, fortement rouillées ou anormalement déformées. Ne jamais goûter un produit suspect.', Icons.health_and_safety_outlined),
  MonthlyCheck('shopping', 'Réapprovisionnement',
      'Repérer les quantités sous l’objectif et préparer la liste de courses pour reconstituer le stock.', Icons.shopping_cart_outlined),
];

class MaReserveApp extends StatelessWidget {
  const MaReserveApp({super.key, required this.controller});
  final ReserveController controller;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(seedColor: green, brightness: Brightness.light).copyWith(
      primary: green,
      secondary: amber,
      surface: const Color(0xFFFFFEFB),
      error: red,
    );
    return MaterialApp(
      title: 'Ma Réserve',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('fr', 'FR')],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: cream,
        appBarTheme: const AppBarTheme(backgroundColor: cream, foregroundColor: ink, elevation: 0),
        textTheme: const TextTheme(
          headlineSmall: TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 24, letterSpacing: -.4),
          titleLarge: TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 19),
          titleMedium: TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 15),
          bodyLarge: TextStyle(color: ink, fontSize: 14),
          bodyMedium: TextStyle(color: ink, fontSize: 13),
          bodySmall: TextStyle(color: muted, fontSize: 11),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFFAFBF7),
          contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: Color(0xFFDDE4D9))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: Color(0xFFDDE4D9))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: green, width: 1.5)),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: greenDark,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      home: HomeShell(controller: controller),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});
  final ReserveController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int selectedIndex = 0;
  String inventoryFilter = 'all';

  static const destinations = [
    _Destination('Accueil', Icons.grid_view_rounded, bottomLabel: 'Accueil'),
    _Destination('Kit 72 h', Icons.backpack_outlined, bottomLabel: 'Kit'),
    _Destination('Réserve 15 jours', Icons.inventory_2_outlined, bottomLabel: '15 j'),
    _Destination('Garde-manger', Icons.kitchen_outlined, bottomLabel: 'Garde'),
    _Destination('Inventaire', Icons.checklist_rounded, bottomLabel: 'Stock'),
    _Destination('Suivi & courses', Icons.event_note_rounded, bottomLabel: 'Suivi'),
  ];

  void select(int index) => setState(() {
        selectedIndex = index;
        if (index == 4) inventoryFilter = 'all';
      });

  void openInventoryFilter(String filter) => setState(() {
        selectedIndex = 4;
        inventoryFilter = filter;
      });

  Future<void> _showBackup() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _BackupManagerDialog(controller: widget.controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 820;

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        // IMPORTANT : recréer les widgets des pages à chaque notification.
        // Dans la V1.6, la liste `pages` était construite en dehors de
        // l'AnimatedBuilder. Les mêmes instances de widgets étaient donc
        // réutilisées et Flutter pouvait ignorer leur mise à jour : une fiche
        // enregistrée depuis l'inventaire restait visuellement inchangée
        // jusqu'à un changement d'écran. Les pages sont maintenant créées
        // dans le builder et reçoivent les dernières données du contrôleur.
        final pages = <Widget>[
          DashboardPage(controller: widget.controller, onNavigate: select, onInventoryFilter: openInventoryFilter),
          ZonePage(controller: widget.controller, zone: 'emergency'),
          ZonePage(controller: widget.controller, zone: 'reserve'),
          ZonePage(controller: widget.controller, zone: 'daily'),
          InventoryPage(controller: widget.controller, initialFilter: inventoryFilter),
          FollowUpPage(controller: widget.controller),
        ];
        return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              if (wide) _SideNavigation(
                destinations: destinations,
                selectedIndex: selectedIndex,
                onSelect: select,
                onBackup: _showBackup,
              ),
              Expanded(
                child: Column(
                  children: [
                    _TopHeader(onBackup: _showBackup, people: widget.controller.people),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1180),
                          child: IndexedStack(index: selectedIndex, children: pages),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: selectedIndex,
                onDestinationSelected: select,
                height: 70,
                backgroundColor: const Color(0xFFFFFEFB),
                indicatorColor: greenSoft,
                labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
                destinations: destinations.map((destination) => NavigationDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.icon, color: greenDark),
                  label: destination.bottomLabel ?? destination.label,
                )).toList(),
              ),
        );
      },
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, {this.bottomLabel});
  final String label;
  final IconData icon;
  final String? bottomLabel;
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation({required this.destinations, required this.selectedIndex, required this.onSelect, required this.onBackup});
  final List<_Destination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onBackup;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 224,
      decoration: const BoxDecoration(color: Color(0xFFFFFEFB), border: Border(right: BorderSide(color: Color(0xFFE5E9E1)))),
      padding: const EdgeInsets.fromLTRB(16, 22, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(width: 42, height: 42, decoration: BoxDecoration(color: greenDark, borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.inventory_2_rounded, color: Colors.white)),
            const SizedBox(width: 10),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Ma Réserve', style: TextStyle(fontWeight: FontWeight.w900, color: ink, fontSize: 17)), Text('Autonomie à la maison', style: TextStyle(color: muted, fontSize: 10))])),
          ]),
          const SizedBox(height: 30),
          const Padding(padding: EdgeInsets.only(left: 11, bottom: 10), child: Text('ESPACE PERSONNEL', style: TextStyle(color: muted, fontSize: 9, letterSpacing: 1.1, fontWeight: FontWeight.w900))),
          for (var index = 0; index < destinations.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: InkWell(
                borderRadius: BorderRadius.circular(13),
                onTap: () => onSelect(index),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
                  decoration: BoxDecoration(color: selectedIndex == index ? greenSoft : Colors.transparent, borderRadius: BorderRadius.circular(13)),
                  child: Row(children: [
                    Icon(destinations[index].icon, size: 19, color: selectedIndex == index ? greenDark : muted),
                    const SizedBox(width: 11),
                    Text(destinations[index].label, style: TextStyle(color: selectedIndex == index ? greenDark : ink, fontWeight: selectedIndex == index ? FontWeight.w800 : FontWeight.w600, fontSize: 12)),
                  ]),
                ),
              ),
            ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cream, borderRadius: BorderRadius.circular(14)),
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.cloud_off_outlined, color: green, size: 20),
              SizedBox(height: 7),
              Text('Données locales', style: TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 11)),
              Text('Fonctionne sans compte et sans connexion.', style: TextStyle(color: muted, fontSize: 10, height: 1.4)),
            ]),
          ),
          const SizedBox(height: 10),
          TextButton.icon(onPressed: onBackup, icon: const Icon(Icons.save_alt, size: 17), label: const Text('Sauvegarder / restaurer'), style: TextButton.styleFrom(foregroundColor: greenDark, textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
          Padding(padding: const EdgeInsets.only(left: 12, top: 7), child: Text('MA RÉSERVE  ·  $appVersionLabel', style: const TextStyle(color: muted, fontSize: 9, letterSpacing: .7))),
        ],
      ),
    );
  }
}

class _TopHeader extends StatelessWidget {
  const _TopHeader({required this.onBackup, required this.people});
  final VoidCallback onBackup;
  final int people;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 13, 18, 11),
      child: Row(children: [
        if (MediaQuery.sizeOf(context).width < 820) ...[
          Container(width: 36, height: 36, decoration: BoxDecoration(color: greenDark, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.inventory_2_rounded, color: Colors.white, size: 19)),
          const SizedBox(width: 9),
        ],
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(MediaQuery.sizeOf(context).width < 820 ? 'Ma Réserve' : 'Espace de gestion', style: const TextStyle(color: ink, fontWeight: FontWeight.w900, fontSize: 15)),
          Text('$people personne${people > 1 ? 's' : ''} · Garde-manger et réserves de sécurité', style: const TextStyle(color: muted, fontSize: 10)),
        ])),
        Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6), decoration: BoxDecoration(color: greenSoft, borderRadius: BorderRadius.circular(20)), child: const Row(children: [Icon(Icons.wifi_off_rounded, size: 12, color: greenDark), SizedBox(width: 5), Text('HORS LIGNE', style: TextStyle(fontSize: 9, letterSpacing: .5, fontWeight: FontWeight.w900, color: greenDark))])),
        const SizedBox(width: 6),
        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), decoration: BoxDecoration(color: cream, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE5E9E1))), child: Text(appVersionLabel, style: const TextStyle(color: greenDark, fontSize: 9, fontWeight: FontWeight.w900))),
        const SizedBox(width: 4),
        IconButton(onPressed: onBackup, tooltip: 'Sauvegarde', icon: const Icon(Icons.save_alt_rounded, color: greenDark)),
      ]),
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.controller, required this.onNavigate, required this.onInventoryFilter});
  final ReserveController controller;
  final ValueChanged<int> onNavigate;
  final ValueChanged<String> onInventoryFilter;

  @override
  Widget build(BuildContext context) {
    final low = controller.lowItems;
    final unknown = controller.unknownItems;
    final dated = controller.soonLots;
    final waterItems = controller.items.where((item) => item.id == 'em-water').toList();
    final water = waterItems.isEmpty ? null : waterItems.first;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 5, 18, 28),
      children: [
        _HeroPanel(people: controller.people, waterStock: water?.stock, waterTarget: water == null ? 6 : controller.targetFor(water), onPeopleChanged: controller.setPeople),
        const SizedBox(height: 10),
        const _InfoBanner(icon: Icons.info_outline_rounded, text: 'Trois espaces distincts : le kit 72 h est prêt en cas d’urgence ; la réserve de 15 jours prolonge l’autonomie ; le garde-manger contient les produits du quotidien. Les stocks et objectifs restent séparés : ne compte jamais un même produit physique dans deux espaces.', color: blue),
        if (controller.storageWarning != null) ...[
          const SizedBox(height: 10),
          _InfoBanner(icon: Icons.warning_amber_rounded, text: controller.storageWarning!, color: red),
        ],
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, constraints) {
          final count = constraints.maxWidth > 850 ? 4 : constraints.maxWidth > 520 ? 2 : 2;
          final gap = 9.0;
          final width = (constraints.maxWidth - gap * (count - 1)) / count;
          return Wrap(spacing: gap, runSpacing: 9, children: [
            _StatCard(width: width, label: 'Références', value: '${controller.activeItems.length}', hint: 'produits suivis · ouvrir', icon: Icons.inventory_2_outlined, tint: greenSoft, iconColor: greenDark, onTap: () => onInventoryFilter('all')),
            _StatCard(width: width, label: 'À renseigner', value: '${unknown.length}', hint: 'stocks inconnus · ouvrir', icon: Icons.edit_note_rounded, tint: blueSoft, iconColor: blue, onTap: () => onInventoryFilter('unknown')),
            _StatCard(width: width, label: 'À compléter', value: '${low.length}', hint: 'sous le seuil · ouvrir', icon: Icons.shopping_cart_outlined, tint: amberSoft, iconColor: amber, onTap: () => onInventoryFilter('low')),
            _StatCard(width: width, label: 'Dates proches', value: '${dated.length}', hint: 'environ 2 mois · ouvrir', icon: Icons.event_outlined, tint: redSoft, iconColor: red, onTap: () => onNavigate(5)),
          ]);
        }),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, constraints) {
          final columns = constraints.maxWidth >= 760 ? 3 : 1;
          final gap = 10.0;
          final cardWidth = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            SizedBox(width: cardWidth, child: _ZoneProgressCard(
              title: 'Kit d’urgence 72 h', subtitle: 'Eau, repas et matériel essentiels', icon: Icons.backpack_outlined,
              complete: controller.completedInZone('emergency'), total: controller.inZone('emergency').length,
              progress: controller.progressInZone('emergency'), onTap: () => onNavigate(1),
            )),
            SizedBox(width: cardWidth, child: _ZoneProgressCard(
              title: 'Réserve alimentaire · 15 jours', subtitle: 'Stock de sécurité complémentaire', icon: Icons.inventory_2_outlined,
              complete: controller.completedInZone('reserve'), total: controller.inZone('reserve').length,
              progress: controller.progressInZone('reserve'), onTap: () => onNavigate(2),
            )),
            SizedBox(width: cardWidth, child: _ZoneProgressCard(
              title: 'Garde-manger', subtitle: 'Épicerie et produits du quotidien', icon: Icons.kitchen_outlined,
              complete: controller.completedInZone('daily'), total: controller.inZone('daily').length,
              progress: controller.progressInZone('daily'), onTap: () => onNavigate(3),
            )),
          ]);
        }),
        const SizedBox(height: 14),
        _SectionCard(
          title: 'Les points à surveiller', trailing: Text('${unknown.length + low.length + dated.length} alerte(s)', style: const TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w700)),
          child: _AlertsList(controller: controller),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Accès rapide',
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            _QuickAction(label: 'Ouvrir le garde-manger', icon: Icons.kitchen_outlined, onTap: () => onNavigate(3)),
            _QuickAction(label: 'Mettre à jour le stock', icon: Icons.edit_note_rounded, onTap: () => onInventoryFilter('all')),
            _QuickAction(label: 'Voir les dates FEFO', icon: Icons.calendar_month_rounded, onTap: () => onNavigate(5)),
            _QuickAction(label: 'Contrôle mensuel', icon: Icons.fact_check_outlined, onTap: () => onNavigate(5)),
          ]),
        ),
      ],
    );
  }
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({required this.people, required this.waterStock, required this.waterTarget, required this.onPeopleChanged});
  final int people;
  final double? waterStock;
  final double waterTarget;
  final ValueChanged<int> onPeopleChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(19),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(23),
        gradient: const LinearGradient(colors: [greenDark, Color(0xFF718D73)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        boxShadow: [BoxShadow(color: greenDark.withOpacity(.14), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 490;
        final intro = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('PRÉVOIR SANS SURSTOCKER', style: TextStyle(color: Color(0xFFDCE8DA), fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
          const SizedBox(height: 6),
          const Text('L’autonomie,\nsimplement.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 25, height: 1.08, letterSpacing: -.5)),
          const SizedBox(height: 8),
          const Text('Un stock clair, renouvelé régulièrement, pour faire face aux imprévus à la maison.', style: TextStyle(color: Color(0xFFEAF0E8), fontSize: 11, height: 1.5)),
          const SizedBox(height: 11),
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('Foyer', style: TextStyle(color: Color(0xFFEAF0E8), fontSize: 10, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            _PersonStepper(value: people, onChanged: onPeopleChanged),
          ]),
        ]);
        final water = Container(
          width: compact ? double.infinity : 190,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.white.withOpacity(.13), border: Border.all(color: Colors.white.withOpacity(.22)), borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.water_drop_outlined, color: Colors.white, size: 21),
            const SizedBox(height: 8),
            const Text('EAU POTABLE · 72 H', style: TextStyle(color: Color(0xFFEAF0E8), fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .6)),
            const SizedBox(height: 2),
            Text(waterStock == null ? 'À renseigner' : '${formatNumber(waterStock!)} / ${formatNumber(waterTarget)} L', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
            Text('Objectif : 6 L par personne', style: TextStyle(color: Colors.white.withOpacity(.82), fontSize: 9)),
          ]),
        );
        if (compact) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [intro, const SizedBox(height: 14), water]);
        return Row(children: [Expanded(child: intro), const SizedBox(width: 16), water]);
      }),
    );
  }
}

class _PersonStepper extends StatelessWidget {
  const _PersonStepper({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: Colors.white.withOpacity(.13), borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(visualDensity: VisualDensity.compact, constraints: const BoxConstraints(minWidth: 30, minHeight: 29), padding: EdgeInsets.zero, onPressed: value > 1 ? () => onChanged(value - 1) : null, icon: const Icon(Icons.remove, color: Colors.white, size: 16)),
          Text('$value', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
          IconButton(visualDensity: VisualDensity.compact, constraints: const BoxConstraints(minWidth: 30, minHeight: 29), padding: EdgeInsets.zero, onPressed: value < 20 ? () => onChanged(value + 1) : null, icon: const Icon(Icons.add, color: Colors.white, size: 16)),
        ]),
      );
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.width, required this.label, required this.value, required this.hint, required this.icon, required this.tint, required this.iconColor, required this.onTap});
  final double width;
  final String label;
  final String value;
  final String hint;
  final IconData icon;
  final Color tint;
  final Color iconColor;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Container(
        width: width,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: const Color(0xFFFFFEFB), borderRadius: BorderRadius.circular(17), border: Border.all(color: const Color(0xFFE5E9E1))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Container(width: 30, height: 30, decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: iconColor, size: 17)), const Spacer(), Text(value, style: const TextStyle(color: ink, fontWeight: FontWeight.w900, fontSize: 22))]),
          const SizedBox(height: 7), Text(label, style: const TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 11)),
          Text(hint, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 9)),
        ]),
          ),
        ),
      );
}

class _ZoneProgressCard extends StatelessWidget {
  const _ZoneProgressCard({required this.title, required this.subtitle, required this.icon, required this.complete, required this.total, required this.progress, required this.onTap});
  final String title;
  final String subtitle;
  final IconData icon;
  final int complete;
  final int total;
  final double progress;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFFFFFEFB), borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE5E9E1))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Container(width: 32, height: 32, decoration: BoxDecoration(color: greenSoft, borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: greenDark, size: 18)), const Spacer(), Icon(Icons.arrow_forward_ios_rounded, color: muted.withOpacity(.65), size: 13)]),
            const SizedBox(height: 9),
            Text(title, style: const TextStyle(color: ink, fontWeight: FontWeight.w900, fontSize: 12)),
            Text(subtitle, style: const TextStyle(color: muted, fontSize: 9)),
            const SizedBox(height: 10),
            ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: progress, minHeight: 6, backgroundColor: const Color(0xFFEDF0E9), color: green)),
            const SizedBox(height: 5),
            Text('$complete / $total objectifs atteints', style: const TextStyle(color: muted, fontSize: 9, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(color: const Color(0xFFFFFEFB), borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE5E9E1))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text(title, style: const TextStyle(color: ink, fontSize: 15, fontWeight: FontWeight.w900))), if (trailing != null) trailing!]),
          const SizedBox(height: 12),
          child,
        ]),
      );
}

class _AlertsList extends StatelessWidget {
  const _AlertsList({required this.controller});
  final ReserveController controller;
  @override
  Widget build(BuildContext context) {
    final alerts = <Widget>[];
    if (controller.unknownItems.isNotEmpty) {
      alerts.add(_AlertLine(icon: Icons.edit_note_rounded, text: '${controller.unknownItems.length} stock(s) à renseigner pour activer le suivi et calculer les besoins.', color: blue));
    }
    for (final item in controller.lowItems.take(4)) {
      alerts.add(_AlertLine(icon: Icons.shopping_cart_outlined, text: '${item.name} : ${formatNumber(item.stock!)} ${item.unit} sur ${formatNumber(controller.targetFor(item))} ${item.unit}.', color: amber));
    }
    for (final entry in controller.soonLots.take(5)) {
      final days = daysUntil(entry.lot.expiryDate!);
      final expiredDlc = days < 0 && entry.lot.dateType == 'DLC';
      final quantity = entry.lot.quantity == null ? 'quantité inconnue' : '${formatNumber(entry.lot.quantity!)} ${entry.item.unit}';
      alerts.add(_AlertLine(
        icon: expiredDlc ? Icons.warning_amber_rounded : Icons.event_outlined,
        text: '${entry.item.name} · $quantity — ${expiryMessageForLot(entry.lot)}',
        color: expiredDlc ? red : amber,
      ));
    }
    if (alerts.isEmpty) alerts.add(const _AlertLine(icon: Icons.check_circle_outline, text: 'Aucune alerte détectée dans les données saisies. Pense à vérifier physiquement les produits.', color: green));
    return Column(children: [for (var i = 0; i < alerts.length; i++) ...[if (i > 0) const SizedBox(height: 7), alerts[i]]]);
  }
}

class _AlertLine extends StatelessWidget {
  const _AlertLine({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: color.withOpacity(.08), borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, color: color, size: 17), const SizedBox(width: 8), Expanded(child: Text(text, style: const TextStyle(color: ink, fontSize: 10, height: 1.4)))]),
      );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(onPressed: onTap, icon: Icon(icon, size: 16), label: Text(label), style: OutlinedButton.styleFrom(foregroundColor: greenDark, side: const BorderSide(color: Color(0xFFDDE5DA)), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
}

class ZonePage extends StatelessWidget {
  const ZonePage({super.key, required this.controller, required this.zone});
  final ReserveController controller;
  final String zone;

  @override
  Widget build(BuildContext context) {
    final emergency = zone == 'emergency';
    final daily = zone == 'daily';
    final items = controller.inZone(zone);
    final groupedItems = <String, List<ReserveItem>>{};
    for (final item in items) {
      groupedItems.putIfAbsent(item.category, () => []).add(item);
    }
    final done = controller.completedInZone(zone);
    final progress = controller.progressInZone(zone);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 5, 18, 28),
      children: [
        _PageHeading(
          eyebrow: emergency ? 'PRIORITÉ SÉCURITÉ' : daily ? 'ÉPICERIE DU QUOTIDIEN' : 'RÉSERVE ALIMENTAIRE',
          title: emergency ? 'Kit d’urgence 72 heures' : daily ? 'Garde-manger' : 'Réserve de 15 jours',
          subtitle: emergency
              ? 'Des aliments non périssables, prêts à consommer si la cuisson ou l’électricité ne sont plus disponibles.'
              : daily
                  ? 'Les produits utilisés au quotidien : épicerie, condiments, boissons et ingrédients courants.'
                  : 'Un stock de sécurité distinct du garde-manger, complémentaire au kit 72 h.',
          icon: emergency ? Icons.backpack_outlined : daily ? Icons.kitchen_outlined : Icons.inventory_2_outlined,
        ),
        Align(alignment: Alignment.centerRight, child: OutlinedButton.icon(
          onPressed: () => showFoodCatalog(context, controller, zone),
          icon: const Icon(Icons.add_circle_outline_rounded, size: 17),
          label: const Text('Ajouter un aliment du catalogue'),
          style: OutlinedButton.styleFrom(foregroundColor: greenDark, side: const BorderSide(color: Color(0xFFDDE5DA), width: 1), textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
        )),
        const SizedBox(height: 8),
        _SectionCard(
          title: 'Progression du foyer',
          trailing: Text('$done / ${items.length}', style: const TextStyle(color: greenDark, fontWeight: FontWeight.w900, fontSize: 12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: progress, minHeight: 8, color: green, backgroundColor: const Color(0xFFEDF0E9))),
            const SizedBox(height: 7),
            Text('${(progress * 100).round()} % des références atteignent leur objectif. Les quantités réelles restent à saisir.', style: const TextStyle(color: muted, fontSize: 10)),
          ]),
        ),
        const SizedBox(height: 12),
        if (emergency) ...[
          const _InfoBanner(icon: Icons.lightbulb_outline, text: 'Pour une personne : au moins 6 litres d’eau pour 72 heures. Ce kit est une réserve dédiée, séparée du stock alimentaire de 15 jours. Privilégie des aliments consommables froids et garde un ouvre-boîte manuel avec le kit.', color: blue),
          const SizedBox(height: 12),
        ] else if (daily) ...[
          const _InfoBanner(icon: Icons.kitchen_outlined, text: 'Le garde-manger correspond aux produits que tu consommes habituellement. Il est distinct du kit 72 h et de la réserve de 15 jours : ses quantités servent à suivre les courses courantes, sans compter deux fois les mêmes produits.', color: blue),
          const SizedBox(height: 12),
        ],
        if (groupedItems.isEmpty) const _EmptyState(
          icon: Icons.kitchen_outlined,
          title: 'Garde-manger vide',
          text: 'Ajoute des produits du quotidien depuis le catalogue ou déplace une référence depuis l’inventaire.',
        ),
        for (final entry in groupedItems.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 2, 7),
            child: Row(children: [
              _FoodAvatar(emoji: categoryEmoji(entry.key), size: 31),
              const SizedBox(width: 8),
              Expanded(child: Text(categoryName(entry.key), style: const TextStyle(color: ink, fontSize: 12, fontWeight: FontWeight.w900))),
              Text('${entry.value.length} produit(s)', style: const TextStyle(color: muted, fontSize: 9, fontWeight: FontWeight.w700)),
            ]),
          ),
          for (final item in entry.value) ...[
            _ProductCard(item: item, controller: controller),
            const SizedBox(height: 8),
          ],
        ],
        if (!emergency && !daily) const _InfoBanner(icon: Icons.tips_and_updates_outlined, text: 'Cette réserve de 15 jours est complémentaire au kit 72 h : elle ne le remplace pas. Les quantités de cette page viennent en plus des produits dédiés au kit. Pour une personne : 12 boîtes de légumes et légumineuses, 11 portions de poissons et protéines, 9 plats et bases de cuisine, 6 kg de féculents et 12 portions de petit-déjeuner/énergie. Ajuste ces objectifs selon tes habitudes.', color: green),
      ],
    );
  }
}

class _PageHeading extends StatelessWidget {
  const _PageHeading({required this.eyebrow, required this.title, required this.subtitle, required this.icon});
  final String eyebrow;
  final String title;
  final String subtitle;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14, top: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(eyebrow, style: const TextStyle(color: green, fontWeight: FontWeight.w900, fontSize: 9, letterSpacing: 1.2)),
            const SizedBox(height: 4), Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 5), Text(subtitle, style: const TextStyle(color: muted, fontSize: 11, height: 1.5)),
          ])),
          const SizedBox(width: 10),
          Container(width: 44, height: 44, decoration: BoxDecoration(color: greenSoft, borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: greenDark, size: 23)),
        ]),
      );
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.item, required this.controller});
  final ReserveItem item;
  final ReserveController controller;
  @override
  Widget build(BuildContext context) {
    final target = controller.targetFor(item);
    final stock = item.stock;
    final percent = stock == null || target <= 0 ? 0.0 : (stock / target).clamp(0.0, 1.0).toDouble();
    final enough = stock != null && stock >= target;
    final color = stock == null ? blue : enough ? green : amber;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => showItemEditor(context, controller, item),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(color: const Color(0xFFFFFEFB), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE5E9E1))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _FoodAvatar(emoji: item.displayEmoji, size: 38),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: const TextStyle(color: ink, fontWeight: FontWeight.w900, fontSize: 12)),
            if (item.notes.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Text(item.notes, style: const TextStyle(color: muted, fontSize: 9, height: 1.4))),
          ])),
          const SizedBox(width: 8),
          _StatusPill(label: stock == null ? 'À renseigner' : enough ? 'Objectif atteint' : 'À compléter', color: color),
        ]),
        const SizedBox(height: 11),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(stock == null ? 'Stock réel : non renseigné' : 'Stock réel : ${formatNumber(stock)} ${item.unit}', style: const TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 10)),
            const SizedBox(height: 2), Text('Objectif : ${formatNumber(target)} ${item.unit}${item.perPerson ? ' · ${formatNumber(item.target)} / personne' : ' · foyer'}', style: const TextStyle(color: muted, fontSize: 9)),
          ])),
          FilledButton.tonalIcon(onPressed: () => showItemEditor(context, controller, item), icon: const Icon(Icons.edit_outlined, size: 15), label: const Text('Saisir', style: TextStyle(fontSize: 10)), style: FilledButton.styleFrom(foregroundColor: greenDark, backgroundColor: greenSoft, padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8), visualDensity: VisualDensity.compact)),
          IconButton(tooltip: 'Déplacer vers une autre réserve', visualDensity: VisualDensity.compact, onPressed: () => showMoveItemDialog(context, controller, item), icon: const Icon(Icons.swap_horiz_rounded, color: blue, size: 18)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: percent, minHeight: 5, backgroundColor: const Color(0xFFEDF0E9), color: color)),
        if (item.activeDatedLots.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 7), child: Row(children: [const Icon(Icons.event_outlined, size: 13, color: muted), const SizedBox(width: 5), Text('Prochaine date · ${formatDate(item.activeDatedLots.map((lot) => lot.expiryDate!).reduce((a, b) => a.isBefore(b) ? a : b))} · ${item.activeDatedLots.length} lot(s)', style: const TextStyle(color: muted, fontSize: 9))])),
          ]),
        ),
      ),
    );
  }
}

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key, required this.controller, this.initialFilter = 'all'});
  final ReserveController controller;
  final String initialFilter;
  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final searchController = TextEditingController();
  String zoneFilter = 'all';
  String sortFilter = 'date';
  String statusFilter = 'all';

  @override
  void initState() {
    super.initState();
    statusFilter = widget.initialFilter;
  }

  @override
  void didUpdateWidget(covariant InventoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialFilter != widget.initialFilter) {
      statusFilter = widget.initialFilter;
      zoneFilter = 'all';
      searchController.clear();
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = searchController.text.trim().toLowerCase();
    final rows = widget.controller.activeItems.where((item) {
      final matchesQuery = query.isEmpty || '${item.name} ${item.notes}'.toLowerCase().contains(query);
      final matchesZone = zoneFilter == 'all' || item.zone == zoneFilter;
      final matchesStatus = statusFilter == 'all' ||
          (statusFilter == 'unknown' && item.stock == null) ||
          (statusFilter == 'low' && item.stock != null && item.stock! < widget.controller.targetFor(item));
      return matchesQuery && matchesZone && matchesStatus;
    }).toList();
    rows.sort((a, b) {
      switch (sortFilter) {
        case 'name': return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'low':
          final aGap = a.stock == null ? double.infinity : a.stock! - widget.controller.targetFor(a);
          final bGap = b.stock == null ? double.infinity : b.stock! - widget.controller.targetFor(b);
          return aGap.compareTo(bGap);
        case 'zone': return a.zone.compareTo(b.zone);
        default:
          if (a.expiryDate == null) return b.expiryDate == null ? a.name.compareTo(b.name) : 1;
          if (b.expiryDate == null) return -1;
          return a.expiryDate!.compareTo(b.expiryDate!);
      }
    });
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 5, 18, 28),
      children: [
        _PageHeading(eyebrow: 'TOUT AU MÊME ENDROIT', title: 'Inventaire', subtitle: 'Renseigne ce que tu possèdes réellement. Les objectifs sont préremplis et s’adaptent à la taille du foyer.', icon: Icons.checklist_rounded),
        Row(children: [
          Expanded(child: TextField(controller: searchController, onChanged: (_) => setState(() {}), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Rechercher un produit…', isDense: true))),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Ajouter un produit libre',
            onPressed: () => showItemEditor(context, widget.controller, null),
            icon: const Icon(Icons.add_circle_outline_rounded, color: greenDark),
          ),
          FilledButton.icon(onPressed: () => showFoodCatalog(context, widget.controller, zoneFilter == 'emergency' || zoneFilter == 'reserve' ? zoneFilter : 'reserve'), icon: const Icon(Icons.restaurant_menu_rounded, size: 17), label: const Text('Catalogue'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15), textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 7, runSpacing: 6, children: [
          _InventoryFilterChip(label: 'Tout', selected: statusFilter == 'all', onTap: () => setState(() => statusFilter = 'all')),
          _InventoryFilterChip(label: 'À renseigner · ${widget.controller.unknownItems.length}', selected: statusFilter == 'unknown', onTap: () => setState(() => statusFilter = 'unknown')),
          _InventoryFilterChip(label: 'À compléter · ${widget.controller.lowItems.length}', selected: statusFilter == 'low', onTap: () => setState(() => statusFilter = 'low')),
        ]),
        const SizedBox(height: 9),
        Row(children: [
          Expanded(child: DropdownButtonFormField<String>(value: zoneFilter, isDense: true, decoration: const InputDecoration(labelText: 'Zone', isDense: true), items: const [DropdownMenuItem(value: 'all', child: Text('Toutes les zones')), DropdownMenuItem(value: 'emergency', child: Text('Kit 72 h')), DropdownMenuItem(value: 'reserve', child: Text('Réserve 15 jours')), DropdownMenuItem(value: 'daily', child: Text('Garde-manger'))], onChanged: (value) => setState(() => zoneFilter = value ?? 'all'))),
          const SizedBox(width: 8),
          Expanded(child: DropdownButtonFormField<String>(value: sortFilter, isDense: true, decoration: const InputDecoration(labelText: 'Trier par', isDense: true), items: const [DropdownMenuItem(value: 'date', child: Text('Date la plus proche')), DropdownMenuItem(value: 'name', child: Text('Nom')), DropdownMenuItem(value: 'low', child: Text('Stock insuffisant')), DropdownMenuItem(value: 'zone', child: Text('Zone'))], onChanged: (value) => setState(() => sortFilter = value ?? 'date'))),
        ]),
        const SizedBox(height: 12),
        Row(children: [Text('${rows.length} produit(s) affiché(s)', style: const TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w700)), const Spacer(), Text('${widget.controller.activeItems.length} références au total', style: const TextStyle(color: muted, fontSize: 10))]),
        const SizedBox(height: 8),
        if (rows.isEmpty) const _EmptyState(icon: Icons.search_off, title: 'Aucun produit', text: 'Essaie une autre recherche ou ajoute une référence.'),
        for (final item in rows) ...[
          _InventoryItemCard(item: item, controller: widget.controller),
          const SizedBox(height: 8),
        ],
        if (widget.controller.legacySummaryItems.isNotEmpty && statusFilter == 'all' && zoneFilter == 'all' && query.isEmpty) ...[
          const SizedBox(height: 14),
          _SectionCard(
            title: 'Anciens totaux conservés',
            child: Column(children: [
              const _InfoBanner(icon: Icons.info_outline, text: 'Ces anciennes lignes globales ont été conservées lors de la mise à jour pour ne perdre aucune quantité saisie. Elles ne sont plus comptées dans les objectifs détaillés.', color: blue),
              const SizedBox(height: 8),
              for (final item in widget.controller.legacySummaryItems) ...[
                _InventoryItemCard(item: item, controller: widget.controller),
                const SizedBox(height: 7),
              ],
            ]),
          ),
        ],
        const SizedBox(height: 8),
        const _InfoBanner(icon: Icons.info_outline, text: 'Laisse le stock réel vide tant que tu n’as pas compté le produit. Une quantité inconnue n’est jamais considérée comme un stock suffisant.', color: blue),
      ],
    );
  }
}


class _InventoryFilterChip extends StatelessWidget {
  const _InventoryFilterChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        selectedColor: greenSoft,
        backgroundColor: const Color(0xFFFFFEFB),
        side: BorderSide(color: selected ? const Color(0xFFC9DDC6) : const Color(0xFFE5E9E1)),
        labelStyle: TextStyle(color: selected ? greenDark : muted),
        visualDensity: VisualDensity.compact,
      );
}

class _FoodAvatar extends StatelessWidget {
  const _FoodAvatar({required this.emoji, this.size = 36});
  final String emoji;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: greenSoft.withOpacity(.8), borderRadius: BorderRadius.circular(size * .32)),
        child: Text(emoji, style: TextStyle(fontSize: size * .48)),
      );
}

class _InventoryItemCard extends StatelessWidget {
  const _InventoryItemCard({required this.item, required this.controller});
  final ReserveItem item;
  final ReserveController controller;
  @override
  Widget build(BuildContext context) {
    final target = controller.targetFor(item);
    final status = item.stock == null ? 'À renseigner' : item.stock! < target ? 'À compléter' : 'Objectif atteint';
    final color = item.stock == null ? blue : item.stock! < target ? amber : green;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFFFFEFB), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFE5E9E1))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _FoodAvatar(emoji: item.displayEmoji, size: 36),
          const SizedBox(width: 9),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item.name, style: const TextStyle(color: ink, fontWeight: FontWeight.w900, fontSize: 12)), const SizedBox(height: 3), Text('${zoneName(item.zone)} · ${categoryName(item.category)}', style: const TextStyle(color: muted, fontSize: 9))])),
          _StatusPill(label: item.isLegacySummary ? 'Ancien total' : status, color: item.isLegacySummary ? blue : color),
        ]),
        const SizedBox(height: 9),
        Wrap(spacing: 14, runSpacing: 6, children: [
          _SmallInfo(label: 'Stock', value: item.stock == null ? 'Non renseigné' : '${formatNumber(item.stock!)} ${item.unit}'),
          _SmallInfo(label: 'Objectif foyer', value: '${formatNumber(target)} ${item.unit}'),
          if (item.expiryDate != null) _SmallInfo(label: item.dateType, value: formatDate(item.expiryDate!)),
        ]),
        const SizedBox(height: 7),
        Row(children: [
          if (item.notes.isNotEmpty) Expanded(child: Text(item.notes, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 9))),
          if (item.notes.isNotEmpty) const Spacer(),
          if (!item.isLegacySummary) IconButton(visualDensity: VisualDensity.compact, tooltip: 'Déplacer sans perdre le stock', onPressed: () => showMoveItemDialog(context, controller, item), icon: const Icon(Icons.swap_horiz_rounded, size: 18, color: blue)),
          IconButton(visualDensity: VisualDensity.compact, tooltip: 'Modifier', onPressed: () => showItemEditor(context, controller, item), icon: const Icon(Icons.edit_outlined, size: 18, color: greenDark)),
          IconButton(visualDensity: VisualDensity.compact, tooltip: 'Supprimer', onPressed: () => confirmDelete(context, controller, item), icon: const Icon(Icons.delete_outline, size: 18, color: red)),
        ]),
      ]),
    );
  }
}

class _SmallInfo extends StatelessWidget {
  const _SmallInfo({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label.toUpperCase(), style: const TextStyle(color: muted, fontSize: 8, letterSpacing: .5, fontWeight: FontWeight.w900)), Text(value, style: const TextStyle(color: ink, fontSize: 10, fontWeight: FontWeight.w800))]);
}

class FollowUpPage extends StatelessWidget {
  const FollowUpPage({super.key, required this.controller});
  final ReserveController controller;

  @override
  Widget build(BuildContext context) {
    final checks = controller.checks[ReserveController.monthKey] ?? {};
    final done = controller.thisMonthDone;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 5, 18, 28),
      children: [
        const _PageHeading(eyebrow: 'GARDER LE STOCK SOUS CONTRÔLE', title: 'Suivi & entretien', subtitle: 'Dates de conservation, rotation, réapprovisionnement et contrôle mensuel.', icon: Icons.event_note_rounded),
        _SectionCard(
          title: 'Rotation des produits · FEFO',
          trailing: Text('${controller.datedLots.length} lot(s) daté(s)', style: const TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w700)),
          child: controller.datedLots.isEmpty
              ? const _EmptyState(icon: Icons.calendar_month_outlined, title: 'Aucune date saisie', text: 'Ajoute un ou plusieurs lots avec leur date DLC ou DDM dans la fiche produit.')
              : Column(children: [
                  const _InfoBanner(icon: Icons.swap_vert_rounded, text: 'FEFO : « First Expired, First Out ». Range devant les produits dont la date arrive le plus tôt et utilise-les en premier.', color: green),
                  const SizedBox(height: 9),
                  for (final entry in controller.datedLots) _ExpiryRow(entry: entry, controller: controller),
                ]),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Liste de courses',
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('${controller.shoppingNeedCount} besoin(s)', style: const TextStyle(color: amber, fontSize: 10, fontWeight: FontWeight.w800)),
            const SizedBox(width: 5),
            IconButton(
              tooltip: 'Copier la liste de courses',
              visualDensity: VisualDensity.compact,
              onPressed: () => copyShoppingList(context, controller),
              icon: const Icon(Icons.copy_rounded, size: 17, color: greenDark),
            ),
          ]),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _InfoBanner(
              icon: Icons.shopping_basket_outlined,
              text: 'La liste calcule les quantités manquantes séparément pour le kit 72 h, la réserve de 15 jours et le garde-manger. Un même produit physique ne doit jamais être compté dans deux espaces.',
              color: blue,
            ),
            const SizedBox(height: 10),
            _ShoppingZoneSection(
              controller: controller,
              zone: 'emergency',
              title: 'Achats prioritaires · Kit 72 h',
              subtitle: 'À acheter en premier pour compléter le kit d’urgence.',
              icon: Icons.backpack_outlined,
              color: red,
              emptyText: 'Aucun achat prioritaire calculable : les objectifs du kit sont atteints ou les stocks restent à compter.',
            ),
            const SizedBox(height: 10),
            _ShoppingZoneSection(
              controller: controller,
              zone: 'reserve',
              title: 'Réapprovisionnement · Réserve 15 jours',
              subtitle: 'Stock complémentaire pour tenir dans la durée.',
              icon: Icons.inventory_2_outlined,
              color: amber,
              emptyText: 'Aucun réapprovisionnement calculable pour la réserve de 15 jours.',
            ),
            const SizedBox(height: 10),
            _ShoppingZoneSection(
              controller: controller,
              zone: 'daily',
              title: 'Achats complémentaires · Garde-manger',
              subtitle: 'Produits du quotidien que tu souhaites garder en avance.',
              icon: Icons.kitchen_outlined,
              color: blue,
              emptyText: 'Aucun produit dans le garde-manger. Ajoute des produits du quotidien depuis le catalogue ou déplace-les depuis l’inventaire.',
            ),
            if (controller.unknownItems.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('À compter avant achat (${controller.unknownItems.length})', style: const TextStyle(color: blue, fontSize: 11, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              const Text('Un stock inconnu n’est pas considéré comme un manque : compte d’abord les produits, puis la quantité à acheter sera calculée.', style: TextStyle(color: muted, fontSize: 9, height: 1.4)),
              const SizedBox(height: 7),
              for (final zone in ['emergency', 'reserve', 'daily'])
                if (controller.unknownItemsInZone(zone).isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 5, bottom: 4),
                    child: Text(zoneName(zone), style: const TextStyle(color: ink, fontSize: 9, fontWeight: FontWeight.w900)),
                  ),
                  for (final item in controller.unknownItemsInZone(zone))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Row(children: [
                        Text(item.displayEmoji, style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 7),
                        Expanded(child: Text(item.name, style: const TextStyle(color: ink, fontSize: 9))),
                        Text('Objectif ${formatNumber(controller.targetFor(item))} ${item.unit}', style: const TextStyle(color: muted, fontSize: 8)),
                        IconButton(
                          tooltip: 'Compter ce produit',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                          onPressed: () => showItemEditor(context, controller, item),
                          icon: const Icon(Icons.edit_note_rounded, size: 16, color: blue),
                        ),
                      ]),
                    ),
                ],
            ],
            if (controller.soonLots.isNotEmpty) ...[
              const SizedBox(height: 10),
              const _InfoBanner(
                icon: Icons.event_available_outlined,
                text: 'Les dates courtes sont signalées dans la rotation FEFO, mais ne déclenchent pas automatiquement un achat. Utilise d’abord les lots concernés et rachète seulement si le stock restant passe sous son objectif.',
                color: amber,
              ),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Contrôle mensuel',
          trailing: Text('${done} / ${monthlyChecks.length}', style: const TextStyle(color: greenDark, fontSize: 11, fontWeight: FontWeight.w900)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(monthLabel(DateTime.now()), style: const TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: done / monthlyChecks.length, minHeight: 7, backgroundColor: const Color(0xFFEDF0E9), color: green)),
            const SizedBox(height: 12),
            for (final check in monthlyChecks) _MonthlyCheckTile(check: check, checked: checks[check.id] == true, onChanged: (value) => controller.setMonthlyCheck(check.id, value)),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: () async {
              final confirm = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(title: const Text('Réinitialiser le contrôle ?'), content: const Text('Les cases de ce mois seront décochées. L’inventaire ne sera pas modifié.'), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Annuler')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Réinitialiser'))]));
              if (confirm == true) controller.resetMonthlyChecks();
            }, icon: const Icon(Icons.refresh, size: 15), label: const Text('Réinitialiser ce mois'), style: TextButton.styleFrom(foregroundColor: muted, textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)))),
          ]),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Les 7 principes d’une réserve bien gérée',
          child: const Column(children: [
            _GuideTile(number: '01', title: 'Préparer 72 heures', text: 'Eau potable, aliments non périssables consommables sans cuisson et ouvre-boîte manuel.', icon: Icons.backpack_outlined),
            _GuideTile(number: '02', title: 'Constituer 15 jours', text: 'Conserves, légumineuses, féculents, plats préparés et petits-déjeuners variés.', icon: Icons.inventory_2_outlined),
            _GuideTile(number: '03', title: 'Appliquer FEFO', text: 'Utiliser d’abord les produits dont la date arrive le plus tôt ; ranger les nouveaux achats derrière.', icon: Icons.swap_vert_rounded),
            _GuideTile(number: '04', title: 'Bien conserver', text: 'Endroit sec, frais, ventilé et à l’abri de la lumière. Protéger les produits secs de l’humidité et des nuisibles.', icon: Icons.warehouse_outlined),
            _GuideTile(number: '05', title: 'Tenir l’inventaire', text: 'Distinguer les quantités réelles des objectifs et noter les dates de conservation.', icon: Icons.fact_check_outlined),
            _GuideTile(number: '06', title: 'Séparer les espaces', text: 'Garde-manger courant, réserve de 15 jours et kit d’urgence de 72 heures : trois espaces distincts.', icon: Icons.inventory_2_outlined),
            _GuideTile(number: '07', title: 'Contrôler chaque mois', text: 'Vérifier l’eau, les quantités, les dates, les emballages et les besoins de réapprovisionnement.', icon: Icons.event_outlined),
          ]),
        ),
        const SizedBox(height: 12),
        const _InfoBanner(icon: Icons.info_outline, text: 'DLC (« à consommer jusqu’au ») : à respecter. DDM (« à consommer de préférence avant ») : concerne surtout la qualité ; après cette date, vérifier attentivement le produit et son emballage. Ne jamais consommer une conserve bombée, fuyante, très rouillée ou suspecte. Après ouverture, réfrigérer dans un récipient adapté et suivre les indications du fabricant.', color: blue),
      ],
    );
  }
}

class _ExpiryRow extends StatelessWidget {
  const _ExpiryRow({required this.entry, required this.controller});
  final DatedLot entry;
  final ReserveController controller;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    final lot = entry.lot;
    final days = daysUntil(lot.expiryDate!);
    final isDlcDanger = days < 0 && lot.dateType == 'DLC';
    final color = isDlcDanger ? red : days <= 60 ? amber : green;
    final label = days < 0 ? 'Dépassée' : days == 0 ? 'Aujourd’hui' : '$days j';
    final quantity = lot.quantity == null ? 'Quantité à renseigner' : '${formatNumber(lot.quantity!)} ${item.unit}';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Container(width: 34, height: 34, decoration: BoxDecoration(color: color.withOpacity(.10), borderRadius: BorderRadius.circular(10)), child: Icon(Icons.event_outlined, color: color, size: 17)),
        const SizedBox(width: 9),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${item.displayEmoji}  ${item.name}', style: const TextStyle(color: ink, fontSize: 10, fontWeight: FontWeight.w800)),
          Text('${lot.dateType} · ${formatDate(lot.expiryDate!)} · $quantity${lot.batchDate == null ? '' : ' · lot du ${formatDate(lot.batchDate!)}'}', style: const TextStyle(color: muted, fontSize: 9)),
        ])),
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          _StatusPill(label: label, color: color),
          if (lot.quantity != null) TextButton(
            onPressed: () => showRemoveFromLotDialog(context, controller, item, lot),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap, foregroundColor: greenDark),
            child: const Text('Sortir du stock', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800)),
          ),
        ]),
      ]),
    );
  }
}


Future<void> showRemoveFromLotDialog(BuildContext context, ReserveController controller, ReserveItem item, StockLot lot) async {
  final quantityController = TextEditingController(text: '1');
  final selectedQuantity = await showDialog<double>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Sortir une quantité de ce lot'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${item.displayEmoji} ${item.name}', style: const TextStyle(color: ink, fontWeight: FontWeight.w900)),
        const SizedBox(height: 5),
        Text('Lot : ${formatNumber(lot.quantity ?? 0)} ${item.unit} · ${lot.dateType} ${lot.expiryDate == null ? '' : formatDate(lot.expiryDate!)}', style: const TextStyle(color: muted, fontSize: 10)),
        const SizedBox(height: 12),
        TextField(controller: quantityController, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Quantité à sortir (${item.unit})')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Annuler')),
        FilledButton(onPressed: () {
          final value = double.tryParse(quantityController.text.trim().replaceAll(',', '.'));
          if (value == null || value <= 0 || lot.quantity == null || value > lot.quantity! + 0.000001) {
            ScaffoldMessenger.of(dialogContext).showSnackBar(const SnackBar(content: Text('Quantité invalide ou supérieure au lot.')));
            return;
          }
          Navigator.pop(dialogContext, value);
        }, child: const Text('Valider')),
      ],
    ),
  );
  quantityController.dispose();
  if (selectedQuantity == null || !context.mounted) return;
  final success = await controller.removeFromLot(item.id, lot.id, selectedQuantity);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success ? 'Quantité sortie du lot. Stock total actualisé.' : 'La sortie du lot n’a pas pu être enregistrée.')));
}

class _ShoppingZoneSection extends StatelessWidget {
  const _ShoppingZoneSection({
    required this.controller,
    required this.zone,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.emptyText,
  });

  final ReserveController controller;
  final String zone;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final needs = controller.lowItemsInZone(zone);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFEFB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E9E1)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(color: color.withOpacity(.11), borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, color: color, size: 17),
          ),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: ink, fontSize: 10, fontWeight: FontWeight.w900)),
            Text(subtitle, style: const TextStyle(color: muted, fontSize: 8, height: 1.3)),
          ])),
          _StatusPill(label: '${needs.length} à acheter', color: needs.isEmpty ? green : color),
        ]),
        const SizedBox(height: 7),
        if (needs.isEmpty)
          Text(emptyText, style: const TextStyle(color: muted, fontSize: 9, height: 1.4))
        else
          for (final item in needs) _ShoppingRow(item: item, controller: controller, color: color),
      ]),
    );
  }
}

class _ShoppingRow extends StatelessWidget {
  const _ShoppingRow({required this.item, required this.controller, required this.color});
  final ReserveItem item;
  final ReserveController controller;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final target = controller.targetFor(item);
    final gap = (target - (item.stock ?? 0)).clamp(0.0, double.infinity).toDouble();
    return InkWell(
      onTap: () => showItemEditor(context, controller, item),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(children: [
          Text(item.displayEmoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: const TextStyle(color: ink, fontSize: 9, fontWeight: FontWeight.w800)),
            Text('Stock : ${formatNumber(item.stock!)} ${item.unit} · objectif : ${formatNumber(target)} ${item.unit}', style: const TextStyle(color: muted, fontSize: 8)),
          ])),
          Text('+ ${formatNumber(gap)} ${item.unit}', style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w900)),
          const SizedBox(width: 3),
          const Icon(Icons.edit_outlined, color: muted, size: 13),
        ]),
      ),
    );
  }
}

Future<void> copyShoppingList(BuildContext context, ReserveController controller) async {
  final buffer = StringBuffer('MA RÉSERVE — LISTE DE COURSES\n');
  final sections = <(String, String)>[
    ('ACHATS PRIORITAIRES — KIT 72 H', 'emergency'),
    ('RÉAPPROVISIONNEMENT — RÉSERVE 15 JOURS', 'reserve'),
    ('ACHATS COMPLÉMENTAIRES — GARDE-MANGER', 'daily'),
  ];
  var hasPurchase = false;
  for (final section in sections) {
    final needs = controller.lowItemsInZone(section.$2);
    if (needs.isEmpty) continue;
    hasPurchase = true;
    buffer.writeln('\n${section.$1}');
    for (final item in needs) {
      final gap = (controller.targetFor(item) - (item.stock ?? 0)).clamp(0.0, double.infinity).toDouble();
      buffer.writeln('- ${item.name} : acheter ${formatNumber(gap)} ${item.unit} (stock ${formatNumber(item.stock!)} / objectif ${formatNumber(controller.targetFor(item))})');
    }
  }
  if (!hasPurchase) buffer.writeln('\nAucun achat calculable : objectifs atteints ou stocks à compter.');
  final unknown = controller.unknownItems;
  if (unknown.isNotEmpty) {
    buffer.writeln('\nÀ COMPTER AVANT ACHAT (non inclus dans les quantités à acheter)');
    for (final item in unknown) {
      buffer.writeln('- ${zoneName(item.zone)} — ${item.name} (objectif ${formatNumber(controller.targetFor(item))} ${item.unit})');
    }
  }
  buffer.writeln('\nNote : utiliser d’abord les lots dont la date arrive le plus tôt (FEFO). Une date proche ne déclenche pas automatiquement un nouvel achat.');
  await Clipboard.setData(ClipboardData(text: buffer.toString()));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Liste de courses copiée.')));
  }
}

class _MonthlyCheckTile extends StatelessWidget {
  const _MonthlyCheckTile({required this.check, required this.checked, required this.onChanged});
  final MonthlyCheck check;
  final bool checked;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 7),
        decoration: BoxDecoration(color: checked ? const Color(0xFFF1F7F0) : const Color(0xFFFAFBF7), borderRadius: BorderRadius.circular(13), border: Border.all(color: checked ? const Color(0xFFD8E7D6) : const Color(0xFFE8ECE5))),
        child: CheckboxListTile(
          value: checked,
          onChanged: (value) => onChanged(value ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          activeColor: green,
          secondary: Icon(check.icon, color: checked ? green : muted, size: 18),
          title: Text(check.title, style: TextStyle(color: checked ? greenDark : ink, fontSize: 11, fontWeight: FontWeight.w900, decoration: checked ? TextDecoration.lineThrough : null)),
          subtitle: Text(check.description, style: const TextStyle(color: muted, fontSize: 9, height: 1.35)),
        ),
      );
}

class _GuideTile extends StatelessWidget {
  const _GuideTile({required this.number, required this.title, required this.text, required this.icon});
  final String number;
  final String title;
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 32, height: 32, decoration: BoxDecoration(color: greenSoft, borderRadius: BorderRadius.circular(10)), child: Center(child: Text(number, style: const TextStyle(color: greenDark, fontSize: 10, fontWeight: FontWeight.w900)))),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Icon(icon, size: 14, color: green), const SizedBox(width: 5), Text(title, style: const TextStyle(color: ink, fontSize: 11, fontWeight: FontWeight.w900))]), const SizedBox(height: 2), Text(text, style: const TextStyle(color: muted, fontSize: 9, height: 1.45))])),
        ]),
      );
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withOpacity(.09), borderRadius: BorderRadius.circular(13)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, color: color, size: 17), const SizedBox(width: 8), Expanded(child: Text(text, style: const TextStyle(color: ink, fontSize: 10, height: 1.45)))]),
      );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), decoration: BoxDecoration(color: color.withOpacity(.10), borderRadius: BorderRadius.circular(8)), child: Text(label, style: TextStyle(color: color, fontSize: 8, fontWeight: FontWeight.w900)));
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20), decoration: BoxDecoration(color: cream, borderRadius: BorderRadius.circular(13)), child: Column(children: [Icon(icon, color: muted, size: 25), const SizedBox(height: 7), Text(title, style: const TextStyle(color: ink, fontWeight: FontWeight.w900, fontSize: 11)), const SizedBox(height: 3), Text(text, textAlign: TextAlign.center, style: const TextStyle(color: muted, fontSize: 9, height: 1.4))]));
}

Future<void> showItemEditor(BuildContext context, ReserveController controller, ReserveItem? original, {FoodTemplate? template, String? defaultZone}) async {
  final saved = await showDialog<ReserveItem>(context: context, barrierDismissible: false, builder: (context) => ItemEditorDialog(original: original, people: controller.people, template: template, defaultZone: defaultZone));
  if (saved == null || !context.mounted) return;
  final wasSaved = await controller.saveItem(saved);
  if (!context.mounted) return;
  final storageMessage = controller.storageWarning;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(!wasSaved
        ? 'Un produit de même nom existe déjà dans cette réserve. Modifie son nom ou sa zone.'
        : storageMessage == null
            ? (original == null ? 'Produit ajouté à l’inventaire et au catalogue. Sauvegarde effectuée.' : 'Produit mis à jour et sauvegardé.')
            : 'Modification appliquée à l’écran, mais sauvegarde à vérifier : $storageMessage'),
    duration: const Duration(seconds: 4),
  ));
}

class FoodTemplate {
  const FoodTemplate({required this.name, required this.category, required this.target, required this.unit, this.notes = '', this.emoji = '', this.sourceItemId});
  final String name;
  final String category;
  final double target;
  final String unit;
  final String notes;
  final String emoji;
  final String? sourceItemId;

  String get displayEmoji => emoji.isNotEmpty ? emoji : foodEmoji(name, category);

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category,
        'target': target,
        'unit': unit,
        'notes': notes,
        'emoji': displayEmoji,
        if (sourceItemId != null) 'sourceItemId': sourceItemId,
      };

  factory FoodTemplate.fromJson(Map<String, dynamic> json) => FoodTemplate(
        name: (json['name'] ?? 'Produit').toString(),
        category: (json['category'] ?? 'other').toString(),
        target: (json['target'] is num) ? (json['target'] as num).toDouble() : (double.tryParse('${json['target']}') ?? 1),
        unit: (json['unit'] ?? 'unités').toString(),
        notes: (json['notes'] ?? '').toString(),
        emoji: (json['emoji'] ?? '').toString(),
        sourceItemId: json['sourceItemId']?.toString(),
      );
}

const List<FoodTemplate> foodCatalog = [
  FoodTemplate(name: 'Haricots verts', category: 'vegetables', target: 2, unit: 'boîtes'),
  FoodTemplate(name: 'Petits pois', category: 'vegetables', target: 2, unit: 'boîtes'),
  FoodTemplate(name: 'Maïs doux', category: 'vegetables', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Carottes', category: 'vegetables', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Ratatouille', category: 'vegetables', target: 2, unit: 'boîtes'),
  FoodTemplate(name: 'Champignons', category: 'vegetables', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Lentilles cuisinées', category: 'legumes', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Pois chiches', category: 'legumes', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Haricots rouges', category: 'legumes', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Haricots blancs', category: 'legumes', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Thon au naturel', category: 'fish', target: 2, unit: 'portions'),
  FoodTemplate(name: 'Sardines à l’huile', category: 'fish', target: 2, unit: 'portions'),
  FoodTemplate(name: 'Maquereaux', category: 'fish', target: 2, unit: 'portions'),
  FoodTemplate(name: 'Saumon en conserve', category: 'fish', target: 1, unit: 'portion'),
  FoodTemplate(name: 'Volaille en conserve', category: 'protein', target: 2, unit: 'portions'),
  FoodTemplate(name: 'Pâté / terrine', category: 'protein', target: 2, unit: 'portions'),
  FoodTemplate(name: 'Soupe en brique', category: 'ready', target: 2, unit: 'briques'),
  FoodTemplate(name: 'Huile végétale', category: 'ready', target: 1, unit: 'bouteille'),
  FoodTemplate(name: 'Tomates pelées', category: 'ready', target: 2, unit: 'boîtes'),
  FoodTemplate(name: 'Sauce tomate', category: 'ready', target: 2, unit: 'bocaux'),
  FoodTemplate(name: 'Ravioli en conserve', category: 'ready', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Cassoulet', category: 'ready', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Chili aux haricots', category: 'ready', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Riz', category: 'starch', target: 2, unit: 'kg'),
  FoodTemplate(name: 'Pâtes', category: 'starch', target: 1.5, unit: 'kg'),
  FoodTemplate(name: 'Semoule / couscous', category: 'starch', target: 1, unit: 'kg'),
  FoodTemplate(name: 'Purée en flocons', category: 'starch', target: .5, unit: 'kg'),
  FoodTemplate(name: 'Farine', category: 'starch', target: .5, unit: 'kg'),
  FoodTemplate(name: 'Flocons d’avoine', category: 'starch', target: .5, unit: 'kg'),
  FoodTemplate(name: 'Compotes', category: 'breakfast', target: 3, unit: 'portions'),
  FoodTemplate(name: 'Lait UHT', category: 'breakfast', target: 3, unit: 'briques'),
  FoodTemplate(name: 'Café', category: 'breakfast', target: 1, unit: 'paquet'),
  FoodTemplate(name: 'Thé / infusions', category: 'breakfast', target: 1, unit: 'boîte'),
  FoodTemplate(name: 'Fruits au sirop', category: 'breakfast', target: 2, unit: 'portions'),
  FoodTemplate(name: 'Miel', category: 'breakfast', target: 1, unit: 'pot'),
  FoodTemplate(name: 'Biscuits secs', category: 'breakfast', target: 2, unit: 'portions'),
  FoodTemplate(name: 'Chocolat noir', category: 'breakfast', target: 2, unit: 'portions'),
  FoodTemplate(name: 'Fruits secs', category: 'snacks', target: 2, unit: 'portions'),
  FoodTemplate(name: 'Noix et amandes', category: 'snacks', target: 2, unit: 'portions'),
  FoodTemplate(name: 'Barres céréalières', category: 'snacks', target: 3, unit: 'unités'),
  FoodTemplate(name: 'Eau potable', category: 'water', target: 6, unit: 'L'),
  FoodTemplate(name: 'Ouvre-boîte manuel', category: 'other', target: 1, unit: 'unité', notes: 'À garder avec le kit d’urgence.'),
  FoodTemplate(name: 'Huile d’olive', category: 'condiments', target: 1, unit: 'bouteille', emoji: '🫒'),
  FoodTemplate(name: 'Vinaigre', category: 'condiments', target: 1, unit: 'bouteille', emoji: '🧴'),
  FoodTemplate(name: 'Sel', category: 'condiments', target: 1, unit: 'paquet', emoji: '🧂'),
  FoodTemplate(name: 'Sucre', category: 'condiments', target: 1, unit: 'kg', emoji: '🧂'),
  FoodTemplate(name: 'Moutarde', category: 'condiments', target: 1, unit: 'pot', emoji: '🟡'),
  FoodTemplate(name: 'Café', category: 'breakfast', target: 1, unit: 'paquet', emoji: '☕'),
  FoodTemplate(name: 'Thé et infusions', category: 'breakfast', target: 1, unit: 'boîte', emoji: '🍵'),
  FoodTemplate(name: 'Lait UHT', category: 'breakfast', target: 3, unit: 'briques', emoji: '🥛'),
];

Future<void> showFoodCatalog(BuildContext context, ReserveController controller, String zone) async {
  final emergency = zone == 'emergency';
  final templates = controller.catalogTemplates.where((item) {
    if (zone == 'daily') return item.name.toLowerCase() != 'ouvre-boîte manuel';
    if (!emergency) return true;
    // Le kit 72 h doit privilégier les produits consommables froids et le matériel.
    return {'water', 'vegetables', 'fish', 'protein', 'breakfast', 'starch', 'snacks', 'other'}.contains(item.category) &&
        !{'Riz', 'Pâtes', 'Semoule / couscous', 'Purée en flocons', 'Farine', 'Flocons d’avoine'}.contains(item.name);
  }).toList();
  final selected = await showDialog<FoodTemplate>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: const Color(0xFFFFFEFB),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: 620,
        height: MediaQuery.sizeOf(context).height * .78,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 17, 12, 12),
            child: Row(children: [
              const _FoodAvatar(emoji: '🧺', size: 42),
              const SizedBox(width: 11),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Catalogue alimentaire', style: Theme.of(context).textTheme.titleLarge),
                Text(emergency ? 'Choisis un aliment pour le kit 72 h' : zone == 'daily' ? 'Choisis un produit pour le garde-manger' : 'Choisis un produit pour la réserve de 15 jours', style: const TextStyle(color: muted, fontSize: 10)),
              ])),
              IconButton(onPressed: () => Navigator.pop(dialogContext), icon: const Icon(Icons.close_rounded)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              for (final category in ['water', 'vegetables', 'legumes', 'fish', 'protein', 'ready', 'starch', 'breakfast', 'snacks', 'condiments', 'other'])
                if (templates.any((item) => item.category == category)) ...[
                  Padding(padding: const EdgeInsets.fromLTRB(3, 8, 3, 7), child: Row(children: [Text(categoryEmoji(category), style: const TextStyle(fontSize: 17)), const SizedBox(width: 7), Text(categoryName(category), style: const TextStyle(color: ink, fontSize: 12, fontWeight: FontWeight.w900))])),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final item in templates.where((entry) => entry.category == category))
                      SizedBox(width: 174, child: Material(
                        color: cream,
                        borderRadius: BorderRadius.circular(13),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(13),
                          onTap: () => Navigator.pop(dialogContext, item),
                          child: Padding(padding: const EdgeInsets.all(10), child: Row(children: [
                            Text(item.displayEmoji, style: const TextStyle(fontSize: 22)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(item.name, style: const TextStyle(color: ink, fontSize: 10, fontWeight: FontWeight.w800), maxLines: 2, overflow: TextOverflow.ellipsis)),
                            const Icon(Icons.add_circle_outline, color: green, size: 16),
                          ])),
                        ),
                      )),
                  ]),
                ],
            ],
          )),
        ]),
      ),
    ),
  );
  if (selected != null && context.mounted) {
    ReserveItem? existing;
    for (final item in controller.items) {
      if (!item.isLegacySummary && item.zone == zone && item.name.trim().toLowerCase() == selected.name.trim().toLowerCase()) {
        existing = item;
        break;
      }
    }
    if (existing != null) {
      await showItemEditor(context, controller, existing);
    } else {
      await showItemEditor(context, controller, null, template: selected, defaultZone: zone);
    }
  }
}

String categoryEmoji(String category) => switch (category) {
  'water' => '💧', 'vegetables' => '🥕', 'legumes' => '🫘', 'fish' => '🐟', 'protein' => '🍗',
  'ready' => '🍲', 'starch' => '🍚', 'breakfast' => '🍯', 'snacks' => '🥜', 'condiments' => '🧂', _ => '🧰',
};

String foodEmoji(String name, String category) {
  final n = name.toLowerCase().trim();
  // Les mots précis passent avant les familles génériques pour éviter les
  // associations incohérentes (ex. haricots verts ≠ légumineuses sèches).
  if (RegExp(r'\beau\b').hasMatch(n) || n.contains('eau potable') || n.contains('bouteille d’eau') || n.contains("bouteille d'eau")) return '💧';
  if (n.contains('ouvre-boîte') || n.contains('ouvre boite')) return '🛠️';
  if (n.contains('haricot vert')) return '🥬';
  if (n.contains('petit pois')) return '🫛';
  if (n.contains('maïs') || n.contains('mais doux')) return '🌽';
  if (n.contains('carotte')) return '🥕';
  if (n.contains('champignon')) return '🍄';
  if (n.contains('ratatouille')) return '🥘';
  if (n.contains('tomate')) return '🍅';
  if (n.contains('thon') || n.contains('sardine') || n.contains('maquereau') || n.contains('saumon') || n.contains('anchois') || n.contains('poisson')) return '🐟';
  if (n.contains('crevette') || n.contains('moule') || n.contains('fruits de mer')) return '🦐';
  if (n.contains('poulet') || n.contains('volaille') || n.contains('dinde')) return '🍗';
  if (n.contains('pâté') || n.contains('pate') || n.contains('terrine') || n.contains('viande') || n.contains('bœuf') || n.contains('boeuf') || n.contains('porc')) return '🥩';
  if (n.contains('lentille') || n.contains('pois chiche') || n.contains('haricot rouge') || n.contains('haricot blanc') || n.contains('flageolet')) return '🫘';
  if (n.contains('soupe') || n.contains('chili') || n.contains('cassoulet') || n.contains('ravioli') || n.contains('plat cuisiné')) return '🍲';
  if (n.contains('huile')) return '🫒';
  if (n.contains('vinaigre')) return '🧴';
  if (n.contains('sel') || n.contains('sucre')) return '🧂';
  if (n.contains('moutarde')) return '🟡';
  if (n.contains('riz')) return '🍚';
  if (n.contains('pâte') || n.contains('pates')) return '🍝';
  if (n.contains('semoule') || n.contains('couscous') || n.contains('avoine')) return '🥣';
  if (n.contains('purée') || n.contains('pomme de terre')) return '🥔';
  if (n.contains('farine') || n.contains('blé') || n.contains('ble')) return '🌾';
  if (n.contains('pain') || n.contains('biscotte') || n.contains('biscuit salé')) return '🍞';
  if (n.contains('biscuit') || n.contains('cookie')) return '🍪';
  if (n.contains('compote') || n.contains('pomme')) return '🍎';
  if (n.contains('fruits secs') || n.contains('noix') || n.contains('amande') || n.contains('cacahuète')) return '🥜';
  if (n.contains('fruit')) return '🍐';
  if (n.contains('miel')) return '🍯';
  if (n.contains('lait')) return '🥛';
  if (n.contains('café')) return '☕';
  if (n.contains('thé') || n.contains('infusion')) return '🍵';
  if (n.contains('barre céréalière') || n.contains('barre de céréales')) return '🥣';
  if (n.contains('chocolat')) return '🍫';
  if (n.contains('barre')) return '🥣';
  if (n.contains('conserve')) return '🥫';
  return categoryEmoji(category);
}

const List<String> foodEmojiChoices = [
  '💧', '🧃', '🥬', '🥕', '🌽', '🫛', '🥦', '🍅', '🍄', '🥘', '🫘', '🥜',
  '🐟', '🐠', '🦐', '🍗', '🥩', '🥚', '🍲', '🥣', '🥫', '🍚', '🍝', '🍞',
  '🥖', '🥔', '🌾', '🍎', '🍐', '🍊', '🍇', '🍯', '🥛', '☕', '🍵', '🍫',
  '🍪', '🫒', '🧰', '🛠️', '📦', '🧂',
];


class ItemEditorDialog extends StatefulWidget {
  const ItemEditorDialog({super.key, required this.original, required this.people, this.template, this.defaultZone});
  final ReserveItem? original;
  final int people;
  final FoodTemplate? template;
  final String? defaultZone;
  @override
  State<ItemEditorDialog> createState() => _ItemEditorDialogState();
}

class _ItemEditorDialogState extends State<ItemEditorDialog> {
  final formKey = GlobalKey<FormState>();
  late final TextEditingController nameController;
  late final TextEditingController targetController;
  late final TextEditingController unitController;
  late final TextEditingController notesController;
  late String category;
  late String zone;
  late bool perPerson;
  late String selectedEmoji;
  bool emojiManuallyChosen = false;
  List<StockLot> lots = [];

  @override
  void initState() {
    super.initState();
    final item = widget.original;
    nameController = TextEditingController(text: item?.name ?? widget.template?.name ?? '');
    targetController = TextEditingController(text: formatNumber(item?.target ?? widget.template?.target ?? 1));
    unitController = TextEditingController(text: item?.unit ?? widget.template?.unit ?? 'unités');
    notesController = TextEditingController(text: item?.notes ?? widget.template?.notes ?? '');
    category = item?.category ?? widget.template?.category ?? 'other';
    zone = item?.zone ?? widget.defaultZone ?? 'reserve';
    perPerson = item?.perPerson ?? true;
    selectedEmoji = item?.displayEmoji ?? widget.template?.displayEmoji ?? foodEmoji(nameController.text, category);
    emojiManuallyChosen = item != null;
    lots = item?.lots.map((lot) => lot.copy()).toList() ?? <StockLot>[];
  }

  @override
  void dispose() {
    nameController.dispose(); targetController.dispose(); unitController.dispose(); notesController.dispose();
    super.dispose();
  }

  Future<DateTime?> chooseDate(DateTime? current) => showDatePicker(
        context: context,
        initialDate: current ?? DateTime.now(),
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        locale: const Locale('fr', 'FR'),
        helpText: 'Choisir une date',
        cancelText: 'Annuler',
        confirmText: 'Valider',
      );

  double? parseNumber(String value) => double.tryParse(value.trim().replaceAll(',', '.'));

  Future<void> pickEmoji() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Choisir une icône'),
        content: SizedBox(
          width: 360,
          height: 300,
          child: GridView.builder(
            itemCount: foodEmojiChoices.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 6, mainAxisSpacing: 7, crossAxisSpacing: 7),
            itemBuilder: (context, index) {
              final emoji = foodEmojiChoices[index];
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.pop(dialogContext, emoji),
                child: Container(
                  decoration: BoxDecoration(
                    color: emoji == selectedEmoji ? greenSoft : cream,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: emoji == selectedEmoji ? green : const Color(0xFFE5E9E1), width: emoji == selectedEmoji ? 1.5 : 1),
                  ),
                  alignment: Alignment.center,
                  child: Text(emoji, style: const TextStyle(fontSize: 23)),
                ),
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Annuler'))],
      ),
    );
    if (choice != null && mounted) {
      setState(() {
        selectedEmoji = choice;
        emojiManuallyChosen = true;
      });
    }
  }

  void resetSuggestedEmoji() {
    setState(() {
      selectedEmoji = foodEmoji(nameController.text, category);
      emojiManuallyChosen = false;
    });
  }

  Future<void> addLot() async {
    final result = await showDialog<StockLot>(
      context: context,
      builder: (dialogContext) => const LotEditorDialog(),
    );
    if (result != null && mounted) setState(() => lots.add(result));
  }

  Future<void> editLot(int index) async {
    final result = await showDialog<StockLot>(
      context: context,
      builder: (dialogContext) => LotEditorDialog(original: lots[index]),
    );
    if (result != null && mounted) setState(() => lots[index] = result);
  }

  void removeLot(int index) {
    setState(() => lots.removeAt(index));
  }

  void submit() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final old = widget.original;
    final saved = ReserveItem(
      id: old?.id ?? 'custom-${DateTime.now().microsecondsSinceEpoch}',
      name: nameController.text.trim(),
      category: category,
      zone: zone,
      stock: null,
      target: parseNumber(targetController.text) ?? 1,
      unit: unitController.text.trim().isEmpty ? 'unités' : unitController.text.trim(),
      perPerson: perPerson,
      purchaseDate: null,
      expiryDate: null,
      dateType: 'DDM',
      notes: notesController.text.trim(),
      isLegacySummary: old?.isLegacySummary ?? false,
      emoji: selectedEmoji,
      history: old == null ? <StockHistoryEntry>[] : List<StockHistoryEntry>.from(old.history),
      lots: lots.map((lot) => lot.copy()).toList(),
    );
    saved.syncLotSummary();
    Navigator.pop(context, saved);
  }

  Widget buildLotsSection() {
    final knownQuantities = lots.where((lot) => lot.quantity != null).fold<double>(0, (sum, lot) => sum + lot.quantity!);
    final hasUnknownQuantity = lots.any((lot) => lot.quantity == null);
    final totalLabel = lots.isEmpty
        ? 'Stock non renseigné'
        : hasUnknownQuantity
            ? '${formatNumber(knownQuantities)} ${unitController.text} connus · total à préciser'
            : '${formatNumber(knownQuantities)} ${unitController.text} au total';
    final ordered = lots.asMap().entries.toList()
      ..sort((a, b) {
        final da = a.value.expiryDate;
        final db = b.value.expiryDate;
        if (da == null) return db == null ? 0 : 1;
        if (db == null) return -1;
        return da.compareTo(db);
      });
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('LOTS ET DATES DE CONSERVATION', style: TextStyle(color: greenDark, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: .5))),
        TextButton.icon(onPressed: addLot, icon: const Icon(Icons.add_circle_outline, size: 16), label: const Text('Ajouter un lot', style: TextStyle(fontSize: 10))),
      ]),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(color: greenSoft, borderRadius: BorderRadius.circular(11)),
        child: Row(children: [const Icon(Icons.inventory_2_outlined, color: greenDark, size: 17), const SizedBox(width: 7), Expanded(child: Text(totalLabel, style: const TextStyle(color: greenDark, fontSize: 10, fontWeight: FontWeight.w900))), Text('${lots.length} lot(s)', style: const TextStyle(color: muted, fontSize: 9))]),
      ),
      if (lots.isEmpty)
        const Padding(padding: EdgeInsets.only(top: 8), child: Text('Ajoute un lot pour saisir une quantité et sa propre date. Tu peux créer plusieurs lots pour le même produit.', style: TextStyle(color: muted, fontSize: 9, height: 1.4)))
      else ...[
        const SizedBox(height: 7),
        for (final entry in ordered)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(color: const Color(0xFFFFFEFB), border: Border.all(color: const Color(0xFFE5E9E1)), borderRadius: BorderRadius.circular(11)),
            child: Row(children: [
              const Icon(Icons.local_offer_outlined, size: 16, color: green),
              const SizedBox(width: 7),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(entry.value.quantity == null ? 'Quantité à renseigner' : entry.value.quantity == 0 ? 'Lot épuisé · 0 ${unitController.text}' : '${formatNumber(entry.value.quantity!)} ${unitController.text}', style: const TextStyle(color: ink, fontSize: 10, fontWeight: FontWeight.w900)),
                Text('${entry.value.batchDate == null ? 'Fabrication / achat non renseigné' : 'Fabriqué / acheté le ${formatDate(entry.value.batchDate!)}'} · ${entry.value.expiryDate == null ? 'Sans date saisie' : '${entry.value.dateType} ${formatDate(entry.value.expiryDate!)}'}', style: const TextStyle(color: muted, fontSize: 8.5)),
                if (entry.value.notes.isNotEmpty) Text(entry.value.notes, style: const TextStyle(color: muted, fontSize: 8)),
              ])),
              IconButton(tooltip: 'Modifier le lot', visualDensity: VisualDensity.compact, onPressed: () => editLot(entry.key), icon: const Icon(Icons.edit_outlined, size: 17, color: greenDark)),
              IconButton(tooltip: 'Supprimer le lot', visualDensity: VisualDensity.compact, onPressed: () => removeLot(entry.key), icon: const Icon(Icons.delete_outline, size: 17, color: red)),
            ]),
          ),
      ],
      const SizedBox(height: 3),
      const _InfoBanner(icon: Icons.swap_vert_rounded, text: 'Chaque lot possède sa propre quantité et sa propre date. Les alertes FEFO signalent chaque lot séparément ; le stock du produit est la somme des quantités connues.', color: blue),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 600;
    return AlertDialog(
      title: Text(widget.original == null ? 'Ajouter un produit' : 'Modifier le produit', style: const TextStyle(color: ink, fontWeight: FontWeight.w900, fontSize: 17)),
      content: SizedBox(
        width: wide ? 540 : double.maxFinite,
        child: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextFormField(
                controller: nameController,
                autofocus: true,
                onChanged: (value) => setState(() {
                  if (!emojiManuallyChosen) selectedEmoji = foodEmoji(value, category);
                }),
                decoration: const InputDecoration(labelText: 'Nom du produit *'),
                validator: (value) => value == null || value.trim().isEmpty ? 'Indique le nom du produit.' : null,
              ),
              const SizedBox(height: 8),
              Row(children: [
                _FoodAvatar(emoji: selectedEmoji, size: 42),
                const SizedBox(width: 9),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Icône du produit', style: TextStyle(color: ink, fontSize: 10, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text(emojiManuallyChosen ? 'Icône actuelle conservée' : 'Suggestion : ${foodEmoji(nameController.text, category)}', style: const TextStyle(color: muted, fontSize: 9)),
                ])),
                TextButton.icon(onPressed: pickEmoji, icon: const Icon(Icons.emoji_emotions_outlined, size: 16), label: const Text('Modifier')),
                IconButton(tooltip: 'Reprendre l’icône suggérée', visualDensity: VisualDensity.compact, onPressed: resetSuggestedEmoji, icon: const Icon(Icons.auto_awesome, size: 17, color: greenDark)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: DropdownButtonFormField<String>(value: zone, decoration: const InputDecoration(labelText: 'Zone'), items: const [DropdownMenuItem(value: 'emergency', child: Text('Kit urgence 72 h')), DropdownMenuItem(value: 'reserve', child: Text('Réserve 15 jours')), DropdownMenuItem(value: 'daily', child: Text('Garde-manger'))], onChanged: (value) => setState(() => zone = value ?? zone))),
                const SizedBox(width: 8),
                Expanded(child: DropdownButtonFormField<String>(value: category, decoration: const InputDecoration(labelText: 'Catégorie'), items: const [DropdownMenuItem(value: 'water', child: Text('Eau')), DropdownMenuItem(value: 'vegetables', child: Text('Légumes')), DropdownMenuItem(value: 'legumes', child: Text('Légumineuses')), DropdownMenuItem(value: 'fish', child: Text('Poisson')), DropdownMenuItem(value: 'protein', child: Text('Viande / protéines')), DropdownMenuItem(value: 'ready', child: Text('Plats préparés')), DropdownMenuItem(value: 'starch', child: Text('Féculents')), DropdownMenuItem(value: 'breakfast', child: Text('Petit-déjeuner')), DropdownMenuItem(value: 'snacks', child: Text('Fruits / en-cas')), DropdownMenuItem(value: 'condiments', child: Text('Épicerie / condiments')), DropdownMenuItem(value: 'other', child: Text('Matériel / autres'))], onChanged: (value) => setState(() {
                  category = value ?? category;
                  if (!emojiManuallyChosen) selectedEmoji = foodEmoji(nameController.text, category);
                }))),
              ]),
              const Padding(
                padding: EdgeInsets.only(top: 5),
                child: Text('Changer de zone déplace la même référence : stock, dates, notes, icône et historique sont conservés.', style: TextStyle(color: muted, fontSize: 9, height: 1.35)),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextFormField(controller: targetController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Objectif de base *'), validator: (value) => value == null || parseNumber(value) == null || parseNumber(value)! < 0 ? 'Objectif invalide.' : null)),
                const SizedBox(width: 8),
                SizedBox(width: 105, child: TextFormField(controller: unitController, decoration: const InputDecoration(labelText: 'Unité'))),
              ]),
              CheckboxListTile(value: perPerson, onChanged: (value) => setState(() => perPerson = value ?? true), contentPadding: EdgeInsets.zero, dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Objectif multiplié par le nombre de personnes', style: TextStyle(fontSize: 10, color: ink, fontWeight: FontWeight.w700)), subtitle: Text('Objectif actuel : ${formatNumber((parseNumber(targetController.text) ?? 0) * (perPerson ? widget.people : 1))} ${unitController.text} pour le foyer', style: const TextStyle(fontSize: 9, color: muted))),
              const Divider(height: 18),
              buildLotsSection(),
              const SizedBox(height: 10),
              TextFormField(controller: notesController, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Notes / composition', hintText: 'Variétés, emplacement, contenu…')),
              if (widget.original?.history.isNotEmpty == true) ...[
                const Divider(height: 22),
                const Text('Historique du produit', style: TextStyle(color: ink, fontSize: 11, fontWeight: FontWeight.w900)),
                const SizedBox(height: 5),
                for (final entry in widget.original!.history.reversed.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.history_rounded, size: 14, color: green),
                      const SizedBox(width: 6),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(entry.label, style: const TextStyle(color: ink, fontSize: 9, fontWeight: FontWeight.w700)),
                        Text('${formatDate(entry.at)} · ${entry.at.hour.toString().padLeft(2, '0')}:${entry.at.minute.toString().padLeft(2, '0')}', style: const TextStyle(color: muted, fontSize: 8)),
                      ])),
                    ]),
                  ),
              ],
              const SizedBox(height: 7),
              const _InfoBanner(icon: Icons.info_outline, text: 'Ajoute un lot lorsque tu connais une quantité. Tu peux noter des dates différentes pour chaque fabrication ou achat.', color: blue),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton.icon(onPressed: submit, icon: const Icon(Icons.check, size: 17), label: const Text('Enregistrer')),
      ],
    );
  }
}

class LotEditorDialog extends StatefulWidget {
  const LotEditorDialog({super.key, this.original});
  final StockLot? original;
  @override
  State<LotEditorDialog> createState() => _LotEditorDialogState();
}

class _LotEditorDialogState extends State<LotEditorDialog> {
  final formKey = GlobalKey<FormState>();
  late final TextEditingController quantityController;
  late final TextEditingController notesController;
  DateTime? batchDate;
  DateTime? expiryDate;
  String dateType = 'DDM';

  @override
  void initState() {
    super.initState();
    final lot = widget.original;
    quantityController = TextEditingController(text: lot?.quantity == null ? '' : formatNumber(lot!.quantity!));
    notesController = TextEditingController(text: lot?.notes ?? '');
    batchDate = lot?.batchDate;
    expiryDate = lot?.expiryDate;
    dateType = lot?.dateType ?? 'DDM';
  }

  @override
  void dispose() {
    quantityController.dispose();
    notesController.dispose();
    super.dispose();
  }

  Future<DateTime?> chooseDate(DateTime? current, String help) => showDatePicker(
        context: context,
        initialDate: current ?? DateTime.now(),
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        locale: const Locale('fr', 'FR'),
        helpText: help,
        cancelText: 'Annuler',
        confirmText: 'Valider',
      );

  double? parseQuantity(String value) => double.tryParse(value.trim().replaceAll(',', '.'));

  void submit() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final raw = quantityController.text.trim();
    final quantity = raw.isEmpty ? null : parseQuantity(raw);
    Navigator.pop(context, StockLot(
      id: widget.original?.id ?? 'lot-${DateTime.now().microsecondsSinceEpoch}',
      quantity: quantity,
      batchDate: batchDate,
      expiryDate: expiryDate,
      dateType: dateType,
      notes: notesController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final allowUnknownQuantity = widget.original != null;
    return AlertDialog(
      title: Text(widget.original == null ? 'Ajouter un lot' : 'Modifier le lot', style: const TextStyle(color: ink, fontWeight: FontWeight.w900, fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Form(
          key: formKey,
          child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: quantityController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Quantité dans ce lot', hintText: 'Ex. 1'),
              validator: (value) {
                final raw = value?.trim() ?? '';
                if (raw.isEmpty) return allowUnknownQuantity ? null : 'Indique la quantité de ce nouveau lot.';
                final parsed = parseQuantity(raw);
                if (parsed == null || parsed < 0 || (parsed == 0 && widget.original == null)) return 'La quantité doit être supérieure à zéro pour un nouveau lot.';
                return null;
              },
            ),
            const SizedBox(height: 12),
            const Text('Date de fabrication ou d’achat', style: TextStyle(color: ink, fontSize: 10, fontWeight: FontWeight.w800)),
            const SizedBox(height: 5),
            _DateButton(label: 'Fabrication / achat', date: batchDate, onTap: () async { final value = await chooseDate(batchDate, 'Date de fabrication ou d’achat'); if (value != null) setState(() => batchDate = value); }, onClear: () => setState(() => batchDate = null)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(value: dateType, decoration: const InputDecoration(labelText: 'Type de date de conservation'), items: const [DropdownMenuItem(value: 'DLC', child: Text('DLC — à consommer jusqu’au')), DropdownMenuItem(value: 'DDM', child: Text('DDM — de préférence avant'))], onChanged: (value) => setState(() => dateType = value ?? dateType)),
            const SizedBox(height: 9),
            _DateButton(label: 'Date de conservation', date: expiryDate, onTap: () async { final value = await chooseDate(expiryDate, 'Date de conservation'); if (value != null) setState(() => expiryDate = value); }, onClear: () => setState(() => expiryDate = null)),
            const SizedBox(height: 9),
            TextFormField(controller: notesController, minLines: 1, maxLines: 3, decoration: const InputDecoration(labelText: 'Note sur ce lot', hintText: 'Ex. fraise 2026, pot 250 g…')),
            const SizedBox(height: 8),
            const _InfoBanner(icon: Icons.info_outline, text: 'Tu peux laisser la date vide si elle n’est pas indiquée. Chaque lot gardera ensuite ses propres dates.', color: blue),
          ])),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')), FilledButton.icon(onPressed: submit, icon: const Icon(Icons.check, size: 16), label: const Text('Enregistrer le lot'))],
    );
  }
}

class _DateButton extends StatelessWidget {
  const _DateButton({required this.label, required this.date, required this.onTap, required this.onClear});
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w800)),
        const SizedBox(height: 5),
        OutlinedButton(onPressed: onTap, style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12), foregroundColor: ink, side: const BorderSide(color: Color(0xFFDDE4D9)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11))), child: Row(children: [const Icon(Icons.calendar_today_outlined, size: 14), const SizedBox(width: 6), Expanded(child: Text(date == null ? 'Choisir' : formatDate(date!), style: const TextStyle(fontSize: 10), overflow: TextOverflow.ellipsis)), if (date != null) InkWell(onTap: onClear, child: const Icon(Icons.close, size: 14, color: muted))])),
      ]);
}

Future<void> showMoveItemDialog(BuildContext context, ReserveController controller, ReserveItem item) async {
  final destinations = <String>['emergency', 'reserve', 'daily'].where((zone) => zone != item.zone).toList();
  final destination = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Déplacer ce produit ?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${item.displayEmoji}  ${item.name}', style: const TextStyle(color: ink, fontWeight: FontWeight.w900)),
          const SizedBox(height: 7),
          const Text('Le produit sera déplacé, pas dupliqué. Son stock réel, ses dates, ses notes, son icône et son historique seront conservés.', style: TextStyle(color: muted, fontSize: 11, height: 1.4)),
          const SizedBox(height: 12),
          for (final zone in destinations)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(zone == 'emergency' ? Icons.backpack_outlined : zone == 'reserve' ? Icons.inventory_2_outlined : Icons.home_outlined, color: greenDark),
              title: Text(zoneName(zone), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
              onTap: () => Navigator.pop(dialogContext, zone),
            ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Annuler'))],
    ),
  );
  if (destination == null || !context.mounted) return;
  final moved = await controller.moveItem(item.id, destination);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(moved
        ? 'Produit déplacé vers ${zoneName(destination)}. Stock et historique conservés.'
        : 'Ce produit existe déjà dans ${zoneName(destination)}. Aucun déplacement effectué.'),
    duration: const Duration(seconds: 3),
  ));
}

Future<void> confirmDelete(BuildContext context, ReserveController controller, ReserveItem item) async {
  final confirm = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
        title: const Text('Supprimer ce produit ?'),
        content: Text('« ${item.name} » sera retiré de l’inventaire.'),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Annuler')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Supprimer'))],
      ));
  if (confirm == true) {
    await controller.deleteItem(item.id);
    if (context.mounted) {
      final message = controller.storageWarning == null
          ? 'Produit supprimé et sauvegardé.'
          : 'Produit supprimé à l’écran, mais sauvegarde à vérifier : ${controller.storageWarning}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

String formatNumber(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(1).replaceAll('.', ',');
}

String formatDateTime(DateTime value) => '${formatDate(value)} à ${value.hour.toString().padLeft(2, '0')}h${value.minute.toString().padLeft(2, '0')}';

String formatDate(DateTime date) => '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

String monthLabel(DateTime date) {
  const names = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
  return '${names[date.month - 1][0].toUpperCase()}${names[date.month - 1].substring(1)} ${date.year}';
}

int daysUntil(DateTime date) {
  final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  final dateOnly = DateTime(date.year, date.month, date.day);
  return dateOnly.difference(today).inDays;
}

String expiryMessageForLot(StockLot lot) {
  final days = daysUntil(lot.expiryDate!);
  if (days < 0) return lot.dateType == 'DLC' ? 'DLC dépassée — ne pas consommer' : 'DDM dépassée — vérifier le produit et son emballage';
  if (days == 0) return 'date du jour';
  if (days <= 60) return 'date dans $days jour(s)';
  return 'date le ${formatDate(lot.expiryDate!)}';
}

String expiryMessage(ReserveItem item) {
  final days = daysUntil(item.expiryDate!);
  if (days < 0) return item.dateType == 'DLC' ? 'DLC dépassée — ne pas consommer' : 'DDM dépassée — vérifier le produit et son emballage';
  if (days == 0) return 'date du jour';
  if (days <= 60) return 'date dans $days jour(s)';
  return 'date le ${formatDate(item.expiryDate!)}';
}

String zoneName(String zone) => switch (zone) {
      'emergency' => 'Kit urgence 72 h',
      'reserve' => 'Réserve 15 jours',
      'daily' => 'Garde-manger',
      _ => 'Autre',
    };

String categoryName(String category) => switch (category) {
      'water' => 'Eau',
      'vegetables' => 'Légumes en conserve',
      'legumes' => 'Légumineuses',
      'fish' => 'Poisson',
      'protein' => 'Viande & protéines',
      'ready' => 'Plats préparés',
      'starch' => 'Féculents',
      'breakfast' => 'Petit-déjeuner',
      'snacks' => 'Fruits & en-cas',
      'condiments' => 'Épicerie & condiments',
      _ => 'Matériel & autres',
    };
