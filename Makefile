APP_NAME := Harf
BUNDLE_ID := com.ali.dodoma
APP_BUNDLE := build/$(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
SIGN_IDENTITY ?= Dodoma Dev

FIXTURES := Tests/DodomaCoreTests/Fixtures/layout-tables.json
CORPUS := Tests/DodomaCoreTests/Fixtures/corpus.tsv
# SwiftPM resource bundle for the DodomaCore target: <package>_<target>.bundle
RESOURCE_BUNDLE := Harf_DodomaCore.bundle

# The face the brand marks are traced from. Its licence permits the letterform
# in a logo but forbids redistributing the font software, so it lives outside
# the repository in gitignored Tools/data/ — override this to retrace the
# identity in another face.
BRAND_FONT ?= Tools/data/fonts/thmanyahserifdisplay-Bold.otf

.PHONY: dmg build bundle sign install run test fixtures logs ngrams brand eval clean

build:
	swift build -c release

bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" $(CONTENTS)/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	@find Resources -mindepth 1 -maxdepth 1 ! -name Info.plist -exec cp -R {} $(CONTENTS)/Resources/ \;
	@# SPM emits DodomaCore's word lists and bigram tables as a separate bundle.
	@# CoreResources.swift searches Contents/Resources for it at runtime, so it
	@# has to be copied in or the app cannot score anything.
	@BIN="$$(swift build -c release --show-bin-path)"; \
	if [ ! -d "$$BIN/$(RESOURCE_BUNDLE)" ]; then \
		echo "error: $(RESOURCE_BUNDLE) not found in $$BIN"; exit 1; \
	fi; \
	cp -R "$$BIN/$(RESOURCE_BUNDLE)" $(CONTENTS)/Resources/
	@echo "Bundled $(APP_BUNDLE)"

# The hardened runtime is on for every build, not just released ones: Apple
# refuses to notarise without it, and a local build that behaves differently
# from the one users install is not worth the debugging. It costs nothing here
# — Accessibility and Input Monitoring are TCC grants, not entitlements, so the
# app needs no exceptions and ships with no entitlements file.
#
# A secure timestamp is also required for notarisation, but it needs Apple's
# timestamp server. Only Developer ID builds pay that network cost; self-signed
# local builds stay offline-capable.
#
# --deep is deliberately absent: the bundle holds one Mach-O and no nested
# code, and Apple documents --deep as unsuitable for distribution signing.
#
# The ad-hoc fallback banner goes to stderr. Callers that silence this recipe
# — scripts/release.sh runs `make ... >/dev/null` — would otherwise ship an
# ad-hoc build without ever seeing the warning.
sign: bundle
	@IDENTITY="$(SIGN_IDENTITY)"; \
	case "$$IDENTITY" in \
		"Developer ID"*) STAMP="--timestamp" ;; \
		*)               STAMP="--timestamp=none" ;; \
	esac; \
	if security find-identity -v -p codesigning | grep -qF -- "$$IDENTITY"; then \
		echo "Signing with identity '$$IDENTITY'"; \
		if ! codesign --force --options runtime $$STAMP --sign "$$IDENTITY" $(APP_BUNDLE); then \
			echo ""; \
			echo "Signing failed. The usual cause is a locked keychain: codesign can"; \
			echo "list the identity without being able to use its private key, and"; \
			echo "reports errSecInternalComponent rather than saying so."; \
			echo ""; \
			echo "Find which keychain holds it, and unlock that one:"; \
			for k in "$$HOME"/Library/Keychains/*.keychain-db; do \
				if security find-certificate -c "$$IDENTITY" "$$k" >/dev/null 2>&1; then \
					echo "    security unlock-keychain $$k"; \
				fi; \
			done; \
			exit 1; \
		fi; \
	else \
		echo "############################################################" >&2; \
		echo "WARNING: code-signing identity '$$IDENTITY' not found." >&2; \
		echo "Falling back to ad-hoc signing." >&2; \
		echo "Ad-hoc signatures change on every rebuild, so macOS treats" >&2; \
		echo "each build as a different app and DROPS the Accessibility" >&2; \
		echo "and Input Monitoring grants. You will have to re-approve" >&2; \
		echo "Harf after every build." >&2; \
		echo "Fix this once by running: scripts/make-cert.sh" >&2; \
		echo "############################################################" >&2; \
		codesign --force --options runtime --timestamp=none --sign - $(APP_BUNDLE); \
	fi
	codesign -dr - $(APP_BUNDLE)

install: build bundle sign
	@# Asked to quit, not signalled: --quit reaches the running copy through the
	@# single-instance port, so it goes out through applicationWillTerminate —
	@# the only write of the words learned since the last flush, up to twenty
	@# seconds of them. The freshly built binary is used because it is the one
	@# that knows the command.
	@#
	@# pkill is the fallback for a copy too old to answer. -i as well as -x
	@# because a copy started from the executable on the PATH rather than the
	@# bundle is named `harf`, and a case-sensitive match leaves it running —
	@# tapping the keyboard alongside the build about to be installed.
	"$$(swift build -c release --show-bin-path)/$(APP_NAME)" --quit || pkill -x -i $(APP_NAME) || true
	rm -rf /Applications/$(APP_NAME).app
	ditto $(APP_BUNDLE) /Applications/$(APP_NAME).app
	open /Applications/$(APP_NAME).app

run: build bundle sign
	@# The same line as install, for the same reason and one more: only one copy
	@# of Harf runs at a time now, so a fresh build launched over an installed
	@# one loses the single-instance name and quits with an alert instead of
	@# starting. Without this the primary dev loop does not work on any machine
	@# that has the app installed.
	"$$(swift build -c release --show-bin-path)/$(APP_NAME)" --quit || pkill -x -i $(APP_NAME) || true
	open $(APP_BUNDLE)

test:
	swift test

# Snapshots this machine's ABC and Arabic uchr tables so renderer tests stay
# deterministic regardless of which input sources are enabled where they run.
fixtures:
	swift run Harf --dump-layout-fixtures $(FIXTURES)

eval:
	swift run Harf --eval $(CORPUS)

# --debug --info: the decision and pipeline categories log at those levels, and
# `log stream` shows neither by default.
logs:
	log stream --debug --info --predicate 'subsystem == "$(BUNDLE_ID)"' --style compact

# Regenerates the committed language models. The only network access in the app
# or its build (the release scripts have their own), and it only happens on a
# dev machine when Tools/data/ is cold. Both downloads are pinned to a commit
# and checksummed, so this is reproducible from a fresh clone.
ngrams:
	uv run Tools/build-ngrams.py

# Regenerates the committed brand assets: the SVGs under docs/brand, the
# generated menu bar glyph, and the .icns rasterised from the icon SVG. Needs
# $(BRAND_FONT) to be present; the committed outputs are what a checkout
# without the font builds from.
brand:
	uv run Tools/build-brand.py --font "$(BRAND_FONT)"
	swift Tools/build-icon.swift

clean:
	rm -rf .build build

dmg: build bundle sign ## Build a distributable disk image
	./scripts/make-dmg.sh
