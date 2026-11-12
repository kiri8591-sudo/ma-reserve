# Ma Réserve Flutter V2.0 — Sauvegarde, restauration et remise à zéro

## Nouveautés

- Téléchargement d’un véritable fichier de sauvegarde `.json` dans Chrome.
- Copie du JSON dans le presse-papiers en solution complémentaire.
- Import d’un fichier `.json` depuis l’ordinateur, avec aperçu avant restauration.
- Restauration depuis un texte JSON conservée comme solution de secours.
- Validation de la structure du fichier avant toute modification des données. Une sauvegarde issue d’un schéma plus récent est refusée pour éviter une perte de données.
- Création automatique d’une copie de sécurité locale avant restauration et avant RAZ complète.
- Possibilité d’annuler la dernière restauration ou RAZ en restaurant cette copie de sécurité.
- Récupération possible d’une copie brute si les données locales précédentes étaient illisibles.
- RAZ complète : recrée les références alimentaires de base avec stocks non renseignés, efface les produits/catalogues personnels, lots, historiques, contrôles mensuels et remet le foyer à une personne.
- L’enregistrement local reste automatique et utilise la même clé `ma_reserve_flutter_v1` : les données V1.9 sont conservées.

## Sauvegarde recommandée

1. Ouvre le bouton de sauvegarde dans l’en-tête ou le menu latéral.
2. Choisis **Télécharger un fichier .json**.
3. Conserve le fichier hors de l’ordinateur également (clé USB ou espace cloud).
4. Pour restaurer, choisis **Restaurer depuis un fichier .json**. Vérifie le nombre de produits/lots et la date de l’export avant confirmation.

La restauration remplace l’état courant. Une copie de sécurité est créée automatiquement avant le remplacement.

## Remise à zéro

Le bouton **Remise à zéro complète** demande de taper `RAZ`. Il recrée les produits de base avec leurs objectifs, mais sans stock saisi. Les produits personnalisés, lots, dates, historiques, catalogue personnel, contrôles mensuels et le nombre de personnes sont remis à zéro. Une copie de sécurité locale permet d’annuler l’opération depuis le même menu.

## Installation sur ton projet Chrome

1. Arrête l’application (`Ctrl + C`).
2. Remplace le contenu de ton dossier `lib` par le dossier `lib` de cette archive (il contient `main.dart`, `backup_io_stub.dart` et `backup_io_web.dart`). Il faut bien copier les trois fichiers.
3. Dans `pubspec.yaml`, remplace la ligne `version:` par `version: 2.0.0+20` pour aligner la version du projet. Aucune nouvelle dépendance n'est nécessaire.
4. À la racine du projet, lance :

```powershell
flutter pub get
flutter run -d chrome
```

Ne remplace pas uniquement `main.dart` : les deux petits fichiers `backup_io_*.dart` sont nécessaires pour la sauvegarde fichier sur Chrome et la compatibilité des autres plateformes.

## Compatibilité

- Clé de stockage locale conservée.
- Schéma des données conservé à la version 4 ; imports des exports précédents acceptés.
- La sélection et le téléchargement de fichiers sont actifs pour le lancement web Chrome. Sur une plateforme native, l’export texte via presse-papiers reste le chemin de secours.

## Vérification

Les fichiers et l’archive sont structurés et vérifiés. Le SDK Flutter n’étant pas disponible dans l’environnement de préparation, la compilation réelle doit être réalisée sur le PC avec `flutter pub get` puis `flutter run -d chrome`.
