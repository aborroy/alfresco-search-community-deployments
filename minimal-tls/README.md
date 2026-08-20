# Minimal with TLS: OpenSearch security plugin enabled, TLS 1.3 only

The same stack as `../minimal`, but with the OpenSearch security plugin switched on and the
HTTP endpoint restricted to TLS 1.3 as the only accepted protocol, using the plugin's own
standard mechanisms.

Use this variant to see what changes on the Alfresco side once the search backend stops
being an open HTTP port: truststores, credentials, and the `https` secure comms mode.

## Generate the demo PKI first

The certificates are not committed. Generate them before the first start:

```bash
./generate-certs.sh
```

This writes into `certs/`, which is git-ignored:

| File | Purpose |
| --- | --- |
| `root-ca.pem`, `root-ca-key.pem` | The demo certificate authority |
| `opensearch.pem`, `opensearch-key.pem` | Node certificate, `CN=opensearch`, SAN `opensearch` and `localhost` |
| `admin.pem`, `admin-key.pem` | Admin certificate, `CN=admin`, matching `admin_dn` |
| `ssl.truststore` | JCEKS truststore holding the CA, for the Alfresco repository |
| `batch-indexer-truststore.jks` | JKS truststore holding the CA, for the indexer's Java client |
| `internal_users.yml` | The `admin` user, with a bcrypt hash of `OPENSEARCH_PASSWORD` |

The script needs `openssl`, `keytool` from any JDK, and a running Docker daemon. Docker is
used only to compute the bcrypt hash with the security plugin's own `hash.sh`, so the hash is
produced by exactly the code that later verifies it.

To regenerate from scratch, delete the directory and run the script again:

```bash
rm -rf certs && ./generate-certs.sh
```

> Everything under `certs/` is throwaway demo material: a self-signed CA with its private key
> unencrypted on disk. Never reuse any of it outside a local demo.

## Credentials

OpenSearch, from `../.env`:

- User: `admin`
- Password: `DemoTls13!Pass`

The repository keeps the stock `admin`/`admin`.

## Start

```bash
docker compose up -d
```

## Verify that TLS 1.3 is enforced

```bash
# Succeeds
curl -sk -u admin:'DemoTls13!Pass' --tlsv1.3 https://localhost:9200/_cluster/health

# Fails with a protocol version alert, proving TLS 1.2 is rejected
curl -sk -u admin:'DemoTls13!Pass' --tlsv1.2 --tls-max 1.2 https://localhost:9200/_cluster/health
```

## Verify indexing

```bash
curl -sk -u admin:'DemoTls13!Pass' "https://localhost:9200/_cat/indices?v"
docker compose logs -f batch-indexer
```

## Custom content models

The repository here is stock, so the indexer's built-in namespace prefix map covers it. Deploy a
model of your own and the map has to be regenerated from the repository, or nodes using the model
are indexed incompletely and silently. The procedure is in
[../docs/custom-content-models.md](../docs/custom-content-models.md); two details are specific to
this variant.

The indexer already receives `JAVA_TOOL_OPTIONS` for the truststore, so append the flag to that
variable rather than adding a `JAVA_OPTS` key:

```yaml
  batch-indexer:
    environment:
      JAVA_TOOL_OPTIONS: >-
        -Djavax.net.ssl.trustStore=/certs/batch-indexer-truststore.jks
        -Djavax.net.ssl.trustStorePassword=${TRUSTSTORE_PASSWORD}
        -Dalfresco.reindex.prefixes-file=file:/config/prefixes.json
    volumes:
      - ./certs/batch-indexer-truststore.jks:/certs/batch-indexer-truststore.jks:ro
      - ./config/prefixes.json:/config/prefixes.json:ro
```

Both services already declare `volumes`, so append to those lists: the addon JAR goes on
`alfresco` next to the truststore mount, and `prefixes.json` on `batch-indexer` next to its own.
`tools/fetch-prefix-map.sh` talks to the repository over plain HTTP on port 8080 as `admin`/`admin`,
which TLS here does not change: only the OpenSearch link is encrypted, and the password in
Credentials above is OpenSearch's, not the repository's.

## What changes compared to the plain variant

- **`opensearch`**: security plugin enabled (`DISABLE_INSTALL_DEMO_CONFIG=true` plus the
  generated certificates and `config/opensearch-security-tls.yml` mounted in), TLS mandatory
  on port 9200, and the accepted protocol list narrowed to `TLSv1.3`. The settings file is
  appended to the image's own `opensearch.yml` rather than replacing it, so the image
  defaults survive.
- **`alfresco`**: `elasticsearch.secureComms=https`, `elasticsearch.user` and
  `elasticsearch.password` credentials, and the JCEKS truststore holding the demo CA mounted
  at `ssl-keystore/ssl.truststore`. The repository resolves the truststore password from the
  `ssl-truststore.password` and `ssl-keystore.password` system properties, which the compose
  file sets from `TRUSTSTORE_PASSWORD`.
- **`batch-indexer`**: `SPRING_ELASTICSEARCH_REST_URIS` switches to the `https://` scheme with
  credentials embedded in the URI, plus `-Djavax.net.ssl.trustStore` pointing at the JKS
  truststore holding the same CA.

Hostname verification is disabled on the Alfresco side
(`elasticsearch.ssl.host.name.verification=false`) because the demo certificate is
self-signed. In a real deployment, issue a certificate whose SAN matches the hostname the
repository actually connects to and leave verification on.

## No post-quantum cryptography here

This is standard TLS 1.3, using whatever key exchange and signature algorithms the
underlying JDK and OpenSSL provide by default. Restricting `enabled_protocols` to `TLSv1.3`
constrains the protocol version, not the algorithm families. No post-quantum key exchange is
involved.
