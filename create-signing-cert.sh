#!/usr/bin/env bash
# create-signing-cert.sh — create a proper self-signed CODE SIGNING identity
# "MetaFactoryDev" in the login keychain, so ./make-app.sh can sign IvyVoice.app
# with a STABLE identity and macOS TCC grants (mic, speech, screen) survive rebuilds.
#
# WHY THIS SCRIPT: a cert created via Certificate Assistant without Certificate
# Type = "Code Signing" has no codeSigning Extended Key Usage, so `codesign` and
# `security find-identity -p codesigning` ignore it (0 valid identities). This
# builds one with the correct EKU via openssl and imports it with the key ACL set
# so codesign can use it without a GUI prompt on every build.
#
# RUN IT YOURSELF (needs your login-keychain password):  ./create-signing-cert.sh
set -euo pipefail

NAME="MetaFactoryDev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[1/5] removing any previous '$NAME' cert/identity (ok if 'not found')..."
security delete-identity    -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
security delete-certificate  -c "$NAME" "$KEYCHAIN" 2>/dev/null || true

echo "[2/5] generating RSA key + self-signed Code Signing cert (10y)..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=${NAME}/C=CH" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# sanity: the EKU that was missing before must be present now
openssl x509 -in "$TMP/cert.pem" -noout -ext extendedKeyUsage | grep -q "Code Signing" \
  || { echo "ERROR: generated cert lacks Code Signing EKU"; exit 1; }

echo "[3/5] packaging as PKCS#12..."
P12PASS="tmp-$RANDOM-$RANDOM"
# macOS `security import` cannot read openssl-3's default PKCS#12 MAC/cipher and
# fails with "MAC verification failed". `-legacy` emits the older SHA1-MAC/3DES
# format macOS accepts. LibreSSL (system openssl) has no -legacy flag but its
# default is already compatible — so try -legacy first, fall back to plain.
if ! openssl pkcs12 -export -legacy \
      -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
      -name "$NAME" -out "$TMP/id.p12" -passout pass:"$P12PASS" 2>/dev/null; then
  openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout pass:"$P12PASS"
fi

echo "[4/5] importing into login keychain (codesign allowed to use the key)..."
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PASS" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "[5/5] authorizing codesign to use the key without a per-build prompt."
echo "      Enter your LOGIN (keychain) password:"
read -r -s KCPW
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KEYCHAIN" >/dev/null
unset KCPW

echo
echo "== verify (real test-sign) =="
# Do NOT use `find-identity -v`: -v means "trusted", and a self-signed dev cert is
# untrusted by design (it lists as CSSMERR_TP_NOT_TRUSTED). Trust is irrelevant to
# SIGNING — it only affects Gatekeeper verification of distributed apps. The
# authoritative check is: can codesign actually sign with it?
PROBE="$(mktemp)"; cp /bin/echo "$PROBE"
if codesign --force --sign "$NAME" "$PROBE" 2>/tmp/cs-verify-err; then
  rm -f "$PROBE"
  echo "OK — '$NAME' can sign (untrusted-but-usable, as expected). Run ./make-app.sh."
else
  echo "FAILED to sign with '$NAME':"; cat /tmp/cs-verify-err; rm -f "$PROBE"; exit 1
fi

# NOTE: this is a self-signed identity for LOCAL running only. Gatekeeper/spctl will
# not accept it for distribution — that's fine; we run the app locally and grant TCC.
