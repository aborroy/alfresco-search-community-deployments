#!/usr/bin/env bash
#
# Generates the self-signed PKI used by the minimal-tls variant.
#
# Everything this script writes is DEMO MATERIAL: a throwaway CA, a node certificate and
# an admin certificate, all with private keys sitting unencrypted on disk. Never reuse any
# of it outside a local demo.
#
# Output, all under ./certs/ and all git-ignored:
#
#   root-ca.pem / root-ca-key.pem        the demo CA
#   opensearch.pem / opensearch-key.pem  node certificate, CN=opensearch, SAN opensearch + localhost
#   admin.pem / admin-key.pem            admin certificate, CN=admin, matches admin_dn
#   ssl.truststore                       JCEKS truststore holding the CA, for the Alfresco repository
#   batch-indexer-truststore.jks         JKS truststore holding the CA, for the batch indexer's Java client
#   internal_users.yml                   admin user with a bcrypt hash of OPENSEARCH_PASSWORD
#
# Requires openssl, keytool (any JDK) and a running Docker daemon. Docker is used only to
# compute the bcrypt hash with the security plugin's own hash.sh, which avoids depending on
# a local bcrypt implementation.

set -euo pipefail

cd "$(dirname "$0")"

CERTS_DIR="certs"
CONFIG_DIR="config"
ENV_FILE="../.env"
VALIDITY_DAYS=730
KEY_BITS=2048

# --- Read the demo credentials from the shared .env -------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found. Run this script from the minimal-tls directory." >&2
  exit 1
fi

get_env() {
  local key="$1"
  local value
  value=$(grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2-)
  if [[ -z "$value" ]]; then
    echo "error: $key is not set in $ENV_FILE" >&2
    exit 1
  fi
  printf '%s' "$value"
}

OPENSEARCH_PASSWORD=$(get_env OPENSEARCH_PASSWORD)
TRUSTSTORE_PASSWORD=$(get_env TRUSTSTORE_PASSWORD)
OPENSEARCH_TAG=$(get_env OPENSEARCH_TAG)

# --- Preflight -------------------------------------------------------------------------

for tool in openssl keytool docker; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required but was not found on PATH" >&2
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "error: the Docker daemon is not reachable, needed to compute the bcrypt hash" >&2
  exit 1
fi

if [[ -d "$CERTS_DIR" ]] && compgen -G "$CERTS_DIR/*.pem" >/dev/null; then
  echo "certs/ already contains certificates. Delete the directory to regenerate:"
  echo "  rm -rf $CERTS_DIR"
  exit 0
fi

mkdir -p "$CERTS_DIR"

echo "Generating demo PKI in $CERTS_DIR/"

# --- Root CA ---------------------------------------------------------------------------

openssl genrsa -out "$CERTS_DIR/root-ca-key.pem" "$KEY_BITS" 2>/dev/null
openssl req -new -x509 -sha256 \
  -key "$CERTS_DIR/root-ca-key.pem" \
  -out "$CERTS_DIR/root-ca.pem" \
  -days "$VALIDITY_DAYS" \
  -subj "/CN=demo-root-ca" \
  -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
echo "  root CA          CN=demo-root-ca"

# --- Helper: issue a leaf certificate signed by the demo CA ----------------------------

issue_cert() {
  local name="$1" cn="$2" extfile="$3"

  openssl genrsa -out "$CERTS_DIR/${name}-key.pem" "$KEY_BITS" 2>/dev/null
  openssl req -new -sha256 \
    -key "$CERTS_DIR/${name}-key.pem" \
    -out "$CERTS_DIR/${name}.csr" \
    -subj "/CN=${cn}" 2>/dev/null

  # shellcheck disable=SC2086
  openssl x509 -req -sha256 \
    -in "$CERTS_DIR/${name}.csr" \
    -CA "$CERTS_DIR/root-ca.pem" \
    -CAkey "$CERTS_DIR/root-ca-key.pem" \
    -CAcreateserial \
    -out "$CERTS_DIR/${name}.pem" \
    -days "$VALIDITY_DAYS" \
    $extfile 2>/dev/null

  rm -f "$CERTS_DIR/${name}.csr"
}

# Node certificate. The SAN must cover both the Compose service name, used for
# container-to-container traffic, and localhost, used by curl from the host.
SAN_FILE=$(mktemp)
printf 'subjectAltName=DNS:opensearch,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n' > "$SAN_FILE"
issue_cert "opensearch" "opensearch" "-extfile $SAN_FILE"
rm -f "$SAN_FILE"
echo "  node cert        CN=opensearch, SAN=opensearch,localhost"

# Admin certificate. CN=admin must match plugins.security.authcz.admin_dn in
# config/opensearch-security-tls.yml.
ADMIN_EXT_FILE=$(mktemp)
printf 'extendedKeyUsage=clientAuth\n' > "$ADMIN_EXT_FILE"
issue_cert "admin" "admin" "-extfile $ADMIN_EXT_FILE"
rm -f "$ADMIN_EXT_FILE"
echo "  admin cert       CN=admin"

# --- Truststores -----------------------------------------------------------------------

# JCEKS for the Alfresco repository. The repository resolves the password from the
# ssl-truststore.password and ssl-keystore.password system properties, which the
# compose file sets from TRUSTSTORE_PASSWORD.
keytool -importcert -noprompt \
  -alias root-ca \
  -file "$CERTS_DIR/root-ca.pem" \
  -keystore "$CERTS_DIR/ssl.truststore" \
  -storetype JCEKS \
  -storepass "$TRUSTSTORE_PASSWORD" >/dev/null 2>&1
echo "  ssl.truststore   JCEKS, alias root-ca (Alfresco repository)"

# JKS for the batch indexer, consumed through javax.net.ssl.trustStore.
keytool -importcert -noprompt \
  -alias root-ca \
  -file "$CERTS_DIR/root-ca.pem" \
  -keystore "$CERTS_DIR/batch-indexer-truststore.jks" \
  -storetype JKS \
  -storepass "$TRUSTSTORE_PASSWORD" >/dev/null 2>&1
echo "  batch-indexer-truststore.jks   JKS, alias root-ca (batch indexer)"

# --- internal_users.yml ----------------------------------------------------------------

# hash.sh ships with the security plugin, so the hash is produced by exactly the code that
# will later verify it. Its output can include log noise, so keep only the last line.
HASH=$(docker run --rm --entrypoint bash \
  "opensearchproject/opensearch:${OPENSEARCH_TAG}" \
  -c "OPENSEARCH_JAVA_HOME=/usr/share/opensearch/jdk \
      /usr/share/opensearch/plugins/opensearch-security/tools/hash.sh -p '${OPENSEARCH_PASSWORD}' 2>/dev/null" \
  | tail -1 | tr -d '\r')

if [[ ! "$HASH" =~ ^\$2y\$ ]]; then
  echo "error: hash.sh did not return a bcrypt hash, got: $HASH" >&2
  exit 1
fi

# The hash contains $ and / characters, so substitute it with awk rather than sed.
awk -v hash="$HASH" '{ gsub(/__ADMIN_HASH__/, hash); print }' \
  "$CONFIG_DIR/internal_users.yml.template" > "$CERTS_DIR/internal_users.yml"
echo "  internal_users.yml   admin user, bcrypt hash of OPENSEARCH_PASSWORD"

# --- Permissions -----------------------------------------------------------------------

# OpenSearch refuses to start if the private key is group or world readable.
chmod 600 "$CERTS_DIR"/*-key.pem
chmod 644 "$CERTS_DIR"/root-ca.pem "$CERTS_DIR"/opensearch.pem "$CERTS_DIR"/admin.pem

echo
echo "Done. Start the stack with:"
echo "  docker compose up -d"
