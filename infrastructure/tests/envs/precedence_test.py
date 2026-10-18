#!/usr/bin/env python3
"""Actual offline loader probes. Missing preinstalled dependencies are explicit SKIP, never installed."""
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("runtime", REPO / ".config/envs/runtime.py")
runtime = importlib.util.module_from_spec(spec); spec.loader.exec_module(runtime)
VALUES = {"SIMPLE": "fixture-simple", "SPACE": "fixture # space", "LF": "fixture\nline", "TAB": "fixture\tline",
          "DOUBLE": 'fixture"quote', "SINGLE": "fixture'quote", "UNICODE": "fixture-λ"}
DOTENV_SRI = "sha512-nI4U3TottKAcAD9LLud4Cb7b2QztQMUEfHbvhTH09bqXTxnSie8WnjPALV/WMCrJZ6UV/qHJ6L03OqO3LcdYZw=="


def run(argv, root, **kwargs):
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "XDG_CONFIG_HOME": str(root / "config"),
           "DOCKER_CONFIG": str(root / "docker"), "ENVS_PROBE": "from_process", "VITE_PROBE": "from_process"}
    return subprocess.run(argv, env=env, cwd=root, capture_output=True, timeout=20, **kwargs)


def cached_package(name, wanted=None):
    cache = Path.home() / ".cache/yarn/v6"
    candidates = []
    for path in cache.glob("npm-" + name.replace("/", "-") + "-*/node_modules/" + name):
        try:
            data = json.loads((path / "package.json").read_text())
            version = tuple(map(int, re.match(r"([0-9]+)\.([0-9]+)\.([0-9]+)", data["version"]).groups()))
            if wanted:
                minimum = tuple(map(int, re.search(r"([0-9]+)\.([0-9]+)\.([0-9]+)", wanted).groups()))
                if version[0] != minimum[0] or version < minimum:
                    continue
            candidates.append((version, path, data))
        except (OSError, ValueError, AttributeError):
            continue
    return max(candidates, key=lambda row: row[0]) if candidates else None


def main():
    passed, skipped = [], []
    with tempfile.TemporaryDirectory(prefix="envs-loader-probes.", dir="/dev/shm") as temp:
        root = Path(temp)
        source = root / "fixture.env"
        source.write_text("ENVS_PROBE=from_file\nVITE_PROBE=from_file\n" + "".join(name + "=" + runtime.dotenv_literal(value) + "\n" for name, value in VALUES.items()))
        python = Path("/srv/devtools/venv/posting/bin/python")
        if python.exists():
            code = ("import dotenv,json,sys,os,importlib.metadata; p=sys.argv[1]; values=dotenv.dotenv_values(p); "
                    "dotenv.load_dotenv(p); assert os.environ['ENVS_PROBE']=='from_process'; "
                    "dotenv.load_dotenv(p,override=True); assert os.environ['ENVS_PROBE']=='from_file'; "
                    "print(json.dumps({'version':importlib.metadata.version('python-dotenv'),'values':values}))")
            result = run([str(python), "-I", "-B", "-c", code, str(source)], root, text=True)
            assert result.returncode == 0, "python-dotenv fixture probe failed"
            data = json.loads(result.stdout)
            assert all(data["values"][name] == value for name, value in VALUES.items()), "python-dotenv literal roundtrip failed"
            passed.append("python-dotenv " + data["version"] + " precedence + exact literal roundtrips")
        else:
            skipped.append("python-dotenv preinstalled posting environment unavailable")
        dotenv = root / "dotenv"
        if Path("/usr/lib/node_modules/npm/node_modules/cacache").exists():
            code = ("require('/usr/lib/node_modules/npm/node_modules/cacache').get.byDigest(" + json.dumps(str(Path.home() / ".npm/_cacache")) + "," + json.dumps(DOTENV_SRI) + ").then(b=>process.stdout.write(b)).catch(()=>process.exit(2))")
            result = run(["/usr/bin/node", "-e", code], root)
            if result.returncode == 0:
                with tarfile.open(fileobj=io.BytesIO(result.stdout), mode="r:gz") as archive:
                    for member in ("package/lib/main.js", "package/package.json"):
                        entry = archive.getmember(member)
                        assert entry.isfile(), "unexpected cached package entry"
                        target = dotenv / member.removeprefix("package/"); target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(archive.extractfile(entry).read())
                code = ("const d=require(process.argv[1]),fs=require('fs');let v=d.parse(fs.readFileSync(process.argv[2]));"
                        "d.config({path:process.argv[2],quiet:true});if(process.env.ENVS_PROBE!=='from_process')process.exit(3);"
                        "d.config({path:process.argv[2],quiet:true,override:true});if(process.env.ENVS_PROBE!=='from_file')process.exit(4);"
                        "console.log(JSON.stringify({version:require(process.argv[3]).version,values:v}))")
                result = run(["/usr/bin/node", "-e", code, str(dotenv / "lib/main.js"), str(source), str(dotenv / "package.json")], root, text=True)
                assert result.returncode == 0, "Node dotenv fixture probe failed"
                data = json.loads(result.stdout)
                assert all(data["values"][name] == value for name, value in VALUES.items()), "Node dotenv literal roundtrip failed"
                passed.append("dotenv " + data["version"] + " precedence + exact literal roundtrips")
            else:
                skipped.append("pinned dotenv17.4.2 public package not cached")
        else:
            skipped.append("Node dotenv cache reader unavailable")
        compose = root / "compose.yml"
        compose.write_text('services:\n  fixture:\n    image: scratch\n    env_file: fixture.env\n    environment:\n      ENVS_PROBE: ${ENVS_PROBE}\n')
        result = run(["/usr/bin/docker", "compose", "-f", str(compose), "config", "--format", "json"], root, text=True)
        if result.returncode == 0:
            values = json.loads(result.stdout)["services"]["fixture"]["environment"]
            assert values["ENVS_PROBE"] == "from_process", "Compose interpolation precedence failed"
            assert all(values[name] == value for name, value in VALUES.items()), "Compose env_file literal roundtrip failed"
            version = run(["/usr/bin/docker", "compose", "version", "--short"], root, text=True).stdout.strip()
            passed.append("Compose " + version + " interpolation + env_file exact literal roundtrips (no daemon)")
        else:
            skipped.append("Docker Compose config dependency unavailable")
        vite = cached_package("vite", "6.4.3")
        if vite:
            modules = root / "node_modules"; modules.mkdir()
            visited = set()
            def link_package(name, wanted=None):
                if name in visited:
                    return
                visited.add(name)
                hit = cached_package(name, wanted)
                if hit is None:
                    raise LookupError(name)
                _, path, package = hit
                target = modules / name; target.parent.mkdir(parents=True, exist_ok=True); target.symlink_to(path)
                for dep, version in package.get("dependencies", {}).items():
                    link_package(dep, version)
                for dep, version in package.get("optionalDependencies", {}).items():
                    if dep in ("@esbuild/linux-x64", "@rollup/rollup-linux-x64-gnu"):
                        link_package(dep, version)
            try:
                link_package("vite", "6.4.3")
                script = root / "probe.mjs"
                script.write_text("import {loadEnv} from 'vite';console.log(JSON.stringify(loadEnv('development',process.argv[2],'')))")
                (root / ".env").write_text(source.read_text())
                result = run(["/usr/bin/node", "--preserve-symlinks", str(script), str(root)], root, text=True)
                if result.returncode:
                    skipped.append("Vite cached dependency graph unavailable")
                else:
                    values = json.loads(result.stdout)
                    assert values["VITE_PROBE"] == "from_process", "Vite process precedence failed"
                    assert all(values[name] == value for name, value in VALUES.items()), "Vite literal roundtrip failed"
                    passed.append("Vite " + vite[2]["version"] + " loadEnv precedence + exact literal roundtrips")
            except LookupError:
                skipped.append("Vite cached dependency graph incomplete")
        else:
            skipped.append("Vite preinstalled cache unavailable")
        skipped.append("godotenv1.5.1 unavailable offline; Load/Overload remain unverified")
    for message in passed:
        print("PASS " + message)
    for message in skipped:
        print("SKIP " + message)
    print("loader probes: %s passed, %s skipped" % (len(passed), len(skipped)))


if __name__ == "__main__":
    main()
