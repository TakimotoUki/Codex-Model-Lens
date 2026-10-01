#!/usr/bin/env python3
"""Offline tests: use stub flows only; no credentials, network or inference."""
import importlib.util,json,pathlib,tempfile,types,sys,unittest
sys.dont_write_bytecode=True
ctx=types.SimpleNamespace(options=types.SimpleNamespace(lens_output=''))
sys.modules['mitmproxy']=types.SimpleNamespace(ctx=ctx)
spec=importlib.util.spec_from_file_location('capture',pathlib.Path(__file__).resolve().parents[1]/'Resources/NetworkCapture/model_capture.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class CaptureTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();ctx.options.lens_output=str(pathlib.Path(self.temp.name)/'models.jsonl');self.addon=m.Models();self.addon.load(types.SimpleNamespace(add_option=lambda *a:None))
 def tearDown(self):self.temp.cleanup()
 def state(self):return {'pair':('task-1','turn-1'),'buffer':b'','seen':set(),'first_ws':True,'pending':False,'ws':True}
 def rows(self):
  p=pathlib.Path(ctx.options.lens_output);return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []
 def test_request_metadata_not_prompt_and_conflicts_rejected(self):
  self.assertIsNone(m.association(payload={'input':{'thread_id':'task-1','turn_id':'turn-1'}}))
  self.assertEqual(m.association(payload={'client_metadata':{'thread_id':'task-1','turn_id':'turn-1'}}),('task-1','turn-1'))
  self.assertIsNone(m.association({'x-codex-turn-metadata':'{"thread_id":"other","turn_id":"turn-1"}'},{'client_metadata':{'thread_id':'task-1','turn_id':'turn-1'}}))
 def test_server_response_projection_and_body_privacy(self):
  obj={'type':'response.created','response':{'id':'resp_1','model':'gpt-6.1-sol','output':'PRIVATE_BODY','encrypted_content':'PRIVATE_SECRET'}}
  self.addon.emit(self.state(),obj);rows=self.rows();self.assertEqual(rows[0]['response'],{'id':'resp_1','model':'gpt-6.1-sol'});self.assertNotIn('PRIVATE',json.dumps(rows))
 def test_sse_split_stream_and_duplicates(self):
  state=self.state();raw=b'data: {"type":"response.completed","response":{"id":"resp_1","model":"gpt-6-astra"}}\n\n'
  self.addon.sse(state,raw[:12]);self.addon.sse(state,raw[12:]);self.addon.sse(state,raw);self.assertEqual(len(self.rows()),1)
 def test_client_websocket_model_is_never_evidence(self):
  flow=types.SimpleNamespace(id='1',websocket=types.SimpleNamespace(messages=[]));self.addon.states['1']=self.state()
  for from_client,obj in [(True,{'type':'response.create','model':'gpt-6-astra','client_metadata':{'thread_id':'task-1','turn_id':'turn-2'}}),(False,{'type':'response.created','response':{'id':'resp_1','model':'gpt-5.6-luna'}})]:
   flow.websocket.messages.append(types.SimpleNamespace(from_client=from_client,content=json.dumps(obj).encode()));self.addon.websocket_message(flow)
  self.assertEqual(self.rows()[0]['response']['model'],'gpt-5.6-luna');self.assertEqual(self.rows()[0]['turn_id'],'turn-2');self.assertEqual(len(flow.websocket.messages),1)
 def test_next_turn_missing_identity_does_not_inherit(self):
  flow=types.SimpleNamespace(id='1',websocket=types.SimpleNamespace(messages=[]));state=self.state();state['first_ws']=False;self.addon.states['1']=state
  for client,obj in [(True,{'type':'response.create','model':'fake'}),(False,{'type':'response.created','response':{'id':'resp_2','model':'gpt-5.6-luna'}})]:
   flow.websocket.messages.append(types.SimpleNamespace(from_client=client,content=json.dumps(obj).encode()));self.addon.websocket_message(flow)
  self.assertEqual(self.rows(),[])
 def test_header_evidence_with_explicit_identity(self):
  self.addon.emit(self.state(),{'type':'response.metadata','headers':{'OpenAI-Model':'gpt-6-astra','Authorization':'PRIVATE'}})
  self.assertEqual(self.rows()[0]['headers'],{'openai-model':'gpt-6-astra'})
 def test_metadata_limits_are_bounded(self):
  state=self.state()
  for i in range(100):self.addon.emit(state,{'type':'response.created','response':{'id':'resp_'+str(i),'model':'gpt-6-astra'}})
  self.assertEqual(len(state['seen']),32);self.assertEqual(len(self.rows()),32)
  self.addon.states={str(i):self.state() for i in range(128)}
  flow=types.SimpleNamespace(id='overflow',request=types.SimpleNamespace(host='chatgpt.com',path='/backend-api/codex/responses'))
  self.addon.request(flow);self.assertEqual(len(self.addon.states),128)
if __name__=='__main__':unittest.main()
