# Ultra Wide

Ultra Wide est une application iPhone en SwiftUI qui compose une image plus large à partir de photos prises avec **l’objectif principal physique**. Le cadrage visé est celui d’un **0,5×** environ, tout en conservant les détails du capteur principal. Un téléobjectif physique peut aussi être choisi quand l’iPhone en possède un ; les cadrages proposés dépendent de sa focale et du nombre de vues nécessaire.

## Prise de vue

1. Choisir l’objectif et le cadrage, puis cadrer la scène au centre. La première photo est déclenchée manuellement : elle fixe le repère du balayage.
2. Tourner légèrement l’iPhone vers les repères successifs. L’application attend l’alignement et la stabilité avant de prendre chaque photo. Elle signale les vues floues ou sombres.
3. Après le premier passage, assembler immédiatement ou lancer un second passage ciblé. Celui-ci permet de refaire jusqu’à six vues sans doubler toute la prise de vue.
4. Examiner le résultat, l’enregistrer dans Photos ou le partager. Les sessions interrompues peuvent être reprises ; l’application demande alors de réaligner la vue centrale.

La caméra choisie reste la même pendant tout le balayage. Le résultat est un assemblage géométrique en projection rectilinéaire, avec sélection des raccords, harmonisation et fusion multibande. Si les photos ne se recouvrent pas assez ou si le cadrage demandé n’est pas couvert, l’application conserve la session afin de refaire les vues nécessaires.

## Construire le projet

- Xcode 27, SDK iOS 27, cible minimale **iOS 26**, iPhone avec caméra arrière.
- Ouvrir [UltraWide.xcodeproj](UltraWide.xcodeproj), sélectionner la cible **UltraWide** et une équipe de signature pour l’installation sur iPhone.
- Le framework OpenCV 4.13.0 pour iPhone est fourni dans `ThirdParty/OpenCV`. Sa provenance, sa licence Apache 2.0 et la commande de préparation figurent dans [ThirdParty/OpenCV/README.md](ThirdParty/OpenCV/README.md).
- Le simulateur permet de compiler et de lancer l’interface, mais ne peut ni capturer avec une caméra arrière physique ni exécuter l’assembleur iPhone.

```sh
xcodebuild -project UltraWide.xcodeproj -scheme UltraWide \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Les tests de planification des vues se lancent avec `xcodebuild test` sur un simulateur iOS 26 ou plus récent. L’assemblage et la qualité des photos doivent être validés sur plusieurs iPhone réels, notamment avec des focales de téléobjectif différentes, avant diffusion.

## Choix techniques et limites

- Les photos source sont conservées localement jusqu’à l’enregistrement du résultat ou l’abandon de la session. L’application ne transmet pas d’images à un serveur.
- Le premier passage est limité à 30 vues et le second à six reprises. Un cadrage téléobjectif qui dépasserait cette limite n’est pas proposé.
- L’assembleur ajuste sa résolution de sortie selon la mémoire de l’appareil, avec un plafond de 48 mégapixels. Les exports sont des HEIF SDR en Display P3 ; les données HDR étendues et ProRAW ne sont pas conservées.
- La scène doit présenter suffisamment de détails communs entre les vues. Un sujet en mouvement, une rotation autour d’un autre point que l’iPhone ou un premier plan très proche peut rendre l’assemblage difficile.

## Organisation

- `UltraWide/Capture` : caméra AVFoundation, guidage Core Motion, reprise et contrôle des vues.
- `UltraWide/Stitching` : moteur OpenCV natif et interface Swift.
- `UltraWide/UI` : interface SwiftUI, prise de vue, second passage et examen du résultat.
- `UltraWideTests` : tests de planification des cadrages et des limites.
