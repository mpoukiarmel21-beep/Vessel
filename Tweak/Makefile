# Makefile — Vessel
#
# LIBRARY_NAME, PAS TweakName. Une cible tweak.mk lie automatiquement
# /Library/Frameworks/CydiaSubstrate.framework, qui n'existe pas sur un appareil
# non jailbreake : dyld echoue a charger la dylib et le tweak entier meurt en
# silence. Le variable <NAME>_USE_SUBSTRATE = 0 ne suffit PAS (verifie en CI sur
# le projet precedent). library.mk produit une dylib pure.
#
# Aucun %hook / MSHook* dans les sources : tous les hooks sont faits a la main
# (method_setImplementation pour ObjC, fishhook/rebind_symbols pour le C).

ARCHS = arm64
TARGET = iphone:clang:latest:16.3

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = Vessel

# La liste grandit phase par phase (cf. ARCHITECTURE.md §10). Chaque phase est
# compilee en CI avant que la suivante ne soit ecrite : un fichier absent de
# cette liste n'est pas encore ecrit, ce n'est pas un oubli.

VESSEL_PHASE1 = \
	Source/vendor/fishhook/fishhook.c \
	Source/Entry/VSBootstrap.m \
	Source/Core/VSLog.m \
	Source/Core/VSPaths.m \
	Source/Core/VSStore.m

# Phase 2 : identite par container + liste des containers.
VESSEL_PHASE2 = \
	Source/Core/VSIdentity.m \
	Source/Core/VSContainer.m \
	Source/Core/VSManager.m \
	Source/Core/VSSelfTest.m

# Phase 3 : isolation couche 1 (filesystem) + couche 2 (keychain). C'est la
# couche 2 qui corrige « le compte disparait » et « les comptes se melangent ».
VESSEL_PHASE3 = \
	Source/Hooks/VSHookHome.m \
	Source/Hooks/VSHookKeychain.m

# Phase 4 : isolation couche 3 (NSUserDefaults/CFPreferences) + couche 4 (cookies
# NSHTTPCookieStorage). cfprefsd et le pot de cookies partage sont hors-processus
# comme le keychain : rediriger HOME ne les separe pas, d'ou ces deux couches.
VESSEL_PHASE4 = \
	Source/Hooks/VSHookDefaults.m \
	Source/Hooks/VSHookCookies.m

# Phase 5 : identite par container. VSHookDevice falsifie les SOURCES que lit
# Instagram (sysctl/sysctlbyname/uname, IOKit IOPlatform*, MobileGestalt, UIDevice,
# ASIdentifierManager, ATTrackingManager) pour que son User-Agent decrive un autre
# iPhone ; VSHookLocale aligne fuseau horaire + langue. Aucune API privee n'est
# APPELEE pour nos donnees : on n'intercepte que ce qu'Instagram lit deja, et on ne
# remplace un IOKit/MG que si l'appel d'origine renvoyait deja une valeur. IOKit
# n'est pas lie : les symboles sont resolus via dlsym (fishhook lie par nom).
VESSEL_PHASE5 = \
	Source/Hooks/VSHookDevice.m \
	Source/Hooks/VSHookLocale.m

# Phase 6 : fake GPS. VSHookLocation pilote la surface CLLocationManager (getter
# location, start/stopUpdatingLocation en FLUX continu, requestLocation, changements
# significatifs, autorisation + precision, locationServicesEnabled) pour projeter la
# ville du container avec un signal realiste (derive de quelques metres, precision
# 5-12 m variable, vitesse/cap -1 a l'arret, timestamp live). Opt-in par container et
# gele au lancement : sans position de base, la couche s'installe PASSIVE (ne swizzle
# rien). CoreLocation est deja lie ; hooks ObjC purs (method_setImplementation).
VESSEL_PHASE6 = \
	Source/Hooks/VSHookLocation.m

# Phase 7 : couche UI. VSTheme centralise les tokens de design ; VSOverlayWindow
# est une UIWindow a passthrough (hitTest laisse passer les touches hors du bouton,
# canBecomeKeyWindow=NO) pour ne jamais voler le focus a Instagram (source des gels
# de l'ancien projet) ; VSFloatingButton est le bouton flottant draggable a
# aimantation de bord ; VSUIController attache l'overlay des qu'une UIWindowScene est
# active et presente le panneau depuis le VC du sommet d'Instagram ; VSPanelVC est le
# panneau principal (liste des containers, creer, diagnostics, tout reinitialiser) ;
# VSCreateVC l'assistant de creation ; VSMapPickerVC le choix de localisation ;
# VSDiagnosticsVC le retour terrain (journaux, auto-test, sink distant opt-in).
# UIKit et MapKit sont deja lies (cf. Vessel_FRAMEWORKS).
VESSEL_PHASE7 = \
	Source/UI/VSTheme.m \
	Source/UI/VSOverlayWindow.m \
	Source/UI/VSFloatingButton.m \
	Source/UI/VSUIController.m \
	Source/UI/VSPanelVC.m \
	Source/UI/VSCreateVC.m \
	Source/UI/VSMapPickerVC.m \
	Source/UI/VSDiagnosticsVC.m

Vessel_FILES = $(VESSEL_PHASE1) $(VESSEL_PHASE2) $(VESSEL_PHASE3) $(VESSEL_PHASE4) $(VESSEL_PHASE5) $(VESSEL_PHASE6) $(VESSEL_PHASE7)

Vessel_CFLAGS = -fobjc-arc \
	-I$(THEOS_PROJECT_DIR)/Source \
	-Wno-deprecated-declarations \
	-Wno-unused-variable \
	-Wno-error=unguarded-availability-new

Vessel_FRAMEWORKS = UIKit CoreLocation MapKit Security SystemConfiguration AdSupport AppTrackingTransparency
Vessel_PRIVATE_FRAMEWORKS =
Vessel_LDFLAGS = -Wl,-no_warn_duplicate_libraries

include $(THEOS_MAKE_PATH)/library.mk
