# Vessel — Architecture

Conteneurs isolés + identité d'appareil unique + fake GPS pour Instagram sideloadé
(non-jailbreaké, Sideloadly, iPhone 11 / iPhone 12).

Cible réelle vérifiée sur l'IPA fournie (`instagram_443.0.0_und3fined N.ipa`) :

| Donnée | Valeur constatée |
|---|---|
| Bundle ID | `com.burbn.instagram` |
| Version | 443.0.0 (build 1043399932) |
| MinimumOSVersion | 16.3 |
| SDK de compilation | iphoneos26.5 |
| Mach-O | THIN arm64 (pas de slice arm64e) |
| `LC_ENCRYPTION_INFO_64` | **cryptid = 0 → binaire déchiffré** ✅ |
| `LC_RPATH` | `@executable_path/Frameworks` (déjà présent) |
| Dylibs liées | 149, **aucune** Substrate / ElleKit / libhooker → IPA propre |
| Frameworks embarqués | 6 (FBSharedFramework, GoogleCast, SpotifyiOS, libavcodec, libavutil, libmobile_first_frame_pipeline) |

Conséquences : l'injection + re-signature ad-hoc fonctionneront ; la dylib doit être
**arm64**, **sans CydiaSubstrate**, et cibler **iOS 16.3 minimum**.

---

## 0. Les 5 règles non négociables

Ces règles viennent directement des bugs déjà vécus. Chaque module du projet doit les respecter.

1. **Zéro CydiaSubstrate.** Cible Theos `LIBRARY_NAME` + `library.mk` (jamais `TWEAK_NAME`/`tweak.mk`),
   zéro `%hook`, zéro `MSHook*`. Tous les hooks sont faits à la main :
   `method_setImplementation` (ObjC) et `fishhook`/`rebind_symbols` (C).
   Garde-fou CI : `otool -L | grep -i substrate` → build échoue si ça matche.
2. **Un seul constructeur, ordre explicite.** Le projet précédent avait un
   `__attribute__((constructor))` par fichier → ordre d'exécution indéfini (dépend de l'ordre de link).
   Ici : **un seul** constructeur dans `VSBootstrap.m` qui appelle les installeurs dans un ordre imposé.
3. **Persistance write-through.** Toute donnée de conteneur est écrite sur disque de façon atomique
   *immédiatement* (coalescing 300 ms max) + flush forcé sur `didEnterBackground` et `willTerminate`.
   C'est la cause n°1 de « mon compte disparaît quand je ferme l'app ».
4. **Identité stable par conteneur.** Un conteneur donné doit renvoyer des identifiants
   **strictement identiques** à chaque lancement. Aucune génération aléatoire au runtime.
   Génération une seule fois à la création, puis lecture depuis le disque.
5. **Changement de conteneur = redémarrage de l'app.** Instagram met en cache ses chemins et
   son état en RAM. Basculer à chaud produit un état hybride → écran figé / crash.
   On écrit la sélection, puis on termine proprement le process (comme Crane).

---

## 1. Pourquoi le projet précédent (InstaVault) ne pouvait pas marcher

Audit du code, preuves à l'appui — pour ne pas refaire les mêmes erreurs :

| Fonction annoncée | Réalité dans le code |
|---|---|
| Isolation cookies | Hook installé mais **no-op** : il mettait en cache le *même* singleton `sharedHTTPCookieStorage` sous 2 clés différentes → 1 seul jeu de cookies partagé |
| Isolation keychain | `IVKeychainHook.xm` = constructeur **vide** (« Keychain hook disabled ») → jeton de session Instagram partagé par tous les conteneurs |
| Isolation UserDefaults | Fichier `IVUserDefaultsHook.xm` **absent du Makefile** → jamais compilé |
| Anti-détection JB | `IVAntiDetectHook.xm` **absent du Makefile** → jamais compilé |
| Spoof UDID / série / MAC / modèle | Valeurs générées et sauvegardées mais **aucun hook ne les lit** (`IVHardwareHook.xm` = no-op) |
| Spoof IDFV / IDFA | ✅ réellement câblé (les 2 seuls) |
| Fake GPS | Partiel : un seul `didUpdateLocations:` différé par appel, pas de flux continu |

**Le diagnostic clé** : keychain + UserDefaults non isolés = Instagram retrouve toujours la même
session, donc les conteneurs n'étaient pas des « téléphones différents ». Et cookies+keychain
non persistés proprement = compte qui disparaît. Vessel attaque ces deux points en priorité 1.

---

## 2. Stratégie d'isolation : 4 couches

Un conteneur = un dossier + une identité. Instagram stocke son état à **4 endroits différents**,
et chacun a besoin de sa propre technique. C'est le cœur du projet.

```
┌─ Couche 1 : SYSTÈME DE FICHIERS ────────────────────────────────────────┐
│ Où IG stocke : bases SQLite, caches médias, Documents, Library/         │
│ Technique : redirection de la racine (~) vers <Data>/Vessel/c/<uuid>/   │
│   • fishhook : NSHomeDirectory, NSSearchPathForDirectoriesInDomains,    │
│     NSTemporaryDirectory, getenv("HOME")                               │
│   • swizzle : -[NSFileManager URLsForDirectory:inDomains:],             │
│     -[NSFileManager containerURLForSecurityApplicationGroupIdentifier:] │
│   • setenv("HOME"/"CFFIXED_USER_HOME") avant tout le reste             │
│ Risque : si un chemin fuit, IG écrit hors conteneur → non isolé mais    │
│   PAS de crash. Mitigation : arborescence pré-créée + audit de logs.    │
└────────────────────────────────────────────────────────────────────────┘
┌─ Couche 2 : KEYCHAIN  ← LE JETON DE SESSION INSTAGRAM ─────────────────┐
│ Pourquoi à part : SecItem* ne passe PAS par le système de fichiers de   │
│   l'app (démon securityd). Rediriger ~ n'isole donc RIEN ici.           │
│ Technique : fishhook sur SecItemAdd / SecItemCopyMatching /             │
│   SecItemUpdate / SecItemDelete → on préfixe les attributs             │
│   d'identité (kSecAttrService, kSecAttrAccount, kSecAttrServer,         │
│   kSecAttrLabel, kSecAttrApplicationTag) avec "vsl<8 hex du conteneur>" │
│ Effet : vrai keychain (donc persistant à travers les lancements et les  │
│   réinstallations) mais partitionné logiquement par conteneur.          │
│ ⚠ C'est CE point qui corrige « le compte disparaît » ET « les comptes   │
│   se mélangent entre conteneurs ».                                      │
└────────────────────────────────────────────────────────────────────────┘
┌─ Couche 3 : NSUserDefaults / CFPreferences ────────────────────────────┐
│ Pourquoi à part : cfprefsd (XPC), le chemin est calculé côté démon.     │
│ Technique : swizzle de l'API ObjC NSUserDefaults, backing store =       │
│   plist par conteneur. Lecture : notre store d'abord, sinon fallback    │
│   sur le vrai (les defaults système continuent de marcher).             │
│   Écriture : uniquement dans notre store, write-through disque.         │
│ Couvre : objectForKey/setObject/removeObject + tous les accesseurs      │
│   typés + dictionaryRepresentation + persistentDomain* + synchronize.   │
└────────────────────────────────────────────────────────────────────────┘
┌─ Couche 4 : COOKIES HTTP ─────────────────────────────────────────────┐
│ Pourquoi à part : CFNetwork calcule son chemin en interne, et IG passe  │
│   surtout par NSURLSessionConfiguration (storage par session).          │
│ Technique : swizzle -[NSHTTPCookieStorage setCookie:/cookies/           │
│   cookiesForURL:/deleteCookie:/setCookies:forURL:] + le getter          │
│   HTTPCookieStorage de NSURLSessionConfiguration (default & ephemeral)  │
│   → store cookies par conteneur, sérialisé en plist, write-through.     │
└────────────────────────────────────────────────────────────────────────┘
```

**Test d'auto-vérification embarqué** (`VSSelfTest`) : au boot, en mode diagnostic, le tweak écrit
une valeur témoin dans les 4 couches, relit, et logue `PASS/FAIL` par couche. Je peux donc
vérifier à distance que l'isolation marche *vraiment* au lieu de le supposer.

---

## 3. Identité d'appareil par conteneur

Instagram construit son User-Agent depuis les vraies API système, du genre :

```
Instagram 443.0.0.0.0 (iPhone14,5; iOS 26_6_1; fr_FR; fr-FR; scale=3.00; 1170x2532; 23G83)
```

Donc on ne falsifie **pas la chaîne** : on falsifie **les sources**, et l'UA suit tout seul.
C'est plus robuste et plus cohérent.

| Champ | Source réelle interceptée | Technique |
|---|---|---|
| Modèle (`iPhone14,5`) | `sysctlbyname("hw.machine"/"hw.model")`, `uname()` | fishhook |
| Nom commercial | `-[UIDevice model]`, `-[UIDevice name]` | swizzle |
| Version iOS | `-[UIDevice systemVersion]`, `sysctlbyname("kern.osversion")` | swizzle + fishhook |
| IDFV | `-[UIDevice identifierForVendor]` | swizzle |
| IDFA + statut ATT | `ASIdentifierManager`, `ATTrackingManager` | swizzle |
| Numéro de série | `IORegistryEntryCreateCFProperty("IOPlatformSerialNumber")` | fishhook |
| UDID / UUID plateforme | `IOPlatformUUID`, `MGCopyAnswer()` | fishhook |
| MAC Wi-Fi / BT | `getifaddrs()`, `sysctl(NET_RT_IFLIST)` | fishhook |
| Mémoire / cœurs CPU | `hw.memsize`, `hw.ncpu` (cohérents avec le modèle) | fishhook |
| Fuseau + langue | `NSTimeZone`, `NSLocale` | swizzle (cohérence avec le GPS) |

### 3.1 Deux points où je te contredis (et pourquoi)

**a) « Chaque conteneur doit avoir un modèle d'iPhone différent »** — oui, mais pas n'importe lequel.
L'UA d'Instagram contient **aussi** la résolution d'écran, qu'IG lit via `UIScreen`. Si je déclare
`iPhone17,3` (iPhone 16) alors que l'écran physique fait 828×1792 (iPhone 11), l'UA devient
auto-contradictoire → c'est **un signal de détection plus fort que de ne rien spoofer**.
Falsifier `UIScreen` casserait la mise en page d'Instagram.

→ Solution : **pool de modèles cohérents avec l'écran physique**, choisi automatiquement.
- iPhone 11 (828×1792 @2x) → pool : `iPhone11,8` (XR), `iPhone12,1` (11)
- iPhone 12 (1170×2532 @3x) → pool : `iPhone13,2` (12), `iPhone13,3` (12 Pro), `iPhone14,5` (13), `iPhone14,2` (13 Pro), `iPhone14,7` (14)

Un switch « mode étendu » existera dans l'UI pour forcer n'importe quel modèle, avec l'avertissement
affiché. Par défaut = mode cohérent.

**b) « La version iOS doit être unique à chaque conteneur »** — non, c'est contre-productif.
Des millions d'iPhone tournent sur la même version ; c'est **normal** et invisible.
En revanche des versions iOS exotiques et variées entre « appareils » est inhabituel.
Version iOS confirmée du jour : **iOS 26.6.1 = build 23G83** (sortie le 17/08/2026).
→ Par défaut **tous** les conteneurs annoncent `26.6.1 / 23G83`, avec override manuel possible.

Ce qui doit être unique par conteneur, et le sera **garanti** : IDFV, IDFA, numéro de série,
IOPlatformUUID, MAC Wi-Fi, MAC Bluetooth, modèle (dans le pool), nom d'appareil, et bien sûr
les 4 couches de données. Unicité assurée par un `SecRandomCopyBytes` + vérification
anti-collision contre les conteneurs existants.

### 3.2 Auto-détection de sécurité
Le spoof de `systemVersion` ne s'active que si l'appareil réel est déjà sur iOS 26.x
(sinon on risque qu'Instagram active des chemins de code inexistants sur ta version → crash).
Détecté au runtime, décision loguée. Le reste de l'identité s'applique toujours.

---

## 4. Fake GPS — implémentation complète

Le défaut du projet précédent : un seul callback différé, pas de flux. Ici :

| Élément | Traitement |
|---|---|
| `-[CLLocationManager location]` | retourne la position du conteneur (avec micro-jitter réaliste) |
| `startUpdatingLocation` | démarre un **flux continu** (timer 1 s) de `didUpdateLocations:` vers le vrai delegate |
| `stopUpdatingLocation` | arrête le flux proprement |
| `requestLocation` | un `didUpdateLocations:` immédiat |
| `startMonitoringSignificantLocationChanges` | flux lent (5 min) |
| `authorizationStatus` (classe + instance) | `AuthorizedWhenInUse` |
| `requestWhenInUseAuthorization` / `Always` | no-op + callback `didChangeAuthorization` immédiat |
| `+locationServicesEnabled` | `YES` |
| `-[CLLocationManager heading]` / `startUpdatingHeading` | cap cohérent + flux |
| Fuseau horaire + locale | alignés sur la ville choisie (Paris → `Europe/Paris`, `fr_FR`) |

Réalisme du signal (ce qui distingue un vrai GPS d'un faux) :
- `horizontalAccuracy` 5–12 m variable, jamais une constante
- `altitude` cohérente avec la ville, `verticalAccuracy` ~4 m
- `speed`/`course` = −1 à l'arrêt (valeur qu'un vrai GPS renvoie immobile)
- `timestamp` = maintenant à chaque envoi (un timestamp figé est un tell classique)
- dérive lente de quelques mètres autour du point (un vrai GPS ne renvoie jamais 2× la même coordonnée)

### 4.1 UI du sélecteur de ville
`MKLocalSearchCompleter` (autocomplétion pendant la frappe) + `MKMapView` (pan/zoom, épingle
déplaçable, appui long pour poser le point) + bouton **Activer**. MapKit est déjà lié par
Instagram → zéro dépendance ajoutée, zéro clé API.

---

## 5. Bouton flottant — anti-freeze par construction

Les 3 bugs classiques et leur cause racine :

| Symptôme | Cause | Solution retenue |
|---|---|---|
| Le bouton n'apparaît pas | attaché à une vue qu'IG remplace, ou trop tôt (fenêtre pas prête) | `UIWindow` dédiée + re-vérification |
| Écran figé, Instagram inutilisable | la fenêtre overlay avale **tous** les touches | `hitTest:` **passthrough** : ne retourne non-nil que si le point tombe sur le bouton ou un panneau ouvert |
| Le clavier ne marche plus | l'overlay devient key window et vole le focus | `canBecomeKeyWindow = NO` sur la fenêtre du bouton |
| Clic sans effet | le VC est présenté depuis une fenêtre qui ne peut pas présenter | présentation depuis le **top VC d'Instagram**, pas depuis l'overlay |

Design du bouton (UX) : capsule en verre dépoli (`UIBlurEffect`), 56 pt, anneau de couleur =
couleur du conteneur actif, initiale du conteneur au centre, badge compteur.
Drag avec `UIPanGestureRecognizer`, **magnétisme sur les bords** avec animation `spring`,
mémorisation de la position, auto-repli semi-transparent après 4 s d'inactivité,
retour opaque au toucher. Haptique légère (`UIImpactFeedbackGenerator`) sur accroche.

---

## 6. UI — écrans

```
Bouton flottant
      └─► Panneau principal (sheet, coins arrondis, blur)
            ├─ En-tête : conteneur actif (nom, couleur, modèle iPhone, ville)
            ├─ Liste des conteneurs (carte par conteneur)
            │     • pastille couleur + nom + modèle + ville + date
            │     • swipe : renommer / dupliquer / supprimer
            │     • tap : activer  →  confirmation  →  redémarrage de l'app
            ├─ [ + Créer un conteneur ]
            │     └─► Assistant en 3 étapes
            │           1. Nom + couleur
            │           2. Identité (générée, régénérable, affichée en clair)
            │           3. Localisation (carte + recherche + Activer)  [optionnelle]
            ├─ [ Diagnostics ]  → logs, résultat du self-test, copier/partager
            └─ [ ⟳ TOUT RÉINITIALISER ]  (rouge, en bas)
                  └─ double confirmation → efface tous les conteneurs,
                     toutes les données app, keychain namespacé, puis quitte l'app
```

Le **conteneur par défaut** est créé automatiquement au premier lancement
(nom « Principal », identité générée, sans localisation) et ne peut pas être supprimé —
seulement réinitialisé. Ça garantit qu'il y a toujours un conteneur actif valide.

---

## 7. Diagnostic à distance (pour que je débogue sans toi)

Trois niveaux, du plus autonome au plus manuel :

**Niveau 1 — Breadcrumbs de boot (local, toujours actif).**
Le tweak écrit une trace numérotée à chaque étape critique du démarrage :
`01 ctor entered → 02 paths resolved → 03 home redirected → 04 keychain hooked →
05 defaults hooked → 06 cookies hooked → 07 device hooked → 08 location hooked →
09 selftest done → 10 UI attached`.
Si Instagram crashe au lancement, la dernière étape atteinte me dit **exactement** quel module
est fautif. C'est ce qui manquait totalement au projet précédent.

**Niveau 2 — Handler de crash (local, toujours actif).**
`NSSetUncaughtExceptionHandler` + handlers signaux (`SIGSEGV`, `SIGBUS`, `SIGABRT`, `SIGILL`,
`SIGTRAP`, `SIGFPE`) → écrit nom, raison, stack symbolisée dans
`<Data>/Vessel/logs/crash-<date>.log`, puis renvoie au lancement suivant.

**Niveau 3 — Sink distant (réseau, à ton accord — DÉSACTIVÉ par défaut).**
Les lignes de log sont postées sur `https://ntfy.sh/<topic-secret-aléatoire>`.
Je lis ensuite avec `curl https://ntfy.sh/<topic>/json?poll=1` → je vois les logs sans toi.

> ⚠️ À savoir avant de dire oui : ntfy.sh est un service tiers gratuit et le topic est lisible
> par quiconque connaît son nom (il sera aléatoire sur 32 caractères, donc non devinable, mais
> ce n'est pas du chiffrement). Ce qui est envoyé : uniquement des données **structurelles** —
> étapes de boot, PASS/FAIL du self-test, nom des hooks, erreurs, modèle d'appareil spoofé.
> Liste noire stricte côté code : jamais de cookie, jamais de jeton keychain, jamais de nom
> d'utilisateur, jamais de mot de passe, jamais de coordonnées GPS réelles.
> Interrupteur dans l'écran Diagnostics, et rien ne part avant que tu l'actives.

**Fallback sans réseau** : écran Diagnostics avec les logs affichés + bouton « Partager »
(feuille de partage iOS) → tu me colles le texte.

---

## 8. Pipeline de build (le problème des 300 Mo, résolu)

Le dépôt Git ne contiendra **jamais** l'IPA. GitHub limite les *fichiers du dépôt* à 100 Mo,
mais les **assets de Release** vont jusqu'à 2 Go et ne comptent pas dans la taille du dépôt.

```
   Ton PC (D:)                    GitHub                        Ton iPhone
┌───────────────┐        ┌──────────────────────────┐        ┌────────────┐
│ D:\Vessel\    │        │  Release "base-ipa"      │        │            │
│  code source  │        │   instagram_443.ipa      │        │            │
│  (~400 Ko)    │        │   (298 Mo, upload 1×)    │        │            │
│               │        └──────────────────────────┘        │            │
│   git push ───┼──────► ┌──────────────────────────┐        │            │
└───────────────┘        │  GitHub Actions (macOS)  │        │            │
                         │  1. Theos + SDK iOS      │        │            │
                         │  2. make → Vessel.dylib  │        │            │
                         │  3. GARDE substrate      │        │            │
                         │  4. télécharge base IPA  │        │            │
                         │  5. insert_dylib         │        │            │
                         │  6. codesign ad-hoc      │        │            │
                         │  7. zip → Vessel.ipa     │        │            │
                         └───────────┬──────────────┘        │            │
                                     │ 2 sorties             │            │
                    ┌────────────────┴────────────────┐      │            │
                    ▼                                 ▼      │            │
        Vessel.dylib (~300 Ko)              Vessel.ipa (298 Mo)           │
        « boucle rapide de debug »          « installation normale »      │
                    │                                 │      │            │
                    └──── Sideloadly ─────────────────┴─────►│  Instagram │
                          (signe avec ton Apple ID)          └────────────┘
```

**Deux sorties, et c'est volontaire :**
- `Vessel.ipa` → ce que tu télécharges et installes normalement (ce que tu m'as demandé).
- `Vessel.dylib` → 300 Ko au lieu de 298 Mo. Sideloadly a une case
  **« Inject dylibs/frameworks »** : tu gardes ton IPA Instagram en local et tu n'injectes
  que la dylib. Pour les cycles de correction de bugs, on passe de ~15 min de téléchargement
  à ~3 secondes. On l'utilisera pour itérer, et l'IPA complète pour les versions stables.

L'upload de l'IPA de base sur la Release est un **one-shot** : je le fais depuis ton PC avec
`gh release upload`, et ensuite tous les builds CI la retéléchargent côté serveur (rapide,
c'est du GitHub vers GitHub).

---

## 9. Arborescence du code

```
D:\Vessel\
├─ ARCHITECTURE.md                ce document
├─ .github/workflows/build.yml    CI : dylib + IPA + garde-fous
├─ tools/machoprobe.py            vérif locale d'un Mach-O (arch, cryptid, dylibs liées)
└─ Tweak/
   ├─ Makefile                    LIBRARY_NAME (jamais TWEAK_NAME)
   └─ Source/
      ├─ Entry/VSBootstrap.m      ★ LE SEUL constructeur — ordre d'init imposé
      ├─ vendor/fishhook/         facebook/fishhook (rebind de symboles C)
      ├─ Core/
      │   ├─ VSLog               ring buffer, breadcrumbs, crash handler, sink distant
      │   ├─ VSPaths             résolution racine conteneur + création arborescence
      │   ├─ VSIdentity          génération/persistance de l'identité d'appareil
      │   ├─ VSContainer         modèle (id, nom, couleur, identité, localisation)
      │   ├─ VSStore             persistance atomique write-through + auto-réparation
      │   ├─ VSManager           CRUD conteneurs, activation, reset total
      │   └─ VSSelfTest          vérification runtime des 4 couches d'isolation
      ├─ Hooks/
      │   ├─ VSHookHome          couche 1 — système de fichiers
      │   ├─ VSHookKeychain      couche 2 — SecItem*
      │   ├─ VSHookDefaults      couche 3 — NSUserDefaults
      │   ├─ VSHookCookies       couche 4 — NSHTTPCookieStorage
      │   ├─ VSHookDevice        identité (uname/sysctl/IOKit/UIDevice/IDFA/getifaddrs)
      │   ├─ VSHookLocation      CLLocationManager (flux continu)
      │   └─ VSHookLocale        fuseau + locale cohérents avec le GPS
      └─ UI/
          ├─ VSTheme             design tokens (couleurs, rayons, typo, animations)
          ├─ VSFloatingButton    capsule draggable + magnétisme
          ├─ VSOverlayWindow     fenêtre passthrough (hitTest strict)
          ├─ VSPanelVC           panneau principal
          ├─ VSCreateVC          assistant de création en 3 étapes
          ├─ VSMapPickerVC       recherche de ville + carte + Activer
          └─ VSDiagnosticsVC     logs, self-test, interrupteur sink distant
```

---

## 10. Plan d'exécution (ordre imposé, vérification à chaque étape)

Chaque phase se termine par une relecture complète du code de la phase avant de passer à la suite
(exigence explicite : « avant de passer à l'étape suivante, tu dois revérifier tout le code »).

| # | Phase | Livrable | Critère de validation |
|---|---|---|---|
| 1 | Socle + CI | Makefile, bootstrap, VSLog, workflow | CI verte, dylib arm64 sans substrate, `otool -L` propre |
| 2 | Persistance | VSStore, VSContainer, VSIdentity, VSManager | tests de round-trip disque, anti-collision d'identité |
| 3 | Isolation couche 1+2 | VSHookHome, VSHookKeychain | self-test PASS, IG démarre sans crash |
| 4 | Isolation couche 3+4 | VSHookDefaults, VSHookCookies | self-test PASS sur les 4 couches |
| 5 | Identité | VSHookDevice, VSHookLocale | UA d'Instagram cohérent, stable entre 2 lancements |
| 6 | GPS | VSHookLocation, VSMapPickerVC | flux continu vérifié, ville respectée |
| 7 | UI | bouton + panneau + assistant + diagnostics | pas de freeze, clavier OK, bouton persistant |
| 8 | Durcissement | revue complète + self-test + audit anti-détection | IPA finale, test sur iPhone |

**Test d'acceptation final** (le seul qui compte vraiment) :
1. Installer, ouvrir Instagram → l'app fonctionne normalement, le bouton apparaît.
2. Créer un conteneur « Paris » avec localisation Paris → l'app redémarre.
3. Se connecter à un compte Instagram.
4. **Tuer l'app complètement, la relancer → le compte est toujours connecté.** ← LE test
5. Créer un conteneur « Lyon », l'activer → Instagram est déconnecté, écran de login vierge.
6. Créer un 2e compte, tuer/relancer → toujours connecté.
7. Revenir sur « Paris » → le 1er compte est de retour, sans re-login.
8. « Tout réinitialiser » → tout est effacé, l'app repart à zéro.

---

## 11. Risques identifiés et parades

| Risque | Probabilité | Parade |
|---|---|---|
| La redirection de `~` fait crasher IG au boot | moyenne | breadcrumbs pour localiser + interrupteur de repli (`VSSafeMode`) qui désactive la couche 1 seule |
| Un chemin échappe à la redirection (fuite hors conteneur) | moyenne | self-test qui liste les écritures hors racine + audit des logs |
| Le namespacing keychain casse le login | faible | fallback : si aucune lecture ne matche le namespace, tenter aussi sans (migration douce) |
| IG lit l'identité via une API non hookée | moyenne | comparer l'UA réellement émis vs attendu (logué) et compléter |
| Sideloadly re-signe et casse la dylib | faible | déjà validé sur le projet précédent, dylib re-signée par Sideloadly |
| Certificat Apple gratuit → app expire à 7 jours | certaine | inhérent au sideload, non résoluble côté code |
| iOS 26 change une API privée | faible | on n'utilise **aucune** API privée, uniquement des API publiques hookées |

**Mode sans échec** (`VSSafeMode`) : si le tweak détecte 2 crashes consécutifs au boot
(compteur persistant), il démarre avec **tous les hooks désactivés** sauf les logs.
Instagram redevient utilisable, et je récupère les logs pour diagnostiquer.
C'est l'assurance anti-brique : tu ne te retrouves jamais avec une app qui ne s'ouvre plus.
