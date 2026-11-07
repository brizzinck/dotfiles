"""Offline integration tests: real listener/socket2 and shim, fake every desktop/daemon CLI."""
import ctypes
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[3]
PLACER = REPO / ".local/bin/skw-ws8"
SHIM = REPO / ".local/lib/skw-shim/skw"
FAKE = '''#!/usr/bin/env -S python3 -I -B
import json, os, sys
from pathlib import Path
assert 'WAYLAND_DISPLAY' not in os.environ and 'DISPLAY' not in os.environ
name = Path(sys.argv[0]).name
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps([name,sys.argv[1:],os.environ.get('HYPRLAND_INSTANCE_SIGNATURE')])+'\\n')
if name == 'skw' and os.environ.get('PASSTHROUGH'):
    print(json.dumps(sys.argv[1:]))
    print('stderr intact',file=sys.stderr)
    print(sys.stdin.read(),end='')
    sys.exit(int(os.environ.get('EXIT_CODE','0')))
data = json.loads(Path(os.environ['FAKE_STATE']).read_text())
if name == 'hyprctl':
    if sys.argv[1:] == ['clients','-j']: print(json.dumps(data['clients']))
    elif sys.argv[1:] == ['activeworkspace','-j']: print(json.dumps(data['workspace']))
    else: sys.exit(91)
elif name == 'skw':
    if sys.argv[1:] == ['ps','--json']: print(json.dumps(data['ps']))
    elif sys.argv[1] == 'automation' and sys.argv[-2:] == ['--list','--json']:
        if data.get('automation_error'): sys.exit(1)
        print(json.dumps(data['automation']))
    else: sys.exit(92)
elif name == 'hyprd':
    if sys.argv[1] != 'movetoworkspacesilent': sys.exit(93)
else: sys.exit(94)
'''


def wait_for(predicate, timeout=5):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("timed out waiting for fake IPC")


def detached(command, env, stdin="", comm=None):
    """Human tests must have no Codex ancestor; reparent to init, without a production test bypass."""
    result = Path(env["HOME"]) / "result.json"
    result.unlink(missing_ok=True)
    child = os.fork()
    if child == 0:
        os.setsid()
        parent = os.getpid()
        if os.fork():
            os._exit(0)
        while os.getppid() == parent:
            time.sleep(0.001)
        try:
            if comm:
                ctypes.CDLL(None).prctl(15, comm.encode(), 0, 0, 0)
            p = subprocess.run(command, env=env, input=stdin, text=True, capture_output=True, timeout=10)
            data = {"code": p.returncode, "stdout": p.stdout, "stderr": p.stderr}
        except Exception as error:
            data = {"error": type(error).__name__}
        tmp = result.with_suffix('.tmp')
        tmp.write_text(json.dumps(data))
        tmp.replace(result)
        os._exit(0)
    os.waitpid(child, 0)
    wait_for(result.exists, 12)
    return json.loads(result.read_text())


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="skw-ws8-test-")
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("hyprctl", "hyprd", "skw", "fzf-menu", "ghostty", "notify-send", "wl-copy"):
            p = self.bin / name
            p.write_text(FAKE)
            p.chmod(0o755)
        self.home = self.root / "home"
        self.home.mkdir()
        shim = self.home / ".local/lib/skw-shim/skw"
        shim.parent.mkdir(parents=True)
        shutil.copy2(SHIM, shim)
        self.shim = shim
        self.run = self.root / "run"
        self.run.mkdir()
        self.log = self.root / "calls"
        self.log.touch()
        self.state = {"clients": [], "ps": {"items": []}, "automation": {"items": []},
                      "workspace": {"id": 3, "name": "3"}}
        self.env = {k: v for k, v in os.environ.items() if k not in
                    ("WAYLAND_DISPLAY", "DISPLAY", "CLAUDECODE", "AI_AGENT", "ZDOTDIR", "SKW_WS8_WORKSPACE")}
        self.env.update(HOME=str(self.home), XDG_RUNTIME_DIR=str(self.run), XDG_CONFIG_HOME=str(self.home / ".config"),
                        XDG_STATE_HOME=str(self.home / ".local/state"), PATH=f"{self.bin}:/usr/bin",
                        HYPRLAND_INSTANCE_SIGNATURE="test", FAKE_LOG=str(self.log), FAKE_STATE=str(self.root / "state"))
        self.process = None
        self.server = None
        self.conn = None
        self.out = None
        self.save()

    def tearDown(self):
        if self.process:
            self.process.terminate()
            self.process.wait(timeout=5)
        if self.conn:
            self.conn.close()
        if self.server:
            self.server.close()
        if self.out:
            self.out.close()
        self.tmp.cleanup()

    def save(self):
        p = self.root / "state.tmp"
        p.write_text(json.dumps(self.state))
        p.replace(self.root / "state")

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def moves(self):
        return [entry[1] for entry in self.calls() if entry[0] == "hyprd"]

    def marker(self, stamp, verb="start", ref="alpha"):
        p = self.run / f"skw-ws8/agent-{ref}"
        p.parent.mkdir(mode=0o700, exist_ok=True)
        p.write_text(f"{stamp} codex {verb}\n")
        p.chmod(0o600)
        return p

    def start(self, existing=False, unavailable=False):
        path = self.run / "hypr/test/.socket2.sock"
        path.parent.mkdir(parents=True, exist_ok=True)
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(path))
        self.server.listen()
        self.server.settimeout(5)
        if existing:
            self.window("0xa", emit=False)
        if unavailable:
            self.state["ps"] = {"items": []}
            self.save()
        self.out = (self.root / "output").open("a")
        self.process = subprocess.Popen([str(PLACER)], env=self.env, stdout=self.out, stderr=self.out)
        self.conn, _ = self.server.accept()
        try:
            wait_for(lambda: self.status().get("connected"))
        except AssertionError:
            raise AssertionError((self.root / "output").read_text() + " calls=" + self.log.read_text())

    def status(self):
        try:
            return json.loads((self.run / "skw-ws8/status.json").read_text())
        except (FileNotFoundError, ValueError):
            return {}

    def window(self, address="0xa", automation=False, emit=True, pid=123, started=None, cls="camoufox", kind="openwindow"):
        started = started or "2026-01-01T00:00:00.000001Z"
        self.state["clients"].append({"address": address, "class": cls, "pid": pid,
                                      "workspace": {"id": int(self.env.get("SKW_WS8_WORKSPACE", "8"))}})
        self.state["ps"] = {"items": [{"name": "alpha", "id": 42, "uuid": "test-uuid",
                                      "session": {"pid": pid, "started_at": started}}]}
        self.state["automation"] = {"items": [{"name": "worker"}] if automation else []}
        self.save()
        if emit:
            count = len(self.decisions())
            self.conn.sendall(f"{kind}>>{address.removeprefix('0x')},8,{cls},private title,URL\n".encode())
            if cls == "camoufox":
                wait_for(lambda: len(self.decisions()) > count)

    def decisions(self):
        path = self.root / "output"
        return [line for line in path.read_text().splitlines() if "decision=" in line] if path.exists() else []


class ListenerTests(Fixture):
    def test_numeric_profile_marker(self):
        self.marker(time.time(), ref="42")
        self.start()
        self.window()
        self.assertEqual(self.moves(), [])
        self.assertIn("keep-agent", self.decisions()[0])

    def test_uuid_profile_marker(self):
        self.marker(time.time(), ref="test-uuid")
        self.start()
        self.window()
        self.assertEqual(self.moves(), [])

    def test_old_session_does_not_consume_restart_marker(self):
        self.marker(time.time(), verb="restart")
        self.start(existing=True)
        self.window("0xb", pid=124, started=dt.datetime.now(dt.timezone.utc).isoformat())
        self.assertEqual(self.moves(), [])
        self.assertIn("keep-agent", self.decisions()[0])

    def test_agent_marker_keeps_window(self):
        self.marker(time.time())
        self.start()
        self.window()
        self.assertEqual(self.moves(), [])
        self.assertIn("keep-agent", self.decisions()[0])

    def test_pending_prestart_agent_marker(self):
        self.marker(time.time() - 5)
        self.start()
        self.window(started=dt.datetime.now(dt.timezone.utc).isoformat())
        self.assertEqual(self.moves(), [])
        self.assertIn("keep-agent", self.decisions()[0])

    def test_human_first_window_returns_even_with_automation(self):
        self.start()
        self.window(automation=True)
        self.assertEqual(self.moves(), [["movetoworkspacesilent", "3,address:0xa"]])

    def test_second_automation_window_stays(self):
        self.start()
        self.window()
        self.window("0xb", automation=True)
        self.assertEqual(len(self.moves()), 1)
        self.assertIn("keep-automation", self.decisions()[-1])

    def test_second_human_window_returns(self):
        self.start()
        self.window()
        self.window("0xb")
        self.assertEqual(len(self.moves()), 2)

    def test_non_camoufox_is_ignored(self):
        self.start()
        self.window(cls="other")
        time.sleep(0.1)
        self.assertEqual(self.moves(), [])
        self.assertEqual(self.decisions(), [])

    def test_duplicate_and_v2(self):
        self.start()
        self.window(kind="openwindowv2")
        self.conn.sendall(b"openwindow>>a,8,camoufox,title\n")
        time.sleep(0.1)
        self.assertEqual(len(self.moves()), 1)

    def test_seed_existing_window_does_not_move(self):
        self.start(existing=True)
        self.assertEqual(self.moves(), [])
        self.window("0xb", automation=True)
        self.assertEqual(self.moves(), [])

    def test_unresolved_startup_snapshot_survives_restart(self):
        self.start(existing=True, unavailable=True)
        self.state["clients"] = []
        self.save()
        self.process.terminate()
        self.process.wait(timeout=5)
        self.conn.close()
        self.process = subprocess.Popen([str(PLACER)], env=self.env, stdout=self.out, stderr=self.out)
        self.conn, _ = self.server.accept()
        wait_for(lambda: self.status().get("pid") == self.process.pid and self.status().get("connected"))
        self.window("0xb", automation=True)
        self.assertEqual(self.moves(), [])

    def test_consumed_marker_does_not_tag_later_session(self):
        self.marker(time.time() - 10)
        self.start()
        self.window(started=dt.datetime.now(dt.timezone.utc).isoformat())
        self.window("0xb", pid=124, started=dt.datetime.now(dt.timezone.utc).isoformat())
        self.assertEqual(self.moves(), [["movetoworkspacesilent", "3,address:0xb"]])

    def test_closed_first_window_history_survives_restart(self):
        self.start()
        self.window()
        self.state["clients"] = []
        self.save()
        self.process.terminate()
        self.process.wait(timeout=5)
        self.conn.close()
        self.process = subprocess.Popen([str(PLACER)], env=self.env, stdout=self.out, stderr=self.out)
        self.conn, _ = self.server.accept()
        wait_for(lambda: self.status().get("pid") == self.process.pid and self.status().get("connected"))
        self.window("0xb", automation=True)
        self.assertEqual(len(self.moves()), 1)

    def test_unknown_profile_fails_closed(self):
        self.start()
        self.state["clients"] = [{"address": "0xa", "class": "camoufox", "pid": 321}]
        self.save()
        self.conn.sendall(b"openwindow>>a,8,camoufox,title\n")
        wait_for(lambda: self.decisions(), 5)
        self.assertIn("keep-unknown", self.decisions()[0])
        self.assertEqual(self.moves(), [])

    def test_unresolved_first_cannot_expose_later_automation(self):
        self.start()
        self.state["clients"] = [{"address": "0xa", "class": "camoufox", "pid": 123}]
        self.save()
        self.conn.sendall(b"openwindow>>a,8,camoufox,title\n")
        wait_for(lambda: self.decisions(), 5)
        self.window("0xb", automation=True)
        self.assertEqual(self.moves(), [])
        self.assertIn("keep-automation", self.decisions()[-1])

    def test_event_does_not_override_manual_move(self):
        self.start()
        self.window(emit=False)
        self.state["clients"][0]["workspace"] = {"id": 5}
        self.save()
        self.conn.sendall(b"openwindow>>a,8,camoufox,title\n")
        wait_for(lambda: self.decisions())
        self.assertEqual(self.moves(), [])
        self.assertIn("keep-moved", self.decisions()[0])

    def test_named_workspace_and_no_focus_dispatch(self):
        self.start()
        self.state["workspace"] = {"id": -1, "name": "special:notes"}
        self.window()
        self.assertEqual(self.moves(), [["movetoworkspacesilent", "special:notes,address:0xa"]])

    def test_workspace_eight_needs_no_move(self):
        self.start()
        self.state["workspace"] = {"id": 8, "name": "8"}
        self.window()
        self.assertEqual(self.moves(), [])
        self.assertIn("return-human", self.decisions()[0])

    def test_configurable_workspace(self):
        self.env["SKW_WS8_WORKSPACE"] = "9"
        self.start()
        self.state["workspace"] = {"id": 9, "name": "9"}
        self.window()
        self.assertEqual(self.moves(), [])

    def test_logs_do_not_contain_titles_or_profiles(self):
        self.start()
        self.window()
        text = "\n".join(self.decisions())
        self.assertNotIn("title", text)
        self.assertNotIn("URL", text)
        self.assertNotIn("alpha", text)

    def test_socket_reconnect_new_instance(self):
        self.start()
        self.conn.close()
        self.server.close()
        (self.run / "hypr/test/.socket2.sock").unlink()
        path = self.run / "hypr/new/.socket2.sock"
        path.parent.mkdir()
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(path))
        self.server.listen()
        self.server.settimeout(5)
        self.conn, _ = self.server.accept()
        wait_for(lambda: self.status().get("signature") == "new" and self.status().get("connected"))
        self.window()
        self.assertEqual(len(self.moves()), 1)
        self.assertEqual([x[2] for x in self.calls() if x[0] == "hyprd"], ["new"])


class ShimTests(Fixture):
    def invoke(self, args, agent=None, comm=None):
        env = dict(self.env, PASSTHROUGH="1", EXIT_CODE="17")
        env["PATH"] = f"{self.shim.parent}:{self.bin}:/usr/bin"
        if agent:
            env[agent] = "codex"
        return detached([str(self.shim), *args], env, "stdin intact\n", comm)

    def markers(self):
        return list((self.run / "skw-ws8").glob("agent-*"))

    def test_stdio_argv_exit_code(self):
        args = ["--json", "--host", "unix:///fake", "start", "alpha", "beta space", "--client", "worker"]
        p = self.invoke(args, "AI_AGENT")
        self.assertEqual(p["code"], 17, p)
        self.assertEqual(p["stdout"], json.dumps(args) + "\nstdin intact\n")
        self.assertEqual(p["stderr"], "stderr intact\n")
        self.assertEqual(sorted(p.name for p in self.markers()), ["agent-alpha", "agent-beta space"])
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in self.markers()))

    def test_human_does_not_mark(self):
        p = self.invoke(["start", "alpha"])
        self.assertEqual(p["code"], 17, p)
        self.assertEqual(self.markers(), [])

    def test_human_clears_pending_marker(self):
        self.marker(time.time())
        self.invoke(["restart", "alpha"])
        self.assertEqual(self.markers(), [])

    def test_leading_zero_numeric_refs_are_normalized(self):
        p = self.invoke(["start", "00042"], "AI_AGENT")
        self.assertEqual(p["code"], 17, p)
        self.assertEqual([p.name for p in self.markers()], ["agent-42"])
        self.assertIn('"00042"', p['stdout'])
        self.start()
        self.window()
        self.assertEqual(self.moves(), [])

    def test_marker_install_failure_still_execs_but_inhibits_placement(self):
        mv = self.bin / "mv"
        mv.write_text('#!/bin/sh\nexit 1\n')
        mv.chmod(0o755)
        p = self.invoke(["start", "alpha"], "AI_AGENT")
        self.assertEqual(p["code"], 17, p)
        self.assertEqual(self.markers(), [])
        self.assertTrue((self.run / 'skw-ws8/inhibit-alpha').exists())
        self.start()
        self.window()
        self.assertEqual(self.moves(), [])

    def test_human_name_invalidates_numeric_agent_intent(self):
        self.marker(time.time() - 1, ref='42')
        self.invoke(["start", "alpha"])
        self.start()
        self.window(started=dt.datetime.now(dt.timezone.utc).isoformat())
        self.assertEqual(len(self.moves()), 1)

    def test_claudecode(self):
        self.invoke(["restart", "alpha"], "CLAUDECODE")
        self.assertEqual(len(self.markers()), 1)

    def test_ancestor_comm(self):
        self.invoke(["automation", "alpha", "--client=worker"], comm="codex")
        self.assertEqual(len(self.markers()), 1)

    def test_interpreter_running_agent(self):
        # A node-compatible runner with an agent script argument; /proc comm is node, argv contains codex.js.
        runner = self.root / "runner.py"
        runner.write_text('import ctypes,subprocess,sys\nctypes.CDLL(None).prctl(15,b"node",0,0,0)\n'
                          'sys.exit(subprocess.call(sys.argv[2:]))\n')
        env = dict(self.env, PASSTHROUGH="1")
        p = detached(["/usr/bin/python3", str(runner), "/tools/@openai/codex/bin/codex.js",
                      str(self.shim), "start", "alpha"], env)
        self.assertEqual(p["code"], 0, p)
        self.assertEqual(len(self.markers()), 1)

    def test_readonly_create_help_do_not_mark(self):
        for args in (["ps", "--json"], ["create", "alpha"], ["start", "alpha", "--help"]):
            self.invoke(args, "AI_AGENT")
        self.assertEqual(self.markers(), [])

    def test_path_alias_cannot_recurse(self):
        alias = self.root / "alias"
        alias.mkdir()
        (alias / "skw").symlink_to(self.shim)
        env = dict(self.env, PASSTHROUGH="1", AI_AGENT="codex",
                   PATH=f"{self.shim.parent}:{alias}:{self.shim.parent}:{self.bin}:/usr/bin")
        p = detached([str(self.shim), "start", "alpha"], env)
        self.assertEqual(p["code"], 0, p)
        self.assertEqual(len([x for x in self.calls() if x[0] == "skw"]), 1)

    def test_no_real_executable_refuses_recursion(self):
        env = dict(self.env, PATH=str(self.shim.parent), AI_AGENT="codex")
        p = detached([str(self.shim), "start", "alpha"], env)
        self.assertEqual(p["code"], 127, p)
        self.assertEqual(p["stdout"], "")

    def test_argument_cannot_escape_marker_directory(self):
        self.invoke(["start", "../../escape", "alpha"], "AI_AGENT")
        self.assertEqual([p.name for p in self.markers()], ["agent-alpha"])
        self.assertFalse((self.run / "escape").exists())

    def test_marker_overhead_under_twenty_ms(self):
        runner = self.root / 'benchmark.py'
        runner.write_text('''import ctypes,json,os,statistics,subprocess,sys,time
ctypes.CDLL(None).prctl(15,b"human-test",0,0,0)
baseline=[]; wrapped=[]
for name, samples in ((sys.argv[1],baseline),(sys.argv[2],wrapped)):
    for _ in range(16):
        start=time.perf_counter()
        subprocess.run([name,"start","alpha"],check=True,stdout=subprocess.DEVNULL)
        samples.append(time.perf_counter()-start)
print(json.dumps(statistics.median(wrapped)-statistics.median(baseline)))
''')
        real = self.bin / 'skw'
        real.write_text('#!/bin/sh\nexit 0\n')
        real.chmod(0o755)
        for agent in (False, True):
            env = dict(self.env)
            if agent:
                env['AI_AGENT'] = 'codex'
            p = detached(['/usr/bin/python3', str(runner), str(real), str(self.shim)], env)
            self.assertEqual(p['code'], 0, p)
            overhead = json.loads(p['stdout']) * 1000
            print(f"shim {'agent' if agent else 'human'} median overhead: {overhead:.2f} ms")
            self.assertLess(overhead, 20)

    def test_umask_is_preserved(self):
        real = self.bin / "skw"
        real.write_text('#!/bin/sh\numask\n')
        real.chmod(0o755)
        env = dict(self.env, AI_AGENT="codex")
        baseline = detached([str(real)], env)
        wrapped = detached([str(self.shim), "start", "alpha"], env)
        self.assertEqual(wrapped, baseline)

    def test_zsh_path_all_shells_and_refresh(self):
        config = self.home / ".config/zsh"
        config.mkdir(parents=True)
        shutil.copy2(REPO / ".config/zsh/skw-shim.zsh", config)
        shutil.copy2(REPO / ".zshenv", self.home)
        for flags in ("-c", "-lc"):
            p = subprocess.run(["zsh", flags, "command -v skw"], env=self.env, text=True, capture_output=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout.strip(), str(self.shim))
        p = subprocess.run(["zsh", "-fc", 'source "$HOME/.config/zsh/skw-shim.zsh"; '
                            'path=(/fake/mise $path); _df_skw_path; print -r -- $path[1]'],
                           env=self.env, text=True, capture_output=True)
        self.assertEqual(p.stdout.strip(), str(self.shim.parent))


class DoctorTests(Fixture):
    def check(self):
        return subprocess.run([str(PLACER), "--check"], env=self.env, capture_output=True, text=True)

    def install_zsh(self):
        config = self.home / ".config/zsh"
        config.mkdir(parents=True)
        shutil.copy2(REPO / ".config/zsh/skw-shim.zsh", config)
        shutil.copy2(REPO / ".zshenv", self.home)

    def test_missing_skw_is_info(self):
        (self.bin / "skw").unlink()
        p = self.check()
        self.assertEqual(p.returncode, 0)
        self.assertIn("INFO skw is not installed", p.stdout)

    def test_bad_login_path_is_failure(self):
        p = self.check()
        self.assertEqual(p.returncode, 1)
        self.assertIn("shim is not first", p.stdout)

    def test_no_hyprland_is_info(self):
        self.install_zsh()
        p = self.check()
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn("INFO no Hyprland", p.stdout)

    def test_placer_missing_is_failure(self):
        self.install_zsh()
        (self.run / "hypr/test").mkdir(parents=True)
        (self.run / "hypr/test/.socket2.sock").touch()
        p = self.check()
        self.assertEqual(p.returncode, 1)
        self.assertIn("placer is not connected", p.stdout)

    def test_connected_is_pass(self):
        self.install_zsh()
        self.start()
        p = self.check()
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn("PASS placer connected", p.stdout)


if __name__ == "__main__":
    os.environ.pop("WAYLAND_DISPLAY", None)
    os.environ.pop("DISPLAY", None)
    sys.argv = [sys.argv[0]] + [a for a in sys.argv[1:] if a != "--quick"]
    suite = (unittest.defaultTestLoader.loadTestsFromNames(sys.argv[1:], sys.modules[__name__]) if sys.argv[1:]
             else unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(f"skw-ws8 tests: {result.testsRun - len(result.failures) - len(result.errors)} passed, "
          f"{len(result.failures) + len(result.errors)} failed")
    sys.exit(not result.wasSuccessful())
