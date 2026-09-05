# Héberger l'app planning sur la VM

Aujourd'hui l'app est sur GitHub Pages et stocke tout dans le `localStorage` du navigateur :
chaque personne qui ouvre le lien voit une app **vide**, et le planning disparaît si le cache
est vidé. L'héberger sur la VM est le prérequis pour que plusieurs personnes travaillent sur
le même planning.

Deux étapes, à faire **dans l'ordre** :

1. **Héberger** (ce document) — l'app est servie par la VM. Elle reste en `localStorage`.
2. **Mettre en base** — les données passent en PostgreSQL et deviennent partagées.

⚠️ **Ne bascule pas les utilisateurs sur l'adresse de la VM entre les deux.** Le
`localStorage` est lié au domaine : en changeant d'adresse, le navigateur considère la VM
comme un autre site et l'app s'ouvre vide. Voir « Reprise des données » plus bas.

---

## Pourquoi une tâche planifiée et pas GitHub Actions

Un runner GitHub Actions exécute sur la VM du code venu de GitHub. C'est acceptable pour le
dépôt de l'app de gestion, qui est privé. Ce dépôt-ci est **public** : GitHub déconseille
explicitement d'y attacher un runner self-hosted, parce qu'une personne extérieure peut
proposer une modification qui s'exécuterait sur la machine.

Ici c'est l'inverse : **la VM va chercher le fichier, personne ne pousse vers la VM.** Aucune
exécution entrante, donc aucune surface d'attaque. C'est le principe déjà utilisé pour la
synchronisation Mégao.

---

## Étape 1 — Installer le script (une seule fois, sur la VM)

Copier [`deploy-planning.ps1`](deploy-planning.ps1) dans `C:\Scripts\` (créer le dossier au
besoin). Il ne contient aucun secret et le dépôt étant public, il n'a besoin d'aucune
authentification.

Premier lancement à la main, en PowerShell **administrateur** :

    powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\deploy-planning.ps1

Attendu : une ligne « Mise a jour deployee : ~396000 octets ». L'app est alors servie sur
**`http://<adresse-de-la-VM>:8080/planning/`** — attention au port, voir l'avertissement plus bas.

## Étape 2 — Automatiser

    schtasks /Create /TN "JMBaches - Deploiement app planning" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\deploy-planning.ps1" /SC MINUTE /MO 15 /RU SYSTEM /RL HIGHEST /F

Toutes les 15 minutes, la VM vérifie si l'app a changé sur GitHub. **Le fichier n'est recopié
que si son contenu diffère** (comparaison d'empreinte), donc la tâche peut tourner souvent
sans rien réécrire ni invalider le cache des navigateurs. Elle tourne en `SYSTEM`, donc sans
session ouverte.

Déclencher un déploiement immédiat sans attendre :

    schtasks /Run /TN "JMBaches - Deploiement app planning"

## Étape 3 — Vérifier

    Get-Content C:\inetpub\wwwroot\planning\_deploiement.log -Tail 10

Le journal ne consigne que ce qui compte : créations, mises à jour effectives et échecs. Les
passages sans changement n'écrivent rien.

Le script refuse de remplacer un fichier valide par une réponse tronquée ou une erreur
réseau : en cas d'échec, la version déjà en place reste servie (testé sur réponse trop
courte et sur 404).

### ⚠️ Deux serveurs web sur cette VM — ne pas se tromper de port

Relevé le 2026-09-05, après trois tentatives de déploiement infructueuses :

| Port | Serveur | Racine | Rôle |
|------|---------|--------|------|
| 80   | Apache 2.4.18 / PHP 5.6 (WAMP) | `c:/wamp/www` | **sans rapport** avec l'app de gestion |
| 8080 | IIS | `C:\inetpub\wwwroot` | sert l'app de gestion et relaie `/api` vers l'API Node du port 3000 |

**C'est le port 8080 qu'il faut viser**, donc `C:\inetpub\wwwroot\planning`. L'app est servie
sur `http://<adresse-de-la-VM>:8080/planning/`.

C'est indispensable et pas seulement pratique : l'app de planning doit être sur la **même
origine** que l'app de gestion pour réutiliser sa session et appeler `/api` sans modifier
quoi que ce soit côté API. Sur le port 80 elle serait sur une autre origine, donc coupée des
deux.

Le port 80 est ce qui a fait perdre le plus de temps : tester `http://<vm>/planning/` interroge
Apache, qui répond `403 Forbidden` — un serveur qui n'a rien à voir avec l'affaire. Le runbook
et le `web.config` du dépôt de l'app de gestion décrivaient bien IIS : ils avaient raison, mais
ils ne mentionnent pas le port, ni l'existence du second serveur.

### Le piège des droits sur le fichier déposé

Sous Windows, **déplacer** un fichier conserve les droits de sa source, alors que le **copier**
lui fait hériter de ceux du dossier de destination. Un fichier arrivé depuis `%TEMP%` par un
déplacement est donc illisible par le compte d'IIS, qui répond `401` — même si le dossier qui
le contient a, lui, les bons droits.

Le symptôme est trompeur : le dossier paraît correct, seul le fichier est en cause. Pour
comparer, un fichier qui fonctionne porte `IIS_IUSRS:(I)(RX)` et tout est marqué `(I)`, hérité.

    icacls C:\inetpub\wwwroot\index.html            # celui-ci fonctionne
    icacls C:\inetpub\wwwroot\planning\index.html   # comparer avec

Réparation manuelle si besoin :

    icacls C:\inetpub\wwwroot\planning\index.html /reset

Le script le fait désormais tout seul à chaque passage, indépendamment du contenu — ce point
compte : le contenu peut être le bon et les droits mauvais, et une comparaison de contenu seule
ne détecte jamais ce cas.

⚠️ Ne pas confondre avec l'app planning **embarquée** dans l'app de gestion (onglet Planning,
iframe) : c'est une copie distincte et plus ancienne, dans un autre dépôt. Voir `CLAUDE.md`.

---

## Reprise des données

Le `localStorage` ne suit pas le changement d'adresse. Avant de basculer :

1. Dans l'app actuelle → **Paramètres → Exporter une sauvegarde**. Garder le fichier
   ailleurs que dans Téléchargements : tant que la mise en base n'est pas faite, c'est la
   seule copie du planning en dehors d'un cache de navigateur.
2. Une fois la VM en service → **Paramètres → Restaurer / importer** avec ce fichier.

⚠️ Si la case « Inclure les clés API » était cochée, la sauvegarde contient les clés
Anthropic et OpenRouteService **en clair**. Ne pas l'envoyer par mail, ne pas la committer.

---

## Étape suivante : les données en base

Tant que ce n'est pas fait, l'app hébergée sur la VM reste en `localStorage` : accessible à
tous, mais **chacun voit encore son propre planning**.

Ce qui est prévu :

1. Ajouter le SDK Firebase Auth. Servie sur le même domaine que l'app de gestion, l'app
   réutilise la session déjà ouverte — pas de second mot de passe.
2. Router les 6 clés de `SK` (`chantiers`, `binomes`, `settings`, `edt`, `closures`,
   `validatedPlans`) vers `GET`/`PUT /api/meta/<clé>`, le stockage clé-valeur JSON déjà
   présent dans l'API. **Aucune table à créer, aucune route à écrire.** Le `localStorage`
   reste en cache local.
3. Les clés API personnelles et le cache de géocodage restent en local.

Volumétrie mesurée sur une sauvegarde réelle (sept. 2026) : 72 chantiers = 37 Ko, 9 semaines
enregistrées = 315 Ko, la plus grosse semaine 54 Ko. Très loin de la limite de 10 Mo par
requête de l'API : écriture en un seul bloc par clé, aucun découpage nécessaire.

Point de vigilance : ces clés sont des blocs entiers, donc le dernier qui écrit écrase. La
table `meta` a une colonne `updated_at` — on s'en sert pour refuser une écriture si la base a
changé depuis le chargement (« le planning a été modifié entre-temps, recharge ») plutôt que
d'effacer le travail de quelqu'un en silence.
