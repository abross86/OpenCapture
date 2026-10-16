#!/bin/bash
# Resubmits build/OpenCapture.app to the notary service until Apple stops returning the
# "agreement missing or expired" 403 (which lingers for a while after accepting an agreement),
# then staples the ticket and re-zips the app for distribution.
#   Tools/notarize-retry.sh            (env: NOTARY_PROFILE, INTERVAL seconds, ATTEMPTS)
set -u
cd "$(dirname "$0")/.."
APP=build/OpenCapture.app; ZIP=build/OpenCapture.zip
PROFILE="${NOTARY_PROFILE:-OpenCapture}"; INTERVAL="${INTERVAL:-300}"; ATTEMPTS="${ATTEMPTS:-24}"
[ -d "$APP" ] || { echo "Build the app first (./build.sh)"; exit 1; }
for i in $(seq 1 "$ATTEMPTS"); do
    echo "[$(date +%H:%M:%S)] submission attempt $i of $ATTEMPTS"
    rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
    out=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1); rc=$?
    echo "$out" | grep -vE '^\s*$'
    if [ $rc -eq 0 ] && echo "$out" | grep -q 'status: Accepted'; then
        echo "==> Accepted. Stapling…"
        xcrun stapler staple "$APP" && xcrun stapler validate "$APP" && spctl --assess --type execute -vv "$APP" || exit 1
        rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
        echo "==> DONE: notarized and stapled; distributable zip at $ZIP"
        exit 0
    fi
    if echo "$out" | grep -q 'status code: 403'; then
        echo "    agreement not yet in effect on Apple's side; retrying in $((INTERVAL/60)) min"
        sleep "$INTERVAL"
    else
        echo "==> Submission failed for a different reason (see above). Fetch details with:"
        echo "    xcrun notarytool log <submission-id> --keychain-profile $PROFILE"
        exit 1
    fi
done
echo "==> Gave up after $ATTEMPTS attempts"; exit 1
