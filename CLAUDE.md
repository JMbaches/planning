# CLAUDE.md — Planning JM Bâches (autonome)

Brief technique pour reprise du projet. Lis ce fichier en entier avant d'agir.

## En une phrase
Planification des chantiers de pose (volets/bâches) : affectation binômes,
créneaux, priorité d'ancienneté, extraction de contrat par IA. App autonome.
Utilisée en production sur la VM (`http://<VM>:8080/planning/`, mode partagé, voir
plus bas) ; la version GitHub Pages (**https://jmbaches.github.io/planning/**) reste
100 % locale.

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
- Persistance `localStorage` (clés `jmb_chantiers_v1`, `jmb_binomes_v1`,
  `jmb_settings_v1`, `jmb_edt_v1`, etc. — voir l'objet `SK` en tête de fichier).
- **Mode partagé (VM uniquement)** : actif seulement si `firebase-config.js` est servi à
  côté d'`index.html` (généré sur la VM, jamais dans ce dépôt public). Connexion Firebase
  Auth, puis les 4 clés `CLES_PARTAGEES` sont synchronisées avec `GET/PUT /api/meta/…`
  de l'API de l'app de gestion. Le localStorage n'est plus qu'un cache, sous des noms
  préfixés `partage:` (la copie embarquée de l'app de gestion écrit les noms nus sur la
  même origine). Plusieurs postes travaillent en même temps : fusion élément par élément
  (chantier par `id`, semaine par semaine), écriture conditionnelle (`X-Version-Attendue`,
  409 → refusion), relecture toutes les 3 s (`/api/meta_versions`, 30 s en repli si l'API
  ne la connaît pas), voyant d'état en bas à gauche, copie en mémoire qui fait foi si le
  localStorage est plein, et récupération au démarrage du travail qui n'était pas parti en
  base. Une même semaine enregistrée sur deux postes ne se fusionne pas (celle du poste qui
  enregistre en second gagne) : un bandeau orange le signale.
  ⚠️ Ne jamais réintroduire un « gel » des écritures ni une erreur d'enregistrement
  silencieuse : c'est ce qui a fait perdre une journée de plannings le 2026-09-22.
  Toute modification de ce bloc se teste avec deux origines (`localhost` et `127.0.0.1`)
  contre une imitation de l'API — elles ne partagent pas le localStorage, comme deux PC.
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
