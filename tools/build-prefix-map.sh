#!/usr/bin/env bash
#
# Build a complete namespace prefix map for the batch indexer.
#
# The indexer resolves a property's namespace URI to its prefix through a static JSON file, and
# the file it ships only knows the namespaces Alfresco ships. A custom content model needs its
# namespace added, and the file replaces rather than extends, so it has to be built from the
# shipped one.
#
# Usage, from the repository root:
#
#   tools/build-prefix-map.sh URI=PREFIX [URI=PREFIX ...] > minimal/config/prefixes.json
#
# Example:
#
#   tools/build-prefix-map.sh http://example.org/model/hr/1.0=hr > minimal/config/prefixes.json
#
# With no arguments it writes the shipped map unchanged, which is useful for reading it.
#
# Requires Docker only. The extraction runs inside the indexer image, using the Python that
# image already carries.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
BATCH_INDEXER_TAG="$(grep '^BATCH_INDEXER_TAG=' "$ROOT/.env" | cut -d= -f2)"
IMAGE="alfresco/alfresco-elasticsearch-batch-indexing:${BATCH_INDEXER_TAG}"

for pair in "$@"; do
    case "$pair" in
        *=*) ;;
        *)
            echo "Not a URI=PREFIX pair: $pair" >&2
            exit 2
            ;;
    esac
done

docker run --rm -i --entrypoint python3 "$IMAGE" - "$@" <<'PYTHON'
import io
import json
import sys
import zipfile

APP_JAR = "/opt/app.jar"
NESTED_JAR_MARKER = "alfresco-elasticsearch-reindexing"
RESOURCE = "reindex.prefixes-file.json"

with zipfile.ZipFile(APP_JAR) as app_jar:
    nested = [
        name
        for name in app_jar.namelist()
        if NESTED_JAR_MARKER in name and name.endswith(".jar")
    ]
    if not nested:
        sys.exit("no %s jar inside %s" % (NESTED_JAR_MARKER, APP_JAR))
    with zipfile.ZipFile(io.BytesIO(app_jar.read(nested[0]))) as reindexing_jar:
        shipped = json.loads(reindexing_jar.read(RESOURCE))

prefix_uri_map = shipped["prefixUriMap"]
for pair in sys.argv[1:]:
    uri, prefix = pair.split("=", 1)
    prefix_uri_map[uri] = prefix

json.dump({"prefixUriMap": prefix_uri_map}, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PYTHON
