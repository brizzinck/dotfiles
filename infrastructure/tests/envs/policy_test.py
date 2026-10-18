#!/usr/bin/env python3
"""Agent approvals and masked commands through isolated fake vaults only."""
import importlib.util
import json
import os
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("refs_fixture", Path(__file__).with_name("references_test.py"))
fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)


class Policy(unittest.TestCase):
    setUp = fixture.References.setUp
    tearDown = fixture.References.tearDown
    save_vault = fixture.References.save_vault
    run_envs = fixture.References.run_envs
    log = fixture.References.log
    ref_file = fixture.References.ref_file
    assert_safe = fixture.References.assert_safe

    def policy(self, commands=None):
        self.ref_file()
        self.script = self.project / "task.py"
        self.script.write_text("import os,sys,base64\nv=os.environ['DATABASE_URL']\nprint(v)\nprint(base64.b64encode(v.encode()).decode(),file=sys.stderr)\n")
        self.cmd = ["/usr/bin/python3", str(self.script)]
        self.rules = commands or [self.cmd]
        self.config()
        result = self.run_envs("bind", "--yes")
        self.assertEqual(0, result.returncode, result.stderr)

    def config(self):
        text = 'project="my-project"\nenvironments=["dev","prod"]\ndefault="dev"\n[agents]\nallow=' + json.dumps([__import__('shlex').join(rule) for rule in self.rules]) + '\n'
        (self.project / ".envs.toml").write_text(text)

    def agent(self, *args):
        env = dict(self.env, CLAUDECODE="1")
        return self.run_envs(*args, env=env)

    def allow(self, cmd=None):
        result = self.run_envs("agent", "allow", "--", *(cmd or self.cmd))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assert_safe(result)

    def test_approved_masked_run_only_selected_and_one_audit(self):
        self.policy(); self.allow()
        mark = len(self.log())
        result = self.agent("run", "--no-mise", "--", *self.cmd)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("[secret DATABASE_URL]\n", result.stdout)
        self.assertEqual("[secret DATABASE_URL]\n", result.stderr)
        self.assert_safe(result)
        journal = (self.fake / "logger.log").read_text()
        self.assertEqual(1, journal.count('"event": "agent-run"'))
        self.assertIn('"decision": "allow"', journal)
        self.assertNotIn("invented-database-value", journal + self.log()[mark:])
        self.assertNotIn(str(self.script), journal)

    def test_denial_before_vault_and_audit(self):
        self.policy(); mark = len(self.log())
        result = self.agent("run", "--no-mise", "--", *self.cmd)
        self.assertEqual(4, result.returncode)
        self.assertIn("not approved", result.stderr)
        self.assertEqual("", self.log()[mark:])
        journal = (self.fake / "logger.log").read_text()
        self.assertEqual(1, journal.count('"event": "agent-run"'))
        self.assertIn('"decision": "deny"', journal)

    def test_policy_change_and_deny_revoke_before_values(self):
        self.policy(); self.allow()
        self.rules.append(["/usr/bin/make", "test"]); self.config()
        mark = len(self.log())
        result = self.agent("run", "--no-mise", "--", *self.cmd)
        self.assertEqual(4, result.returncode)
        self.assertIn("policy changed", result.stderr)
        self.assertEqual("", self.log()[mark:])
        self.allow()
        result = self.run_envs("agent", "deny", "--", *self.cmd)
        self.assertEqual(0, result.returncode, result.stderr)
        mark = len(self.log())
        self.assertEqual(4, self.agent("run", "--no-mise", "--", *self.cmd).returncode)
        self.assertEqual("", self.log()[mark:])

    def test_agents_cannot_approve_or_read_protected_even_flag(self):
        self.policy()
        for args in (("agent", "allow", "--", *self.cmd), ("agent", "list"),
                     ("run", "-e", "prod", "--prod", "--no-mise", "--", *self.cmd)):
            mark = len(self.log()); result = self.agent(*args)
            self.assertEqual(4, result.returncode, result.stderr)
            self.assertNotIn("rbw get", self.log()[mark:])

    def test_hard_refusal_including_symlinks_and_interpreter_options(self):
        link = self.project / "innocent"; link.symlink_to("/usr/bin/env")
        commands = [["/usr/bin/env"], [str(link)], ["/usr/bin/python3", "-c", "pass"],
                    ["/usr/bin/python3"], ["/usr/bin/bash", "-c", "true"], ["/usr/bin/timeout", "1", "true"]]
        self.policy(commands)
        for cmd in commands:
            result = self.run_envs("agent", "allow", "--", *cmd)
            self.assertEqual(4, result.returncode, result.stderr)
            self.assertIn("forbidden", result.stderr)

    def test_executable_resolution_change_refuses_before_values(self):
        self.ref_file()
        tool = self.project / "approved-tool"; tool.symlink_to("/usr/bin/true")
        self.policy([[str(tool)]])
        self.allow([str(tool)])
        tool.unlink(); tool.symlink_to("/usr/bin/false")
        mark = len(self.log())
        result = self.agent("run", "--no-mise", "--", str(tool))
        self.assertEqual(4, result.returncode)
        self.assertIn("executable changed", result.stderr)
        self.assertEqual("", self.log()[mark:])

    def test_envfile_requires_placeholder_and_private_file_is_cleaned(self):
        self.policy()
        self.script.write_text("import os,sys,pathlib\np=pathlib.Path(sys.argv[1]); text=p.read_text()\nassert 'invented-database-value' in text and 'APP_PORT=8080' in text\nassert p.stat().st_mode & 0o777 == 0o600\nprint(str(p))\n")
        result = self.run_envs("run", "--env-file", "--no-mise", "--", *self.cmd, "{envfile}")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(Path(result.stdout.strip()).exists())
        self.assert_safe(result)
        result = self.run_envs("run", "--env-file", "--no-mise", "--", *self.cmd)
        self.assertEqual(2, result.returncode)
    def test_allow_records_missing_metadata_policy_only_after_human_confirmation(self):
        self.ref_file()
        self.assertEqual(0, self.run_envs("bind", "--yes").returncode)
        command = ["/usr/bin/true"]
        result = self.run_envs("agent", "allow", "--", *command)
        self.assertEqual(0, result.returncode, result.stderr)
        text = (self.project / ".envs.toml").read_text()
        self.assertIn("[agents]", text)
        self.assertNotIn("[secrets]", text)
        self.assertEqual(0, self.agent("run", "--no-mise", "--", *command).returncode)

    def test_outermost_mise_output_is_masked(self):
        self.policy(); (self.project / ".mise.toml").write_text("[tools]\n")
        self.allow()
        self.env["FAKE_MISE_ECHO_SECRET"] = "1"
        result = self.agent("run", "--", *self.cmd)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(2, result.stdout.count("[secret DATABASE_URL]"))
        self.assert_safe(result)

    def test_no_tty_allow_denied_and_stale_policy_revocable(self):
        self.policy()
        env = dict(self.env); env.pop("ENVS_TEST_YES", None)
        result = self.run_envs("agent", "allow", "--", *self.cmd, env=env)
        self.assertEqual(4, result.returncode)
        self.assertIn("human terminal", result.stderr)
        self.allow()
        self.ref_file("DATABASE_URL=bw://Env/my-project/dev#@notes\n")
        result = self.run_envs("agent", "deny", "--", *self.cmd)
        self.assertEqual(0, result.returncode, result.stderr)
        record = json.loads((self.root / "state/envs/agent-approvals.json").read_text())
        self.assertTrue(all(not row.get("entries") for row in record.values()))

    def test_changed_protected_ref_and_new_secret_fail_before_get(self):
        self.policy(); self.allow()
        self.vault["items"].append(dict(self.vault["items"][0], id="prod-item", name="prod")); self.save_vault()
        self.ref_file("DATABASE_URL=bw://Env/my-project/prod#DATABASE_URL\n")
        self.assertEqual(0, self.run_envs("bind", "--yes").returncode)
        mark = len(self.log())
        result = self.agent("run", "--prod", "--no-mise", "--", *self.cmd)
        self.assertEqual(4, result.returncode)
        self.assertIn("protected reference", result.stderr)
        self.assertEqual("", self.log()[mark:])

    def test_agent_reference_edit_cannot_erase_durable_protection(self):
        self.policy()
        self.assertEqual(0, self.run_envs("bind", "--yes", "--protect-ref", "DATABASE_URL").returncode)
        result = self.agent("refs", "set", "DATABASE_URL", "bw://Env/my-project/dev#@notes")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(0, self.run_envs("bind", "--yes").returncode)
        rows = json.loads((self.root / "state/envs/ref-policies.json").read_text())
        self.assertTrue(any("DATABASE_URL" in row.get("protected", []) for row in rows.values()))
        mark = len(self.log())
        result = self.run_envs("agent", "allow", "--", *self.cmd)
        self.assertEqual(4, result.returncode)
        self.assertIn("protected reference", result.stderr)
        self.assertEqual("", self.log()[mark:])

    def test_invalid_agent_run_options_still_emit_one_denial_audit(self):
        self.policy()
        journal = self.fake / "logger.log"
        for args in (("run", "--unknown", "--", "/usr/bin/true"), ("run", "--env-file", "--", "/usr/bin/true"),
                     ("run", "--env-source", ".env", "--", "/usr/bin/true"), ("run", "--no-mise")):
            before = journal.read_text().count('"event": "agent-run"') if journal.exists() else 0
            mark = len(self.log()); result = self.agent(*args)
            self.assertEqual(2, result.returncode, result.stderr)
            self.assertEqual(before + 1, journal.read_text().count('"event": "agent-run"'))
            self.assertEqual("", self.log()[mark:])



if __name__ == "__main__":
    unittest.main()
