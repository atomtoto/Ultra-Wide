# Ultra Wide

Application iPhone en **SwiftUI**, iOS **17.0+**, sans dépendance externe. Elle élargit le cadrage du capteur principal ou du téléobjectif physique par une séquence de photos prises pendant une rotation, puis assemblées localement.

## Lancer

1. Ouvrir `UltraWide.xcodeproj` dans Xcode 15 ou ultérieur (projet vérifié avec Xcode 27).
2. Sélectionner le schéma **UltraWide**.
3. Pour un iPhone : choisir votre équipe dans **Signing & Capabilities**, adapter l’identifiant `com.ultrawide.camera` si nécessaire et sélectionner l’appareil.
4. Exécuter. Autoriser l’appareil photo. L’accès en ajout à Photos n’est demandé qu’au moment de l’export.

Le simulateur utilise automatiquement une **démonstration clairement identifiée** : cinq cadrages d’une illustration passent dans le même moteur Vision/Core Image que les photos réelles. L’argument de lancement `--demo` active également ce mode sur appareil. `--uitesting` masque seulement le guide du premier lancement.

## Prise de vue

- Tenir l’iPhone **en portrait**, face à un sujet distant et immobile, avec suffisamment de lumière.
- Choisir **Principal** ou **Téléobjectif**. Le téléobjectif n’apparaît que si ce capteur physique existe ; aucun zoom numérique n’est présenté comme un téléobjectif.
- Choisir une amplitude : **Large**, **Très large** ou **Panorama**. L’angle affiché désigne la rotation à effectuer, pas le champ de vision final.
- Déclencher, attendre la première photo puis pivoter lentement vers la gauche **ou** la droite, autour de l’objectif, sans marcher ni incliner l’iPhone.
- La capture se termine automatiquement à l’amplitude visée, ou manuellement après trois photos. Une capture peut être annulée.
- Consulter l’image avec zoom, la partager, l’ajouter à Photos ou la retrouver dans la galerie locale.

## Assemblage

1. AVFoundation sélectionne exclusivement un capteur arrière `.builtInWideAngleCamera` ou `.builtInTelephotoCamera`. La session tourne sur une file série et capture des JPEG, avec une taille d’entrée plafonnée à environ 12 MP lorsque le format le permet.
2. Mise au point, exposition et balance des blancs sont verrouillées pour la séquence. Core Motion suit l’orientation relative au départ. L’espacement des déclenchements dépend du champ de vision du capteur, avec recouvrement important. La vitesse, l’inclinaison, les retours en arrière et les écarts excessifs sont contrôlés.
3. Image I/O applique l’orientation EXIF et décode des versions réduites. Vision estime d’abord le décalage global, puis `VNHomographicImageRegistrationRequest` affine la perspective dans la zone commune des images. Les transformations locales sont ramenées aux coordonnées des photos. Une comparaison des pixels partagés sélectionne le meilleur des deux modèles pour limiter les déformations inutiles dans les zones peu détaillées. Les déplacements incohérents, les alignements trop différents et les images identiques sont rejetés.
4. Les homographies sont composées, puis recentrées sur l’image médiane pour réduire l’étirement de perspective. Core Image projette les images, adoucit les bords et les compose une à une.
5. Un calcul du plus grand rectangle dans une couverture conservatrice retire les zones vides et les bordures translucides. Le canevas est plafonné à **18 MP** et **8 000 px** sur son plus grand côté ; les images sources sont décodées à **2 400 px** maximum. La définition réelle dépend du recouvrement et du recadrage.
6. Le JPEG sRGB et ses métadonnées sont enregistrés atomiquement dans `Documents/Panoramas`. Aucun serveur, compte, suivi ou bibliothèque externe n’est utilisé.

## Organisation

| Dossier | Rôle |
| --- | --- |
| `UltraWide/App` | Point d’entrée et types partagés |
| `UltraWide/Camera` | Session AVFoundation, suivi de mouvement, politique de capture et état de l’interface |
| `UltraWide/Imaging` | Alignement Vision, projection, fondu, recadrage et scène de démonstration |
| `UltraWide/Library` | Galerie locale et export Photos |
| `UltraWide/Views` | Viseur, guide, progression, résultat, zoom et galerie SwiftUI |
| `UltraWideTests` | Géométrie, sens de balayage, assemblage réel Vision, rejet de doublons et persistance |
| `UltraWideUITests` | Capture de démonstration, annulation et galerie après relancement |

Les captures du simulateur sont disponibles dans `docs/screenshots/` : viseur et résultat d’un assemblage de démonstration.

## Validation

```sh
xcodebuild -project UltraWide.xcodeproj -scheme UltraWide \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# Remplacer le nom par un simulateur installé : xcrun simctl list devices available
xcodebuild -project UltraWide.xcodeproj -scheme UltraWide \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
```

Le projet Xcode est livré prêt à ouvrir. `python3 scripts/generate_project.py` le régénère de façon déterministe si des fichiers Swift sont ajoutés. L’icône est dessinée par `scripts/draw_icon.swift` et son PNG est inclus.

Validation effectuée : **9 tests réussis** sur le simulateur iPhone, dont un assemblage de cinq vues calculées avec une rotation optique de −20° à +20°, un contrôle des pixels sur des images de référence, les deux sens de balayage, le recadrage, la persistance et deux tests de parcours utilisateur. Les compilations simulateur et iPhone ont été vérifiées. Les résultats `.xcresult` restent dans `TestResults/` (exclus de Git).

## Limites et validation sur iPhone

L’assemblage utilise une **projection rectilinéaire par homographies et un fondu**, sans reconstruction 3D ni génération de contenu. Les objets proches, la parallaxe, les sujets mobiles, les grandes différences d’exposition et les surfaces sans détails peuvent produire des raccords ou empêcher l’alignement. L’application signale alors l’échec et permet de recommencer. Le téléobjectif élargit son cadrage de départ ; une petite rotation ne lui donne pas nécessairement le champ d’un objectif 0,5×. La définition native de 48 MP et le RAW ne sont pas conservés.

Le simulateur vérifie l’interface et le traitement d’images, **pas la qualité optique ni la synchronisation réelle capteur/mouvement**. Avant distribution, vérifier sur un iPhone compatible : principal et téléobjectif, les deux sens de rotation, scènes détaillées et uniformes, faible lumière, refus des permissions, export Photos, interruption par appel/verrouillage, retour d’arrière-plan, faible espace disque et pression mémoire. La publication App Store et la signature de distribution restent à effectuer avec votre compte Apple.

Références Apple : [alignement homographique](https://developer.apple.com/documentation/vision/vnimagehomographicalignmentobservation), [capture photographique](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput), [orientation de capture](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle).
