# Quotum — le code qui touche à vos identifiants

Quotum est une application de barre de menus pour macOS, vendue sur
[quotum.app](https://quotum.app/fr/). Elle affiche ce qu'il reste de quota sur vos comptes d'outils
de codage — vingt-cinq outils, de Claude et Codex à Cursor, Windsurf, Grok, Kiro ou GitHub
Copilot — en relisant les identifiants que ces outils ont déjà posés sur votre machine, en
lançant leur outil en ligne de commande officiel, sur sa seule commande d'affichage du quota, ou,
pour Z.ai et MiniMax, avec la clé que vous collez vous-même.
⚠️ Pour Antigravity, rien d'officiel ne garantit que cette commande ne consomme aucun quota : la
mise en garde est affichée avant que vous suiviez l'outil.

Une application qui lit votre Trousseau doit pouvoir être contredite. Ce dépôt,
`mashgundash/quotum-transparence`, publie en lecture seule **la partie de son code source qui lit
un identifiant, envoie une requête, écrit sur un compte, garde votre consentement ou lance
l'outil d'un autre éditeur** — pour que vous puissiez vérifier la page
[Ce que Quotum lit sur votre machine](https://quotum.app/fr/lecture) sans nous croire sur parole.

## Ce que ce dépôt n'est pas

- **Ce n'est pas l'application.** L'interface, le panneau, la grille, l'appariement des comptes,
  le modèle de quota, les actions (lancer une app, épingler un terminal), les traductions et le
  point d'entrée ne sont pas publiés. Un peu moins de la moitié du code source y est.
- **Ce n'est pas la mécanique de licence.** La vérification de la clé, l'activation d'un Mac,
  l'ouverture de l'essai, la clé que la puce crée et le témoin d'essai ne sont pas publiés : leur
  lecture indiquerait quoi neutraliser dans le binaire. Ce qu'emportent les deux requêtes de la
  licence et de l'essai reste vérifiable ici, par le test qui les construit — voir
  [Les trois requêtes vers l'éditeur](#les-trois-requêtes-vers-léditeur).
- **Il ne se compile pas.** Les fichiers dépendent de types qui ne sont pas ici — la liste est
  plus bas. `swiftc -typecheck` échoue à la première passe, et c'est voulu.
- **Ce n'est pas un projet ouvert aux contributions.** Voir [Licence](#licence).
- **Il ne remplace pas le binaire.** Rien ici ne permet de reconstruire l'application vendue ni de
  comparer ce code au binaire octet pour octet. Ce qui relie les deux est expliqué dans
  [Ce que ce dépôt ne peut pas prouver](#ce-que-ce-dépôt-ne-peut-pas-prouver).

## D'où viennent ces fichiers

Chaque fichier est recopié **à l'identique** depuis le dépôt de développement, au même chemin,
pour une version donnée. `PROVENANCE` dit laquelle. `SHA256SUMS` donne l'empreinte de chaque
fichier du dépôt — ce `README.md`, `LICENSE` et `PROVENANCE` compris —, sauf la sienne, qu'il ne
peut pas contenir. Les numéros de ligne cités sur quotum.app sont donc ceux que vous lisez ici.

```sh
shasum -a 256 -c SHA256SUMS
```
recalcule l'empreinte de chaque fichier listé, et signale celui qui a changé ou qui manque. Elle
ne voit pas un fichier ni un lien ajoutés hors de la liste ; la commande suivante, si, et ne rend rien quand
le dépôt ne contient que les fichiers listés et `SHA256SUMS` :

```sh
diff <(find . -path ./.git -prune -o \( -type f -o -type l \) ! -path ./SHA256SUMS -print | sed 's|^\./||' | LC_ALL=C sort) <(cut -c67- SHA256SUMS | LC_ALL=C sort)
```

## Les fichiers, et ce que chacun permet de vérifier

| Fichier | Ce qu'il fait |
|---|---|
| `Sources/Quotum/Donnees/Outils.swift` | La session réseau : `ephemeral`, sans cache, sans en-tête de session |
| `Sources/Quotum/Systeme/Processus.swift` | L'exécution des utilitaires système, arguments en tableau, jamais par un shell |
| `Sources/Quotum/Donnees/Trousseau.swift` | La seule lecture d'un élément du Trousseau qui appartient à un autre outil, par `/usr/bin/security` |
| `Sources/Quotum/Donnees/IdentifiantsCodex.swift` | `~/.codex/auth.json`, et chaque autre `auth.json` de Codex connu, un même dossier une seule fois, lus sans être réécrits |
| `Sources/Quotum/Donnees/TrousseauCodex.swift` | La connexion de Codex quand son `config.toml` la range au Trousseau (`cli_auth_credentials_store` à `keyring` ou `auto`), lu par un analyseur TOML complet qui ne devine jamais un mode incertain : l'élément `Codex Auth` du compte `cli\|…` de ce `CODEX_HOME`, lu par la fonction de `Trousseau.swift`, jamais écrit ; en `auto`, `auth.json` seulement si l'élément est absent ; le stockage chiffré (`secret_auth_storage`) n'est pas lu ; un refus suspend la lecture jusqu'à « Actualiser » ; le suivi se relit juste avant chaque ouverture, pour `auth.json` dans le travail même de la file |
| `Sources/Quotum/Donnees/IdentiteClaudeCode.swift` | `~/.claude.json`, trois clés, aucun jeton |
| `Sources/Quotum/Donnees/Quota*.swift` (26) | Un fichier par outil, plus un second pour Codex connecté par jeton personnel : l'identifiant lu, la requête envoyée ou l'outil lancé, la réponse lue |
| `Sources/Quotum/Donnees/ReleveurMuse.swift` | La cadence de Muse Code — chaque mesure crée une clé sur votre compte Meta : un envoi au plus toutes les quinze minutes, même après une relance de l'application |
| `Sources/Quotum/Systeme/LanceurCLISysteme.swift`, `Sources/Quotum/Systeme/ResultatCLI.swift`, `Sources/Quotum/Donnees/OutilsCLI.swift` | La seule exécution d'un binaire tiers : chemin vérifié, liste fermée, jamais de shell, sortie bornée |
| `Sources/Quotum/Donnees/ReserveCodex.swift` | La réserve et l'historique des réinitialisations Codex, lus quand vous dépliez le tiroir |
| `Sources/Quotum/Donnees/StatistiquesCodex.swift` | L'usage Codex jour par jour, lu au même dépli : une requête qui se présente comme Quotum, dont seuls l'usage par jour et par semaine et la date des données sont gardés, en mémoire |
| `Sources/Quotum/Donnees/LecteurProxy.swift` | Les deux proxys de la boucle locale |
| `Sources/Quotum/Donnees/RelevesDirects.swift` | La garde de consentement, fournisseur par fournisseur |
| `Sources/Quotum/Donnees/Inventaire.swift` | Le seul appel de cette garde, et les lectures faites sans elle |
| `Sources/Quotum/Modeles/Reglages.swift` | Où le consentement est rangé, et ce qu'il vaut à l'installation |
| `Sources/Quotum/Donnees/HistoriquePlanClaude.swift` | L'historique que l'application de bureau Claude écrit elle-même dans son dossier de données |
| `Sources/Quotum/Donnees/HistoriqueRolloutCodex.swift` | La fin des journaux de session du CLI Codex |
| `Sources/Quotum/Donnees/Decouverte.swift` | `~/Applications`, le `Local State` de Chrome, `ps` |
| `Sources/Quotum/Donnees/ReinitialisationCodex.swift` | L'une des deux écritures sur un compte : la réinitialisation du quota Codex |
| `Sources/Quotum/Donnees/ArmementReinitialisation.swift` | Les conditions de cette écriture |
| `Sources/Quotum/Donnees/RegistreReinitialisation.swift` | Ce qui l'empêche de partir deux fois |
| `Sources/Quotum/Donnees/ReinitialisationAutomatique.swift` | Le mode sans confirmation, éteint par défaut |
| `Sources/Quotum/Systeme/MiseAJour.swift` | Les mises à jour : la seule des trois requêtes vers l'éditeur dont le code est ici |
| `Sources/Quotum/Donnees/DepenseAnthropicEntreprise.swift` | La clé de lecture : la garde de saisie, et la seule requête qu'elle permet, la dépense Claude Enterprise |
| `Sources/Quotum/Donnees/ClesDeLecture.swift` | L'une des écritures au Trousseau : la clé de lecture que vous avez collée, dans un élément propre à Quotum |
| `Sources/Quotum/Donnees/ClesOutil.swift` | L'autre écriture au Trousseau d'une clé collée : celle de Z.ai ou de MiniMax, dans un élément propre à Quotum (`app.quotum.mac.cle-outil`), avec sa région ; la clé relue repasse par la garde de saisie avant de partir, et ne part qu'à l'hôte de sa région (`QuotaZai.swift`, `QuotaMiniMax.swift`) |
| `Sources/Quotum/Donnees/SuiviCleLecture.swift` | Sans clé, aucune requête ; le secret relu repasse par la garde avant de partir |
| `Sources/Quotum/Donnees/DepenseBudget.swift`, `Sources/Quotum/Donnees/SignatureAWS.swift`, `Sources/Quotum/Donnees/DepenseAWS.swift`, `Sources/Quotum/Donnees/DepenseAzure.swift` | Les budgets AWS et Azure, lus par une identité que vous avez collée. AWS : la signature faite sur le Mac et l'utilisateur racine refusé, mais aucune route ne permet de vérifier que l'identité n'a pas d'autres droits — l'écran de saisie le dit. Azure : toute permission du principal qui n'est pas une lecture fait refuser l'identité avant de lire un budget |
| `Tests/QuotumTests/GardesReseauTests.swift` | Le garde qui énumère chaque requête et ses en-têtes exacts, y compris le contrat des deux requêtes de la licence et de l'essai, dont le code n'est pas ici |

## Vérifier, promesse par promesse

Chaque commande s'exécute à la racine de ce dépôt. Les résultats donnés ont été relevés le
2026-10-11 ; une ligne qui aurait bougé depuis se retrouve par le même `grep`.

### La session réseau ne garde rien

```sh
grep -n ephemeral Sources/Quotum/Donnees/Outils.swift
```
rend `65:        let configuration = URLSessionConfiguration.ephemeral` — la commande et le
résultat de la section 06 du site, à l'identique. Les lignes 66 et 67 posent
`reloadIgnoringLocalCacheData` et `urlCache = nil`.

```sh
grep -rn httpAdditionalHeaders Sources/
```
ne rend rien : la session ne porte aucun en-tête, chaque identifiant est posé sur sa requête. Pour
l'en-tête `Authorization`, c'est ce qui le protège d'une redirection : posé sur la requête, il est
retiré par CFNetwork, ce qui a été mesuré sur macOS 26.6 et n'est pas un engagement d'Apple —
`GardesReseauTests.swift` dit la mesure et sa limite. Les lecteurs qui l'envoient refusent en plus
toute redirection qui change d'hôte ou passe en clair (`RedirectionMemeHoteSeulement`,
`Outils.swift`). Rien de cela ne couvre un cookie ni un secret placé dans le corps de la requête,
qu'une redirection 307 ou 308 rejoue : Cursor et Codebuff, qui envoient un cookie, ne suivent que
les redirections vers leur propre domaine ; Windsurf, dont la clé voyage dans le corps, et les
trois dépenses lues par une clé de lecture n'en suivent aucune (`QuotaWindsurf.RefusDeRedirection`).

### Le jeton ne fait que transiter

```sh
grep -rnE '\bprint\(|NSLog|\bdump\(' Sources/
```
ne rend rien. Les seules journalisations passent par `Journal.donnees` (`os.Logger`) ; lisez-les :
aucune n'interpole un jeton.

### Les identifiants des autres outils sont lus à un seul endroit ; trois écritures, dans des éléments propres à Quotum

```sh
grep -rn 'find-generic-password' Sources/
```
rend `Trousseau.swift:67` (commentaire) et `Trousseau.swift:91`, l'unique appel. Warp passe par
la même fonction (`QuotaWarp.swift:69`), comme Codex quand il range sa connexion au Trousseau
(`TrousseauCodex.swift`, élément `Codex Auth`). Aucune commande d'écriture du Trousseau
(`add-generic-password`, `delete-generic-password`) n'apparaît.

```sh
grep -rn 'SecItemAdd\|SecItemUpdate\|SecItemDelete' Sources/
```
rend `ClesDeLecture.swift:100`, `:104` et `:107` : l'élément « Quotum — clé de lecture »
(service `app.quotum.mac.cle-lecture`), écrit seulement quand vous collez une clé de lecture, et
supprimé quand vous la retirez ; puis `ClesOutil.swift:136`, `:141` et `:144` : les éléments
« Quotum — clé Z.ai » et « Quotum — clé MiniMax » (service `app.quotum.mac.cle-outil`), écrits
seulement quand vous collez la clé de l'un de ces outils, et supprimés quand vous la retirez. La
troisième écriture de l'application au Trousseau est l'élément « Quotum — essai ». Son code appartient à la mécanique de l'essai et n'est pas publié ; la
[politique de confidentialité](https://quotum.app/PRIVACY.md) dit ce qu'il contient, et
l'élément se lit dans Trousseaux d'accès. Aucun élément d'un autre outil n'est modifié.

### Toutes les requêtes

```sh
grep -rn 'session.data(for:' Sources/
```
rend vingt-sept lignes : les vingt lecteurs qui émettent une requête, la mesure d'un compte
Codex connecté par jeton personnel, la lecture d'un proxy, la réinitialisation et la réserve de
Codex, et les trois dépenses lues par une clé de lecture —
Claude Enterprise, AWS et Azure. JetBrains AI n'en émet aucune : son quota se lit dans un fichier.
Antigravity, Doubao, Alibaba Model Studio et Amp non plus : Quotum lance leur outil en ligne de
commande, en lecture seule, par `LanceurCLISysteme.swift`, la seule exécution d'un binaire tiers. Le
profil Anthropic passe par la même fonction que son quota. L'ouverture de l'essai et l'activation
d'un Mac n'y sont pas : leur code n'est pas publié, et `GardesReseauTests.swift` fixe les
en-têtes et les champs de leurs deux requêtes. La dépense Claude Enterprise, lue seulement avec une
clé de lecture que vous avez collée, passe par `DepenseAnthropicEntreprise.swift`.
`GardesReseauTests.requetesSortantes()`
en dresse la même liste et vérifie, pour chacune, l'ensemble exact des en-têtes envoyés et
qu'aucune ne se présente comme un client officiel, à une seule exception près : un compte Codex
connecté par jeton personnel (`personal_access_token`), dont les deux requêtes, vers
`auth.openai.com` puis `chatgpt.com`, s'annoncent comme le CLI officiel de Codex
(`User-Agent: codex_cli_rs/…`, `originator: codex_cli_rs`), seul moyen connu d'obtenir une réponse :

```sh
grep -rn 'static let agent' Sources/
```
rend `"Quotum"` pour tous les lecteurs qui envoient un `User-Agent`, hormis cette exception.

### Les adresses

```sh
grep -rn 'https\?://' Sources/
```
C'est la commande de la section 06 du site. **Ici elle rend moins de lignes que sur le dépôt
complet**, et voici exactement lesquelles manquent :

| Lignes absentes | Pourquoi elles ne sont pas ici |
|---|---|
| `Compte.swift:64, 65, 69-75, 78-93, 190, 191` | La page d'accueil et la page de téléchargement de chaque outil, **ouvertes par votre navigateur**, jamais interrogées par l'application (tableau B du site) |
| `VueReglages.swift:799` | `https://exemple.test`, adresse jetable qui sert à demander à macOS la liste des navigateurs (tableau C) |
| `VueFinEssai.swift:13, 14` | Les deux pages d'achat du site, française et anglaise, **ouvertes par votre navigateur** à la fin de l'essai (tableau B) |
| `CommandesInstallation.swift:9, 10` | Les installeurs officiels de Claude Code et de Codex, **une commande à copier** que l'accueil affiche quand il ne trouve aucune session : Quotum ne la lance jamais (tableau C) |
| `AdressesLicences.swift:5, 9` | Le service des licences de l'éditeur, et son double de test, compilé dans les seules copies de développement (tableau A) : la mécanique de licence n'est pas publiée |

Toutes les autres lignes du tableau A — celles où l'application se connecte — sont ici. L'adresse
d'Augment n'y figure pas plus qu'ailleurs : elle est lue dans `~/.augment/session.json`, et
`QuotaAugment.swift` ne l'accepte que sous `augmentcode.com`.

### Les proxys locaux ne quittent pas la machine

```sh
grep -n 'hotesDeLaBoucleLocale: Set' Sources/Quotum/Donnees/LecteurProxy.swift
```
rend `56: … ["127.0.0.1", "::1", "localhost"]` — une liste de ce qui est admis, pas de ce qui
est interdit. `RedirectionLocaleSeulement`, dans le même fichier, applique la même liste à toute
redirection.

### Rien n'est mesuré tant que vous ne suivez aucun outil

```sh
grep -c 'sousConsentement(\.' Sources/Quotum/Donnees/RelevesDirects.swift
grep -n 'mesureParJeton: \[String: Bool\] = \[:\]' Sources/Quotum/Modeles/Reglages.swift
```
rendent `25` — un passage par la garde pour chacun des vingt-cinq outils — et la ligne `478`, où
le consentement vaut « aucun outil suivi » à l'installation. `RelevesDirects.sousConsentement` ne
**lance** pas le lecteur d'un outil non suivi : ni jeton demandé, ni fichier ouvert, ni
requête.

### Les lectures faites sans suivi

```sh
grep -n 'async let' Sources/Quotum/Donnees/Inventaire.swift
```
rend les lectures d'un cycle. Toutes, sauf `RelevesDirects.relever`, partent **sans**
consentement : ce sont les sources que le site nomme « lues sans qu'aucun outil soit suivi ».
⚠️ L'une d'elles, `Correspondances.tables()`, lit `~/.config/quotum/comptes.json` — un fichier
de Quotum lui-même, qu'aucun autre outil n'écrit. Son code n'est pas publié.

Une autre se fait hors de ce cycle, à l'ouverture de la feuille « Ajouter un compte » :
`TracesAjoutOutil.surCeMac` vérifie seulement que les fichiers d'identifiants de quinze des
vingt-cinq outils existent — ou, pour Nous Portal et Factory Droid, leur dossier ; pour Windsurf,
aussi ses deux bases d'éditeur ; Grok Bot partage la base de Cursor —, sans les ouvrir, avant
même que le suivi soit activé ; les chemins sont ceux des lecteurs, cités un par un dans la
[politique de confidentialité](https://quotum.app/PRIVACY.md).
Claude et Codex, Warp, JetBrains AI, les quatre outils lancés par leur outil en
ligne de commande, Z.ai et MiniMax n'y sont pas regardés ; pour ces deux derniers, la feuille
regarde seulement si une clé est enregistrée dans l'élément du Trousseau propre à Quotum, sans la
lire (`ClesOutil.swift`). Elle regarde aussi si
`GROK_DEPLOYMENT_KEY` est posée, et n'interroge pas le Trousseau. Son code n'est pas publié.

Pour les journaux de session du CLI Codex, les bornes annoncées par le site :

```sh
grep -n 'static let \(joursExplores\|fichiersExplores\|lectureMaximale\)' Sources/Quotum/Donnees/HistoriqueRolloutCodex.swift
```
rend `29: … = 3`, `36: … = 40`, `43: … = 512 * 1024` — trois jours, quarante fichiers, la fin de
chacun, 512 Kio au plus.

### Le rafraîchissement ne descend pas sous la minute

```sh
grep -n 'plancherRafraichissement: TimeInterval' Sources/Quotum/Modeles/Reglages.swift
```
rend `834: … = 60`.

### Les deux écritures sur un compte

```sh
grep -rn 'consume' Sources/
```
rend `ReinitialisationCodex.swift:58`, la route qui consomme un crédit de réinitialisation
du quota Codex d'un compte ChatGPT.

```sh
grep -n 'muse-code/key' Sources/Quotum/Donnees/QuotaMuse.swift
```
rend la seconde : chaque mesure de Muse Code crée une clé sur votre compte Meta, seule façon
d'obtenir son quota. La clé créée n'est ni décodée, ni gardée, ni journalisée, et
`ReleveurMuse.swift` borne l'envoi à un toutes les quinze minutes, même après une relance de
l'application ; la mise en garde est affichée avant que vous suiviez l'outil. Les autres `POST`
du dépôt (Windsurf, Warp, Augment, Grok Bot, et les deux d'AWS, l'identité puis le budget) sont des lectures que ces services
exposent sous cette méthode ; celui d'Azure demande le jeton qui permet de lire le budget.

Les conditions de la réinitialisation Codex, dans `ArmementReinitialisation.swift` : Codex seulement, le cas `.chatgpt`
(ligne 76), un crédit restant, un épuisement **constaté par le serveur**, une mesure de moins de
dix minutes (`fraicheurMaximale`, ligne 24), une échéance encore devant.

```sh
grep -n 'reinitialisationAutomatique = false' Sources/Quotum/Modeles/Reglages.swift
```
rend `452` : le mode sans confirmation est éteint à l'installation.

Les fichiers que ce dépôt écrit sont le registre qui empêche la double dépense, dans le dossier
de Quotum lui-même, et le dossier temporaire privé (droits `0700`) que `LanceurCLISysteme.swift`
crée pour chaque lancement d'un outil en ligne de commande et supprime aussitôt après :

```sh
grep -rnE '\.write\(to|O_CREAT|createDirectory' Sources/
```

Il écrit aussi dans les préférences de Quotum (`UserDefaults`) : vos réglages, consentement
compris (`Reglages.swift`), et la date du dernier envoi à Muse Code (`ReleveurMuse.swift`),
qui fait tenir la cadence d'un lancement à l'autre :

```sh
grep -rn '\.set(' Sources/Quotum/Modeles/Reglages.swift Sources/Quotum/Donnees/ReleveurMuse.swift
```

Les écritures au Trousseau sont décrites plus haut.

### La licence s'active par Mac, puis se vérifie hors ligne

Ce code-là n'est pas ici, à dessein : le publier dirait quoi neutraliser dans le binaire. Ce que
vous pouvez en savoir : une fois ce Mac activé, la licence se vérifie sur le Mac, sans qu'aucune
requête parte, et la clé ne porte ni courriel, ni nom, ni rien de la machine. Ce qui part, ce sont
les deux requêtes de la section suivante.

### Les trois requêtes vers l'éditeur

`MiseAJour.swift` n'arme la vérification des mises à jour que sur une adresse de flux en `https`
(ligne 71). Elle ne dépend pas de votre consentement de mesure, et le site le dit.

Les deux autres appartiennent à la licence et à l'essai. Leur constructeur n'est pas publié : il
vit dans les mêmes fichiers que la vérification de la réponse, que publier dirait quoi
neutraliser. Ce dépôt ne vous permet donc pas de les construire. Ce qu'il montre, c'est le
contrat que le test publié impose au vrai code : `GardesReseauTests.swift`, dont les tests
`entetesDeLEssai` et `entetesDeLActivation` fixent exactement les trois en-têtes et les champs
du corps nommés ci-dessous, et font échouer la suite du dépôt de développement si l'un d'eux
s'ajoute ou disparaît. Pour le constater sans ce code, observez le trafic de l'application.

```sh
grep -n '"demande", "jeton_appareil"\|"cle", "cle_publique", "preuve"' Tests/QuotumTests/GardesReseauTests.swift
```
rend les lignes `486` et `501` : les champs de l'activation, puis ceux de l'essai.

La deuxième est l'ouverture de l'essai : un `POST` à `/essai`, au premier lancement, qui emporte un
code tiré au hasard sur ce Mac et un jeton qu'Apple délivre à ce Mac par DeviceCheck — rien
d'autre. Elle est relancée tant que le service ne répond pas, et plus du tout une fois l'essai
ouvert ou refusé, une licence activée ou les quatorze jours d'essai passés.

La troisième est l'activation, celle de la licence achetée : un `POST` à `/activer`, sur le
geste « Activer ce Mac ». Un Mac activé ne l'envoie plus. Elle est relancée tant que le service ne
répond pas, sept jours au plus après le geste. Elle emporte la clé, la clé publique de la puce et
une signature, rien d'autre.

## Vérifier sur l'application installée

Ce qui suit ne dépend pas de ce dépôt, et comble une partie de ce qu'il ne peut pas prouver.

```sh
# Chaque adresse écrite en toutes lettres dans le binaire
strings -a /Applications/Quotum.app/Contents/MacOS/Quotum | grep -E 'https?://' | sort -u

# Les bibliothèques liées, et les cadres embarqués
otool -L /Applications/Quotum.app/Contents/MacOS/Quotum
ls /Applications/Quotum.app/Contents/Frameworks

# Ce que Sparkle a le droit d'envoyer : SUEnableSystemProfiling doit être absente
plutil -p /Applications/Quotum.app/Contents/Info.plist | grep '"SU'
```

La première liste doit se retrouver entièrement dans les tableaux A, B et C du site. ⚠️ Une
chaîne très courte peut être rangée par le compilateur hors de la zone que lit `strings`, et une
adresse composée à l'exécution n'y figure pas — c'est le cas d'Augment. Pour une vérification
complète, observez le trafic de l'application avec un pare-feu applicatif.

## Ce que ce dépôt ne peut pas prouver

Nous préférons le dire que le laisser deviner.

1. **Qu'aucun fichier non publié n'envoie de requête.** Ce dépôt montre les requêtes qui y
   sont ; il ne peut pas montrer l'absence d'une requête ailleurs. Le garde
   `GardesReseauTests` énumère toutes celles du produit, mais il s'appuie sur le type
   `Fournisseur`, qui n'est pas publié. Les vérifications sur le binaire et une observation du
   trafic sont les moyens de le constater par vous-même.
2. **Que ces fichiers sont ceux du binaire.** L'application n'est pas reconstructible à partir de
   ce dépôt, donc pas comparable octet pour octet. Le lien tient à `PROVENANCE`, aux empreintes,
   et à la cohérence entre les adresses du binaire et celles du code.
3. **Ce que fait la licence.** La vérification de la clé, l'activation, l'essai et leurs
   relances ne sont pas publiés, à dessein, ni le code qui construit leurs deux requêtes. Ce
   dépôt montre le contrat que le test publié impose à ces requêtes ; il ne montre ni leur
   construction ni la façon dont leur réponse est vérifiée.
4. **Ce que font les écritures sur disque hors de ce dépôt** — création des applications de
   compte, script d'épinglage du terminal, LaunchAgent de démarrage, préférences, fichier de
   verrou de la licence. Elles ne touchent à aucun identifiant ; leur code n'est pas publié.

## Les types dont dépendent ces fichiers, et qui ne sont pas ici

| Type | Rôle |
|---|---|
| `Quota`, `Fenetre` | Le modèle de quota : une liste de fenêtres, pourcentage consommé borné de 0 à 100 |
| `Fournisseur`, `Cause`, `Ligne`, `ApplicationsInstallees` | Les fournisseurs, les états d'un compte, une ligne du panneau |
| `Fusion`, `Correspondances`, `TablesCorrespondances` | L'appariement des sources en lignes |
| `ReponseProxy`, `EtatProxy` | Le décodage de la réponse d'un proxy |
| `CreationCompte`, `DossiersCompte` | La création des applications de compte, leurs dossiers |
| `Mots` | Les traductions |
| `Alerte`, `AutorisationAlertes`, `ServiceNotifications` | Les notifications |
| `Demarrage` | Le LaunchAgent d'ouverture au démarrage |
| `Sparkle` | Le cadre de mise à jour, embarqué sous forme binaire |
| `LimiteComptes`, `PorteEssai`, `FixturesLicence` | La limite de l'essai et les deux requêtes de la licence, non publiées à dessein ; `GardesReseauTests.swift` fixe le contrat de ces requêtes |

## Signaler un écart

Une adresse, une lecture ou une écriture que vous trouveriez et que le site ne décrit pas est
exactement ce qu'il faut nous signaler : [quotum.app/fr/support](https://quotum.app/fr/support).

## Licence

Ce dépôt est publié sous une licence de consultation, tous droits réservés, dont le texte est
dans `LICENSE` : vous pouvez lire ces fichiers, les télécharger, les compiler et les exécuter sur
votre machine pour vérifier leur comportement, et en citer des extraits dans une analyse, un
audit ou un signalement de faille. Tout autre usage demande une autorisation écrite.

Il existe pour que vous puissiez vérifier ce que Quotum fait de vos identifiants, pas pour que
son code soit repris ailleurs : une licence ouverte permettrait à n'importe quel produit de
recopier ces lecteurs tels quels. C'est pourquoi ce code est publié en consultation, et pas en
open source.

L'application elle-même relève de sa propre licence d'utilisation, décrite dans les
[mentions légales](https://quotum.app/fr/mentions).

---

Quotum n'est affilié ni à Anthropic, ni à OpenAI, ni à aucun des éditeurs des outils qu'il lit.
Quotum est édité par MASH MEDIA ; les [mentions légales](https://quotum.app/fr/mentions) disent qui.
