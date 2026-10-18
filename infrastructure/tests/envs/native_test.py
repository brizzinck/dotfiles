#!/usr/bin/python3 -IB
"""Native account imports/sets through invented broker protocol fixtures only."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location('native_refs',Path(__file__).with_name('references_test.py'))
f = importlib.util.module_from_spec(spec); spec.loader.exec_module(f)

BOOT = r'''import sys,os,pathlib,json,uuid
source=sys.argv.pop(1)
ns={'__name__':'native_fixture','__file__':source}
exec(compile(open(source).read(),source,'exec'),ns)
ns['HOME']=pathlib.Path(os.environ['HOME'])
root=pathlib.Path(os.environ['FAKE_DIR'])
written=False
def share(msg):
 global written
 op=msg['op']; user=os.environ['ENVS_TEST_MANAGED_USER']; mode=os.environ.get('NATIVE_FAIL','')
 log=root/'native.log'
 with log.open('a') as target: target.write(json.dumps({k:msg[k] for k in ('op','request_id') if k in msg})+'\n')
 path=root/'vault.json'; vault=json.loads(path.read_text()); folders={row['id']:row['name'] for row in vault['folders']}
 def row(item):
  return {'id':item['id'],'folder':folders.get(item['folderId']),'name':item['name'],'type':'note',
          'fields':[{'name':'field:'+x['name'],'set':bool(x.get('value')),'hidden':x.get('type')==1} for x in item.get('fields',[])]}
 visible=[item for item in vault['items'] if folders.get(item['folderId'],'').startswith(('Users/'+user+'/','Shared/'))]
 if op=='whoami': return {'v':1,'ok':True,'vault':'unlocked','user':user}
 if op=='list': return {'v':1,'ok':True,'items':[row(item) for item in visible]}
 if op=='env-put':
  if user!='td': ns['fail']('fixture policy denied',4)
  if mode=='write': ns['fail']('fixture-private-backend-error',1)
  folder='Users/'+user+'/Env/'+msg['project']; hits=[item for item in vault['items'] if folders.get(item['folderId'])==folder and item['name']==msg['env']]
  if len(hits)>1: ns['fail']('fixture ambiguous',4)
  if hits:
   item=hits[0]
  else:
   fid=str(uuid.uuid4()); vault['folders'].append({'id':fid,'name':folder}); folders[fid]=folder
   item={'id':str(uuid.uuid4()),'folderId':fid,'name':msg['env'],'type':2,'fields':[]};vault['items'].append(item)
  current={field['name']:field.get('value') for field in item['fields']}
  if not msg['overwrite'] and any(name in current and current[name]!=value for name,value in msg['values'].items()): ns['fail']('fixture conflict',4)
  for name,value in msg['values'].items():
   fields=[field for field in item['fields'] if field['name']==name]
   if fields: fields[0].update(value=value,type=1)
   else:item['fields'].append({'name':name,'value':value,'type':1})
  path.write_text(json.dumps(vault));written=True
  if mode=='source':
   target=pathlib.Path.cwd()/'.env';target.write_text('OWNER_EDIT=fixture-concurrent-edit\n')
  receipt={'v':1,'ok':True,'id':item['id'],'project':msg['project'],'env':msg['env'],'names':sorted(msg['values']),'verified':True}
  if mode=='receipt':receipt['verified']=False
  return receipt
 if op=='describe':
  hits=[item for item in visible if (item['id']==msg['id'] if 'id' in msg else folders.get(item['folderId'])==msg['folder'] and item['name']==msg['name'])]
  if len(hits)!=1:ns['fail']('fixture unavailable',4)
  description=row(hits[0])
  if written and mode=='target':description['folder']='Shared/Env/foreign'
  return {'v':1,'ok':True,'item':description}
 if op=='get':
  hits=[item for item in visible if item['id']==msg['id']]
  if len(hits)!=1:ns['fail']('fixture unavailable',4)
  fields={x['name']:x.get('value') for x in hits[0]['fields']};values={name:fields[name[6:]] for name in msg['fields'] if name[6:] in fields}
  if written and mode=='readback':values={name:'fixture-wrong-value' for name in values}
  return {'v':1,'ok':True,'id':hits[0]['id'],'values':values,'missing':[name for name in msg['fields'] if name not in values]}
 ns['fail']('unexpected fixture operation',1)
ns['share']=share
sys.exit(ns['main'](sys.argv[1:]))
'''

class Native(unittest.TestCase):
    setUp = f.References.setUp
    tearDown = f.References.tearDown
    save_vault = f.References.save_vault
    log = f.References.log
    ref_file = f.References.ref_file

    def run_envs(self,*args,env=None,input=None):
        child=dict(env or self.env);child.setdefault('ENVS_TEST_MANAGED_USER','td')
        return subprocess.run([sys.executable,'-I','-B','-c',BOOT,str(f.SOURCE),*args],cwd=self.project,env=child,
                              input=input,capture_output=True,text=True,timeout=15)

    def bind(self):
        result=self.run_envs('bind','--yes');self.assertEqual(0,result.returncode,result.stderr)

    def native_log(self):
        path=self.fake/'native.log';return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def import_one(self):
        return self.run_envs('import','--secrets','NEW_TOKEN','--plain','APP_PORT')

    def test_import_bind_run_no_toml_and_plain_bytes_preserved(self):
        source=self.project/'.env';source.write_bytes(b'# keep\r\nNEW_TOKEN=fixture-native-secret\r\nAPP_PORT = 8080 # unchanged')
        self.bind();result=self.import_one();self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual(b'# keep\r\nNEW_TOKEN=bw://Users/td/Env/demo/dev#NEW_TOKEN\r\nAPP_PORT = 8080 # unchanged',source.read_bytes())
        self.assertFalse((self.project/'.envs.toml').exists());self.bind()
        child=self.project/'verify.py';child.write_text('import os,sys\nsys.exit(0 if os.environ.get("NEW_TOKEN")=="fixture-native-secret" else 9)\n')
        run=self.run_envs('run','--no-mise','--','/usr/bin/python3','-I','-B',str(child))
        self.assertEqual(0,run.returncode,run.stderr)
        self.assertNotIn('fixture-native-secret',result.stdout+result.stderr+run.stdout+run.stderr)
        self.assertEqual('',self.log())

    def test_set_new_and_existing_inline_without_toml_or_parent_export(self):
        self.ref_file('APP_PORT=8080\n');self.bind()
        for value in ('fixture-first-native','fixture-next-native'):
            result=self.run_envs('set','NEW_TOKEN','--stdin',input=value+'\n')
            self.assertEqual(0,result.returncode,result.stderr)
            self.assertEqual('APP_PORT=8080\nNEW_TOKEN=bw://Users/td/Env/demo/dev#NEW_TOKEN\n',(self.project/'.env').read_text())
            self.assertNotIn(value,result.stdout+result.stderr)
        self.assertFalse((self.project/'.envs.toml').exists())
        self.assertNotIn('NEW_TOKEN',os.environ)
        self.assertEqual('',self.log())

    def test_optional_toml_exact_self_mapping_coexists_and_shared_conflicts(self):
        (self.project/'.envs.toml').write_text('project="my-project"\nenvironments=["dev"]\ndefault="dev"\n[secrets]\nNEW_TOKEN=""\n')
        self.ref_file('NEW_TOKEN=fixture-native-secret\n');self.bind()
        result=self.run_envs('import','--secrets','NEW_TOKEN');self.assertEqual(0,result.returncode,result.stderr)
        self.bind();self.assertEqual(0,self.run_envs('check').returncode)
        self.ref_file('NEW_TOKEN=bw://Shared/Env/my-project/dev#NEW_TOKEN\n')
        denied=self.run_envs('check');self.assertEqual(4,denied.returncode);self.assertIn('conflicting',denied.stderr)

    def test_agent_and_yc_denial_keep_source_and_no_owner_backend(self):
        self.ref_file('NEW_TOKEN=fixture-native-secret\n');self.bind();before=(self.project/'.env').read_bytes()
        for args in (('import','--secrets','NEW_TOKEN'),('set','NEW_TOKEN','--stdin')):
            mark=len(self.native_log());result=self.run_envs(*args,env=dict(self.env,CLAUDECODE='1'),input='fixture-stdin-secret\n')
            self.assertEqual(4,result.returncode);self.assertEqual(mark,len(self.native_log()))
        result=self.run_envs('import','--secrets','NEW_TOKEN',env=dict(self.env,ENVS_TEST_MANAGED_USER='yc'))
        self.assertNotEqual(0,result.returncode);self.assertEqual(before,(self.project/'.env').read_bytes());self.assertEqual('',self.log())

    def test_failure_receipt_target_readback_retain_plaintext_and_reuse_request(self):
        self.ref_file('NEW_TOKEN=fixture-native-secret\n');self.bind();source=self.project/'.env';before=source.read_bytes()
        request_ids=[]
        for mode in ('write','receipt','target','readback'):
            result=self.run_envs('import','--secrets','NEW_TOKEN',env=dict(self.env,NATIVE_FAIL=mode))
            self.assertNotEqual(0,result.returncode);self.assertEqual(before,source.read_bytes())
            self.assertNotIn('fixture-private-backend-error',result.stdout+result.stderr)
            self.assertNotIn('fixture-native-secret',result.stdout+result.stderr)
            request_ids.append([row['request_id'] for row in self.native_log() if row['op']=='env-put'][-1])
        self.assertEqual(1,len(set(request_ids)))
        result=self.run_envs('import','--secrets','NEW_TOKEN');self.assertEqual(0,result.returncode,result.stderr)
        records=(self.root/'state/envs/native-writes.json').read_text();self.assertNotIn('fixture-native-secret',records)
        self.assertNotIn('values',records)

    def test_overwrite_conflict_all_or_none_and_concurrent_source_retained(self):
        self.ref_file('NEW_TOKEN=fixture-native-secret\n');self.bind()
        result=self.run_envs('import','--secrets','NEW_TOKEN');self.assertEqual(0,result.returncode,result.stderr)
        self.ref_file('NEW_TOKEN=fixture-changed-secret\n');self.bind()
        denied=self.run_envs('import','--secrets','NEW_TOKEN');self.assertNotEqual(0,denied.returncode)
        self.assertEqual('NEW_TOKEN=fixture-changed-secret\n',(self.project/'.env').read_text())
        # Retry original pending batch explicitly with overwrite permitted.
        result=self.run_envs('import','--secrets','NEW_TOKEN','--overwrite',env=dict(self.env,NATIVE_FAIL='source'))
        self.assertNotEqual(0,result.returncode)
        self.assertEqual('OWNER_EDIT=fixture-concurrent-edit\n',(self.project/'.env').read_text())

    def test_set_refuses_literal_shared_crossuser_selector_and_wrong_item_before_stdin(self):
        for value in ('fixture-native-literal','bw://Shared/Env/demo/dev#NEW_TOKEN','bw://Users/yc/Env/demo/dev#NEW_TOKEN',
                      'bw://Users/td/Env/demo/dev#@notes','bw://Users/td/Env/demo/stage#NEW_TOKEN'):
            self.ref_file('NEW_TOKEN='+value+'\n')
            # Bind the root only; foreign targets need not exist to reject set.
            raw=self.run_envs('set','NEW_TOKEN','--stdin',input='fixture-new-secret\n')
            self.assertNotEqual(0,raw.returncode)
            self.assertFalse(any(row['op']=='env-put' for row in self.native_log()))
            self.assertEqual('NEW_TOKEN='+value+'\n',(self.project/'.env').read_text())

    def test_global_import_and_set_write_only_account_local_map(self):
        (self.root/'global/global.toml').write_text('project="global"\n[secrets]\n')
        source=self.root/'export.sh';source.write_text("export NEW_TOKEN='fixture-global-secret'\nexport APP_MODE='development'\n");source.chmod(0o600)
        result=self.run_envs('import','-g',str(source),'--secrets','NEW_TOKEN','--plain','APP_MODE','--yes')
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual('NEW_TOKEN=bw://Users/td/Env/global/default#NEW_TOKEN\n',(self.root/'global/global.env').read_text())
        self.assertEqual('',source.read_text())
        result=self.run_envs('set','NEXT_TOKEN','-g','--stdin',input='fixture-next-global\n')
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertIn('NEXT_TOKEN=bw://Users/td/Env/global/default#NEXT_TOKEN',(self.root/'global/global.env').read_text())
        self.assertFalse((self.root/'state/envs/scoped-global-import.json').exists())

    def test_batch_boundary_64_succeeds_65_refuses_without_split_mutation(self):
        source=self.project/'.env'
        names=['TOKEN_%02d' % i for i in range(64)]
        source.write_text(''.join(name+'=fixture-bounded-secret\n' for name in names));self.bind()
        result=self.run_envs('import','--secrets',','.join(names))
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual(1,sum(row['op']=='env-put' for row in self.native_log()))
        names.append('TOKEN_64')
        source.write_text(''.join(name+'=fixture-bounded-secret\n' for name in names));self.bind()
        before=source.read_bytes();count=sum(row['op']=='env-put' for row in self.native_log())
        result=self.run_envs('import','--secrets',','.join(names))
        self.assertNotEqual(0,result.returncode)
        self.assertEqual(before,source.read_bytes())
        self.assertEqual(count,sum(row['op']=='env-put' for row in self.native_log()))

    def test_limits_and_unsupported_mutators_fail_without_backend(self):
        self.ref_file('APP_PORT=8080\n');self.bind()
        for name,value in (('X'*101,'fixture-value'),('TOKEN','short'),('TOKEN','X'*5001)):
            result=self.run_envs('set',name,'--stdin',input=value+'\n')
            self.assertNotEqual(0,result.returncode)
        for args in (('unset','TOKEN'),('copy','dev','stage'),('project','rename','other'),('set','TOKEN','--for','yc','--stdin')):
            result=self.run_envs(*args,input='fixture-other-secret\n');self.assertNotEqual(0,result.returncode)
        self.assertFalse(any(row['op']=='env-put' for row in self.native_log()))


if __name__=='__main__':unittest.main()
