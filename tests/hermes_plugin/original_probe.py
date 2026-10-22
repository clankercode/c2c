import importlib.util, sys, os, json, threading, hashlib
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
ROOT=Path(os.environ['C2C_HERMES_SOURCE'])
spec=importlib.util.spec_from_file_location('probe_c2c',ROOT/'__init__.py',submodule_search_locations=[str(ROOT)])
p=importlib.util.module_from_spec(spec); sys.modules[spec.name]=p; spec.loader.exec_module(p)
from probe_c2c import identity as ident, delivery as d, c2c_cli, broker_watcher
rows=[]
def record(name, **kw): rows.append(dict(case=name,**kw))
def reset(): d._dedup=d.DeliveryDedup(); d._drain_owed=False
class Cli:
    available=True
    def __init__(self): self.mail=[]; self.polls=0; self.calls=[]
    def whoami(self): return {'alias':'alias-'+os.environ['C2C_MCP_SESSION_ID'],'session_id':os.environ['C2C_MCP_SESSION_ID']}
    def rooms_join(self,room): self.calls.append(('join',room))
    def peek_inbox(self): return list(self.mail)
    def poll_inbox(self):
        self.polls+=1; mail=self.mail; self.mail=[]; return mail
    def send(self,*args,**kwargs): return {'sender_session':os.environ['C2C_MCP_SESSION_ID']}
cli=Cli()
class Ctx:
    def __init__(self): self.hooks={}; self.tools={}; self.commands={}; self.injections=[]
    def register_hook(self,n,h): self.hooks[n]=h
    def register_tool(self,**kw): self.tools[kw['name']]=kw['handler']
    def register_command(self,n,h,*args): self.commands[n]=h
    def register_skill(self,*a): pass
    def inject_message(self,body,**kw): self.injections.append(kw); return False
ctx=Ctx()
with patch.dict(os.environ, {'C2C_MCP_AUTO_JOIN_ROOMS':''}), patch.object(c2c_cli,'C2cCli',return_value=cli), patch.object(broker_watcher.BrokerWatcher,'start'):
    p.register(ctx)
    ident.register_identity(session_id='session-A')
    ident.register_identity(session_id='session-B')
    record('two_session_identity',last_session=ident.get_session_id(),A_tool_observed=json.loads(ctx.tools['c2c_send']({'to':'peer','body':'x'},session_id='session-A')),A_command_observed=json.loads(ctx.commands['c2c-send']('peer x')))
    reset(); cli.mail=[{'id':'private-B','body':'B-only'}]
    out=ctx.hooks['pre_llm_call'](session_id='session-A',is_first_turn=False)
    record('foreign_pre_llm_drain',A_context_contains_B='B-only' in str(out),B_mail_remaining=len(cli.mail))
    reset(); cli.mail=[{'id':'early','body':'early'}]; before=cli.polls
    out=ctx.hooks['pre_llm_call'](session_id='session-B',is_first_turn=True)
    record('first_turn_skips_mail',context=out,polls=cli.polls-before,mail_remaining=len(cli.mail))
    reset(); before=cli.polls
    delivered=d.drain_and_inject(ctx,cli=cli,self_alias='alias-B')
    record('declined_injection_retains_mail',delivered=delivered,polls=cli.polls-before,mail_remaining=len(cli.mail),inject_kwargs=ctx.injections[-1])
    ended=[]
    with patch.object(ctx._c2c_watcher,'stop',side_effect=lambda:ended.append(True)):
        ctx.hooks['on_session_end'](session_id='session-B',completed=True)
    record('session_end_does_not_stop_watcher',stop_calls=len(ended))
# Real Hermes routing function; no real manager or CLI is loaded.
routespec=importlib.util.spec_from_file_location('probe_injection',os.environ['HERMES_INJECTION_SOURCE'])
r=importlib.util.module_from_spec(routespec); routespec.loader.exec_module(r)
tui_calls=[]
mgr=SimpleNamespace(_cli_ref=None,has_gateway_message_injector=False,has_tui_message_injector=True,inject_tui_message=lambda **kw:tui_calls.append(kw) or True)
rctx=SimpleNamespace(_manager=mgr,plugin_id='c2c',_gateway_injection_allowed=lambda:True)
record('real_TUI_routing',keyless=r.inject_plugin_message(rctx,'x','user',session_key=None,origin=None),explicit=r.inject_plugin_message(rctx,'x','user',session_key='session-A',origin=None),tui_calls=tui_calls)
# Peek/poll late arrival: second injection declined, mailbox already drained.
reset(); cli=Cli(); cli.mail=[{'id':'first','body':'first'}]
class LateCtx:
    def __init__(self): self.count=0
    def inject_message(self,*a,**kw):
        self.count+=1
        if self.count==1:
            cli.mail.append({'id':'late','body':'late'}); return True
        return False
lc=LateCtx(); count=d.drain_and_inject(lc,cli=cli)
record('late_arrival_inject_failure',delivered=count,injections=lc.count,remaining=cli.mail,late_marked=d._dedup.has('id:late'))
# Thread race: both read novelty before either injection finishes.
reset(); cli=Cli(); cli.mail=[{'id':'race','body':'race'}]; barrier=threading.Barrier(2)
class RaceCtx:
    def __init__(self): self.calls=0
    def inject_message(self,*a,**kw): self.calls+=1; barrier.wait(timeout=2); return True
rc=RaceCtx(); threads=[threading.Thread(target=d.drain_and_inject,args=(rc,),kwargs={'cli':cli}) for _ in range(2)]
for t in threads:t.start()
for t in threads:t.join()
record('concurrent_delivery_duplicate',same_message_injections=rc.calls,polls=cli.polls)
# Actual watcher/pre-LLM interleaving: injection blocks after novelty check.
reset(); cli=Cli(); cli.mail=[{'id':'cross-race','body':'cross-race'}]
entered=threading.Event(); release=threading.Event()
class CrossCtx:
    def inject_message(self,*a,**kw): entered.set(); release.wait(timeout=2); return True
cross=CrossCtx(); t=threading.Thread(target=d.drain_and_inject,args=(cross,),kwargs={'cli':cli}); t.start()
assert entered.wait(timeout=2)
context=d.drain_for_context(cli=cli); release.set(); t.join()
record('watcher_pre_llm_duplicate',watcher_injected=True,pre_llm_also_returned_same_message='cross-race' in str(context),polls=cli.polls)
result={'source':str(ROOT),'sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(ROOT.glob('*.py'))},'observations':rows}
print(json.dumps(result,indent=2))
Path(os.environ['TMPDIR'],'c2c-session-probe-results.json').write_text(json.dumps(result,indent=2))
