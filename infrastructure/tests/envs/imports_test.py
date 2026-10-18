#!/usr/bin/env python3
"""Import transactions and names inventories use disposable invented files and fake vaults."""
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("refs_fixture", Path(__file__).with_name("references_test.py"))
fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)


class Imports(unittest.TestCase):
    def setUp(self):
        fixture.References.setUp(self)
        runtime = self.root / "run/vault"; runtime.mkdir(mode=0o700)
        session = runtime / "bw-session"; session.write_text("SESSION-KEY-abc"); session.chmod(0o600)
        (self.fake / "bw-unlocked").touch()
        self.env["VAULT_BW_SERVE"] = "0"
    tearDown = fixture.References.tearDown
    save_vault = fixture.References.save_vault
    run_envs = fixture.References.run_envs
    log = fixture.References.log
    ref_file = fixture.References.ref_file
    assert_safe = fixture.References.assert_safe

    def bind(self):
        result = self.run_envs("bind", "--yes")
        self.assertEqual(0, result.returncode, result.stderr)

    def test_project_retains_plain_bytes_redacts_every_duplicate_and_no_toml(self):
        source = self.project / ".env"
        source.write_bytes(b'# keep\r\nNEW_TOKEN=first-fixture-secret\r\nAPP_PORT = 8080 # exact\r\nNEW_TOKEN="second-fixture-secret"')
        self.bind()
        result = self.run_envs("import", "--secrets", "NEW_TOKEN", "--plain", "APP_PORT")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(b'# keep\r\nNEW_TOKEN=bw://Env/demo/dev#NEW_TOKEN\r\nAPP_PORT = 8080 # exact', source.read_bytes())
        self.assertFalse((self.project / ".envs.toml").exists())
        self.assertFalse((self.project / ".mise.toml").exists())
        vault = json.loads((self.fake / "vault.json").read_text())
        self.assertTrue(any(field.get("name") == "NEW_TOKEN" and field.get("value") == "second-fixture-secret"
                            for item in vault["items"] for field in item.get("fields", [])))
        backups = list((self.root / "state/usr/secrets-backups").glob("envs-import-*/source.env"))
        self.assertEqual(1, len(backups)); self.assertEqual(0o600, backups[0].stat().st_mode & 0o777)
        self.assertIn(b"first-fixture-secret", backups[0].read_bytes())
        self.assertNotIn("second-fixture-secret", result.stdout + result.stderr + self.log())

    def test_keep_is_explicit_plaintext_compatibility_and_plain_mise_opt_in(self):
        source = self.project / ".env"; raw = "NEW_TOKEN=fixture-new-token\nAPP_PORT=8080\n"; source.write_text(raw)
        self.bind()
        result = self.run_envs("import", "--secrets", "NEW_TOKEN", "--plain", "APP_PORT", "--keep", "--plain-to-mise")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(raw, source.read_text())
        self.assertIn("plaintext", result.stderr)
        self.assertIn('APP_PORT = "8080"', (self.project / ".mise.toml").read_text())

    def test_preflight_errors_leave_source_and_vault_unchanged(self):
        for raw, options in (("NEW_TOKEN=short\n", ["--secrets", "NEW_TOKEN"]),
                             ("NEW_TOKEN=fixture-token\nAPP_MODE=dev\n", ["--secrets", "NEW_TOKEN"]),
                             ("NEW_TOKEN=$(danger)\n", ["--secrets", "NEW_TOKEN"]),
                             ("PATH=fixture-value\n", ["--plain", "PATH"])):
            with self.subTest(raw=raw):
                self.ref_file("APP_MODE=development\n"); self.bind(); self.ref_file(raw); before = (self.fake / "vault.json").read_bytes(); mark = len(self.log())
                result = self.run_envs("import", *options)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual(raw, (self.project / ".env").read_text())
                self.assertEqual(before, (self.fake / "vault.json").read_bytes())
                self.assertNotIn("bw edit", self.log()[mark:])

    def test_global_shell_import_exports_only_plain_and_refs_never_sourced(self):
        (self.root / "global/global.toml").write_text('project="global"\n[secrets]\n')
        directory = self.root / "secrets"; directory.mkdir(mode=0o700)
        source = directory / "env.sh"; source.write_text("export NEW_TOKEN='fixture-global-token'\nexport APP_MODE='development'\n"); source.chmod(0o600)
        result = self.run_envs("import", "-g", str(source), "--secrets", "NEW_TOKEN", "--plain", "APP_MODE", "--yes")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('export APP_MODE="development"\n', source.read_text())
        refs = self.root / "global/global.env"
        self.assertEqual("NEW_TOKEN=bw://Env/global/default#NEW_TOKEN\n", refs.read_text())
        self.assertEqual(0o600, refs.stat().st_mode & 0o777)
        self.assertFalse((self.root / "global/global.local.toml").exists())
        self.assertNotIn("fixture-global-token", result.stdout + result.stderr + self.log())

    def test_global_shell_commands_refuse_whole_file_and_agent_before_open(self):
        (self.root / "global/global.toml").write_text('project="global"\n[secrets]\n')
        source = self.root / "export.sh"; raw = "export NEW_TOKEN=fixture-token\nAPP_MODE=one echo danger\n"; source.write_text(raw); source.chmod(0o600)
        result = self.run_envs("import", "-g", str(source), "--secrets", "NEW_TOKEN", "--plain", "APP_MODE", "--yes")
        self.assertEqual(4, result.returncode)
        self.assertIn("line 2", result.stderr)
        self.assertEqual("", self.log())
        self.assertEqual(raw, source.read_text())
        env = dict(self.env, CLAUDECODE="1")
        result = self.run_envs("import", "-g", "/nonexistent/source", env=env)
        self.assertEqual(4, result.returncode)
        self.assertIn("refused inside an agent", result.stderr)
        self.assertNotIn("cannot safely read", result.stderr)

    def fault_import(self, mode, *args):
        code = """import sys, pathlib
source, target, mode = sys.argv[1:4]
ns={'__name__':'import_fault_fixture','__file__':source}
exec(compile(open(source).read(),source,'exec'),ns)
ns['HOME']=pathlib.Path(__import__('os').environ['HOME'])
original=ns['bw_save']
def save(manager,item):
    if mode=='write': ns['fail']('fixture-private-backend-error',1)
    original(manager,item)
    if mode=='readback':
        call=manager.bw_json
        manager.bw_json=lambda *a,**k: {'id':item['id'],'fields':[]} if a[:2]==('get','item') else call(*a,**k)
    if mode=='concurrent': pathlib.Path(target).write_text('APP_PORT=9091\\nNEW_TOKEN=fixture-owner-concurrent-edit\\n')
ns['bw_save']=save
if mode in ('local','parent','existing'):
    ns['extras']('state_path','fault-placeholder')
    integration=ns['_EXTRA']; imports=integration.module('imports'); original_publish=imports.publish
    def publish(path,*a,**k):
        if pathlib.Path(path).name=='global.env' and mode=='local': raise OSError('fixture-private-backend-error')
        return original_publish(path,*a,**k)
    imports.publish=publish
    if mode=='parent':
        link=imports.os.link
        def swapped(src,dst,**kw):
            if dst=='global.env':
                base=pathlib.Path(ns['global_dir']()); base.rename(base.with_name('global-displaced')); base.mkdir(mode=0o700)
            return link(src,dst,**kw)
        imports.os.link=swapped
    if mode=='existing':
        replace=integration.D.Snapshot.replace
        def overwritten(self,text,**kw):
            result=replace(self,text,**kw)
            if self.path.name=='global.env': self.path.write_text('OWNER=bw://Env/global/default#OWNER\\n')
            return result
        integration.D.Snapshot.replace=overwritten
sys.exit(ns['main'](sys.argv[4:]))
"""
        return subprocess.run([sys.executable, "-I", "-B", "-c", code, str(fixture.SOURCE), str(self.project / ".env"), mode, *args],
                              cwd=self.project, env=self.env, capture_output=True, text=True, timeout=15)

    def test_remote_failure_and_readback_failure_retain_source_then_retry(self):
        self.ref_file("NEW_TOKEN=fixture-new-token\n"); self.bind()
        source = self.project / ".env"; before = source.read_bytes()
        for mode in ("write", "readback"):
            result = self.fault_import(mode, "import", "--secrets", "NEW_TOKEN")
            self.assertEqual(1, result.returncode, result.stderr)
            self.assertEqual(before, source.read_bytes())
            self.assertNotIn("fixture-private-backend-error", result.stdout + result.stderr)
            self.assertNotIn("fixture-new-token", result.stdout + result.stderr)
        result = self.run_envs("import", "--secrets", "NEW_TOKEN")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("bw://", source.read_text())

    def test_local_global_publication_failure_retains_source_after_vault_success(self):
        (self.root / "global/global.toml").write_text('project="global"\n[secrets]\n')
        source = self.root / "export.sh"; source.write_text("export NEW_TOKEN='fixture-global-token'\n"); source.chmod(0o600)
        before = source.read_bytes()
        result = self.fault_import("local", "import", "-g", str(source), "--secrets", "NEW_TOKEN", "--yes")
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertEqual(before, source.read_bytes())
        self.assertNotIn("fixture-private-backend-error", result.stdout + result.stderr)
        self.assertFalse((self.root / "global/global.env").exists())
        result = self.run_envs("import", "-g", str(source), "--secrets", "NEW_TOKEN", "--yes")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn("fixture-global-token", source.read_text())
        self.assertIn("bw://", (self.root / "global/global.env").read_text())

    def test_existing_global_destination_changed_after_replace_retains_source(self):
        (self.root / "global/global.toml").write_text('project="global"\n[secrets]\n')
        target = self.root / "global/global.env"; target.write_text("OWNER=bw://Env/global/default#OWNER\n"); target.chmod(0o600)
        source = self.root / "export.sh"; source.write_text("export NEW_TOKEN='fixture-global-token'\n"); source.chmod(0o600)
        before = source.read_bytes()
        result = self.fault_import("existing", "import", "-g", str(source), "--secrets", "NEW_TOKEN", "--yes")
        self.assertEqual(4, result.returncode, result.stderr)
        self.assertEqual(before, source.read_bytes())
        self.assertNotIn("import complete", result.stdout)
        self.assertNotIn("NEW_TOKEN", target.read_text())

    def test_absent_global_destination_parent_swap_never_retires_source(self):
        (self.root / "global/global.toml").write_text('project="global"\n[secrets]\n')
        source = self.root / "export.sh"; source.write_text("export NEW_TOKEN='fixture-global-token'\n"); source.chmod(0o600)
        before = source.read_bytes()
        result = self.fault_import("parent", "import", "-g", str(source), "--secrets", "NEW_TOKEN", "--yes")
        self.assertEqual(4, result.returncode, result.stderr)
        self.assertEqual(before, source.read_bytes())
        self.assertNotIn("import complete", result.stdout)
        self.assertFalse((self.root / "global/global.env").exists())
        self.assertTrue((self.root / "global-displaced/global.env").exists())
        self.assertNotIn("fixture-global-token", result.stdout + result.stderr)

    def test_concurrent_source_edit_after_remote_write_is_preserved(self):
        self.ref_file("NEW_TOKEN=fixture-new-token\nAPP_PORT=8080\n"); self.bind()
        result = self.fault_import("concurrent", "import", "--secrets", "NEW_TOKEN", "--plain", "APP_PORT")
        self.assertEqual(4, result.returncode, result.stderr)
        self.assertIn("source changed", result.stderr)
        self.assertEqual("APP_PORT=9091\nNEW_TOKEN=fixture-owner-concurrent-edit\n", (self.project / ".env").read_text())
        self.assertNotIn("fixture-owner-concurrent-edit", result.stdout + result.stderr)

    def test_scoped_global_retains_source_and_owner_map_until_target_user_setup(self):
        (self.root / "global/global.toml").write_text('project="global"\n[secrets]\n')
        owner_map = self.root / "global/global.env"; owner_map.write_text("OWNER=bw://Env/global/default#OWNER\n"); owner_map.chmod(0o600)
        source = self.root / "export.sh"; source.write_text("export NEW_TOKEN='fixture-global-token'\n"); source.chmod(0o600)
        before, owner_before = source.read_bytes(), owner_map.read_bytes()
        result = self.run_envs("import", "-g", str(source), "--for", "td", "--secrets", "NEW_TOKEN", "--yes")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("target-user global mapping still needs setup", result.stdout)
        self.assertEqual(before, source.read_bytes()); self.assertEqual(owner_before, owner_map.read_bytes())
        handoff = json.loads((self.root / "state/envs/scoped-global-import.json").read_text())
        self.assertEqual("bw://Users/td/Env/global/default#NEW_TOKEN", handoff["refs"]["NEW_TOKEN"])
        self.assertNotIn("fixture-global-token", json.dumps(handoff) + result.stdout + result.stderr)

    def test_scan_names_only_prunes_templates_links_and_reports_errors(self):
        self.ref_file("API_TOKEN=fixture-visible-only-in-memory\nAPP_PORT=8080\nURL=https://user:fixture-password@example.test/path\n")
        (self.project / ".env.example").write_text("SAMPLE=fixture-example\n")
        blocked = self.project / "node_modules"; blocked.mkdir(); (blocked / ".env").write_text("HIDDEN=fixture-hidden\n")
        (self.project / ".env.link").symlink_to(self.project / ".env")
        (self.project / ".env.bad").write_text("BAD=$(danger)\n")
        result = self.run_envs("scan", "--json")
        self.assertEqual(1, result.returncode, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual({"API_TOKEN", "APP_PORT", "URL", "SAMPLE"}, {row["name"] for row in data["records"]})
        self.assertEqual("URL-with-password", next(row["reason"] for row in data["records"] if row["name"] == "URL"))
        self.assertTrue(next(row["template"] for row in data["records"] if row["name"] == "SAMPLE"))
        self.assertEqual(1, len(data["errors"]))
        self.assertNotIn("fixture-", result.stdout + result.stderr)
        self.assertNotIn("example.test", result.stdout)
        self.assertEqual("", self.log())
        env = dict(self.env, CLAUDECODE="1")
        self.assertEqual(4, self.run_envs("scan", env=env).returncode)
    def test_scan_explicit_excluded_root_refused(self):
        for relative in (".git", "node_modules", ".config/rbw"):
            target = self.project / relative; target.mkdir(parents=True, exist_ok=True)
            (target / ".env").write_text("TOKEN=fixture-never-read\n")
            result = self.run_envs("scan", str(target), "--json")
            self.assertEqual(4, result.returncode)
            self.assertIn("credential location", result.stderr)
            self.assertNotIn("TOKEN", result.stdout + result.stderr)
        self.assertEqual("", self.log())



if __name__ == "__main__":
    unittest.main()
