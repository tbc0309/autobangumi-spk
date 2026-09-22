"""Bundle non-system ELF libraries needed by Python extensions."""
import os
import re
import shutil
import subprocess
from pathlib import Path

baseline = re.compile(r"^(?:lib(?:c|m|pthread|dl|rt|resolv|util|nsl|anl|stdc\+\+|gcc_s|z)\.so\.|ld-linux|libpython)")
venv = Path("/work/venv")
destination = venv / "lib"
destination.mkdir(exist_ok=True)
libraries = {}
for module in venv.rglob("*.so*"):
    if not module.is_file():
        continue
    with module.open("rb") as stream:
        if stream.read(4) != b"\x7fELF":
            continue
    result = subprocess.run(["ldd", str(module)], capture_output=True, text=True)
    if result.returncode or "=> not found" in result.stdout:
        raise RuntimeError(f"Unresolved ELF dependencies: {module}\n{result.stdout}\n{result.stderr}")
    for name, path in re.findall(r"^\s*(\S+)\s+=>\s+(/\S+)\s+\(", result.stdout, re.M):
        if baseline.match(name):
            continue
        source = Path(path).resolve()
        if str(source).startswith("/work/venv/"):
            continue
        libraries.setdefault(name, source)
for name, source in sorted(libraries.items()):
    shutil.copy2(source, destination / name)
    print(f"Bundled {name} from {source}")
for forbidden in ("libz.so.1", "libc.so.6"):
    assert not (destination / forbidden).exists(), forbidden
env = dict(os.environ, LD_LIBRARY_PATH=str(destination))
subprocess.run(
    [str(venv / "bin/python"), "-c", "import fastapi, pydantic, sqlalchemy"],
    cwd="/work/source/src",
    env=env,
    check=True,
)
