"""Read-only mitmproxy addon. Never dumps flows, prompts, auth, cookies or outputs.
Only explicit Codex thread/turn metadata can associate a server model with a task.
"""
import asyncio, json, os, re, time
from mitmproxy import ctx

ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$')
MODEL = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$')
HOSTS = {'chatgpt.com', 'api.openai.com'}
EVENTS = {'response.created', 'response.completed', 'response.incomplete', 'response.failed', 'response.metadata'}

def object_value(value):
    if isinstance(value, dict): return value
    if isinstance(value, str) and len(value) < 65536:
        try:
            parsed = json.loads(value)
            if isinstance(parsed, dict): return parsed
        except (ValueError, TypeError): pass
    return {}

def association(headers=None, payload=None):
    candidates = []
    if headers:
        candidates.append(object_value(headers.get('x-codex-turn-metadata', '')))
    if payload:
        meta = object_value(payload.get('client_metadata'))
        candidates += [meta, object_value(meta.get('x-codex-turn-metadata'))]
    pairs = set()
    for metadata in candidates:
        thread = metadata.get('thread_id') or metadata.get('session_id')
        turn = metadata.get('turn_id')
        if isinstance(thread, str) and isinstance(turn, str) and ID.fullmatch(thread) and ID.fullmatch(turn): pairs.add((thread, turn))
    return next(iter(pairs)) if len(pairs) == 1 else None

def eligible(flow):
    return flow.request.host in HOSTS and flow.request.path.split('?', 1)[0] in {'/backend-api/codex/responses', '/v1/responses'}

class Models:
    def load(self, loader):
        loader.add_option('lens_output', str, '', 'Private metadata-only JSONL destination')
        loader.add_option('lens_owner_pid', int, 0, 'Owning Model Lens process')
        self.states = {}
        self.total = 0
        self.owner_task = None
    def running(self):
        owner = ctx.options.lens_owner_pid
        if owner > 1:
            async def watch_owner():
                while True:
                    await asyncio.sleep(2)
                    try: os.kill(owner, 0)
                    except ProcessLookupError:
                        ctx.master.shutdown()
                        return
                    except PermissionError:
                        ctx.master.shutdown()
                        return
            self.owner_task = asyncio.create_task(watch_owner())
    def done(self):
        if self.owner_task: self.owner_task.cancel()
    def request(self, flow):
        if not eligible(flow): return
        if len(self.states) >= 128: return
        payload = object_value(flow.request.get_text(strict=False)) if len(flow.request.raw_content or b'') <= 16*1024*1024 else {}
        self.states[flow.id] = {'pair': association(flow.request.headers, payload), 'buffer': b'', 'ws': False, 'seen': set(), 'first_ws': True}
        # Avoid retaining raw request bodies after this hook; mitmproxy owns the live
        # forwarding buffers, our state contains ONLY the explicit IDs above.
    def responseheaders(self, flow):
        state = self.states.get(flow.id)
        if not state: return
        if flow.response.status_code == 101:
            state['ws'] = True
            return
        if 200 <= flow.response.status_code < 300:
            self.emit(state, {'type': 'response.metadata', 'headers': dict((k, v) for k, v in flow.response.headers.items() if k.lower() in {'openai-model','x-openai-model'})})
        if 'text/event-stream' in flow.response.headers.get('content-type',''):
            def stream(chunk):
                self.sse(state, chunk)
                return chunk  # byte-for-byte pass-through
            flow.response.stream = stream
    def sse(self, state, chunk):
        state['buffer'] += chunk
        if len(state['buffer']) > 2*1024*1024:
            state['buffer'] = b''
            return
        while b'\n\n' in state['buffer'] or b'\r\n\r\n' in state['buffer']:
            split = b'\r\n\r\n' if b'\r\n\r\n' in state['buffer'] else b'\n\n'
            frame, state['buffer'] = state['buffer'].split(split, 1)
            data = b'\n'.join(line[5:].lstrip() for line in frame.splitlines() if line.startswith(b'data:'))
            try: self.emit(state, json.loads(data))
            except (ValueError, TypeError): pass
    def websocket_message(self, flow):
        state = self.states.get(flow.id)
        if not state or not flow.websocket: return
        message = flow.websocket.messages[-1]
        flow.websocket.messages[:] = [message]  # bounded metadata observer; no transcript history
        if len(message.content) > 2*1024*1024: return
        try: obj = json.loads(message.content)
        except (ValueError, TypeError): return
        if not isinstance(obj, dict): return
        if message.from_client and obj.get('type') == 'response.create':
            # A new turn must identify itself. Do not inherit a previous turn's ID.
            pair = association(payload=obj)
            if state['first_ws'] and pair is None: pair = state['pair']
            state['first_ws'] = False
            if state.get('pending'): state['pair'] = None
            else: state['pair'] = pair
            state['pending'] = True
            state['seen'] = set()
        elif not message.from_client:
            self.emit(state, obj)
            if obj.get('type') in {'response.completed','response.failed','response.incomplete'}: state['pending'] = False
        # The addon never changes a message or its delivery order.
    def emit(self, state, obj):
        if not isinstance(obj, dict) or obj.get('type') not in EVENTS or not state.get('pair'): return
        response = object_value(obj.get('response'))
        response_id = response.get('id')
        if response_id is not None and (not isinstance(response_id,str) or not response_id.startswith('resp_') or len(response_id)>200): return
        incoming = object_value(obj.get('headers')) or object_value(response.get('headers'))
        headers = {k.lower():v for k,v in incoming.items() if k.lower() in {'openai-model','x-openai-model'} and isinstance(v,str) and MODEL.fullmatch(v)}
        model = response.get('model')
        if not isinstance(model, str) or not MODEL.fullmatch(model): model = None
        if not model and not headers: return
        if model and not response_id: return
        thread, turn = state['pair']
        signature = (turn, response_id, model, tuple(sorted(headers.items())))
        if signature in state['seen'] or len(state['seen']) >= 32: return
        state['seen'].add(signature)
        out = {'type':obj['type'], 'thread_id':thread, 'turn_id':turn, 'timestamp':time.time(), 'headers':headers}
        if response_id: out['response'] = {'id':response_id}
        if model: out['response']['model'] = model
        path = ctx.options.lens_output
        if not path or self.total >= 200000: return
        descriptor = os.open(path, os.O_WRONLY|os.O_APPEND|os.O_CREAT|os.O_NOFOLLOW, 0o600)
        try:
            os.write(descriptor, (json.dumps(out,separators=(',',':'))+'\n').encode())
            self.total += 1
        finally: os.close(descriptor)
    def response(self, flow):
        state = self.states.get(flow.id)
        if state and not state['ws']:
            if not flow.response.stream and len(flow.response.raw_content or b'') <= 2*1024*1024:
                try: self.emit(state, flow.response.json())
                except (ValueError, TypeError): pass
            self.states.pop(flow.id,None)
    def websocket_end(self, flow): self.states.pop(flow.id,None)
    def error(self, flow): self.states.pop(flow.id,None)

addons = [Models()]
