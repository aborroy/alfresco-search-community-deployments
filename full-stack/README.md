# Full stack: the complete Alfresco Community deployment

The whole platform behind a single reverse proxy, with Alfresco Search Community as the
search tier. This is the variant to start from if you want a working Alfresco you can click
around in, rather than a configuration to read.

The layout follows the output of
[alfresco-docker-installer](https://github.com/Alfresco/alfresco-docker-installer) run with
`--searchType=opensearch`, which is why the repository and Share images are built locally:
that is the hook for layering in your own AMPs and JARs.

## What it runs

| Service | Purpose | Exposed |
| --- | --- | --- |
| `proxy` | nginx, single entry point for every web service | 8080 |
| `alfresco` | Content repository, built locally, `elasticsearch` subsystem | via proxy |
| `share` | Share UI, built locally | via proxy |
| `content-app` | Alfresco Content App | via proxy |
| `transform-core-aio` | Transformations and text extraction | internal |
| `postgres` | Repository database | internal |
| `opensearch` | The search index, security plugin disabled | internal |
| `batch-indexer` | Feeds the search index from repository transactions | internal |
| `opensearch-dashboards` | Web UI to inspect the indexes | 5601 |

## Requirements

The repository container alone is capped at 5952 MB, and the stack as a whole asks for
roughly 12 GB. Give Docker at least 14 GB of memory, or use `../minimal` instead. First start
also builds two images and pulls around 4 GB, so expect ten minutes or more before the login
page answers.

## Start

```bash
docker compose up -d --build
```

Watch the repository come up:

```bash
docker compose logs -f alfresco
```

## Access

| What | URL | Credentials |
| --- | --- | --- |
| Content App | http://localhost:8080 | `admin` / `admin` |
| Share | http://localhost:8080/share | `admin` / `admin` |
| Repository | http://localhost:8080/alfresco | `admin` / `admin` |
| API Explorer | http://localhost:8080/api-explorer | |
| OpenSearch Dashboards | http://localhost:5601 | none, security disabled |

`SERVER_NAME` in `../.env` is `localhost`. Change it if you are reaching the stack by
hostname or IP, since the repository builds absolute URLs from it.

## Verify indexing

OpenSearch is not published on the host in this variant, so query it from inside the network:

```bash
docker compose exec opensearch curl -s "http://localhost:9200/_cat/indices?v"
docker compose logs -f batch-indexer
```

Or use Dashboards on http://localhost:5601, which is what it is there for.

## Stop

```bash
docker compose down          # keeps data
docker compose down -v       # also removes volumes
```

Repository content, database, index and logs are bind-mounted under `./data` and `./logs`,
both git-ignored. `docker compose down` leaves them in place. To start genuinely clean, delete
those directories as well.

## Adding your own extensions

- `alfresco/modules/amps` and `share/modules/amps`: AMP files, installed with the Alfresco
  Module Management Tool during the build.
- `alfresco/modules/jars` and `share/modules/jars`: JAR files, copied straight onto the
  webapp classpath.

Each directory holds an `empty` placeholder file so the `COPY` instructions succeed on a
clean checkout. Leave it in place. After adding anything, rebuild with
`docker compose up -d --build`.

## Notes

- The nginx configuration returns 403 for every path that would expose the repository's Solr
  API to unauthenticated callers, including the Share and Content App proxy routes to it.
- The messaging subsystem is switched off (`messaging.subsystem.autoStart=false`,
  `repo.event2.enabled=false`), so no ActiveMQ service is present. The ActiveMQ broker JAR is
  still required on the classpath and the repository Dockerfile fetches it from Maven Central,
  checksum-verified.
- `solr.secureComms=secret` is mandatory and its value must match the indexer's
  `ALFRESCO_CONTENT_TRANSFORM_SHAREDSECRET`. Both come from `SHARED_SECRET` in `../.env`.
- OpenSearch runs with its security plugin disabled and is not exposed to the host. For a
  TLS-enabled search tier see `../minimal-tls`.
