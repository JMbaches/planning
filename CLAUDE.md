# CLAUDE.md — Planning JM Bâches (autonome)

Brief technique pour reprise du projet. Lis ce fichier en entier avant d'agir.

## En une phrase
Planification des chantiers de pose (volets/bâches) : affectation binômes,
créneaux, priorité d'ancienneté, extraction de contrat par IA. App autonome,
**tout en local** (pas de Firebase ici). Déployé : **https://jmbaches.github.io/planning/**

## ⚠️ Ce dépôt a une copie jumelle — à lire avant tout fix
Il existe une **deuxième copie** de cette app, embarquée dans l'app de gestion
de dossiers (`JMbaches.github.io/planning.html` + `planning.js`, dépôt séparé).
Les deux copies **ne sont pas synchronisées automatiquement** — c'est une
maintenance manuelle : tout correctif sur l'algorithme de planning (priorités,
créneaux, affichage) doit être **réappliqué à la main dans les deux dépôts**,
sur les mêmes zones de code. Voir le `CLAUDE.md` du dépôt `JMbaches.github.io`
pour la méthode de resynchronisation déjà utilisée par le passé.

## Architecture
- `index.html` : app React en un seul fichier (composants inline, pas de build,
  pas de bundler). Toute la logique est dedans.
- **Aucun Firebase.** Persistance 100% `localStorage` (clés `jmb_chantiers_v1`,
  `jmb_binomes_v1`, `jmb_settings_v1`, `jmb_edt_v1`, `jmb_closures_v1`,
  `jmb_validated_plans_v1`, etc. — voir l'objet `SK` en tête de fichier).
- Deux clés API saisies et stockées par l'utilisateur, en local uniquement :
  - une clé API Claude (`jmb_api_key_v1`) pour l'extraction de contrat par IA
    depuis un PDF (`extractContractFromPDF`, appel direct à l'API Claude) ;
  - une clé OpenRouteService (`jmb_ors_key_v1`) pour le calcul de distances/trajets.
  Ces clés vivent dans le navigateur de chaque utilisateur (Paramètres) — pas
  de backend qui les centralise. Si l'app est réinstallée/vidée, il faut les
  ressaisir.
- Algorithme de priorité : priorité d'ancienneté renforcée (bonus dégressif,
  pas un simple départage), priorité aux commandes les plus anciennes à
  distance équivalente, plafond horaire du soir (constante `WORKDAY_END_MIN`).

## Retour Planning → Admin (app de gestion)
Le statut "validé" côté Planning IA ne remonte à l'app de gestion que lorsqu'il
est réellement validé (pas avant) — logique déjà en place, attention à ne pas
la casser en modifiant le pont d'intégration côté copie embarquée.

## Historique détaillé
Journalisé dans la mémoire Claude de ce projet (fichier `project_planning_app.md`
côté Claude).
