# Ultra Wide

Ultra Wide est une application iPhone en SwiftUI qui compose une image plus large à partir d’un balayage continu de **l’objectif principal physique**. Le cadrage visé est celui d’un **0,5×** environ. Un téléobjectif physique peut aussi être choisi quand l’iPhone en possède un ; les cadrages proposés dépendent de sa focale et de la couverture réalisable.

## Prise de vue

1. Choisir l’objectif et le cadrage. L’aperçu est déjà actif : pointer le centre de la scène et toucher le bouton rond.
2. Balayer librement, dans n’importe quel ordre. Le petit cadre ambre représente le champ instantané de l’iPhone dans le cadre final ; les zones colorées sont déjà couvertes. Le flux vidéo est échantillonné en images nettes qui se recouvrent.
3. La capture s’arrête et l’assemblage commence automatiquement lorsque tout le cadre est couvert. Le bouton rond permet aussi d’arrêter plus tôt. Si l’assemblage demande des vues supplémentaires, choisir **Continuer** pour compléter le même balayage.
4. Examiner le résultat, l’enregistrer dans Photos ou le partager. Une session interrompue peut être reprise après réalignement de la vue centrale.

La caméra choisie reste la même pendant tout le balayage. Le résultat est un assemblage géométrique en projection rectilinéaire, avec sélection des raccords, harmonisation et fusion multibande. Si les images ne se recouvrent pas assez ou si le cadrage demandé n’est pas couvert, l’application conserve la session afin de compléter les zones manquantes.

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

Les tests de planification et de couverture se lancent avec `xcodebuild test` sur un simulateur iOS 26 ou plus récent. `UltraWideTests/test_stitch_projection.py` rejoue deux balayages synthétiques avec OpenCV 4.13. Sur iPhone, `NativeStitchIntegrationTests` vérifie l’export HEIF et `CameraPipelineIntegrationTests` vérifie le format des images du flux après autorisation de la caméra. La qualité des captures réelles doit être validée sur plusieurs iPhone avant diffusion.

## Choix techniques et limites

- Les images source sélectionnées dans le flux sont conservées localement jusqu’à l’enregistrement du résultat ou l’abandon de la session. L’application ne transmet pas d’images à un serveur.
- Le flux continu retient au plus 60 images utiles. Le champ vidéo réellement livré, y compris son ratio, sert à calculer la couverture ; il est souvent plus étroit qu’une photo 4:3. Un cadrage téléobjectif qui demanderait un balayage trop long n’est pas proposé.
- L’assembleur ajuste sa résolution de sortie selon la mémoire de l’appareil, avec un plafond de 48 mégapixels. Les exports sont des HEIF SDR en Display P3 ; les données HDR étendues et ProRAW ne sont pas conservées.
- Les images d’entrée proviennent du flux vidéo : chacune peut être moins détaillée qu’une photo fixe haute résolution. La couverture du capteur principal et le recouvrement entre vues compensent partiellement cette limite dans l’image finale.
- La scène doit présenter suffisamment de détails communs entre les vues. Un sujet en mouvement, une rotation autour d’un autre point que l’iPhone ou un premier plan très proche peut rendre l’assemblage difficile.

## Organisation

- `UltraWide/Capture` : caméra AVFoundation en continu, guidage Core Motion, couverture et reprise.
- `UltraWide/Stitching` : moteur OpenCV natif et interface Swift.
- `UltraWide/UI` : interface SwiftUI, cadre de couverture, prise de vue et examen du résultat.
- `UltraWideTests` : tests de cadrage, de couverture et de projection OpenCV synthétique.
