"""Synthetic NDJSON sidecars: no audio, model downloads, or network."""
import json
import sys
import time

session_id = None

def emit(kind, **fields):
    print(json.dumps(dict(v=1, type=kind, **fields)), flush=True)

for line in sys.stdin:
    msg = json.loads(line)
    kind, request = msg['type'], msg.get('id')
    if kind == 'hello':
        emit('hello_ack', id=request, protocol_version=1, engine_versions={}, models_ready=True, runtime='fixture')
    elif kind == 'ping': emit('pong', id=request)
    elif kind == 'prepare_models': emit('models_ready', id=request)
    elif kind == 'prepare_model': emit('model_ready', id=request, model=msg['model'])
    elif kind == 'list_devices':
        emit('devices', id=request, items=[dict(uid='synthetic', name='Synthetic microphone', sample_rate=48000, is_default=True)])
    elif kind == 'start_session':
        session_id = msg['session_id']
        emit('session_started', id=request, session_id=session_id, t0_epoch_ms=int(time.time()*1000))
        emit('transcript', session_id=session_id, segment=dict(idx=0, channel='me', t0=0, t1=1, text='Synthetic meeting transcript.', confidence=1, final=True, engine='fixture'))
    elif kind == 'stop_session':
        emit('session_stopped', id=request, session_id=session_id, audio=[], stats=dict(segments=1, dropped_windows=0))
    elif kind == 'enhance':
        emit('llm_token', id=request, text='Synthetic Meeting' if msg.get('options', {}).get('max_tokens') == 24 else '## Decisions\n\nShip Friday.')
        emit('llm_done', id=request, finish_reason='stop', stats=dict(prompt_tokens=10, completion_tokens=10, duration_ms=1, tokens_per_s=10))
    elif kind == 'shutdown': break
