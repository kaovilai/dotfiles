# DoH fallback resolver, installed as sitecustomize.py into a proxy runtime dir
# and reached through PYTHONPATH, so it only ever loads in that proxy child.
#
# A stale manual DNS server on one network service breaks the gateway name
# while everything else still works. This retries that name over DNS-over-HTTPS
# and leaves every other name alone: the system resolver answers first and
# always wins, so split-horizon and VPN names keep their real records.
#
# Knobs (the launcher pins them; all optional):
#   ENMAAS_DNS_FALLBACK_HOSTS  comma-separated allow-list; empty disables it
#   ENMAAS_DNS_DOH_URLS        comma-separated URL templates with one %s
import json
import os
import socket
import time
import urllib.request

DEFAULT_DOH = (
    'https://1.1.1.1/dns-query?name=%s&type=A',
    'https://1.0.0.1/dns-query?name=%s&type=A',
    'https://8.8.8.8/resolve?name=%s&type=A',
    'https://dns.google/resolve?name=%s&type=A',
)
MIN_TTL = 30
MAX_TTL = 300
TIMEOUT = 3.0

HOSTS = frozenset(
    host.strip().lower().rstrip('.')
    for host in (os.environ.get('ENMAAS_DNS_FALLBACK_HOSTS') or '').split(',')
    if host.strip()
)
DOH = tuple(
    url.strip() for url in (os.environ.get('ENMAAS_DNS_DOH_URLS') or ','.join(DEFAULT_DOH)).split(',')
    if url.strip()
) or DEFAULT_DOH

_cache = {}


def _lookup(host, depth=0):
    """(addresses, ttl) from the first DoH server that answers, else ([], 0)."""
    for template in DOH:
        try:
            url = template % host if '%s' in template else template
            request = urllib.request.Request(url,
                                             headers={'accept': 'application/dns-json'})
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                document = json.load(response)
        except Exception:
            continue
        if not isinstance(document, dict) or document.get('Status') not in (0, None):
            continue
        addresses, ttl, alias = [], 0, None
        for answer in document.get('Answer') or []:
            if not isinstance(answer, dict):
                continue
            try:
                ttl = max(ttl, int(answer.get('TTL') or 0))
            except (TypeError, ValueError):
                pass
            record, data = answer.get('type'), answer.get('data')
            if not isinstance(data, str):
                continue
            if record in (1, 28):
                addresses.append(data)
            elif record == 5 and alias is None:
                alias = data.rstrip('.')
        if addresses:
            return addresses, min(max(ttl, MIN_TTL), MAX_TTL)
        # Only a CNAME came back: follow it once rather than give up.
        if alias and depth < 2 and alias.lower() not in HOSTS:
            return _lookup(alias, depth + 1)
    return [], 0


def _addresses(host):
    now = time.time()
    cached = _cache.get(host)
    if cached and cached[0] > now:
        return cached[1]
    addresses, ttl = _lookup(host)
    if addresses:
        _cache[host] = (now + ttl, addresses)
    return addresses


def _results(host, port, family, socktype, proto, addresses):
    if not isinstance(port, int):
        return None
    out = []
    for address in addresses:
        af = socket.AF_INET6 if ':' in address else socket.AF_INET
        if family not in (0, af):
            continue
        sockaddr = (address, port, 0, 0) if af == socket.AF_INET6 else (address, port)
        for stype in ({0, socktype} if socktype else {0}):
            for pro in ({0, proto} if proto else {0}):
                out.append((af, stype, pro, '', sockaddr))
    return out or None


try:
    _real_getaddrinfo = socket.getaddrinfo

    def getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
        try:
            return _real_getaddrinfo(host, port, family, type, proto, flags)
        except socket.gaierror:
            name = host.decode('idna', 'ignore') if isinstance(host, bytes) else host
            if not HOSTS or not isinstance(name, str):
                raise
            key = name.lower().rstrip('.')
            if key not in HOSTS:
                raise
            found = _results(key, port, family, type, proto, _addresses(key))
            if not found:
                raise
            return found

    socket.getaddrinfo = getaddrinfo
except Exception:
    pass
