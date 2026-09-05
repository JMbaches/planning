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
    [int]    $TailleMini  = 100000   # garde-fou : l'app fait ~390 Ko, en dessous c'est une reponse tronquee
)

$ErrorActionPreference = 'Stop'
if (-not $Journal) { $Journal = Join-Path $Destination '_deploiement.log' }

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
