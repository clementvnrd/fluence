# Installer Fluence sur un autre Mac

Ce guide est pour quelqu'un qui n'a jamais vu Fluence. Comptez dix minutes, dont la plus grande partie est un téléchargement de modèles de voix.

## Ce qu'il faut

- Un **Mac avec une puce Apple** (M1 ou plus récent) sous **macOS 26 ou plus récent**. Fluence ne s'installe pas sur un Mac Intel ni sur un macOS plus ancien.
- Environ **1 Go** de place libre : l'app est petite, les modèles de voix qu'elle télécharge ensuite ne le sont pas.
- Fluence existe aussi pour Windows, mais pas dans cette version.

## 1. Récupérer l'app

Téléchargez **`Fluence-<version>.zip`** depuis la page des versions : <https://github.com/clementvnrd/fluence/releases/latest>. Safari ouvre l'archive tout seul ; sinon, double-cliquez dessus dans *Téléchargements*.

Vous obtenez **Fluence** (une icône bleue ronde). Glissez-la dans le dossier **Applications**.

Facultatif : le fichier `.sha256` à côté de l'archive permet de vérifier que le téléchargement est intact. Dans Terminal : `shasum -a 256 -c Fluence-<version>.zip.sha256` doit répondre `OK`.

## 2. Premier lancement : macOS demande une autorisation

Fluence n'est **pas notarisée par Apple** : cela coûte un abonnement de développeur que Clement n'a pas voulu prendre. macOS affiche donc un avertissement au premier lancement d'une copie téléchargée. Ce n'est pas un signe que l'app est abîmée, et vous ne le verrez **qu'une seule fois**.

1. Double-cliquez sur Fluence dans *Applications*. macOS répond qu'il ne peut pas vérifier l'app. Cliquez sur **Terminé** (surtout pas sur « Placer dans la corbeille »).
2. Ouvrez **Réglages Système › Confidentialité et sécurité**, et descendez jusqu'à la section **Sécurité**.
3. Une ligne dit que « Fluence » a été bloquée. Cliquez sur **Ouvrir quand même**, puis confirmez avec votre mot de passe ou Touch ID.
4. Fluence s'ouvre. Les lancements suivants sont normaux, et les mises à jour de Fluence aussi.

Les libellés peuvent varier légèrement d'une version de macOS à l'autre. Si vous ne voyez pas le bouton *Ouvrir quand même*, relancez Fluence une fois : il n'apparaît que pendant une heure environ après la tentative.

## 3. Les autorisations

Au premier lancement, une fenêtre **Configurer Fluence** vous guide : une autorisation après l'autre, avec un bouton qui ouvre le bon réglage et un voyant qui s'allume quand c'est fait.

| Autorisation | Pourquoi | Obligatoire ? |
|---|---|---|
| **Accessibilité** | Écrire le texte dicté dans l'app où vous êtes | Oui |
| **Micro** | Entendre votre voix | Oui |
| **Réunions** (son des appels) | Enregistrer l'autre côté d'un appel, seulement pendant une prise de notes | Non |
| **Calendrier** | Donner un titre aux notes d'une réunion | Non |

Pour *Accessibilité*, Fluence ouvre la liste de macOS : activez l'interrupteur à côté de Fluence. La fenêtre de configuration passe à la suite toute seule.

## 4. La première dictée

1. Cliquez dans n'importe quel champ de texte (une note, un mail, un message).
2. **Maintenez ⌥ Espace**, parlez, puis relâchez : le texte s'écrit à l'endroit du curseur.

Au départ, Fluence utilise la reconnaissance vocale d'Apple, qui écoute dans la langue de votre Mac. Pour un français plus juste, notamment avec des mots techniques :

1. Ouvrez **Réglages › Transcription** et, à **Moteur vocal**, choisissez **Parakeet Ultra**.
2. Faites une première dictée et laissez-lui le temps : Fluence télécharge alors le modèle de voix (environ 600 Mo, une seule fois). La première dictée est lente ; les suivantes sont presque instantanées.

Pour changer de raccourci, de langue ou de micro : **Réglages**, dans la fenêtre Fluence ou depuis l'icône de la barre des menus.

## Mises à jour

Fluence vérifie une fois par jour si une nouvelle version existe. Si une version est trouvée, elle vous demande **Installer** ou **Plus tard**, jamais pendant que vous dictez ou enregistrez une réunion. **Réglages › À propos** permet de couper la vérification.

## Ce qui reste sur votre Mac

Votre voix, les textes dictés et les notes de réunion restent sur votre Mac, chiffrés. Fluence ne se connecte à Internet que pour deux choses : vérifier les mises à jour et télécharger les modèles de voix. Aucun texte, aucun son, aucun nom ne part. La liste complète des composants et de leurs licences est dans **Réglages › À propos › Licences**.

## Si ça ne marche pas

| Ce que vous voyez | Ce qu'il faut faire |
|---|---|
| macOS refuse d'ouvrir Fluence | Refaites l'étape 2 (*Ouvrir quand même*). Si le message persiste, retéléchargez l'archive et comparez son empreinte (étape 1). |
| Rien ne s'écrit quand vous relâchez la touche | Vérifiez *Accessibilité* : Fluence doit y être cochée. Quittez puis rouvrez Fluence. |
| La dictée donne du texte étranger ou illisible | Choisissez le bon micro dans **Réglages › Dictée** (un micro de webcam fonctionne). |
| L'icône disparaît du Dock quand vous fermez la fenêtre | C'est voulu : Fluence reste dans la **barre des menus** (en haut à droite) ; « Ouvrir Fluence » y rouvre la fenêtre. |

Pour toute autre difficulté, écrivez à Clement avec la version indiquée dans **Réglages › À propos**.
