#!/usr/bin/env bash
set -euo pipefail
arch="${1:?spksrc architecture required}"
tcversion="${2:-7.1}"
version="${3:-3.3.6}"
work="${GITHUB_WORKSPACE}/.spksrc-cache/${arch}-${tcversion}"
source_dir="${RUNNER_TEMP:-/tmp}/autobangumi-source-${version}"
spksrc_commit="e69c641e3f26b53e587f551b3b6edef27792632e"

rm -rf "${source_dir}" "${GITHUB_WORKSPACE}/cross-wheels"
mkdir -p "${source_dir}"
curl -fsSL "https://github.com/EstrellaXD/Auto_Bangumi/releases/download/${version}/app-v${version}.zip" -o "${RUNNER_TEMP}/autobangumi.zip"
unzip -q "${RUNNER_TEMP}/autobangumi.zip" -d "${source_dir}"
test -s "${source_dir}/uv.lock"
docker run --rm -v "${source_dir}:/src" -w /src python:3.14-bookworm bash -euc '
  python -m pip install --disable-pip-version-check --upgrade uv
  python -m uv export --frozen --no-dev --no-emit-project --no-hashes \
    -o /src/requirements-crossenv.txt
'
sudo chown "$(id -u):$(id -g)" "${source_dir}/requirements-crossenv.txt"
case "${arch}" in x64) target_arch="x86_64" ;; *) target_arch="armv8" ;; esac
docker run --rm -v "${GITHUB_WORKSPACE}:/repo:ro" -v "${source_dir}:/src" -w /src python:3.14-bookworm bash -euc '
  python -m pip install --disable-pip-version-check packaging
  python /repo/scripts/select_spksrc_candidates.py /src/requirements-crossenv.txt '"${target_arch}"' '"${tcversion}"' /src/spksrc-candidates.txt /src/dependency-report.json
'
sudo chown -R "$(id -u):$(id -g)" "${source_dir}"

mkdir -p "${GITHUB_WORKSPACE}/cross-wheels"
cp "${source_dir}/spksrc-candidates.txt" "${source_dir}/dependency-report.json" "${GITHUB_WORKSPACE}/cross-wheels/"
if [ ! -s "${source_dir}/spksrc-candidates.txt" ]; then
  echo "All locked dependencies have compatible wheels; spksrc compilation is unnecessary."
  exit 0
fi
if [ ! -d "${work}/.git" ]; then
  mkdir -p "$(dirname "${work}")"
  git clone --filter=blob:none --no-checkout https://github.com/SynoCommunity/spksrc.git "${work}"
fi
git -C "${work}" checkout -f "${spksrc_commit}"
rm -rf "${work}/spk/codex-autobangumi-full"
mkdir -p "${work}/spk/codex-autobangumi-full/src"
cp "${source_dir}/spksrc-candidates.txt" "${work}/spk/codex-autobangumi-full/src/requirements-crossenv.txt"
cat > "${work}/spk/codex-autobangumi-full/Makefile" <<'EOF'
SPK_NAME = codex-autobangumi-full
SPK_VERS = 1.0
SPK_REV = 1
PYTHON_PACKAGE = python314
MAINTAINER = Codex
DESCRIPTION = Full AutoBangumi dependency build with Synology toolchain
STARTABLE = no
DISPLAY_NAME = AutoBangumi full dependency build
HOMEPAGE = https://github.com/tbc0309/autobangumi-spk
LICENSE = MIT
WHEELS = src/requirements-crossenv.txt
WHEELS_PURE_PYTHON_PACKAGING_ENABLE = 1
include ../../mk/spksrc.spk-meta.mk
EOF
printf 'rsc:share/wheelhouse\n' > "${work}/spk/codex-autobangumi-full/PLIST"
docker run --rm --platform linux/amd64 -v "${work}:/spksrc" -w /spksrc \
  ghcr.io/synocommunity/spksrc:latest bash -euc "
    git config --global --add safe.directory /spksrc
    make -C spk/codex-autobangumi-full -j2 arch-${arch}-${tcversion}
  "

sudo chown -R "$(id -u):$(id -g)" "${work}"

for library in libstdc++.so.6 libgcc_s.so.1; do
  source="$(find "${work}" -type f \( -name "${library}" -o -name "${library}.*" \) -print -quit)"
  [ -n "${source}" ] || { echo "Missing toolchain runtime ${library}" >&2; exit 1; }
  cp -Lv "${source}" "${GITHUB_WORKSPACE}/cross-wheels/${library}"
done

while IFS= read -r requirement; do
  name="${requirement%%==*}"; version="${requirement#*==}"
  normalized="$(printf '%s' "${name}" | tr '[:upper:]-' '[:lower:]_')"
  wheel="$(find "${work}" -type f -path '*/wheelhouse/*' \
    -iname "${normalized}-${version}-*.whl" ! -name '*_pc_linux_gnu.whl' \
    -print -quit)"
  if [ -z "${wheel}" ]; then
    wheel="$(find "${work}" -type f -path '*/wheelhouse/*' \
      -iname "${normalized}-${version}-*.whl" -print -quit)"
  fi
  [ -n "${wheel}" ] || { echo "Missing exact wheel for ${requirement}" >&2; exit 1; }
  cp -v "${wheel}" "${GITHUB_WORKSPACE}/cross-wheels/"
done < "${source_dir}/spksrc-candidates.txt"
test -n "$(find "${GITHUB_WORKSPACE}/cross-wheels" -maxdepth 1 -name '*.whl' -print -quit)"
cp "${source_dir}/spksrc-candidates.txt" "${GITHUB_WORKSPACE}/cross-wheels/requirements.txt"
echo "Built $(find "${GITHUB_WORKSPACE}/cross-wheels" -maxdepth 1 -name '*.whl' | wc -l) wheels"
