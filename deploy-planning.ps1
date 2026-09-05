<#
    Deploiement de l'app planning sur la VM, sans runner GitHub Actions.

    Principe : la VM va CHERCHER le fichier sur GitHub, personne ne pousse vers la VM.
    Aucune execution entrante, donc aucune surface d'attaque -- contrairement a un runner
    self-hosted, deconseille par GitHub sur un depot public. Meme principe que la synchro
    Megao, deja en place sur cette VM.

    A lancer par une tache planifiee Windows (voir DEPLOIEMENT_VM.md).
    Le fichier n'est recopie QUE s'il a change (comparaison d'empreinte), donc la tache peut
    tourner souvent sans rien reecrire ni casser le cache des navigateurs.
#>

param(
    # Valeurs par defaut = la VM. Surchargeables pour tester ailleurs sans rien deployer.
    [string] $Source      = 'https://raw.githubusercontent.com/JMbaches/planning/main/index.html',
    # ATTENTION : cette VM heberge DEUX serveurs web.
    #   - port 80   : Apache 2.4.18 / PHP 5.6 (WAMP), DocumentRoot c:/wamp/www.
    #                 Rien a voir avec l'app de gestion. C'est lui qui renvoyait un 403 quand on
    #                 testait http://<vm>/planning/ -- on interrogeait le mauvais serveur.
    #   - port 8080 : IIS, qui sert l'app de gestion (Aquamaster) ET relaie /api vers l'API Node
    #                 du port 3000. C'est CE serveur qui doit servir l'app de planning, pour
    #                 qu'elle soit sur la meme origine que l'app de gestion : sans ca, pas de
    #                 session partagee et pas d'appel a /api possible.
    # D'ou la destination ci-dessous, la racine d'IIS. L'app est alors sur
    # http://<vm>:8080/planning/
    [string] $Destination = 'C:\inetpub\wwwroot\planning',
    [string] $Journal     = '',
    # Fichier de l'app de gestion d'ou est relue la configuration Firebase (voir plus bas).
    [string] $SourceConfig = 'C:\inetpub\wwwroot\postgres-layer.js',
    [int]    $TailleMini  = 100000   # garde-fou : l'app fait ~390 Ko, en dessous c'est une reponse tronquee
)

$ErrorActionPreference = 'Stop'
if (-not $Journal) { $Journal = Join-Path $Destination '_deploiement.log' }

function Ecrire-ConfigFirebase {
    $cfg = Join-Path $Destination 'firebase-config.js'
    if (-not (Test-Path $SourceConfig)) {
        Ecrire-Journal "postgres-layer.js introuvable ($SourceConfig) : l'app restera en mode local."
        return
    }
    try {
        $src = Get-Content $SourceConfig -Raw
        if ($src -notmatch '(?s)const\s+firebaseConfig\s*=\s*(\{.*?\})\s*;') {
            Ecrire-Journal "Bloc firebaseConfig introuvable dans postgres-layer.js : mode local."
            return
        }
        $contenu = "// Genere automatiquement par deploy-planning.ps1 depuis postgres-layer.js." + [Environment]::NewLine `
                 + "// Ne pas modifier a la main, ne pas committer : ce fichier n'existe que sur la VM." + [Environment]::NewLine `
                 + "window.JMB_FIREBASE_CONFIG = " + $Matches[1] + ";" + [Environment]::NewLine
        # Comparaison sur contenu ajuste : Set-Content ajoute un saut de ligne final, donc une
        # egalite stricte serait toujours fausse et le fichier serait reecrit -- et journalise --
        # a chaque passage de la tache planifiee, noyant le journal.
        $ancien = if (Test-Path $cfg) { (Get-Content $cfg -Raw) } else { '' }
        if ($ancien.Trim() -ne $contenu.Trim()) {
            Set-Content -Path $cfg -Value $contenu -Encoding utf8
            Ecrire-Journal 'firebase-config.js genere (mode partage actif).'
        }
    } catch {
        Ecrire-Journal "Generation de firebase-config.js impossible : $($_.Exception.Message)"
    }
}

function Ecrire-Journal([string] $Message) {
    $ligne = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $ligne
    try { Add-Content -Path $Journal -Value $ligne -Encoding utf8 } catch {}
}

try {
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        Ecrire-Journal "Dossier $Destination cree."
    }

    $cible      = Join-Path $Destination 'index.html'
    $temporaire = Join-Path $env:TEMP ('planning-{0}.html' -f [guid]::NewGuid())

    # -UseBasicParsing : indispensable, la VM n'a pas de session Internet Explorer configuree.
    Invoke-WebRequest -Uri $Source -OutFile $temporaire -UseBasicParsing

    $taille = (Get-Item $temporaire).Length
    if ($taille -lt $TailleMini) {
        Remove-Item $temporaire -Force
        throw "Fichier telecharge anormalement petit ($taille octets). Rien n'a ete remplace."
    }

    # On ne remplace que si le contenu a reellement change : evite de reecrire le fichier
    # a chaque passage de la tache planifiee, et donc d'invalider le cache des navigateurs.
    # Si le fichier en place est illisible (droits abimes), on ne compare pas : on le remplace.
    # Sans ce filet, le calcul d'empreinte levait une exception et le script s'arretait -- donc
    # un fichier mal installe une fois ne pouvait plus JAMAIS etre repare automatiquement.
    $identique = $false
    if (Test-Path $cible) {
        try { $identique = (Get-FileHash $temporaire).Hash -eq (Get-FileHash $cible).Hash }
        catch { Ecrire-Journal "Fichier en place illisible, il sera remplace." }
    }

    # REPARATION DES DROITS, independante du contenu.
    # Un fichier peut avoir le BON contenu et de MAUVAIS droits : c'est le cas de tout fichier
    # installe par une version precedente de ce script, qui utilisait Move-Item (un deplacement
    # conserve les droits de la source, ici %TEMP%). Le fichier arrive alors sans le compte
    # d'IIS dans ses droits, et IIS repond 401 -- constate sur la VM le 2026-09-05.
    # Comparer le contenu ne suffisait donc pas : le script ressortait "rien a faire" en laissant
    # le fichier illisible indefiniment. On remet l'heritage a chaque passage ; c'est idempotent
    # et sans effet quand tout va bien.
    # On passe par icacls /reset plutot que Get-Acl/Set-Acl : ce dernier reclame le privilege
    # SeSecurityPrivilege, dont le compte executant la tache ne dispose pas forcement, alors
    # qu'icacls /reset se contente du droit de modifier les permissions du fichier.
    if (Test-Path $cible) {
        $protege = $false
        try { $protege = (Get-Acl $cible).AreAccessRulesProtected } catch { $protege = $true }
        if ($protege) {
            & icacls.exe $cible /reset | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Ecrire-Journal 'Droits du fichier reinitialises (heritage du dossier retabli).'
            } else {
                Ecrire-Journal "Echec de la reinitialisation des droits (icacls code $LASTEXITCODE)."
            }
        }
    }

    # ---- Configuration Firebase, generee depuis l'app de gestion ----------------------------
    # L'app de planning n'entre en mode partage (donnees en base) que si ce fichier existe a
    # cote d'index.html. On le FABRIQUE ici, en relisant la configuration de l'app de gestion
    # deja presente sur la VM, plutot que de la committer : le depot planning est public, et
    # cela garantit en prime que les deux apps parlent toujours au meme projet Firebase.
    # Si le fichier ne peut pas etre genere, l'app reste en mode local -- degradation propre.
    Ecrire-ConfigFirebase

    if ($identique) {
        Remove-Item $temporaire -Force
        # Pas de journal ici : la tache tourne souvent, ca noierait les vraies informations.
        exit 0
    }

    # Copy-Item et NON Move-Item. Sous Windows, deplacer un fichier CONSERVE les droits qu'il
    # avait a la source ; le copier lui fait HERITER de ceux du dossier de destination. Un
    # fichier deplace depuis %TEMP% vers la racine web arrive donc illisible pour le compte
    # d'IIS, qui repond 401 -- constate sur la VM le 2026-09-05, le dossier ayant pourtant les
    # bons droits. La copie regle ca sans avoir a toucher aux ACL.
    # Suppression prealable indispensable : ecraser un fichier existant en conserve les droits.
    # Sans ca, un fichier deja installe avec de mauvaises permissions les garderait indefiniment
    # et le correctif ci-dessus n'aurait aucun effet.
    if (Test-Path $cible) { Remove-Item $cible -Force }
    Copy-Item -Path $temporaire -Destination $cible -Force
    Remove-Item $temporaire -Force
    Ecrire-Journal "Mise a jour deployee : $taille octets."
    exit 0
}
catch {
    Ecrire-Journal "ECHEC : $($_.Exception.Message)"
    exit 1
}
