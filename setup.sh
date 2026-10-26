#!/bin/bash
# Einmaliges Setup für Skipper.
#
# Legt eine feste Signatur-Identität fest und baut/installiert die App damit. Grund: macOS merkt sich
# Freigaben (z. B. Zugriff auf Schreibtisch, Dokumente, Downloads) pro Signatur. Mit der bisherigen
# Ad-hoc-Signatur ist jeder Build für macOS eine "neue" App und fragt erneut. Mit einer festen
# Identität bleiben die Freigaben über alle künftigen Builds erhalten.
#
# Reihenfolge:
#   1. bereits gewählte Identität (Datei .signing-identity)
#   2. vorhandenes Entwickler-Zertifikat (Apple Development / Developer ID / Mac Developer)
#   3. sonst: selbst ausgestelltes Zertifikat "Skipper Local Signing" im Anmelde-Schlüsselbund anlegen
#
# Erneut ausführen ist unbedenklich.  Andere Identität erzwingen:  rm .signing-identity && ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"
CONF=".signing-identity"
SELF_NAME="Skipper Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

have_identity() { security find-identity -p codesigning 2>/dev/null | grep -q "$1"; }

ID=""
if [ -s "$CONF" ] && have_identity "$(cat "$CONF")"; then
  ID="$(cat "$CONF")"
  echo "→ Verwende gespeicherte Signatur-Identität $ID"
fi

if [ -z "$ID" ]; then
  ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"(Apple Development|Developer ID Application|Mac Developer)' | head -1 | awk '{print $2}')"
  [ -n "$ID" ] && echo "→ Verwende vorhandenes Entwickler-Zertifikat: $(security find-identity -v -p codesigning | grep "$ID" | cut -d'"' -f2)"
fi

if [ -z "$ID" ]; then
  if ! security find-certificate -c "$SELF_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "→ Lege selbst ausgestelltes Signatur-Zertifikat „$SELF_NAME“ im Anmelde-Schlüsselbund an …"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $SELF_NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
      -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    PW="explorer-setup"
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$SELF_NAME" \
      -out "$TMP/cert.p12" -passout "pass:$PW"
    security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign >/dev/null
  fi
  ID="$(security find-certificate -c "$SELF_NAME" -Z "$KEYCHAIN" | awk '/SHA-1/ {print $3}')"
  echo "→ Verwende „$SELF_NAME“ ($ID)"
fi

echo "$ID" > "$CONF"
./build.sh --install
echo
echo "✓ Setup fertig. Ab jetzt bleiben Ordner-Freigaben auch nach neuen Builds erhalten."
echo "  macOS fragt nach diesem ersten Build mit der neuen Signatur noch EIN letztes Mal pro Ordner."
