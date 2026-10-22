"""Owned headless integration fixture: real Hermes manager + real c2c binary.

Run only on the buildbox with C2C_BIN, HERMES_SOURCE_ROOT, C2C_HERMES_SOURCE
and C2C_HERMES_FIXTURE_ROOT (an existing owned scratch directory) set.
Disposable profiles and brokers stay under that root. No model, GUI, service
or real user session starts. This proves host enqueue and request-context
handoff, not model-visible live wake.
"""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch


@unittest.skipUnless(all(os.environ.get(key) for key in (
    'C2C_BIN', 'HERMES_SOURCE_ROOT', 'C2C_HERMES_SOURCE', 'C2C_HERMES_FIXTURE_ROOT')),
    'set the documented isolated native fixture environment')
class NativeFixture(unittest.TestCase):
    def test_real_manager_routing_and_native_mailbox(self):
        root = Path(os.environ['C2C_HERMES_FIXTURE_ROOT']).resolve(strict=True)
        binary = str(Path(os.environ['C2C_BIN']).resolve(strict=True))
        source = Path(os.environ['C2C_HERMES_SOURCE']).resolve(strict=True)
        hermes = Path(os.environ['HERMES_SOURCE_ROOT']).resolve(strict=True)
        sys.path.insert(0, str(hermes))
        with tempfile.TemporaryDirectory(prefix='native-', dir=root) as tmp:
            tmp = Path(tmp)
            profile, workspace, broker = tmp/'profile', tmp/'workspace', tmp/'broker'
            for p in (profile, workspace, broker): p.mkdir()
            def config(consent):
                (profile/'config.yaml').write_text(json.dumps({'plugins': {'entries': {'c2c': {'allow_gateway_injection': consent}}}}))
            config(True)
            env = {'HOME': str(tmp), 'HERMES_HOME': str(profile), 'C2C_BIN': binary,
                   'C2C_STATE_HOME': str(tmp/'state'), 'C2C_HERMES_BROKER_ROOT': str(broker),
                   'C2C_MCP_AUTO_JOIN_ROOMS': '', 'C2C_MCP_CLIENT_PID': '1',
                   'C2C_MCP_AUTO_REGISTER_ALIAS': 'foreign-parent',
                   'C2C_MCP_BROKER_ROOT': str(tmp/'foreign-broker'),
                   'C2C_MCP_SESSION_ID': 'foreign-parent', 'C2C_CODEX_APPSERVER_SESSION': 'foreign'}
            with patch.dict(os.environ, env):
                from hermes_cli.plugins import PluginManager, PluginContext, PluginManifest
                from hermes_constants import set_hermes_home_override, reset_hermes_home_override
                from gateway.session_context import set_session_vars, clear_session_vars
                from hermes_cli.plugin_command_dispatch import invoke_plugin_command
                from tui_gateway import plugin_inject
                spec = importlib.util.spec_from_file_location('native_c2c_fixture', source/'__init__.py', submodule_search_locations=[str(source)])
                plugin = importlib.util.module_from_spec(spec)
                sys.modules[spec.name] = plugin
                spec.loader.exec_module(plugin)
                from native_c2c_fixture import broker_watcher
                manager = PluginManager(scope_key=str(profile))
                ctx = PluginContext(PluginManifest(name='c2c', key='c2c', source='user'), manager)
                with patch.object(broker_watcher.BrokerWatcher, 'start'):
                    plugin.register(ctx)
                @contextlib.contextmanager
                def scope(sid, key):
                    home_token = set_hermes_home_override(profile)
                    tokens = set_session_vars(platform='tui', session_id=sid, session_key=key, cwd=str(workspace))
                    try: yield
                    finally:
                        clear_session_vars(tokens)
                        reset_hermes_home_override(home_token)
                def hook(name, sid='native-A', key='route-A', **kwargs):
                    with scope(sid, key):
                        return manager.invoke_hook(name, session_id=sid, platform='tui', **kwargs)
                with patch.object(broker_watcher.BrokerWatcher, 'start'):
                    hook('on_session_start')
                    hook('on_session_start', sid='native-B', key='route-B')
                a = ctx._c2c_sessions.resolve(session_id='native-A', session_key='route-A')
                b = ctx._c2c_sessions.resolve(session_id='native-B', session_key='route-B')
                self.assertEqual(a.cli.env['C2C_MCP_CLIENT_PID'], str(os.getpid()))
                self.assertEqual(a.binding.broker_root, str(broker))
                self.assertNotEqual(a.binding.alias, 'foreign-parent')
                self.assertFalse((tmp/'foreign-broker').exists())
                self.assertNotIn('C2C_CODEX_APPSERVER_SESSION', a.cli.env)
                def mail(session):
                    result = session.cli.peek_inbox()
                    return result.get('messages', []) if isinstance(result, dict) else result
                accepted, wakes = [], []
                sessions = {'ui-A': {'session_key': 'route-A', 'history_lock': threading.RLock(), 'running': False},
                            'ui-B': {'session_key': 'route-B', 'history_lock': threading.RLock(), 'running': True}}
                def enqueue(session, body, transport): accepted.append((session['session_key'], body))
                class WakeThread:
                    def __init__(self, **kw): self.kw = kw
                    def start(self): wakes.append(self.kw['args'][1])
                # Real host routing; only host state and model launch are fixtures.
                patch_globals = {'_sessions': sessions, '_sessions_lock': threading.Lock(),
                    '_enqueue_prompt': enqueue, '_drain_queued_prompt': lambda *a: None,
                    'threading': SimpleNamespace(Thread=WakeThread), 'time': __import__('time'), 'uuid': __import__('uuid')}
                with patch.dict(plugin_inject.inject_tui_session_message.__globals__, patch_globals):
                    manager.set_tui_message_injector(object(), plugin_inject.inject_tui_session_message)
                    b.cli.send(a.binding.alias, 'first-turn-data', ephemeral=True)
                    out = hook('pre_llm_call', is_first_turn=True, turn_id='turn-1')
                    body = out[0]['context']
                    self.assertIn('first-turn-data', body)
                    self.assertTrue(mail(a))
                    hook('pre_api_request', turn_id='turn-1', request_messages=[{'role': 'user', 'content': body}])
                    self.assertEqual(mail(a), [])
                    for state in ('idle', 'busy', 'ended', 'unknown', 'no-consent'):
                        sessions['ui-A']['running'] = state == 'busy'
                        sessions['ui-A']['_finalized'] = state == 'ended'
                        sessions['ui-A']['session_key'] = 'other' if state == 'unknown' else 'route-A'
                        config(state != 'no-consent')
                        b.cli.send(a.binding.alias, state, ephemeral=True)
                        count = a.delivery.inject(ctx)
                        self.assertEqual(count, 1 if state in ('idle', 'busy') else 0, state)
                        if not count:
                            self.assertTrue(mail(a), state)
                            a.cli.ack_inbox([m['message_id'] for m in mail(a)])
                    self.assertEqual([key for key, body in accepted], ['route-A', 'route-A'])
                    self.assertEqual(wakes, ['ui-A'])
                    config(True)
                    sessions['ui-A']['_finalized'] = False
                    sessions['ui-A']['session_key'] = 'route-A'
                    with scope('native-A', 'route-A'):
                        result = invoke_plugin_command(manager._plugin_commands['c2c-send']['handler'],
                                                       b.binding.alias + ' command-data', session_id='native-A', session_key='route-A', platform='tui')
                    self.assertIn(a.binding.alias + ' -> ' + b.binding.alias, result)
                    self.assertIn('| command-data', result)
                    self.assertEqual(len(mail(b)), 1)
                    hook('on_session_finalize')
                    self.assertFalse(a.active)
                    self.assertTrue(b.active)
                ctx._c2c_sessions.close()
                print(json.dumps({'fixture': 'real-PluginManager-native-c2c', 'acceptance': 'enqueue-and-request-context',
                                  'model_wake_proven': False, 'c2c_binary': binary, 'hermes_source': str(hermes)}))


if __name__ == '__main__':
    unittest.main(verbosity=2)
