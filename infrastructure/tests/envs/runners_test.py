#!/usr/bin/python3 -IB
"""Go shortcut routing in isolated shells; invented executables and no live vault."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
START = '# Go run/test shortcuts use the same project discovery as envs.'
BLOCK = START + (REPO / '.zshrc').read_text().split(START, 1)[1].split('alias lg=', 1)[0]


class Runners(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='envs-go-runners.')
        self.root = Path(self.temp.name); self.home = self.root / 'home'; self.home.mkdir()
        self.project = self.root / 'project'; self.project.mkdir()
        self.snippet = self.root / 'runners.zsh'; self.snippet.write_text(BLOCK)
        self.tools = self.root / 'bin'; self.tools.mkdir()
        self.envs = self.home / '.local/bin/envs'; self.envs.parent.mkdir(parents=True)
        stub = '#!/usr/bin/python3 -IB\nimport json,os,sys\nprint(json.dumps([sys.argv[0].split("/")[-1],sys.argv[1:]]))\nsys.exit(int(os.environ.get("FIXTURE_RC","0")))\n'
        for path in (self.envs, self.tools / 'go'):
            path.write_text(stub); path.chmod(0o755)
        for name in ('fzf-menu','ghostty','notify-send','hyprctl','wl-copy'):
            path = self.tools / name; path.write_text('#!/bin/sh\nexit 97\n'); path.chmod(0o755)
        self.env = {'HOME':str(self.home),'PATH':str(self.tools)+':/usr/bin:/bin'}
        for name in ('CONFIG','STATE','CACHE','DATA','RUNTIME'):
            path = self.home / name.lower(); path.mkdir(mode=0o700)
            self.env['XDG_'+name+('_DIR' if name=='RUNTIME' else '_HOME')] = str(path)

    def tearDown(self):
        self.temp.cleanup()

    def run_shell(self, command, cwd=None, env=None, prefix=''):
        script = 'typeset -gr _ENVS_BIN=$1; ' + (prefix + '; ' if prefix else '') + 'source "$2"; ' + command
        result = subprocess.run(['/usr/bin/zsh','-dfc',script,'fixture',str(self.envs),str(self.snippet)],cwd=cwd or self.project,
                                env=env or self.env,capture_output=True,text=True,timeout=15)
        if result.returncode == 0:
            self.assertEqual('',result.stderr)
        return result

    def test_unconfigured_go_and_all_grun_branches_forward_literal_arguments(self):
        for path, target in (('cmd/api/main.go','./cmd/api/main.go'),('cmd/main.go','./cmd/main.go'),('main.go','.')):
            with self.subTest(path=path):
                source = self.project / path; source.parent.mkdir(parents=True,exist_ok=True); source.touch()
                result = self.run_shell("grun 'two words' '--literal=$value'")
                self.assertEqual(0,result.returncode,result.stderr)
                self.assertEqual(['go',['run',target,'two words','--literal=$value']],json.loads(result.stdout))
        result = self.run_shell("tg -run 'two words' -count=1")
        self.assertEqual(['go',['test','./...','-run','two words','-count=1']],json.loads(result.stdout))

    def test_configured_metadata_routes_envs_and_never_falls_back(self):
        (self.project / 'main.go').touch()
        for name in ('.env','.envs.toml'):
            with self.subTest(name=name):
                metadata = self.project / name; metadata.write_text('# invented metadata\n')
                result = self.run_shell("grun 'two words'",env=dict(self.env,FIXTURE_RC='7'))
                self.assertEqual(7,result.returncode)
                self.assertEqual(['envs',['run','--','go','run','.','two words']],json.loads(result.stdout))
                metadata.unlink()
        (self.project / '.env').symlink_to(self.project / 'missing')
        result = self.run_shell('tg',env=dict(self.env,FIXTURE_RC='4'))
        self.assertEqual(4,result.returncode)
        self.assertEqual('envs',json.loads(result.stdout)[0])

    def test_git_root_and_ancestor_toml_follow_envs_discovery(self):
        subprocess.run(['/usr/bin/git','init','-q',str(self.project)],check=True)
        child = self.project / 'child'; child.mkdir()
        (self.project / '.env').write_text('# root metadata\n')
        result = self.run_shell('tg',cwd=child)
        self.assertEqual('envs',json.loads(result.stdout)[0])
        (self.project / '.env').unlink()
        (child / '.env').write_text('# not an approved git root document\n')
        result = self.run_shell('tg',cwd=child)
        self.assertEqual('go',json.loads(result.stdout)[0])
        (self.project / '.envs.toml').write_text('# ancestor config\n')
        result = self.run_shell('tg',cwd=child)
        self.assertEqual('envs',json.loads(result.stdout)[0])

    def test_existing_tg_alias_is_removed_when_sourcing_real_snippet(self):
        (self.project / '.env').write_text('# configured project\n')
        result = self.run_shell('tg -count=1',prefix="alias tg='go test ./...'")
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual(['envs',['run','--','go','test','./...','-count=1']],json.loads(result.stdout))

    def test_git_environment_cannot_hide_configured_project(self):
        subprocess.run(['/usr/bin/git','init','-q',str(self.project)],check=True)
        other = self.root / 'other'; other.mkdir()
        subprocess.run(['/usr/bin/git','init','-q',str(other)],check=True)
        (self.project / '.env').write_text('# approved project metadata\n')
        (self.project / 'main.go').touch()
        environment = dict(self.env,GIT_DIR=str(other / '.git'),GIT_WORK_TREE=str(other),GIT_CONFIG_COUNT='0')
        result = self.run_shell('grun',env=environment)
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual(['envs',['run','--','go','run','.']],json.loads(result.stdout))

    def test_no_main_and_parent_environment_remains_unchanged(self):
        result = self.run_shell('grun; [[ -z ${DATABASE_URL+x} ]]')
        self.assertEqual(0,result.returncode,result.stderr); self.assertEqual('',result.stdout)
        (self.project / '.env').write_text('# metadata\n')
        result = self.run_shell('tg; rc=$?; [[ -z ${DATABASE_URL+x} ]] || exit 91; exit $rc')
        self.assertEqual(0,result.returncode,result.stderr)

    def test_real_envs_agent_approval_and_masking_are_preserved(self):
        spec = importlib.util.spec_from_file_location('runners_refs',Path(__file__).with_name('references_test.py'))
        refs = importlib.util.module_from_spec(spec); spec.loader.exec_module(refs)
        fixture = refs.References(); fixture.setUp()
        try:
            fixture.ref_file()
            (fixture.project / '.envs.toml').write_text('project="my-project"\nenvironments=["dev"]\ndefault="dev"\n[agents]\nallow=["go test ./..."]\n')
            tool = fixture.root / 'go-bin'; tool.mkdir()
            go = tool / 'go'; go.write_text('#!/usr/bin/python3 -IB\nimport os\nprint(os.environ["DATABASE_URL"])\n'); go.chmod(0o755)
            fixture.env['PATH'] = str(tool)+':'+fixture.env['PATH']
            self.assertEqual(0,fixture.run_envs('bind','--yes').returncode)
            boot = fixture.root / 'envs-boot.py'
            boot.write_text('import os,pathlib,sys\np='+repr(str(refs.SOURCE))+'\nns={"__name__":"fixture_envs","__file__":p}\nexec(compile(open(p).read(),p,"exec"),ns)\nns["HOME"]=pathlib.Path(os.environ["HOME"])\nsys.exit(ns["main"](sys.argv[1:]))\n')
            self.envs.write_text('#!/bin/sh\nexec /usr/bin/python3 -I -B '+shlex.quote(str(boot))+' "$@"\n')
            agent_env = dict(fixture.env,CLAUDECODE='1')
            denied = self.run_shell('tg',cwd=fixture.project,env=agent_env)
            self.assertEqual(4,denied.returncode,denied.stderr)
            self.assertNotIn('invented-database-value',denied.stdout+denied.stderr)
            allowed = fixture.run_envs('agent','allow','--','go','test','./...')
            self.assertEqual(0,allowed.returncode,allowed.stderr)
            result = self.run_shell('tg; rc=$?; [[ -z ${DATABASE_URL+x} ]] || exit 91; exit $rc',cwd=fixture.project,env=agent_env)
            self.assertEqual(0,result.returncode,result.stderr)
            self.assertEqual('[secret DATABASE_URL]\n',result.stdout)
        finally:
            fixture.tearDown()


if __name__ == '__main__':
    unittest.main()
