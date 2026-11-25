"""Local PTP supervisor. Audio arrives as interleaved 44.1 kHz stereo PCM16 on stdin."""
import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import ctypes
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import select
import shlex
import signal
import socket
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

PINNED_SHA256 = 'de19cc204837640301061a088459ed72e2aa10a352c9040f9e26f9dbb10f7c3a'
ENDPOINT_CACHE = Path.home() / 'Library' / 'Caches' / 'local.roomaudio.discovery' / 'airplay-endpoints'
START_LEAD_MS = 6500
SONOS_START_LEAD_MS = 4500
CONNECT_RETRY_DELAY = .75
CONNECT_RETRY_WINDOW = 4
stop_requested = False


class Stop(Exception):
    pass


def clock_exists():
    libc = ctypes.CDLL(None, use_errno=True)
    fd = libc.shm_open(b'/cliairplay-ptp', os.O_RDONLY)
    if fd >= 0:
        os.close(fd)
        return True
    code = ctypes.get_errno()
    if code == errno.ENOENT:
        return False
    raise OSError(code, os.strerror(code))


def publish(status, **fields):
    print(json.dumps({'status': status, **fields}, ensure_ascii=False), flush=True)


def resolve_bonjour(name):
    browse = subprocess.Popen(['/usr/bin/dns-sd', '-L', name, '_airplay._tcp', 'local.'],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    pending = b''
    endpoint = None
    try:
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            readable, _, _ = select.select([browse.stdout], [], [], max(0, deadline - time.monotonic()))
            if not readable:
                break
            chunk = os.read(browse.stdout.fileno(), 4096)
            if not chunk:
                break
            lines = (pending + chunk).split(b'\n')
            pending = lines.pop()
            for raw in lines:
                line = raw.decode(errors='replace')
                match = re.search(r'can be reached at (\S+):(\d+)', line)
                if match:
                    endpoint = match
                if endpoint and 'features=' in line:
                    fields = dict(re.findall(r'\b(features|flags|model|manufacturer|acl|protovers|srcvers|deviceid)=([^\s]+)', line))
                    if 'features' not in fields:
                        continue
                    identity = device_id(fields.pop('deviceid', ''))
                    return (socket.gethostbyname(endpoint[1]), int(endpoint[2]),
                            ' '.join(f'{key}={value}' for key, value in fields.items()), identity)
    finally:
        if browse.poll() is None:
            browse.terminate()
        try:
            browse.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            browse.kill()
            browse.communicate()
    raise RuntimeError(f'Не удалось определить адрес {name}')


def device_id(value):
    if not isinstance(value, str):
        return None
    value = value.replace(':', '').replace('-', '').lower()
    return value if re.fullmatch(r'[0-9a-f]{12}', value) else None


def airplay_identity(host, port):
    with socket.create_connection((host, port), timeout=.45) as connection:
        connection.sendall(b'GET /info RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: AirPlay/550.10\r\n\r\n')
        with connection.makefile('rb') as reply:
            if not reply.readline(1024).startswith(b'RTSP/1.0 200 '):
                return None
            size = 0
            for _ in range(32):
                line = reply.readline(2048)
                if line == b'\r\n':
                    if not 0 < size <= 262144:
                        return None
                    info = plistlib.loads(reply.read(size))
                    return device_id(info.get('deviceID')) if isinstance(info, dict) else None
                key, _, value = line.partition(b':')
                if key.lower() == b'content-length':
                    size = int(value)
            return None


def route_context(host):
    route = subprocess.check_output(['/sbin/route', '-n', 'get', host], text=True, stderr=subprocess.DEVNULL)
    interface = re.search(r'^\s*interface:\s+(\S+)', route, re.M)
    if not interface:
        raise RuntimeError('Сетевой интерфейс для AirPlay не найден')
    address = subprocess.check_output(['/usr/sbin/ipconfig', 'getifaddr', interface[1]], text=True).strip()
    gateway = re.search(r'^\s*gateway:\s+(\S+)', route, re.M)
    return [interface[1], address, gateway[1] if gateway else None]


def resolve(name):
    cache = ENDPOINT_CACHE / (hashlib.sha256(name.encode()).hexdigest() + '.json')
    try:
        entry = json.loads(cache.read_text())
        host, port, txt, identity = (entry[key] for key in ('host', 'port', 'txt', 'identity'))
        socket.inet_pton(socket.AF_INET, host)
        if (type(port) is int and 0 < port <= 65535 and isinstance(txt, str) and device_id(identity) == identity
            and identity and route_context(host) == entry['network'] and airplay_identity(host, port) == identity):
            return host, port, txt
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError, plistlib.InvalidFileException):
        pass

    host, port, txt, identity = resolve_bonjour(name)
    if identity:
        try:
            entry = dict(host=host, port=port, txt=txt, identity=identity, network=route_context(host))
            ENDPOINT_CACHE.mkdir(parents=True, mode=0o700, exist_ok=True)
            fd, temporary = tempfile.mkstemp(dir=ENDPOINT_CACHE)
            try:
                with os.fdopen(fd, 'w') as file:
                    json.dump(entry, file)
                os.replace(temporary, cache)
            finally:
                Path(temporary).unlink(missing_ok=True)
        except (OSError, RuntimeError, subprocess.SubprocessError):
            pass
    return host, port, txt


def start_lead(endpoints):
    # Measured with the native Sonos One and Amp on a shared PTP timeline.
    for _, _, txt in endpoints:
        fields = dict(field.split('=', 1) for field in txt.casefold().split() if '=' in field)
        if fields.get('manufacturer') != 'sonos' or fields.get('model') not in ('one', 'amp'):
            return START_LEAD_MS
    return SONOS_START_LEAD_MS


def command(session, value):
    with os.fdopen(os.open(session['fifo'], os.O_WRONLY | os.O_NONBLOCK), 'w') as pipe:
        pipe.write(value)


def sonos_transport_value(host, action, field):
    namespace = 'urn:schemas-upnp-org:service:AVTransport:1'
    content = ('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
               f'<s:Body><u:{action} xmlns:u="{namespace}">'
               f'<InstanceID>0</InstanceID></u:{action}></s:Body></s:Envelope>')
    request = Request(f'http://{host}:1400/MediaRenderer/AVTransport/Control', data=content.encode(),
                      headers={'Content-Type': 'text/xml; charset="utf-8"',
                               'SOAPACTION': f'"{namespace}#{action}"'})
    with urlopen(request, timeout=1.5) as reply:
        root = ET.fromstring(reply.read())
    return next((node.text for node in root.iter() if node.tag.rsplit('}', 1)[-1] == field), None)


def sonos_transport_state(host):
    return sonos_transport_value(host, 'GetTransportInfo', 'CurrentTransportState')


def sonos_block(host, state):
    if not state:
        return 'unknown', 'не удалось проверить, свободна ли Sonos'
    try:
        uri = (sonos_transport_value(host, 'GetMediaInfo', 'CurrentURI') or '').lower()
    except (OSError, ValueError, ET.ParseError):
        uri = ''
    if uri.startswith('x-sonos-htastream:'):
        return 'tv', 'занят ТВ-вход'
    if ':airplay:' in uri:
        return 'airplay', 'занята другим потоком AirPlay'
    if state == 'PAUSED_PLAYBACK':
        return 'paused', 'другой источник на паузе'
    return 'other', 'занята другим источником'


def check_sonos(host):
    try:
        state = sonos_transport_state(host)
    except (OSError, ValueError, ET.ParseError):
        state = None
    if state in ('STOPPED', 'NO_MEDIA_PRESENT'):
        return None
    return sonos_block(host, state)


def open_session(binary, endpoint, address, rate, volume, folder, label):
    host, port, txt = endpoint
    fifo, log = (folder / f'{label}.{extension}' for extension in ('fifo', 'log'))
    argv = [str(binary), '--protocol', 'airplay2', '--timing', 'ptp', '--ptp-shared',
            '--buffered', '--if', address, '--port', str(port), '--volume', str(volume),
            '--samplerate', str(rate), '--txt', txt, '--cmdpipe', str(fifo), host]
    with log.open('w') as sink:
        child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=sink, stderr=subprocess.STDOUT)
    fd = child.stdin.fileno()
    os.set_blocking(fd, False)
    return dict(child=child, fifo=fifo, log=log.open(), fd=fd, queue=bytearray(), tail='', statuses=[],
                diagnostics=deque(maxlen=8))


def join_position(anchor, sample_rate, received_bytes, now_ms):
    # The next receiver must queue the same source frame that the existing
    # receivers will render at its scheduled start.
    first_frame = max(math.ceil(received_bytes / 4), math.ceil((now_ms + 5500 - anchor) * sample_rate / 1000))
    return first_frame * 4, anchor + round(first_frame * 1000 / sample_rate)


def request_session_stop(session):
    child = session['child']
    if child.poll() is None:
        try:
            command(session, 'ACTION=STOP\n')
        except OSError:
            child.terminate()


def close_session(session):
    child = session['child']
    request_session_stop(session)
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
    child.stdin.close()
    session['log'].close()


def start_clock(binary, address, stop, heartbeat):
    # The root-owned launchd job is installed once through macOS authorization.
    manifest = Path('/Library/LaunchDaemons/local.roomaudio.ptp.plist')
    if manifest.exists() and manifest.stat().st_uid == 0:
        publish('managed_clock')
        return subprocess.Popen([str(binary.with_name('PTPService')), '--connect', address],
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    supervisor = f'''
set -eu
[ ! -e {shlex.quote(str(stop))} ] || exit 0
stage=$(/usr/bin/mktemp -d /private/tmp/room-audio-clock.XXXXXXXX)
child=
trap 'if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi; /bin/rm -f "$stage/cliairplay"; /bin/rmdir "$stage"' EXIT
trap 'exit 1' HUP INT TERM
/bin/cp {shlex.quote(str(binary))} "$stage/cliairplay"
actual=$(/usr/bin/shasum -a 256 "$stage/cliairplay")
[ "${{actual%% *}}" = {PINNED_SHA256} ] || exit 1
/bin/chmod 700 "$stage/cliairplay"
/usr/bin/sudo -n -- "$stage/cliairplay" --ptp-daemon --if {shlex.quote(address)} >/dev/null 2>&1 &
child=$!
while kill -0 "$child" 2>/dev/null && [ ! -e {shlex.quote(str(stop))} ]; do
  modified=$(/usr/bin/stat -f %m {shlex.quote(str(heartbeat))} 2>/dev/null) || break
  [ "$(( $(/bin/date +%s) - modified ))" -lt 15 ] || break
  /bin/sleep 0.5
done
'''
    script = '''on run argv
do shell script (item 1 of argv) with prompt "Room Audio: allow the AirPlay PTP clock until streaming stops." with administrator privileges
end run'''
    publish('authorization')
    return subprocess.Popen(['/usr/bin/osascript', '-e', script, supervisor],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


def wait_for_clock(daemon, heartbeat, parent):
    deadline = time.monotonic() + 120
    while not clock_exists():
        heartbeat.touch()
        if daemon.poll() is not None:
            raise RuntimeError('Не удалось запустить PTP: ' + daemon.stderr.read().strip())
        if stop_requested or os.getppid() != parent:
            raise Stop()
        if time.monotonic() >= deadline:
            raise RuntimeError('Истекло время подтверждения PTP')
        time.sleep(.15)


def stop_clock(daemon, stop):
    stop.touch()
    if daemon is None:
        return
    try:
        daemon.communicate(timeout=4)
    except subprocess.TimeoutExpired:
        daemon.terminate()
        daemon.communicate(timeout=3)


def main(args):
    binary = Path(args.transport).resolve()
    if hashlib.sha256(binary.read_bytes()).hexdigest() != PINNED_SHA256:
        raise RuntimeError('Контрольная сумма AirPlay-передатчика не совпадает')
    if args.check:
        if clock_exists():
            print('An AirPlay PTP clock is already running')
        publish('checked')
        return
    names = args.receivers
    with ThreadPoolExecutor(max_workers=min(8, len(names))) as resolvers:
        endpoints = dict(zip(names, resolvers.map(resolve, names)))
    interfaces = set()
    for host, _, _ in endpoints.values():
        route = subprocess.check_output(['/sbin/route', '-n', 'get', host], text=True)
        interface = re.search(r'^\s*interface:\s+(\S+)', route, re.M)
        if not interface:
            raise RuntimeError('Сетевой интерфейс для AirPlay не найден')
        interfaces.add(interface[1])
    if len(interfaces) != 1:
        raise RuntimeError('AirPlay-устройства доступны через разные интерфейсы')
    address = subprocess.check_output(['/usr/sbin/ipconfig', 'getifaddr', interfaces.pop()], text=True).strip()
    if args.use_shared_clock:
        if args.clock_address != address:
            raise RuntimeError('Выход доступен через другой сетевой интерфейс PTP')
        if not clock_exists():
            raise RuntimeError('Общий PTP-процесс недоступен')
    elif clock_exists():
        raise RuntimeError('Общий PTP-процесс уже запущен')
    if not args.clock_only:
        volume_file = Path(args.volumes)
        volumes = json.loads(volume_file.read_text())

    sessions = {}
    retiring = {}
    joining = ThreadPoolExecutor(max_workers=2)
    daemon = None
    parent = os.getppid()
    with tempfile.TemporaryDirectory(prefix='room-audio-') as directory:
        folder = Path(directory)
        stop = folder / 'stop'
        heartbeat = folder / 'heartbeat'
        heartbeat.touch(mode=0o600)
        try:
            if not args.use_shared_clock:
                daemon = start_clock(binary, address, stop, heartbeat)
                wait_for_clock(daemon, heartbeat, parent)
            if args.clock_only:
                publish('clock_ready', address=address)
                while clock_exists() and daemon.poll() is None:
                    if stop_requested:
                        raise Stop()
                    heartbeat.touch()
                    if select.select([0], [], [], 0.5)[0] and not os.read(0, 1024):
                        raise Stop()
                raise RuntimeError('PTP-процесс завершился')

            skipped = {}
            tv_skips = set()
            failed_receivers = set()
            for index, (name, (host, port, txt)) in enumerate(endpoints.items()):
                if name not in volumes:
                    publish('receiver_stopped', receiver=name)
                    continue
                if args.protect_sonos and 'manufacturer=sonos' in txt.casefold().split():
                    block = check_sonos(host)
                    if block:
                        category, reason = block
                        if category != 'tv' or name not in args.override_tv:
                            skipped[name] = reason
                            if category == 'tv':
                                tv_skips.add(name)
                            publish('receiver_skipped', receiver=name, message=reason, category=category)
                            continue
                sessions[name] = open_session(binary, endpoints[name], address, args.sample_rate, volumes[name], folder, str(index))
                publish('connecting', receiver=name)

            if not sessions and skipped:
                raise RuntimeError(' · '.join(f'{name}: {reason}' for name, reason in skipped.items()))

            os.set_blocking(0, False)
            anchor = None
            connected = set()
            playing = set()
            deadline = time.monotonic() + 60
            capture_requested = False
            next_heartbeat = 0
            next_volume = 0
            received = 0
            seen_joins = set()
            probes = {}
            pending_connects = {}
            retried = set()

            def retire(name, failure=None):
                session = sessions.pop(name)
                try:
                    request_session_stop(session)
                except ProcessLookupError:
                    pass
                retiring[name] = (session, time.monotonic() + 3, failure)
                connected.discard(name)
                playing.discard(name)

            def fail_receiver(name, reason):
                diagnostic = ' | '.join(sessions[name]['diagnostics'])
                failed_receivers.add(name)
                publish('receiver_failed', receiver=name, message=reason, diagnostic=diagnostic)
                retire(name)
                if not sessions and not pending_connects:
                    raise RuntimeError(f'{name}: {reason}')

            while True:
                if stop_requested:
                    raise Stop()
                for name, (session, expires, failure) in list(retiring.items()):
                    child = session['child']
                    if child.poll() is None:
                        if time.monotonic() >= expires:
                            child.kill()
                        continue
                    close_session(session)
                    del retiring[name]
                    if failure:
                        if session.get('recovering'):
                            failed_receivers.add(name)
                            publish('receiver_failed', receiver=name, message=failure,
                                    diagnostic=' | '.join(session['diagnostics']))
                        else:
                            tv_skips.add(name)
                            publish('receiver_skipped', receiver=name, message=failure, category='tv')
                    else:
                        publish('receiver_stopped', receiver=name)
                if daemon is not None and time.monotonic() >= next_heartbeat:
                    heartbeat.touch()
                    next_heartbeat = time.monotonic() + 1
                if (daemon is not None and daemon.poll() is not None) or not clock_exists():
                    raise RuntimeError('PTP-процесс завершился')
                if time.monotonic() >= next_volume:
                    new_volumes = json.loads(volume_file.read_text())
                    for name, (retry_at, retry_until) in list(pending_connects.items()):
                        if name not in new_volumes:
                            del pending_connects[name]
                            publish('receiver_stopped', receiver=name)
                            continue
                        now = time.monotonic()
                        if now < retry_at:
                            continue
                        del pending_connects[name]
                        host, _, txt = endpoints[name]
                        if args.protect_sonos and 'manufacturer=sonos' in txt.casefold().split():
                            block = check_sonos(host)
                            if block and block[0] == 'unknown' and now < retry_until:
                                pending_connects[name] = (min(now + .4, retry_until), retry_until)
                                continue
                            if block and (block[0] != 'tv' or name not in args.override_tv):
                                category, reason = block
                                if category == 'tv':
                                    tv_skips.add(name)
                                publish('receiver_skipped', receiver=name, message=reason, category=category)
                                if not sessions and not pending_connects:
                                    raise RuntimeError(f'{name}: {reason}')
                                continue
                        try:
                            sessions[name] = open_session(binary, endpoints[name], address, args.sample_rate,
                                                          new_volumes[name], folder, f'retry-{names.index(name)}')
                        except OSError as error:
                            failed_receivers.add(name)
                            publish('receiver_failed', receiver=name, message='не удалось открыть AirPlay', diagnostic=str(error))
                            if not sessions and not pending_connects:
                                raise
                            continue
                        volumes[name] = new_volumes[name]
                        publish('connecting', receiver=name)
                    if args.tv_join_file and deadline is None:
                        requests = json.loads(Path(args.tv_join_file).read_text())
                        for name, token in requests.items():
                            if token in seen_joins:
                                continue
                            if name in retiring:
                                continue
                            seen_joins.add(token)
                            recovering = token.startswith('recover:')
                            eligible = failed_receivers if recovering else tv_skips
                            if name in eligible and name in new_volumes and name not in sessions:
                                probes[name] = (joining.submit(check_sonos, endpoints[name][0]), recovering)
                            else:
                                publish('receiver_skipped', receiver=name, message='недоступна для подключения', category='unknown')
                    for name, (future, recovering) in list(probes.items()):
                        if not future.done():
                            continue
                        del probes[name]
                        if name not in new_volumes:
                            continue
                        block = future.result()
                        if block and (recovering or block[0] != 'tv'):
                            if recovering and block[0] != 'tv':
                                publish('receiver_failed', receiver=name, message=block[1])
                            else:
                                if block[0] == 'tv':
                                    failed_receivers.discard(name)
                                    tv_skips.add(name)
                                else:
                                    tv_skips.discard(name)
                                publish('receiver_skipped', receiver=name, message=block[1], category=block[0])
                            continue
                        try:
                            fresh = open_session(binary, endpoints[name], address, args.sample_rate,
                                                 new_volumes[name], folder, f'join-{len(seen_joins)}-{names.index(name)}')
                        except OSError as exc:
                            if recovering:
                                publish('receiver_failed', receiver=name, message='не удалось заново открыть AirPlay', diagnostic=str(exc))
                            else:
                                publish('receiver_skipped', receiver=name, message=str(exc), category='tv')
                            continue
                        fresh['late'] = {'deadline': time.monotonic() + 16}
                        fresh['recovering'] = recovering
                        sessions[name] = fresh
                        volumes[name] = new_volumes[name]
                        tv_skips.discard(name)
                        failed_receivers.discard(name)
                        publish('connecting', receiver=name)
                    for name in list(sessions):
                        if name not in new_volumes:
                            retire(name)
                    if not sessions and not pending_connects:
                        raise Stop()
                    for name, session in sessions.items():
                        if name in connected and new_volumes[name] != volumes[name]:
                            command(session, f'VOLUME={new_volumes[name]}\n')
                            volumes[name] = new_volumes[name]
                    next_volume = time.monotonic() + .2
                for name, s in list(sessions.items()):
                    text = s['tail'] + s['log'].read()
                    lines = text.split('\n')
                    s['tail'] = lines.pop()
                    for line in lines:
                        if re.search(r'\b(error|failed|failure|refused|timeout|timed out|stalled)\b', line, re.I):
                            s['diagnostics'].append(line[:350])
                        if line.startswith(('[STATUS] connected', '[STATUS] audio buffered',
                                            '[STATUS] started ', '[STATUS] error')) or (
                            line.startswith('[STATUS] clock_ready ') and ('state=ready' in line or 'state=stalled' in line)
                        ):
                            s['statuses'].append(line)
                    late = s.get('late')
                    exited = s['child'].poll() is not None
                    if exited and not late:
                        if s.get('joined'):
                            retire(name, 'подключённая колонка отключилась')
                            continue
                        confirmed = name in connected or any(line.startswith('[STATUS] connected') for line in s['statuses'])
                        if (not confirmed and name not in retried and
                            any('error code=connect_failed http=0' in line for line in s['statuses'])):
                            retried.add(name)
                            close_session(s)
                            del sessions[name]
                            now = time.monotonic()
                            pending_connects[name] = (now + CONNECT_RETRY_DELAY, now + CONNECT_RETRY_WINDOW)
                            publish('receiver_retry', receiver=name, diagnostic=' | '.join(s['diagnostics']))
                            continue
                        reason = ('соединение AirPlay прервалось' if confirmed
                                  else 'не удалось подключиться по AirPlay')
                        fail_receiver(name, reason)
                        continue
                    statuses = '\n'.join(s['statuses'])
                    ready = 'state=ready' in statuses
                    stalled = 'state=stalled' in statuses and not ready
                    if late:
                        if '[STATUS] connected' in statuses and 'offset' not in late:
                            late['offset'], late['start'] = join_position(anchor, args.sample_rate, received, int(time.time() * 1000))
                            connected.add(name)
                            publish('connected', receiver=name)
                        if any(line.startswith('[STATUS] playing ') for line in lines):
                            late['playing'] = True
                        ack = re.search(r'^\[STATUS\] started .*?\bat_unix_ms=(\d+)', statuses, re.M)
                        if (exited or stalled or time.monotonic() >= late['deadline'] or
                            (ack and int(ack[1]) != late.get('start'))):
                            retire(name, 'не удалось подключиться синхронно')
                            continue
                        if 'start' in late and '[STATUS] audio buffered_ms=' in statuses and not late.get('sent'):
                            try:
                                command(s, f'TITLE=Room Audio\nSTART_JOIN=1\nSTART_UNIX_MS={late["start"]}\nACTION=START\n')
                            except OSError:
                                retire(name, 'не удалось запустить синхронную передачу')
                                continue
                            late['sent'] = True
                        if ack and ready and late.get('playing'):
                            del s['late']
                            s['joined'] = True
                            playing.add(name)
                            publish('playing', receiver=name)
                        else:
                            continue
                    if '[STATUS] connected' in statuses and name not in connected:
                        connected.add(name)
                        publish('connected', receiver=name)
                    if stalled:
                        fail_receiver(name, 'не удалось синхронизировать часы AirPlay')
                        continue
                    if any(line.startswith('[STATUS] playing ') for line in lines) and name not in playing:
                        playing.add(name)
                        publish('playing', receiver=name)
                if sessions and not pending_connects and len(connected) == len(sessions) and not capture_requested:
                    publish('capture')
                    capture_requested = True
                if capture_requested and anchor is None and all(any('[STATUS] audio buffered_ms=' in line for line in s['statuses']) for s in sessions.values()):
                    anchor = int(time.time() * 1000) + start_lead(endpoints[name] for name in sessions)
                    for name, s in list(sessions.items()):
                        try:
                            command(s, f'TITLE=Room Audio\nSTART_UNIX_MS={anchor}\nACTION=START\n')
                        except OSError:
                            fail_receiver(name, 'не удалось запустить передачу AirPlay')
                clocks_ready = all(any('state=ready' in line for line in s['statuses']) for s in sessions.values())
                if anchor and len(playing) == len(sessions) and clocks_ready and deadline is not None:
                    starts = [re.search(r'^\[STATUS\] started .*?\bat_unix_ms=(\d+)', '\n'.join(s['statuses']), re.M) for s in sessions.values()]
                    if all(starts) and all(int(match[1]) == anchor for match in starts):
                        publish('streaming', anchor=str(anchor))
                        deadline = None
                    elif all(starts):
                        raise RuntimeError('AirPlay-устройства подтвердили разное время старта')
                if deadline is not None and time.monotonic() >= deadline:
                    raise RuntimeError('Истекло время запуска AirPlay')
                read, writes, _ = select.select([0], [s['fd'] for s in sessions.values() if s['queue']], [], .08)
                if read:
                    chunk = os.read(0, 16384)
                    if not chunk:
                        raise Stop()
                    for name, s in list(sessions.items()):
                        late = s.get('late')
                        if late:
                            if 'offset' in late:
                                begin = max(0, late['offset'] - received)
                                s['queue'].extend(chunk[begin:])
                        else:
                            s['queue'].extend(chunk)
                        if len(s['queue']) > args.sample_rate * 4 * 6:
                            if late or s.get('joined'):
                                retire(name, 'переполнилась очередь звука')
                            else:
                                fail_receiver(name, 'переполнилась очередь звука')
                    received += len(chunk)
                for name, s in list(sessions.items()):
                    if s['fd'] in writes:
                        try:
                            del s['queue'][:os.write(s['fd'], s['queue'])]
                        except BlockingIOError:
                            pass
                        except BrokenPipeError:
                            if s.get('late') or s.get('joined'):
                                retire(name, 'AirPlay-сессия закрылась')
                            else:
                                fail_receiver(name, 'AirPlay-сессия закрылась')
        finally:
            try:
                for session in sessions.values():
                    close_session(session)
                for session, _, _ in retiring.values():
                    close_session(session)
            finally:
                if daemon is not None:
                    stop_clock(daemon, stop)
                joining.shutdown(wait=False, cancel_futures=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--transport', required=True)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--clock-only', action='store_true')
    parser.add_argument('--use-shared-clock', action='store_true')
    parser.add_argument('--clock-address')
    parser.add_argument('--protect-sonos', action='store_true')
    parser.add_argument('--override-tv', action='append', default=[])
    parser.add_argument('--tv-join-file')
    parser.add_argument('--volumes')
    parser.add_argument('--sample-rate', type=int, choices=(44100, 48000), default=44100)
    parser.add_argument('receivers', nargs='*')
    args = parser.parse_args()
    if not args.check and (not args.receivers or (not args.clock_only and not args.volumes)):
        parser.error('receiver names and a volume file are required')
    if args.override_tv and (not args.protect_sonos or not set(args.override_tv).issubset(args.receivers)):
        parser.error('TV override requires a protected, named receiver')

    def stop(*_):
        # A signal can arrive while subprocess holds its waitpid lock.
        # Unwind from the main loop at a point where cleanup can reap children.
        global stop_requested
        stop_requested = True

    signal.signal(signal.SIGTERM, stop)
    try:
        main(args)
    except Stop:
        publish('stopped')
    except Exception as exc:
        publish('error', message=str(exc))
        raise SystemExit(1)
