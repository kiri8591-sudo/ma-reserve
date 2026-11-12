import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = ReserveController();
  await controller.load();
  runApp(MaReserveApp(controller: controller));
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
  });

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

class ReserveController extends ChangeNotifier {
  static const String storageKey = 'ma_reserve_flutter_v1';
  SharedPreferences? _preferences;

  int people = 1;
  List<ReserveItem> items = [];
  Map<String, Map<String, bool>> checks = {};

  Future<void> load() async {
    _preferences = await SharedPreferences.getInstance();
    final raw = _preferences!.getString(storageKey);
    if (raw == null || raw.isEmpty) {
      items = _seedItems();
      await _persist(notify: false);
      return;
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final savedPeople = (decoded['people'] as num?)?.toInt() ?? 1;
    people = savedPeople.clamp(1, 20).toInt();
      final rawItems = decoded['items'];
      items = rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((item) => ReserveItem.fromJson(Map<String, dynamic>.from(item)))
              .toList()
          : _seedItems();
      final rawChecks = decoded['checks'];
      checks = {};
      if (rawChecks is Map) {
        for (final entry in rawChecks.entries) {
          if (entry.value is Map) {
            checks[entry.key.toString()] = Map<String, bool>.from(
              (entry.value as Map).map((key, value) => MapEntry(key.toString(), value == true)),
            );
          }
        }
      }
      // Add newly introduced default products without overwriting the user's inventory.
      for (final seed in _seedItems()) {
        if (!items.any((item) => item.id == seed.id)) items.add(seed);
      }
    } catch (_) {
      people = 1;
      items = _seedItems();
      checks = {};
    }
    await _persist(notify: false);
  }

  List<ReserveItem> _seedItems() => [
        ReserveItem(
          id: 'em-water', name: 'Eau potable', category: 'water', zone: 'emergency',
          target: 6, unit: 'L', notes: 'Minimum 6 litres par personne pour 72 h.',
        ),
        ReserveItem(
          id: 'em-veg', name: 'Conserves de légumes', category: 'vegetables', zone: 'emergency',
          target: 3, unit: 'boîtes', notes: 'À consommer froid si nécessaire.',
        ),
        ReserveItem(
          id: 'em-fish', name: 'Conserves de poisson', category: 'fish', zone: 'emergency',
          target: 3, unit: 'boîtes', notes: 'Thon, sardines ou maquereaux.',
        ),
        ReserveItem(
          id: 'em-meat', name: 'Conserves de viande / plats cuisinés', category: 'protein', zone: 'emergency',
          target: 3, unit: 'boîtes', notes: 'Choisir des produits prêts à consommer.',
        ),
        ReserveItem(
          id: 'em-fruit', name: 'Fruits au sirop / compotes', category: 'breakfast', zone: 'emergency',
          target: 3, unit: 'portions', notes: '3 portions pour 72 h.',
        ),
        ReserveItem(
          id: 'em-biscuits', name: 'Biscuits / pain longue conservation', category: 'starch', zone: 'emergency',
          target: 2, unit: 'paquets', notes: 'Fourchette indicative : 1 à 2 paquets.',
        ),
        ReserveItem(
          id: 'em-dried', name: 'Fruits secs', category: 'snacks', zone: 'emergency',
          target: 200, unit: 'g', notes: 'Environ 200 g pour 72 h.',
        ),
        ReserveItem(
          id: 'em-starch', name: 'Féculents précuits / faciles à consommer', category: 'starch', zone: 'emergency',
          target: 3, unit: 'portions', notes: 'Privilégier les portions consommables sans cuisson.',
        ),
        ReserveItem(
          id: 'em-bars', name: 'Barres céréalières', category: 'snacks', zone: 'emergency',
          target: 3, unit: 'unités', notes: 'Fourchette indicative : 3 à 6 unités.',
        ),
        ReserveItem(
          id: 'em-opener', name: 'Ouvre-boîte manuel', category: 'other', zone: 'emergency',
          target: 1, unit: 'unité', perPerson: false,
          notes: 'Matériel à garder avec le kit ; objectif 1 par foyer.',
        ),
        ReserveItem(
          id: 'res-veg', name: 'Légumes & légumineuses (assortiment)', category: 'vegetables', zone: 'reserve',
          target: 12, unit: 'boîtes', notes: 'Cible de départ : 12 boîtes (fourchette 10 à 15). Haricots verts, petits pois, maïs, carottes, lentilles, pois chiches, haricots rouges.',
        ),
        ReserveItem(
          id: 'res-protein', name: 'Poissons & protéines (assortiment)', category: 'fish', zone: 'reserve',
          target: 11, unit: 'portions', notes: 'Cible de départ : 11 portions (fourchette 10 à 12). Thon, sardines, maquereaux, pâtés de viande, conserves de volaille.',
        ),
        ReserveItem(
          id: 'res-ready', name: 'Plats préparés & bases de cuisine', category: 'ready', zone: 'reserve',
          target: 9, unit: 'unités', notes: 'Cible de départ : 9 unités (fourchette 8 à 10). Ratatouille, soupes, tomates pelées, sauces tomates, plats cuisinés.',
        ),
        ReserveItem(
          id: 'res-starch', name: 'Féculents & produits secs', category: 'starch', zone: 'reserve',
          target: 6, unit: 'kg', notes: 'Cible de départ : 6 kg au total (fourchette 5 à 7 kg). Riz, pâtes, semoule, purée en flocons, farine, flocons d’avoine.',
        ),
        ReserveItem(
          id: 'res-breakfast', name: 'Petits-déjeuners & énergie (assortiment)', category: 'breakfast', zone: 'reserve',
          target: 12, unit: 'portions', notes: 'Cible de départ : 12 portions (fourchette 10 à 15). Compotes, miel, fruits secs, biscuits, noix, chocolat noir.',
        ),
      ];

  Map<String, dynamic> toJson() => {
        'app': 'Ma Réserve Flutter',
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'people': people,
        'items': items.map((item) => item.toJson()).toList(),
        'checks': checks,
      };

  Future<void> _persist({bool notify = true}) async {
    await _preferences?.setString(storageKey, jsonEncode(toJson()));
    if (notify) notifyListeners();
  }

  void _save() {
    unawaited(_persist());
  }

  double targetFor(ReserveItem item) => item.targetFor(people);

  List<ReserveItem> inZone(String zone) => items.where((item) => item.zone == zone).toList();

  List<ReserveItem> get unknownItems => items.where((item) => item.stock == null).toList();

  List<ReserveItem> get lowItems => items
      .where((item) => item.stock != null && item.stock! < targetFor(item))
      .toList();

  List<ReserveItem> get datedItems {
    final values = items.where((item) => item.expiryDate != null).toList();
    values.sort((a, b) => a.expiryDate!.compareTo(b.expiryDate!));
    return values;
  }

  List<ReserveItem> get soonItems => datedItems.where((item) {
        final days = daysUntil(item.expiryDate!);
        return days <= 60;
      }).toList();

  int get completedCount => items.where((item) {
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

  void saveItem(ReserveItem item) {
    final index = items.indexWhere((entry) => entry.id == item.id);
    if (index < 0) {
      items.add(item);
    } else {
      items[index] = item;
    }
    _save();
  }

  void deleteItem(String id) {
    items.removeWhere((item) => item.id == id);
    _save();
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

  Future<void> restoreJson(String source) async {
    final decoded = jsonDecode(source) as Map<String, dynamic>;
    final rawItems = decoded['items'];
    if (rawItems is! List) throw const FormatException('Liste de produits manquante.');
    final savedPeople = (decoded['people'] as num?)?.toInt() ?? 1;
    people = savedPeople.clamp(1, 20).toInt();
    items = rawItems
        .whereType<Map>()
        .map((entry) => ReserveItem.fromJson(Map<String, dynamic>.from(entry)))
        .toList();
    for (final seed in _seedItems()) {
      if (!items.any((item) => item.id == seed.id)) items.add(seed);
    }
    final rawChecks = decoded['checks'];
    checks = {};
    if (rawChecks is Map) {
      for (final entry in rawChecks.entries) {
        if (entry.value is Map) {
          checks[entry.key.toString()] = Map<String, bool>.from(
            (entry.value as Map).map((key, value) => MapEntry(key.toString(), value == true)),
          );
        }
      }
    }
    await _persist();
  }

  static String get monthKey {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
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

  static const destinations = [
    _Destination('Accueil', Icons.grid_view_rounded),
    _Destination('Kit 72 h', Icons.backpack_outlined),
    _Destination('Réserve 15 j', Icons.inventory_2_outlined),
    _Destination('Inventaire', Icons.checklist_rounded),
    _Destination('Suivi', Icons.event_note_rounded),
  ];

  void select(int index) => setState(() => selectedIndex = index);

  Future<void> _showBackup() async {
    final jsonText = const JsonEncoder.withIndent('  ').convert(widget.controller.toJson());
    final textController = TextEditingController(text: jsonText);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sauvegarde des données'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Copie ce texte dans tes notes pour conserver une sauvegarde. Pour restaurer, colle un ancien export dans le même écran.'),
              const SizedBox(height: 12),
              SizedBox(
                height: 210,
                child: TextField(
                  controller: textController,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                  decoration: const InputDecoration(hintText: 'Données JSON'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: textController.text));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sauvegarde copiée dans le presse-papiers.')));
            },
            child: const Text('Copier la sauvegarde'),
          ),
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Fermer')),
          FilledButton.tonal(
            onPressed: () async {
              final sourceController = TextEditingController();
              Navigator.pop(dialogContext);
              final restore = await showDialog<String>(
                context: context,
                builder: (restoreContext) => AlertDialog(
                  title: const Text('Restaurer une sauvegarde'),
                  content: SizedBox(
                    width: 560,
                    child: TextField(
                      controller: sourceController,
                      minLines: 8,
                      maxLines: 12,
                      decoration: const InputDecoration(hintText: 'Colle ici le contenu JSON sauvegardé'),
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(restoreContext), child: const Text('Annuler')),
                    FilledButton(onPressed: () => Navigator.pop(restoreContext, sourceController.text), child: const Text('Restaurer')),
                  ],
                ),
              );
              if (restore == null || restore.trim().isEmpty || !mounted) return;
              try {
                await widget.controller.restoreJson(restore);
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sauvegarde restaurée.')));
              } catch (_) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fichier ou texte de sauvegarde invalide.')));
              }
            },
            child: const Text('Restaurer…'),
          ),
        ],
      ),
    );
    textController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 820;
    final pages = [
      DashboardPage(controller: widget.controller, onNavigate: select),
      ZonePage(controller: widget.controller, zone: 'emergency'),
      ZonePage(controller: widget.controller, zone: 'reserve'),
      InventoryPage(controller: widget.controller),
      FollowUpPage(controller: widget.controller),
    ];

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => Scaffold(
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
                destinations: destinations.map((destination) => NavigationDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.icon, color: greenDark),
                  label: destination.label,
                )).toList(),
              ),
      ),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon);
  final String label;
  final IconData icon;
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
          const Padding(padding: EdgeInsets.only(left: 12, top: 7), child: Text('MA RÉSERVE  ·  V1.0', style: TextStyle(color: muted, fontSize: 9, letterSpacing: .7))),
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
          Text('$people personne${people > 1 ? 's' : ''} · Réserve alimentaire et kit de sécurité', style: const TextStyle(color: muted, fontSize: 10)),
        ])),
        Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6), decoration: BoxDecoration(color: greenSoft, borderRadius: BorderRadius.circular(20)), child: const Row(children: [Icon(Icons.wifi_off_rounded, size: 12, color: greenDark), SizedBox(width: 5), Text('HORS LIGNE', style: TextStyle(fontSize: 9, letterSpacing: .5, fontWeight: FontWeight.w900, color: greenDark))])),
        const SizedBox(width: 6),
        IconButton(onPressed: onBackup, tooltip: 'Sauvegarde', icon: const Icon(Icons.save_alt_rounded, color: greenDark)),
      ]),
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.controller, required this.onNavigate});
  final ReserveController controller;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final low = controller.lowItems;
    final unknown = controller.unknownItems;
    final dated = controller.soonItems;
    final waterItems = controller.items.where((item) => item.id == 'em-water').toList();
    final water = waterItems.isEmpty ? null : waterItems.first;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 5, 18, 28),
      children: [
        _HeroPanel(people: controller.people, waterStock: water?.stock, waterTarget: water == null ? 6 : controller.targetFor(water), onPeopleChanged: controller.setPeople),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, constraints) {
          final count = constraints.maxWidth > 850 ? 4 : constraints.maxWidth > 520 ? 2 : 2;
          final gap = 9.0;
          final width = (constraints.maxWidth - gap * (count - 1)) / count;
          return Wrap(spacing: gap, runSpacing: 9, children: [
            _StatCard(width: width, label: 'Références', value: '${controller.items.length}', hint: 'produits suivis', icon: Icons.inventory_2_outlined, tint: greenSoft, iconColor: greenDark),
            _StatCard(width: width, label: 'À renseigner', value: '${unknown.length}', hint: 'stocks inconnus', icon: Icons.edit_note_rounded, tint: blueSoft, iconColor: blue),
            _StatCard(width: width, label: 'À compléter', value: '${low.length}', hint: 'sous le seuil', icon: Icons.shopping_cart_outlined, tint: amberSoft, iconColor: amber),
            _StatCard(width: width, label: 'Dates proches', value: '${dated.length}', hint: 'dans les 60 jours ou dépassées', icon: Icons.event_outlined, tint: redSoft, iconColor: red),
          ]);
        }),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _ZoneProgressCard(
            title: 'Kit d’urgence 72 h', subtitle: 'Eau, repas et matériel essentiels', icon: Icons.backpack_outlined,
            complete: controller.completedInZone('emergency'), total: controller.inZone('emergency').length,
            progress: controller.progressInZone('emergency'), onTap: () => onNavigate(1),
          )),
          const SizedBox(width: 10),
          Expanded(child: _ZoneProgressCard(
            title: 'Réserve alimentaire', subtitle: 'Objectif de 15 jours', icon: Icons.inventory_2_outlined,
            complete: controller.completedInZone('reserve'), total: controller.inZone('reserve').length,
            progress: controller.progressInZone('reserve'), onTap: () => onNavigate(2),
          )),
        ]),
        const SizedBox(height: 14),
        _SectionCard(
          title: 'Les points à surveiller', trailing: Text('${unknown.length + low.length + dated.length} alerte(s)', style: const TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w700)),
          child: _AlertsList(controller: controller),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Accès rapide',
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            _QuickAction(label: 'Mettre à jour le stock', icon: Icons.edit_note_rounded, onTap: () => onNavigate(3)),
            _QuickAction(label: 'Voir les dates FEFO', icon: Icons.calendar_month_rounded, onTap: () => onNavigate(4)),
            _QuickAction(label: 'Contrôle mensuel', icon: Icons.fact_check_outlined, onTap: () => onNavigate(4)),
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
  const _StatCard({required this.width, required this.label, required this.value, required this.hint, required this.icon, required this.tint, required this.iconColor});
  final double width;
  final String label;
  final String value;
  final String hint;
  final IconData icon;
  final Color tint;
  final Color iconColor;
  @override
  Widget build(BuildContext context) => Container(
        width: width,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: const Color(0xFFFFFEFB), borderRadius: BorderRadius.circular(17), border: Border.all(color: const Color(0xFFE5E9E1))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Container(width: 30, height: 30, decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: iconColor, size: 17)), const Spacer(), Text(value, style: const TextStyle(color: ink, fontWeight: FontWeight.w900, fontSize: 22))]),
          const SizedBox(height: 7), Text(label, style: const TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 11)),
          Text(hint, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 9)),
        ]),
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
    for (final item in controller.soonItems.take(4)) {
      final days = daysUntil(item.expiryDate!);
      final expiredDlc = days < 0 && item.dateType == 'DLC';
      alerts.add(_AlertLine(
        icon: expiredDlc ? Icons.warning_amber_rounded : Icons.event_outlined,
        text: '${item.name} — ${expiryMessage(item)}',
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
    final items = controller.inZone(zone);
    final done = controller.completedInZone(zone);
    final progress = controller.progressInZone(zone);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 5, 18, 28),
      children: [
        _PageHeading(
          eyebrow: emergency ? 'PRIORITÉ SÉCURITÉ' : 'RÉSERVE ALIMENTAIRE',
          title: emergency ? 'Kit d’urgence 72 heures' : 'Réserve de 15 jours',
          subtitle: emergency
              ? 'Des aliments non périssables, prêts à consommer si la cuisson ou l’électricité ne sont plus disponibles.'
              : 'Un stock tampon qui complète le placard courant et se renouvelle au fil des consommations.',
          icon: emergency ? Icons.backpack_outlined : Icons.inventory_2_outlined,
        ),
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
          const _InfoBanner(icon: Icons.lightbulb_outline, text: 'Pour une personne : au moins 6 litres d’eau pour 72 heures. Privilégie des aliments consommables froids et garde un ouvre-boîte manuel avec le kit.', color: blue),
          const SizedBox(height: 12),
        ],
        for (final item in items) ...[
          _ProductCard(item: item, controller: controller),
          const SizedBox(height: 8),
        ],
        if (!emergency) const _InfoBanner(icon: Icons.tips_and_updates_outlined, text: 'Objectifs indicatifs pour une personne : 10 à 15 boîtes de légumes/légumineuses, 10 à 12 portions de protéines, 8 à 10 plats préparés, 5 à 7 kg de féculents et 10 à 15 portions de petit-déjeuner/énergie.', color: green),
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
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: const Color(0xFFFFFEFB), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE5E9E1))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
        ]),
        const SizedBox(height: 8),
        ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: percent, minHeight: 5, backgroundColor: const Color(0xFFEDF0E9), color: color)),
        if (item.expiryDate != null) Padding(padding: const EdgeInsets.only(top: 7), child: Row(children: [const Icon(Icons.event_outlined, size: 13, color: muted), const SizedBox(width: 5), Text('${item.dateType} · ${formatDate(item.expiryDate!)}', style: const TextStyle(color: muted, fontSize: 9))])),
      ]),
    );
  }
}

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key, required this.controller});
  final ReserveController controller;
  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final searchController = TextEditingController();
  String zoneFilter = 'all';
  String sortFilter = 'date';

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = searchController.text.trim().toLowerCase();
    final rows = widget.controller.items.where((item) {
      final matchesQuery = query.isEmpty || '${item.name} ${item.notes}'.toLowerCase().contains(query);
      final matchesZone = zoneFilter == 'all' || item.zone == zoneFilter;
      return matchesQuery && matchesZone;
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
          FilledButton.icon(onPressed: () => showItemEditor(context, widget.controller, null), icon: const Icon(Icons.add, size: 17), label: const Text('Ajouter'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15), textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 9),
        Row(children: [
          Expanded(child: DropdownButtonFormField<String>(value: zoneFilter, isDense: true, decoration: const InputDecoration(labelText: 'Zone', isDense: true), items: const [DropdownMenuItem(value: 'all', child: Text('Toutes les zones')), DropdownMenuItem(value: 'emergency', child: Text('Kit 72 h')), DropdownMenuItem(value: 'reserve', child: Text('Réserve 15 jours')), DropdownMenuItem(value: 'daily', child: Text('Placard courant'))], onChanged: (value) => setState(() => zoneFilter = value ?? 'all'))),
          const SizedBox(width: 8),
          Expanded(child: DropdownButtonFormField<String>(value: sortFilter, isDense: true, decoration: const InputDecoration(labelText: 'Trier par', isDense: true), items: const [DropdownMenuItem(value: 'date', child: Text('Date la plus proche')), DropdownMenuItem(value: 'name', child: Text('Nom')), DropdownMenuItem(value: 'low', child: Text('Stock insuffisant')), DropdownMenuItem(value: 'zone', child: Text('Zone'))], onChanged: (value) => setState(() => sortFilter = value ?? 'date'))),
        ]),
        const SizedBox(height: 12),
        Row(children: [Text('${rows.length} produit(s) affiché(s)', style: const TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w700)), const Spacer(), Text('${widget.controller.items.length} références au total', style: const TextStyle(color: muted, fontSize: 10))]),
        const SizedBox(height: 8),
        if (rows.isEmpty) const _EmptyState(icon: Icons.search_off, title: 'Aucun produit', text: 'Essaie une autre recherche ou ajoute une référence.'),
        for (final item in rows) ...[
          _InventoryItemCard(item: item, controller: widget.controller),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        const _InfoBanner(icon: Icons.info_outline, text: 'Laisse le stock réel vide tant que tu n’as pas compté le produit. Une quantité inconnue n’est jamais considérée comme un stock suffisant.', color: blue),
      ],
    );
  }
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
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item.name, style: const TextStyle(color: ink, fontWeight: FontWeight.w900, fontSize: 12)), const SizedBox(height: 3), Text('${zoneName(item.zone)} · ${categoryName(item.category)}', style: const TextStyle(color: muted, fontSize: 9))])),
          _StatusPill(label: status, color: color),
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
          trailing: Text('${controller.datedItems.length} date(s)', style: const TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w700)),
          child: controller.datedItems.isEmpty
              ? const _EmptyState(icon: Icons.calendar_month_outlined, title: 'Aucune date saisie', text: 'Ajoute une date DLC ou DDM dans l’inventaire pour organiser la rotation.')
              : Column(children: [
                  const _InfoBanner(icon: Icons.swap_vert_rounded, text: 'FEFO : « First Expired, First Out ». Range devant les produits dont la date arrive le plus tôt et utilise-les en premier.', color: green),
                  const SizedBox(height: 9),
                  for (final item in controller.datedItems) _ExpiryRow(item: item),
                ]),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Liste de courses',
          trailing: Text('${controller.lowItems.length} à compléter', style: const TextStyle(color: amber, fontSize: 10, fontWeight: FontWeight.w800)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (controller.lowItems.isEmpty) const _InfoBanner(icon: Icons.check_circle_outline, text: 'Aucun produit renseigné sous son objectif. Les produits dont le stock est inconnu sont listés séparément.', color: green),
            for (final item in controller.lowItems)
              _ShoppingRow(item: item, controller: controller),
            if (controller.unknownItems.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('À compter avant de faire les courses (${controller.unknownItems.length})', style: const TextStyle(color: muted, fontSize: 10, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              for (final item in controller.unknownItems.take(12))
                Padding(padding: const EdgeInsets.only(bottom: 5), child: Row(children: [const Icon(Icons.help_outline, size: 14, color: blue), const SizedBox(width: 7), Expanded(child: Text(item.name, style: const TextStyle(color: ink, fontSize: 10))), Text('Objectif ${formatNumber(controller.targetFor(item))} ${item.unit}', style: const TextStyle(color: muted, fontSize: 9))])),
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
            _GuideTile(number: '06', title: 'Séparer les espaces', text: 'Placard courant, réserve de 15 jours et kit d’urgence de 72 heures facilement accessible.', icon: Icons.inventory_2_outlined),
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
  const _ExpiryRow({required this.item});
  final ReserveItem item;
  @override
  Widget build(BuildContext context) {
    final days = daysUntil(item.expiryDate!);
    final isDlcDanger = days < 0 && item.dateType == 'DLC';
    final isSoon = days <= 60;
    final color = isDlcDanger ? red : isSoon ? amber : green;
    final label = days < 0 ? 'Dépassée' : days == 0 ? 'Aujourd’hui' : days <= 30 ? '$days j' : days <= 60 ? '$days j' : 'À venir';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Container(width: 34, height: 34, decoration: BoxDecoration(color: color.withOpacity(.10), borderRadius: BorderRadius.circular(10)), child: Icon(Icons.event_outlined, color: color, size: 17)),
        const SizedBox(width: 9),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item.name, style: const TextStyle(color: ink, fontSize: 10, fontWeight: FontWeight.w800)), Text('${item.dateType} · ${formatDate(item.expiryDate!)}', style: const TextStyle(color: muted, fontSize: 9))])),
        _StatusPill(label: label, color: color),
      ]),
    );
  }
}

class _ShoppingRow extends StatelessWidget {
  const _ShoppingRow({required this.item, required this.controller});
  final ReserveItem item;
  final ReserveController controller;
  @override
  Widget build(BuildContext context) {
    final gap = (controller.targetFor(item) - (item.stock ?? 0)).clamp(0.0, double.infinity).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        const Icon(Icons.add_shopping_cart_outlined, color: amber, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item.name, style: const TextStyle(color: ink, fontSize: 10, fontWeight: FontWeight.w800)), Text('Stock : ${formatNumber(item.stock!)} ${item.unit}', style: const TextStyle(color: muted, fontSize: 9))])),
        Text('+ ${formatNumber(gap)} ${item.unit}', style: const TextStyle(color: amber, fontSize: 10, fontWeight: FontWeight.w900)),
      ]),
    );
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

Future<void> showItemEditor(BuildContext context, ReserveController controller, ReserveItem? original) async {
  final saved = await showDialog<ReserveItem>(context: context, barrierDismissible: false, builder: (context) => ItemEditorDialog(original: original, people: controller.people));
  if (saved != null) controller.saveItem(saved);
}

class ItemEditorDialog extends StatefulWidget {
  const ItemEditorDialog({super.key, required this.original, required this.people});
  final ReserveItem? original;
  final int people;
  @override
  State<ItemEditorDialog> createState() => _ItemEditorDialogState();
}

class _ItemEditorDialogState extends State<ItemEditorDialog> {
  final formKey = GlobalKey<FormState>();
  late final TextEditingController nameController;
  late final TextEditingController stockController;
  late final TextEditingController targetController;
  late final TextEditingController unitController;
  late final TextEditingController notesController;
  late String category;
  late String zone;
  late String dateType;
  late bool perPerson;
  DateTime? purchaseDate;
  DateTime? expiryDate;

  @override
  void initState() {
    super.initState();
    final item = widget.original;
    nameController = TextEditingController(text: item?.name ?? '');
    stockController = TextEditingController(text: item?.stock == null ? '' : formatNumber(item!.stock!));
    targetController = TextEditingController(text: formatNumber(item?.target ?? 1));
    unitController = TextEditingController(text: item?.unit ?? 'unités');
    notesController = TextEditingController(text: item?.notes ?? '');
    category = item?.category ?? 'other';
    zone = item?.zone ?? 'reserve';
    dateType = item?.dateType ?? 'DDM';
    perPerson = item?.perPerson ?? true;
    purchaseDate = item?.purchaseDate;
    expiryDate = item?.expiryDate;
  }

  @override
  void dispose() {
    nameController.dispose(); stockController.dispose(); targetController.dispose(); unitController.dispose(); notesController.dispose();
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

  void submit() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final old = widget.original;
    Navigator.pop(context, ReserveItem(
      id: old?.id ?? 'custom-${DateTime.now().microsecondsSinceEpoch}',
      name: nameController.text.trim(),
      category: category,
      zone: zone,
      stock: stockController.text.trim().isEmpty ? null : parseNumber(stockController.text),
      target: parseNumber(targetController.text) ?? 1,
      unit: unitController.text.trim().isEmpty ? 'unités' : unitController.text.trim(),
      perPerson: perPerson,
      purchaseDate: purchaseDate,
      expiryDate: expiryDate,
      dateType: dateType,
      notes: notesController.text.trim(),
    ));
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
              TextFormField(controller: nameController, autofocus: true, decoration: const InputDecoration(labelText: 'Nom du produit *'), validator: (value) => value == null || value.trim().isEmpty ? 'Indique le nom du produit.' : null),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: DropdownButtonFormField<String>(value: zone, decoration: const InputDecoration(labelText: 'Zone'), items: const [DropdownMenuItem(value: 'emergency', child: Text('Kit urgence 72 h')), DropdownMenuItem(value: 'reserve', child: Text('Réserve 15 jours')), DropdownMenuItem(value: 'daily', child: Text('Placard courant'))], onChanged: (value) => setState(() => zone = value ?? zone))),
                const SizedBox(width: 8),
                Expanded(child: DropdownButtonFormField<String>(value: category, decoration: const InputDecoration(labelText: 'Catégorie'), items: const [DropdownMenuItem(value: 'water', child: Text('Eau')), DropdownMenuItem(value: 'vegetables', child: Text('Légumes')), DropdownMenuItem(value: 'legumes', child: Text('Légumineuses')), DropdownMenuItem(value: 'fish', child: Text('Poisson')), DropdownMenuItem(value: 'protein', child: Text('Viande / protéines')), DropdownMenuItem(value: 'ready', child: Text('Plats préparés')), DropdownMenuItem(value: 'starch', child: Text('Féculents')), DropdownMenuItem(value: 'breakfast', child: Text('Petit-déjeuner')), DropdownMenuItem(value: 'snacks', child: Text('Fruits / en-cas')), DropdownMenuItem(value: 'other', child: Text('Matériel / autres'))], onChanged: (value) => setState(() => category = value ?? category))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextFormField(controller: stockController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Stock réel', hintText: 'À renseigner'), validator: (value) => value != null && value.trim().isNotEmpty && (parseNumber(value) == null || parseNumber(value)! < 0) ? 'Quantité invalide.' : null)),
                const SizedBox(width: 8),
                Expanded(child: TextFormField(controller: targetController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Objectif de base *'), validator: (value) => value == null || parseNumber(value) == null || parseNumber(value)! < 0 ? 'Objectif invalide.' : null)),
                const SizedBox(width: 8),
                SizedBox(width: 90, child: TextFormField(controller: unitController, decoration: const InputDecoration(labelText: 'Unité'))),
              ]),
              CheckboxListTile(value: perPerson, onChanged: (value) => setState(() => perPerson = value ?? true), contentPadding: EdgeInsets.zero, dense: true, controlAffinity: ListTileControlAffinity.leading, title: const Text('Objectif multiplié par le nombre de personnes', style: TextStyle(fontSize: 10, color: ink, fontWeight: FontWeight.w700)), subtitle: Text('Objectif actuel : ${formatNumber((parseNumber(targetController.text) ?? 0) * (perPerson ? widget.people : 1))} ${unitController.text} pour le foyer', style: const TextStyle(fontSize: 9, color: muted))),
              const Divider(height: 18),
              Row(children: [
                Expanded(child: _DateButton(label: 'Date d’achat', date: purchaseDate, onTap: () async { final date = await chooseDate(purchaseDate); if (date != null) setState(() => purchaseDate = date); }, onClear: () => setState(() => purchaseDate = null))),
                const SizedBox(width: 8),
                Expanded(child: _DateButton(label: 'Date de conservation', date: expiryDate, onTap: () async { final date = await chooseDate(expiryDate); if (date != null) setState(() => expiryDate = date); }, onClear: () => setState(() => expiryDate = null))),
              ]),
              const SizedBox(height: 9),
              DropdownButtonFormField<String>(value: dateType, decoration: const InputDecoration(labelText: 'Type de date'), items: const [DropdownMenuItem(value: 'DLC', child: Text('DLC — à consommer jusqu’au')), DropdownMenuItem(value: 'DDM', child: Text('DDM — de préférence avant'))], onChanged: (value) => setState(() => dateType = value ?? dateType)),
              const SizedBox(height: 9),
              TextFormField(controller: notesController, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Notes / composition', hintText: 'Variétés, emplacement, contenu…')),
              const SizedBox(height: 7),
              const _InfoBanner(icon: Icons.info_outline, text: 'Laisse le stock réel vide tant que tu n’as pas compté le produit. L’objectif se calcule automatiquement selon le foyer.', color: blue),
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

Future<void> confirmDelete(BuildContext context, ReserveController controller, ReserveItem item) async {
  final confirm = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
        title: const Text('Supprimer ce produit ?'),
        content: Text('« ${item.name} » sera retiré de l’inventaire.'),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Annuler')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Supprimer'))],
      ));
  if (confirm == true) controller.deleteItem(item.id);
}

String formatNumber(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(1).replaceAll('.', ',');
}

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
      'daily' => 'Placard courant',
      _ => 'Autre',
    };

String categoryName(String category) => switch (category) {
      'water' => 'Eau',
      'vegetables' => 'Légumes',
      'legumes' => 'Légumineuses',
      'fish' => 'Poisson',
      'protein' => 'Viande & protéines',
      'ready' => 'Plats préparés',
      'starch' => 'Féculents',
      'breakfast' => 'Petit-déjeuner',
      'snacks' => 'Fruits & en-cas',
      _ => 'Matériel & autres',
    };
