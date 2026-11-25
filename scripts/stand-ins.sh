#!/bin/sh
# Puts local copies of the packages that are not on Hex yet into
# build/packages, so that the build and the tests run with no Hex request.
#
# dream_postgres 2.1.0 needs dream_postgres_client 1.1.0 and
# dream_postgres_driver 1.1.0. manifest.toml already names these versions,
# with a checksum of zeros. Gleam does not download a package that
# build/packages/packages.toml lists with the version of the manifest, so
# this script copies each package and lists it.
#
# Remove this script when both packages are on Hex. Then run
# `gleam deps update dream_postgres_client dream_postgres_driver` to write
# the real checksums into manifest.toml.
#
# The sources (each one can be changed with an environment variable):
#   DREAM_POSTGRES_CLIENT_SOURCE  a clone of the client at version 1.1.0
#   DREAM_POSTGRES_CLIENT_COMMIT  the commit of version 1.1.0 (default HEAD)
#   DREAM_POSTGRES_DRIVER_SOURCE  a clone of the driver at version 1.1.0
#   DREAM_POSTGRES_DRIVER_COMMIT  the commit of version 1.1.0 (default HEAD)
#
# Usage: sh scripts/stand-ins.sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
client_source="${DREAM_POSTGRES_CLIENT_SOURCE:-$root/../dream_postgres_client-numeric}"
client_commit="${DREAM_POSTGRES_CLIENT_COMMIT:-HEAD}"
driver_source="${DREAM_POSTGRES_DRIVER_SOURCE:-$root/../dream_postgres_driver-numeric}"
driver_commit="${DREAM_POSTGRES_DRIVER_COMMIT:-HEAD}"
packages="$root/build/packages"

# list_package <name> <version>
list_package() {
  file="$packages/packages.toml"
  [ -f "$file" ] || printf '[packages]\n' > "$file"
  awk -v name="$1" -v version="$2" '
    $1 == name && $2 == "=" { next }
    { print }
    $0 == "[packages]" { printf "%s = \"%s\"\n", name, version }
  ' "$file" > "$file.next"
  mv "$file.next" "$file"
}

# version_of_manifest <name>: the version in manifest.toml
version_of_manifest() {
  sed -n "s/.*{ name = \"$1\", version = \"\([^\"]*\)\".*/\1/p" "$root/manifest.toml" | head -n 1
}

# copy_package <source clone> <commit> <name> <files...>
copy_package() {
  source="$1"
  commit="$2"
  name="$3"
  shift 3
  target="$packages/$name"
  rm -rf "$target" "$root/build/dev/erlang/$name" "$root/build/prod/erlang/$name" \
    "$root/build/lsp/erlang/$name"
  mkdir -p "$target"
  git -C "$source" archive "$commit" "$@" | tar -x -C "$target"
  list_package "$name" "$(version_of_manifest "$name")"
}

# The client is a Gleam package. The driver is a rebar3 package: the files
# of its Hex package, without gleam.toml.
copy_package "$client_source" "$client_commit" dream_postgres_client \
  src gleam.toml LICENSE README.md
copy_package "$driver_source" "$driver_commit" dream_postgres_driver \
  src rebar.config rebar.lock README.md LICENSE CHANGELOG.md
echo "Copied dream_postgres_client and dream_postgres_driver into build/packages"
