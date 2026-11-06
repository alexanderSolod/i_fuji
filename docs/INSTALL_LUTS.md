# Installing the Fujifilm LUTs (agent runbook)

Follow this to build Fujifilm's film simulation LUTs into FilmLab, so the app starts with them and never
shows the import screen. The steps are written for a coding agent on macOS, and a person can follow
them too.

**Done means:** the 10 `.cube` files below are in `iOS/FilmLab/Resources/LUTs/`, their checksums match,
none of them are tracked by git, and the built app contains all 10 under `LUTs/`.

## Rules

1. **Never commit or redistribute the `.cube` files** (spec rule 7). `.gitignore` already excludes them.
   Don't add them with `git add -f`, and don't upload them anywhere.
2. **Use only Fujifilm's own files.** Don't take LUTs from another site, and don't generate them.
3. **Don't get around a block on Fujifilm's site** (see Troubleshooting). Stop and tell the owner.
4. **Don't uninstall the app from the phone without asking the owner.** That deletes shots stored inside
   the app, including any that never reached Photos.

## Which files to use

Fujifilm publishes packages per camera at
<https://www.fujifilm-x.com/en-us/support/download/lut/>. Use the GFX ETERNA 55 package (Ver.1.10, 46 MB):

```text
https://dl.fujifilm-x.com/support/lut/gfx-eterna-55-3d-lut-v110.zip
```

The package has 71 files (about 235 MB unzipped), nearly all with similar names. Only one folder is right:

| Path in the package | Use it? | Why |
| --- | --- | --- |
| `33Grid/F-Log2/` | **Yes** | The app encodes F-Log2 and loads these |
| `33Grid/F-Log/`, `33Grid/F-Log2C/` | No | Different input curves. The app will load them without an error, but the colour and exposure will be wrong |
| `65Grid/` | No | Same looks at higher resolution, with much larger files. Not what the app has been tested with |

Inside `33Grid/F-Log2/`, install 10 of the 12 `.cube` files. Skip `FLog2_to_FLog2-709` and
`FLog2_to_WDR-709`, because they are output transforms and not film simulations.

## Step 1: Download, verify and copy

Run this from anywhere inside the repo. It checks every file before copying any, so a failure leaves the
repo unchanged. It is safe to run again.

<!-- install-script:start -->
```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
DEST="$ROOT/iOS/FilmLab/Resources/LUTs"
URL="https://dl.fujifilm-x.com/support/lut/gfx-eterna-55-3d-lut-v110.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fL --retry 3 -o "$WORK/lut.zip" "$URL"
mkdir "$WORK/x"
unzip -qq -j "$WORK/lut.zip" '*/33Grid/F-Log2/FLog2_to_*_33grid_V.1.00.cube' -d "$WORK/x"

cat > "$WORK/SHA256" <<'SUMS'
14b0c3644c1f81391aa79ca5bd8c33a4b50844f525295574ce2af9237d021930  FLog2_to_ACROS_33grid_V.1.00.cube
c019934ee9e3fe9abadd6dfdc03d1013bbd6ba4277f6bd505d340d2730b1b83d  FLog2_to_ASTIA_33grid_V.1.00.cube
b68c8f4b38da958388931c34ce9eb5c09a495e8c37e654537d534dfd8f023b75  FLog2_to_CLASSIC-CHROME_33grid_V.1.00.cube
f3db5fe777c3a64e998b8ada64ff8cc2e61f9b44538fd7c550733d1c55c197c5  FLog2_to_CLASSIC-Neg._33grid_V.1.00.cube
61404637816b57af5af17c82efc4b1349ab0f30a143795779b216b623b487ec3  FLog2_to_ETERNA-BB_33grid_V.1.00.cube
4fe74f18d88b81124b688a218d9be4ac23c41d467430ec31cfe5d70aa2de5bb8  FLog2_to_ETERNA_33grid_V.1.00.cube
a2fe3a8a1730c8428d1878a7628c45a452c8031990e13fb4b9680d3cc4fb9680  FLog2_to_PRO-Neg.Std_33grid_V.1.00.cube
6b603a266584f19a988a352bc311ea64192fe460ed3493fe97aeef5afbe8a239  FLog2_to_PROVIA_33grid_V.1.00.cube
99d30c17b9246130fe0b4ae37e0207adb811e39ce4eb092f9186072173982749  FLog2_to_REALA-ACE_33grid_V.1.00.cube
1e7cea327d920e50dcfafeb16e463d596cf7940ab211f8b5b66ebf91769e0de6  FLog2_to_Velvia_33grid_V.1.00.cube
SUMS

(cd "$WORK/x" && shasum -a 256 --quiet -c "$WORK/SHA256")

mkdir -p "$DEST"
awk '{print $2}' "$WORK/SHA256" | while read -r name; do
  cp "$WORK/x/$name" "$DEST/$name"
  git -C "$ROOT" check-ignore -q "$DEST/$name" || { echo "NOT IGNORED BY GIT: $name" >&2; exit 1; }
done

test "$(find "$DEST" -name '*.cube' | wc -l | tr -d ' ')" = 10
echo "Installed 10 LUTs in $DEST"
```
<!-- install-script:end -->

**Success looks like** `Installed 10 LUTs in ...` as the last line. Any other ending is a failure, so go
to Troubleshooting.

## Step 2: Build

The project already includes `iOS/FilmLab/Resources/LUTs` as a folder, so **you don't need to run
`xcodegen`**. Whatever is in that folder is copied into the app at `FilmLab.app/LUTs/`.

Requirements: full Xcode, not only the Command Line Tools. If `xcode-select -p` doesn't point at Xcode,
prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. If the build reports a
missing Metal Toolchain, run `xcodebuild -downloadComponent MetalToolchain`.

To check the bundling without any signing:

```bash
cd iOS && xcodebuild -project FilmLab.xcodeproj -scheme FilmLab -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
find build/dd/Build/Products/Debug-iphoneos/FilmLab.app/LUTs -name '*.cube' | wc -l   # must print 10
```

## Step 3: Install on the iPhone

`iOS/project.yml` has the owner's signing team and bundle ID. On a different Apple account, change
`DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` there and run `xcodegen generate`. Don't commit those
changes to the shared repo unless asked.

```bash
xcrun devicectl list devices    # copy the phone's identifier into UDID below
UDID=<identifier>
cd iOS && xcodebuild -project FilmLab.xcodeproj -scheme FilmLab -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build/dd build
xcrun devicectl device install app --device "$UDID" build/dd/Build/Products/Debug-iphoneos/FilmLab.app
xcrun devicectl device process launch --terminate-existing --device "$UDID" com.alexandersolod.filmlab
```

Add `-allowProvisioningUpdates` to the build only if it reports missing signing assets or a missing
profile. Avoid running that flag while Xcode has this project open: both can refresh certificates at once,
which caused a `no identity found` failure on the owner's Mac. Trusting the developer profile on the phone
(Settings > General > VPN & Device Management) is a step only the owner can do.

## Step 4: Verify on the device

```bash
xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
  --domain-identifier com.alexandersolod.filmlab \
  --source "Library/Application Support/LUTs/simulations.json" --destination /tmp/simulations.json
grep displayName /tmp/simulations.json
```

Expect these 10 names: Acros, Astia, Classic Chrome, Classic Neg., Eterna, Eterna Bleach Bypass,
PRO Neg. Std, Provia, Reala Ace, Velvia. Neutral is built in and isn't listed in this file.

**Already installed with LUTs?** The app copies bundled LUTs only once, on first launch, and remembers that
it did (`bundledLUTsInstalled`). This keeps deleted simulations deleted. So reinstalling won't add or update
LUTs on a phone that has already done this. If the phone's list is wrong, ask the owner before doing anything
that resets the app (rule 4). Importing with the `+` at the end of the simulation picker is the safe option.

## Troubleshooting

| Symptom | Cause | What to do |
| --- | --- | --- |
| `curl` gets 404 | Fujifilm published a new version and changed the URL | Open the page above in a real browser, copy the GFX ETERNA 55 link, update `URL` in the script and this doc, and re-run. The checksums still protect you |
| The LUT page returns 403 to `curl` | The site refuses scripted page requests. Observed 2026-11-05 | Expected. The zip URL on `dl.fujifilm-x.com` worked with plain `curl`. Read the page in a real browser only |
| A captcha or a block on the zip itself | The site is restricting automated downloads | Stop (rule 3). Ask the owner to download the zip in their browser, then replace the `curl` line with a copy of their file |
| `shasum` reports `FAILED` | Fujifilm changed the LUT, or the download is bad | Re-run once. If it fails again, **don't edit the checksums to make it pass**. Tell the owner: a changed LUT changes the app's colour, so they should decide |
| `unzip` finds no matching files | The package layout or file versions changed | List it with `unzip -l`, confirm the F-Log2 33-grid files with the owner, then update this doc |
| `NOT IGNORED BY GIT` | `.gitignore` no longer covers `*.cube` | Fix `.gitignore` before anything else (rule 1) |
| Colours or exposure look wrong, with no errors | Possibly a wrong LUT set, such as F-Log2C or F-Log imported by hand | Rerun the script, which accepts only the correct files. A phone that has already installed LUTs won't pick them up (see Step 4) |
| The app still shows the import screen | The LUTs weren't in the bundle at build time | Re-run the Step 2 count, then rebuild and reinstall |

## Other cameras' packages

The X and GFX packages on the same page are for those cameras, and the app has only been tested with this
one. Other F-Log2 packages may hold different LUTs, so they won't match the checksums. Use them only if the
owner asks, through the in-app import.
