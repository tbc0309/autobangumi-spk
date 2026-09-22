#!/usr/bin/env bash
set -euo pipefail

version="${1:?version required}"
arch="${2:?arch required}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="${root}/work/${arch}"
output="${root}/dist/${arch}"
rm -rf "${work}" "${output}"
mkdir -p "${work}/source" "${work}/payload" "${work}/outer" "${output}"

curl -fL --retry 4 -o "${work}/app.zip" \
  "https://github.com/EstrellaXD/Auto_Bangumi/releases/download/${version}/app-v${version}.zip"
unzip -q "${work}/app.zip" -d "${work}/source"
test -f "${work}/source/pyproject.toml"
test -f "${work}/source/uv.lock"
test -f "${work}/source/src/main.py"

case "${arch}" in
  x86_64) image="quay.io/pypa/manylinux2014_x86_64:latest" ;;
  armv8) image="quay.io/pypa/manylinux2014_aarch64:latest" ;;
  *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;;
esac

docker run --rm \
  -v "${root}:/repo:ro" -v "${work}:/work" \
  "${image}" bash -euxo pipefail -c '
    python=/opt/python/cp314-cp314/bin/python
    "$python" -m pip install --disable-pip-version-check uv supervisor==4.3.0
    cd /work/source
    UV_PROJECT_ENVIRONMENT=/work/venv /opt/python/cp314-cp314/bin/uv sync \
      --python /opt/python/cp314-cp314/bin/python --frozen --no-dev --no-install-project
    /opt/python/cp314-cp314/bin/uv export --frozen --no-dev --no-hashes \
      --output-file /work/venv/requirements.txt
    "$python" -m pip --python /work/venv install supervisor==4.3.0
    cp /opt/python/cp314-cp314/bin/uv /work/venv/bin/uv
    "$python" /repo/scripts/bundle_runtime_libraries.py
    if compgen -G "/repo/cross-wheels/*.whl" >/dev/null; then
      /opt/python/cp314-cp314/bin/uv pip install --python /work/venv/bin/python \
        --reinstall --no-deps /repo/cross-wheels/*.whl
    fi
    install -m 0644 /repo/cross-wheels/libstdc++.so.6 /repo/cross-wheels/libgcc_s.so.1 /work/venv/lib/
    readelf -h /work/venv/lib/python3.14/site-packages/greenlet/_greenlet*.so | grep -Eq "Machine:.*(Advanced Micro Devices X86-64|AArch64)"
    strings /work/venv/lib/libstdc++.so.6 | grep -Fx CXXABI_1.3.9
  '

cp -a "${work}/venv/." "${work}/payload/"
cp -a "${work}/source/src" "${work}/payload/app"
cp -a "${work}/source/pyproject.toml" "${work}/source/uv.lock" "${work}/payload/"
cp -a "${root}/packages/autobangumi/payload/." "${work}/payload/"
rm -f "${work}/payload/CACHEDIR.TAG"
mkdir -p "${work}/payload/logs"
mkdir -p "${work}/payload/var/config" "${work}/payload/var/data"
ln -sfn /var/packages/AutoBangumi/var/config "${work}/payload/app/config"
ln -sfn /var/packages/AutoBangumi/var/data "${work}/payload/app/data"
ln -sfn lib "${work}/payload/lib64"
ln -sfn /usr/local/bin/python3.14 "${work}/payload/bin/python3.14"
ln -sfn python3.14 "${work}/payload/bin/python"
ln -sfn python3.14 "${work}/payload/bin/python3"
find "${work}/payload/bin" -type f -maxdepth 1 -exec sed -i \
  '1s|^#!/work/venv/bin/python.*$|#!/var/packages/AutoBangumi/target/bin/python|' {} +

cp -a "${root}/packages/autobangumi/outer/." "${work}/outer/"
chmod 755 "${work}/outer/scripts/"*
python3 - "${work}/outer/INFO" "${version}" "${arch}" <<'PY'
from pathlib import Path
import re, sys
p, version, arch = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = p.read_text()
models = {
    "x86_64": "apollolake avoton braswell broadwell broadwellnk broadwellnkv2 broadwellntbap bromolow cedarview denverton epyc7002 epyc7003 epyc7003ntb geminilake geminilakenk grantley icelaked kvmx64 purley r1000 r1000nk v1000 v1000nk x86 x86_64",
    "armv8": "rtd1296 rtd1619b armada37xx armv8",
}
text = re.sub(r'^version=.*$', f'version="{version}"', text, flags=re.M)
text = re.sub(r'^arch=.*$', f'arch="{models[arch]}"', text, flags=re.M)
text = re.sub(r'^changelog=.*$', f'changelog="更新 AutoBangumi 到 v{version}，使用 Python 3.14 运行环境。"', text, flags=re.M)
p.write_text(text.rstrip() + "\n")
PY

# 群晖安装时再按套件规则调整运行目录权限；归档内容统一使用 0755。
find "${work}/payload" ! -type l -exec chmod 0755 '{}' + -exec chmod u-s,g-s,o-t '{}' +
(
  cd "${work}/payload"
  tar --sort=name --owner=0 --group=0 --numeric-owner -cJf "${work}/outer/package.tgz" *
)
checksum="$(md5sum "${work}/outer/package.tgz" | cut -d' ' -f1)"
sed -i "s/^checksum=.*/checksum=\"${checksum}\"/" "${work}/outer/INFO"
find "${work}/outer" ! -type l -exec chmod 0755 '{}' + -exec chmod u-s,g-s,o-t '{}' +
name="AutoBangumi_v${version}_${arch}-DSM7.spk"
(
  cd "${work}/outer"
  tar --sort=name --owner=0 --group=0 --numeric-owner -cf "${output}/${name}" *
)
tar -tf "${output}/${name}" > "${work}/outer-files.txt"
grep -qx 'package.tgz' "${work}/outer-files.txt"
if grep -q '^\./' "${work}/outer-files.txt"; then
  echo "SPK outer archive unexpectedly contains ./ prefixes" >&2
  exit 1
fi
xz -t "${work}/outer/package.tgz"
tar -tf "${work}/outer/package.tgz" > "${work}/payload-files.txt"
grep -qx 'ui/config' "${work}/payload-files.txt"
grep -qx 'var/config/' "${work}/payload-files.txt"
grep -qx 'var/data/' "${work}/payload-files.txt"
if grep -qx 'CACHEDIR.TAG' "${work}/payload-files.txt"; then
  echo "CACHEDIR.TAG must not be packaged" >&2
  exit 1
fi
echo "Created ${output}/${name}"
