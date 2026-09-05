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
    # Racine d'Apache relevee sur la VM le 2026-09-05 : c'est du WAMP, pas IIS.
    #   DocumentRoot "c:/wamp/www"   (c:\wamp\bin\apache\apache2.4.18\conf\httpd.conf)
    # La machine possede AUSSI un C:\inetpub\wwwroot, vestige d'IIS, qu'Apache ne sert pas.
    # Ne pas s'y fier : le runbook et le web.config du depot de l'app de gestion decrivent une
    # installation IIS qui ne correspond plus a la realite de la machine.
    [string] $Destination = 'C:\wamp\www\planning',
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
    $identique = $false
    if (Test-Path $cible) {
        $identique = (Get-FileHash $temporaire).Hash -eq (Get-FileHash $cible).Hash
    }

    if ($identique) {
        Remove-Item $temporaire -Force
        # Pas de journal ici : la tache tourne souvent, ca noierait les vraies informations.
        exit 0
    }

    Move-Item -Path $temporaire -Destination $cible -Force
    Ecrire-Journal "Mise a jour deployee : $taille octets."
    exit 0
}
catch {
    Ecrire-Journal "ECHEC : $($_.Exception.Message)"
    exit 1
}
