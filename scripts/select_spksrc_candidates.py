#!/usr/bin/env python3
"""Select locked requirements that have no DSM-compatible binary wheel."""
import argparse, io, json, re, tarfile, time, urllib.request, zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from packaging.markers import default_environment
from packaging.requirements import Requirement
from packaging.tags import compatible_tags, cpython_tags
from packaging.utils import parse_wheel_filename

def fetch(url, timeout=60, attempts=4):
    request = urllib.request.Request(url, headers={"User-Agent": "autobangumi-spk-dependency-check/1"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response: return response.read()
        except Exception:
            if attempt + 1 == attempts: raise
            time.sleep(2 ** attempt)

def requirements(path):
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", "-")): continue
        try: req = Requirement(line)
        except Exception: continue
        if req.url or len(req.specifier) != 1: continue
        spec = next(iter(req.specifier))
        if spec.operator == "==" and not spec.version.endswith(".*"): yield req, spec.version

def main():
    p = argparse.ArgumentParser(); p.add_argument("requirements", type=Path); p.add_argument("arch"); p.add_argument("dsm"); p.add_argument("candidates", type=Path); p.add_argument("report", type=Path); a = p.parse_args()
    machine = "x86_64" if a.arch == "x86_64" else "aarch64"; top = 17 if a.dsm == "7.1" else 28
    platforms = [f"manylinux_2_{n}_{machine}" for n in range(top, 4, -1)] + [f"manylinux2014_{machine}", f"manylinux2010_{machine}", f"manylinux1_{machine}", f"linux_{machine}"]
    tags = set(cpython_tags((3, 14), platforms=platforms)) | set(compatible_tags((3, 14), interpreter="cp314", platforms=platforms))
    env = default_environment(); env.update(python_version="3.14", python_full_version="3.14.0", sys_platform="linux", platform_system="Linux", platform_machine=machine, implementation_name="cpython", platform_python_implementation="CPython")
    active=[(req,version) for req,version in requirements(a.requirements) if not req.marker or req.marker.evaluate(env)]
    def has_native(files):
        source=next((x for x in files if x.get("packagetype")=="sdist"),None)
        if not source: return True
        data=fetch(source["url"])
        try:
            with tarfile.open(fileobj=io.BytesIO(data),mode="r:*") as archive: names=archive.getnames()
        except tarfile.TarError:
            try:
                with zipfile.ZipFile(io.BytesIO(data)) as archive: names=archive.namelist()
            except zipfile.BadZipFile: return True
        suffixes=(".c",".cc",".cpp",".cxx",".pyx",".rs",".s",".S")
        return any(name.endswith(suffixes) or name.endswith("Cargo.toml") for name in names)
    def inspect(item):
        req,version=item
        name = re.sub(r"[-_.]+", "-", req.name).lower()
        try:
            files=json.loads(fetch(f"https://pypi.org/pypi/{name}/{version}/json", timeout=30)).get("urls", [])
        except Exception as error:
            return {"requirement":str(req),"status":"metadata_error","detail":str(error)}
        wheels=[]
        for item in files:
            filename=item.get("filename", "")
            if not filename.endswith(".whl"): continue
            try: wheel_tags=parse_wheel_filename(filename)[3]
            except Exception: continue
            if wheel_tags & tags: wheels.append(filename)
        if wheels: return {"requirement":str(req),"status":"downloadable","wheels":wheels}
        if not has_native(files): return {"requirement":str(req),"status":"source_installable"}
        return {"requirement":str(req),"candidate":f"{req.name}=={version}","status":"spksrc_candidate"}
    with ThreadPoolExecutor(max_workers=16) as pool: report=list(pool.map(inspect,active))
    candidates=[item["candidate"] for item in report if "candidate" in item]
    a.candidates.write_text("\n".join(candidates) + ("\n" if candidates else ""), encoding="utf-8"); a.report.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    errors=[item for item in report if item["status"]=="metadata_error"]
    if errors: raise SystemExit("PyPI metadata lookup failed after retries: " + ", ".join(item["requirement"] for item in errors))
    print(f"downloadable={sum(x['status']=='downloadable' for x in report)} candidates={len(candidates)}")
    for item in candidates: print("SPKSRC", item)
if __name__ == "__main__": main()
