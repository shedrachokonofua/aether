#!/usr/bin/env python3
"""Read old telemetry, preserving nanoseconds; writes are opt-in (no dependencies)."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import urllib.request

NS = 1_000_000_000
# First live (collector) TimeUnix per metrics table, measured 2026-10-13 when
# dual-write began, truncated to 10 ms so the bound never exceeds the true
# value. The backfill never emits a row at or after these. Querying
# min(TimeUnix) at runtime instead breaks resumes: once any backfilled row
# exists, the minimum is that row, and later chunks of the same window are
# silently skipped.
LIVE_T0 = {'otel_metrics_gauge': '2026-10-13T11:07:45.34Z', 'otel_metrics_sum': '2026-10-13T11:07:52.42Z',
           'otel_metrics_histogram': '2026-10-13T11:08:00.85Z', 'otel_metrics_summary': '2026-10-13T11:08:00.85Z'}
# Rows per Prometheus INSERT. One (chunk, metric) can be millions of rows (a
# 6 h chunk of kube_pod_status_phase or a Caddy bucket family); building it as
# one batch drove the backfill into the VM's OOM killer on 2026-10-29. Batches
# cut only at series boundaries, so StartTimeUnix/reset segments are unchanged.
PROM_BATCH_ROWS = 100_000
SEMCONV = '''service.name service.namespace service.instance.id service.version
host.name host.id host.arch host.type os.type os.version os.description
k8s.cluster.name k8s.namespace.name k8s.pod.name k8s.pod.uid k8s.pod.ip
k8s.container.name k8s.node.name k8s.deployment.name k8s.replicaset.name
k8s.statefulset.name k8s.daemonset.name container.name container.id
cloud.provider cloud.region cloud.availability_zone deployment.environment
deployment.environment.name telemetry.sdk.name telemetry.sdk.language
telemetry.sdk.version process.pid process.executable.name process.command_line'''.split()
REVERSE = {key.replace('.', '_'): key for key in SEMCONV}
RESOURCE = set(SEMCONV) | {'provider', 'collector', 'domain'}
UNIT_SUFFIX = {'s': 'seconds', 'By': 'bytes', 'bytes': 'bytes', '1': 'ratio'}


def prom_candidates(name, unit, monotonic, table):
    """Prometheus names a ClickHouse metric may have had, best first.

    Reverse of live-schema: dotted OTLP names become underscores, then the
    unit suffix (s->seconds, By->bytes, 1->ratio; ``{...}`` dropped), then
    ``_total`` for monotonic sums. Names already ending in ``_total``/``_count``
    (e.g. ``kestra.*.total``) must not gain a second suffix, so stripped
    variants are tried too. Histograms expand to _bucket/_count/_sum.
    """
    base = name.replace('.', '_')
    suffix = UNIT_SUFFIX.get(unit or '')
    variants = []

    def add(value):
        if value not in variants:
            variants.append(value)

    stems = [base]
    for ending in ('_total', '_count'):
        if base.endswith(ending):
            stems.append(base[:-len(ending)])
    for stem in stems:
        add(stem)
        if suffix:
            add(stem + '_' + suffix)
        add(stem + '_total')
        if suffix:
            add(stem + '_' + suffix + '_total')
    if table == 'histogram':
        expanded = []
        for variant in variants:
            expanded += [variant + '_bucket', variant + '_count', variant + '_sum']
        return expanded
    return variants


def prom_service(labels):
    """(ServiceName, ResourceAttributes, Attributes) from Prometheus labels.

    job -> ServiceName + resource service.name, except the OTLP-push form
    ``<namespace>/<name>`` where service.name is the part after ``/``;
    instance -> resource service.instance.id; otel_scope_* -> scope columns
    (handled by caller); every other label stays an Attribute verbatim.
    Resource attributes beyond that are not recoverable from Prometheus
    labels and are left empty rather than invented.
    """
    job = labels.get('job', '')
    service = labels.get('service_name') or (job.rsplit('/', 1)[-1] if job else '')
    resource = {}
    if service:
        resource['service.name'] = service
    if labels.get('service_namespace'):
        resource['service.namespace'] = labels['service_namespace']
    if labels.get('instance'):
        resource['service.instance.id'] = labels['instance']
    attributes = {k: string(v) for k, v in labels.items()
                  if k not in ('__name__', 'job', 'instance', 'otel_scope_name', 'otel_scope_version')}
    return service, resource, attributes


def timestamp(text):
    if text.isdigit():
        return int(text)
    match = re.fullmatch(r'(.*?)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)', text)
    if not match:
        raise ValueError('Use an epoch nanosecond integer or RFC3339 with timezone')
    date = dt.datetime.fromisoformat(match[1] + match[3].replace('Z', '+00:00'))
    return int(date.timestamp()) * NS + int((match[2] or '').ljust(9, '0'))


def date(ns):
    return dt.datetime.fromtimestamp(ns // NS, dt.timezone.utc).strftime('%Y-%m-%d %H:%M:%S') + f'.{ns % NS:09d}'


def string(value):
    return value if isinstance(value, str) else json.dumps(value, separators=(',', ':'), ensure_ascii=False)


def attrs(values):
    def anyvalue(v):
        if 'arrayValue' in v:
            return [anyvalue(x) for x in v['arrayValue'].get('values', [])]
        if 'kvlistValue' in v:
            return {x['key']: anyvalue(x['value']) for x in v['kvlistValue'].get('values', [])}
        return next(iter(v.values()), '')
    return {x['key']: string(anyvalue(x['value'])) for x in values or []}


def ident(value, length):
    if not value:
        return ''
    # Tempo's JSON gateway uses protobuf base64 bytes, search uses hexadecimal.
    if re.fullmatch(r'[0-9a-fA-F]{' + str(length) + '}', value):
        return value.lower()
    return base64.b64decode(value, validate=True).hex()


def logrow(labels, value):
    metadata = value[2] if len(value) > 2 else {}
    metadata = metadata.get('structuredMetadata', metadata)
    merged = {**labels, **metadata}
    resource, logs = {}, {}
    for key, val in merged.items():
        if key.startswith('__'):
            continue
        name = REVERSE.get(key, key)
        (resource if name in RESOURCE else logs)[name] = string(val)
    severity = str(merged.get('severity_text') or merged.get('detected_level') or merged.get('level') or '')
    number = int(merged.get('severity_number') or {'trace': 1, 'debug': 5, 'info': 9, 'warn': 13, 'warning': 13, 'error': 17, 'fatal': 21, 'critical': 21}.get(severity.lower(), 0))
    return {'Timestamp': date(int(value[0])), 'ServiceName': labels.get('service_name', ''),
            'Body': value[1], 'SeverityText': severity, 'SeverityNumber': number,
            'TraceId': merged.get('trace_id', ''), 'SpanId': merged.get('span_id', ''),
            'TraceFlags': int(merged.get('flags') or merged.get('trace_flags') or 0),
            'ResourceAttributes': resource, 'LogAttributes': logs,
            'ResourceSchemaUrl': merged.get('resource_schema_url', ''),
            'ScopeSchemaUrl': merged.get('scope_schema_url', ''),
            'ScopeName': merged.get('scope_name', ''), 'ScopeVersion': merged.get('scope_version', ''), 'ScopeAttributes': {}}


def tracerows(payload, tenant):
    kinds = ['Unspecified', 'Internal', 'Server', 'Client', 'Producer', 'Consumer']
    codes = ['Unset', 'Ok', 'Error']
    for batch in payload.get('batches', payload.get('resourceSpans', [])):
        resource = attrs(batch.get('resource', {}).get('attributes', []))
        if tenant != 'aether':
            existing = resource.get('service.namespace')
            if existing and existing != tenant:
                raise ValueError(f'Tenant/resource mismatch: {tenant} != {existing}')
            resource['service.namespace'] = tenant
        for group in batch.get('scopeSpans', batch.get('instrumentationLibrarySpans', [])):
            scope = group.get('scope', group.get('instrumentationLibrary', {}))
            for span in group.get('spans', []):
                start, end = int(span['startTimeUnixNano']), int(span['endTimeUnixNano'])
                kind = span.get('kind', 0)
                code = span.get('status', {}).get('code', 0)
                if isinstance(kind, str):
                    kind = ['SPAN_KIND_' + x.upper() for x in kinds].index(kind)
                if isinstance(code, str):
                    code = ['STATUS_CODE_UNSET', 'STATUS_CODE_OK', 'STATUS_CODE_ERROR'].index(code)
                events, links = span.get('events', []), span.get('links', [])
                yield start, {'Timestamp': date(start), 'TraceId': ident(span.get('traceId'), 32),
                    'SpanId': ident(span.get('spanId'), 16), 'ParentSpanId': ident(span.get('parentSpanId'), 16),
                    'TraceState': span.get('traceState', ''), 'SpanName': span.get('name', ''),
                    'SpanKind': kinds[int(kind)], 'ServiceName': resource.get('service.name', ''),
                    'ResourceAttributes': resource, 'ScopeName': scope.get('name', ''), 'ScopeVersion': scope.get('version', ''),
                    'SpanAttributes': attrs(span.get('attributes', [])), 'Duration': end - start,
                    'StatusCode': codes[int(code)], 'StatusMessage': span.get('status', {}).get('message', ''),
                    'Events.Timestamp': [date(int(x['timeUnixNano'])) for x in events],
                    'Events.Name': [x.get('name', '') for x in events],
                    'Events.Attributes': [attrs(x.get('attributes', [])) for x in events],
                    'Links.TraceId': [ident(x.get('traceId'), 32) for x in links],
                    'Links.SpanId': [ident(x.get('spanId'), 16) for x in links],
                    'Links.TraceState': [x.get('traceState', '') for x in links],
                    'Links.Attributes': [attrs(x.get('attributes', [])) for x in links]}


class Migration:
    def __init__(self, args):
        self.a = args
        self.last = 0
        self.printed = 0
        self.db = None
        if not args.dry_run:
            self.db = sqlite3.connect(args.checkpoint)
            self.db.execute('CREATE TABLE IF NOT EXISTS chunks (id TEXT PRIMARY KEY, state TEXT, payload TEXT)')
            self.db.execute('CREATE TABLE IF NOT EXISTS spans (id TEXT PRIMARY KEY)')

    def request(self, path, params=None, tenant=None, greptime=False):
        time.sleep(max(0, self.a.interval - (time.monotonic() - self.last)))
        self.last = time.monotonic()
        url = self.a.source.rstrip('/') + path + ('?' + urllib.parse.urlencode(params) if params else '?')
        headers = {'Accept': 'application/json'}
        if tenant:
            headers['X-Scope-OrgID'] = tenant
        if self.a.backend == 'loki':
            headers['X-Loki-Response-Encoding-Flags'] = 'categorize-labels'
        if greptime:
            credentials = os.environ['GREPTIME_USER'] + ':' + os.environ['GREPTIME_PASSWORD']
            headers['Authorization'] = 'Basic ' + base64.b64encode(credentials.encode()).decode()
        if self.a.ssh:
            # Enter the rootless pod network: Tempo is not published on the host.
            curl = ['curl', '-fsS', '--max-time', str(self.a.timeout)]
            for key, val in headers.items():
                curl += ['-H', key + ': ' + val]
            curl += [url]
            remote = shlex.join(curl)
            if self.a.backend == 'tempo':
                remote = 'PID=$(podman inspect monitoring-stack-infra --format "{{.State.Pid}}"); sudo nsenter -t "$PID" -n ' + remote
            raw = subprocess.check_output(['ssh', '-o', 'BatchMode=yes', self.a.ssh, remote], timeout=self.a.timeout + 20)
        else:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=self.a.timeout) as response:
                raw = response.read()
        payload = json.loads(raw)
        if payload.get('status') == 'error' or 'error' in payload:
            raise RuntimeError(string(payload))
        return payload

    def clickhouse(self, sql):
        """Read-only ClickHouse query as agent_reader (or $CLICKHOUSE_USER)."""
        time.sleep(max(0, self.a.interval - (time.monotonic() - self.last)))
        self.last = time.monotonic()
        user = os.environ.get('CLICKHOUSE_USER', 'agent_reader')
        key = {'agent_reader': 'CLICKHOUSE_AGENT_PASSWORD', 'grafana_readonly': 'CLICKHOUSE_GRAFANA_PASSWORD'}.get(user, 'CLICKHOUSE_PASSWORD')
        if not os.environ.get(key):
            # Fall back to the repo helper used for live-schema probes.
            return [json.loads(line) for line in subprocess.check_output(['/tmp/chq.sh', user], input=(sql + ' FORMAT JSONEachRow').encode()).decode().splitlines() if line.strip()]
        url = self.a.clickhouse.rstrip('/') + '?' + urllib.parse.urlencode({'query': sql + ' FORMAT JSONEachRow'})
        headers = {'X-ClickHouse-User': user, 'X-ClickHouse-Key': os.environ[key]}
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=self.a.timeout) as response:
            return [json.loads(line) for line in response.read().decode().splitlines() if line.strip()]

    def prom_map(self):
        """Runtime reverse map: Prometheus name -> ClickHouse metric target.

        Built from ClickHouse's current distinct (MetricName, table, unit,
        IsMonotonic) plus Prometheus /api/v1/metadata (type/unit/help) and the
        live Prometheus name list. No name is invented: a Prometheus series
        whose name matches no candidate is skipped and counted. The map is
        cached on self.
        """
        if hasattr(self, '_prom_map'):
            return self._prom_map
        window = getattr(self.a, 'map_hours', 24)
        specs = [('gauge', 'MetricUnit', '0', 'any(MetricDescription)'), ('sum', 'MetricUnit', 'max(toUInt8(IsMonotonic))', 'any(MetricDescription)'),
                 ('histogram', 'MetricUnit', '2', 'any(MetricDescription)'), ('summary', 'MetricUnit', '0', 'any(MetricDescription)')]
        targets = []
        for table, unit, mono, desc in specs:
            full = 'otel_metrics_' + table
            rows = self.clickhouse(f"SELECT MetricName, {unit} AS unit, {mono} AS mono, {desc} AS descr, any(ScopeName) AS scope, any(ScopeVersion) AS scopever FROM otel.{full} WHERE TimeUnix > now() - INTERVAL {window} HOUR GROUP BY MetricName, unit")
            for row in rows:
                targets.append({'table': full, 'name': row['MetricName'], 'unit': row.get('unit') or '',
                                'mono': bool(row.get('mono')), 'descr': row.get('descr') or '',
                                'scope': row.get('scope') or '', 'scopever': row.get('scopever') or ''})
        names = set(self.request('/api/v1/label/__name__/values')['data'])
        try:
            metadata = self.request('/api/v1/metadata').get('data', {})
        except Exception:
            metadata = {}
        mapping, claimed = {}, {}
        for target in targets:
            short = target['table'].split('_')[-1]
            for candidate in prom_candidates(target['name'], target['unit'], target['mono'], short):
                if candidate in names and candidate not in mapping:
                    mapping[candidate] = target
                    claimed.setdefault(target['name'], candidate)
        # Histogram families claim their three component names together.
        for target in targets:
            if target['table'] != 'otel_metrics_histogram':
                continue
            for candidate in prom_candidates(target['name'], target['unit'], target['mono'], 'histogram'):
                if candidate in names:
                    mapping[candidate] = target
        # Summary _count/_sum components share the base target.
        for target in targets:
            if target['table'] != 'otel_metrics_summary':
                continue
            for variant in prom_candidates(target['name'], target['unit'], target['mono'], 'summary'):
                for suffix in ('_count', '_sum'):
                    if variant + suffix in names:
                        mapping[variant + suffix] = target
        self._prom_map, self._prom_claimed = mapping, claimed
        self._prom_metadata = metadata
        self._prom_names = names
        unmatched = [t['name'] for t in targets if t['name'] not in claimed and t['table'] != 'otel_metrics_histogram']
        print(f'prometheus map: {len(targets)} ClickHouse metrics, {len(mapping)} Prometheus names claimed, '
              f'{len(unmatched)} ClickHouse metrics without a Prometheus counterpart (sample: {unmatched[:10]})', file=sys.stderr)
        return mapping

    def emit(self, rows, key, table):
        if self.a.dry_run:
            for row in rows:
                print(json.dumps(row, separators=(',', ':'), ensure_ascii=False))
                self.printed += 1
                if self.printed >= self.a.samples:
                    raise StopIteration
            return
        old = self.db.execute('SELECT state FROM chunks WHERE id=?', (key,)).fetchone()
        if old:
            if old[0] == 'done':
                return
            raise RuntimeError('Ambiguous earlier INSERT for ' + key + '; inspect checkpoint payload and reconcile in ClickHouse before marking done. Never blindly replay.')
        if table == 'otel_traces':
            rows = [r for r in rows if not self.db.execute('SELECT 1 FROM spans WHERE id=?', (r['TraceId'] + ':' + r['SpanId'],)).fetchone()]
        body = ''.join(json.dumps(row, separators=(',', ':'), ensure_ascii=False) + '\n' for row in rows)
        if rows:
            self.db.execute('INSERT INTO chunks VALUES (?, ?, ?)', (key, 'pending', body))
            self.db.commit()
            query = 'INSERT INTO otel.' + table + ' FORMAT JSONEachRow'
            url = self.a.clickhouse.rstrip('/') + '?' + urllib.parse.urlencode({'query': query, 'date_time_input_format': 'best_effort', 'async_insert': 0})
            headers = {'X-ClickHouse-User': 'aether', 'X-ClickHouse-Key': os.environ['CLICKHOUSE_PASSWORD']}
            with urllib.request.urlopen(urllib.request.Request(url, body.encode(), headers), timeout=self.a.timeout) as response:
                response.read()
            if table == 'otel_traces':
                self.db.executemany('INSERT OR IGNORE INTO spans VALUES (?)', ((r['TraceId'] + ':' + r['SpanId'],) for r in rows))
            self.db.execute('UPDATE chunks SET state=?, payload=? WHERE id=?', ('done', '', key))
        else:
            self.db.execute('INSERT INTO chunks VALUES (?, ?, ?)', (key, 'done', ''))
        self.db.commit()
        print(f'{key}: committed {len(rows)} rows', file=sys.stderr)

    def loki(self, start, end, key):
        try:
            payload = self.request('/loki/api/v1/query_range', {'query': self.a.selector, 'start': start, 'end': end - 1, 'limit': self.a.limit, 'direction': 'forward'})
        except urllib.error.HTTPError as error:
            # 413 = Loki's querier response exceeded its gRPC message cap (a page of
            # very large lines). Same remedy as saturation: split the window.
            if error.code != 413 or end - start <= 1:
                raise
            middle = (start + end) // 2
            self.chunk(start, middle, key + '/0')
            self.chunk(middle, end, key + '/1')
            return
        streams = payload['data']['result']
        entries = [(s['stream'], v) for s in streams for v in s['values']]
        if len(entries) >= self.a.limit:
            if end - start <= 1:
                raise RuntimeError('Loki limit saturated at one nanosecond; select individual streams or raise --limit; no rows skipped')
            # Splitting instead of last_timestamp+1 preserves all timestamp ties.
            middle = (start + end) // 2
            self.chunk(start, middle, key + '/0')
            self.chunk(middle, end, key + '/1')
            return
        self.emit([logrow(labels, value) for labels, value in sorted(entries, key=lambda x: int(x[1][0]))], key, 'otel_logs')

    def traceids(self, start, end, tenant):
        payload = self.request('/api/search', {'start': start, 'end': end, 'limit': self.a.limit}, tenant)
        traces = payload.get('traces', [])
        if len(traces) >= self.a.limit:
            if end - start <= 1:
                raise RuntimeError('Tempo search saturated in one second; raise --limit; enumeration cannot be proven complete')
            middle = (start + end) // 2
            return self.traceids(start, middle, tenant) | self.traceids(middle, end, tenant)
        return {x['traceID'] for x in traces}

    def tempo(self, start, end, key):
        for tenant in self.a.tenants.split(','):
            for traceid in sorted(self.traceids(start // NS, (end + NS - 1) // NS, tenant)):
                subkey = key + '/' + tenant + '/' + traceid
                if self.done(subkey):
                    continue
                payload = self.request('/api/traces/' + traceid, tenant=tenant)
                # Full trace retrieval can cross windows; persistent span IDs deduplicate it.
                rows = [row for ts, row in tracerows(payload, tenant) if self.a.start_ns <= ts < self.a.cutoff_ns]
                self.emit(rows, subkey, 'otel_traces')
        self.emit([], key, 'otel_traces')

    def done(self, key):
        if not self.db:
            return False
        state = self.db.execute('SELECT state FROM chunks WHERE id=?', (key,)).fetchone()
        if state and state[0] == 'pending':
            raise RuntimeError('Pending ambiguous INSERT: ' + key + '; see README reconciliation procedure')
        return state and state[0] == 'done'

    def sql(self, sql):
        result = self.request('/v1/sql', {'db': self.a.database, 'sql': sql}, greptime=True)
        records = result['output'][0]['records']
        names = [col['name'] for col in records['schema']['column_schemas']]
        return [dict(zip(names, row)) for row in records['rows']]

    def greptime(self, start, end, key):
        table = self.a.table
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', table):
            raise ValueError('Invalid table identifier')
        field = 'timestamp' if self.a.backend == 'greptime-logs' else 'greptime_timestamp'
        # A bounded range without OFFSET avoids unstable ordering of timestamp ties.
        result = self.sql(f'SELECT * FROM "{table}" WHERE "{field}" >= \'{date(start)}\' AND "{field}" < \'{date(end)}\' LIMIT {self.a.limit}')
        if len(result) >= self.a.limit:
            resolution = 1 if self.a.backend == 'greptime-logs' else 1_000_000
            if end - start <= resolution:
                raise RuntimeError('Greptime timestamp tie saturates limit; raise --limit, no data skipped')
            middle = (start + end) // 2
            self.chunk(start, middle, key + '/0')
            self.chunk(middle, end, key + '/1')
            return
        rows = []
        for record in result:
            if self.a.backend == 'greptime-logs':
                def mapping(key):
                    value = record.get(key) or {}
                    if isinstance(value, str):
                        value = json.loads(value)
                    return {k: string(v) for k, v in value.items()}
                resource = mapping('resource_attributes')
                ts = record['timestamp']
                row = {'Timestamp': date(ts) if isinstance(ts, int) else ts,
                       'ServiceName': resource.get('service.name', record.get('service_name') or ''),
                       'ResourceAttributes': resource, 'LogAttributes': mapping('log_attributes'),
                       'Body': record.get('body') or '', 'TraceId': record.get('trace_id') or '',
                       'SpanId': record.get('span_id') or '', 'TraceFlags': record.get('trace_flags') or 0,
                       'SeverityText': record.get('severity_text') or '', 'SeverityNumber': record.get('severity_number') or 0,
                       'ResourceSchemaUrl': record.get('resource_schema_url') or '',
                       'ScopeName': record.get('scope_name') or '', 'ScopeVersion': record.get('scope_version') or '',
                       'ScopeSchemaUrl': record.get('scope_schema_url') or '', 'ScopeAttributes': mapping('scope_attributes')}
            else:
                # Prometheus remote-write loses OTLP type/start-time metadata. Require an explicit inventory classification.
                attributes = {k: string(v) for k, v in record.items() if k not in ('greptime_timestamp', 'greptime_value') and v is not None}
                resource = {}
                if attributes.get('service_namespace'):
                    resource['service.namespace'] = attributes['service_namespace']
                ts = record['greptime_timestamp']
                row = {'TimeUnix': date(ts * 1_000_000) if isinstance(ts, int) else ts,
                       'StartTimeUnix': date(0), 'MetricName': table, 'Value': record['greptime_value'],
                       'ServiceName': attributes.get('service_name', attributes.get('job', '')),
                       'ResourceAttributes': resource, 'Attributes': attributes, 'ResourceSchemaUrl': '',
                       'ScopeName': '', 'ScopeVersion': '', 'ScopeAttributes': {}, 'ScopeDroppedAttrCount': 0, 'ScopeSchemaUrl': ''}
                if self.a.metric_type == 'sum':
                    row.update(AggregationTemporality=2, IsMonotonic=True)
            rows.append(row)
        target = 'otel_logs' if self.a.backend == 'greptime-logs' else 'otel_metrics_' + self.a.metric_type
        self.emit(rows, key, target)

    def prom_range(self, expr, start, end):
        """One query_range at recorded resolution (step = --step-seconds).

        Chosen over remote-read: stdlib-only (remote-read needs protobuf +
        snappy), and measured 2026-10-13 at ~1.5M samples/s from this host
        (up 1d 0.54s, node_cpu 1d 2.7s, a large _bucket family 1d 21s).
        """
        payload = self.request('/api/v1/query_range', {'query': expr, 'start': start // NS, 'end': (end - 1) // NS,
                                                        'step': f"{getattr(self.a, 'step_seconds', 30)}s"})
        return payload['data']['result']

    def prom_base(self, labels, target):
        service, resource, attributes = prom_service(labels)
        return {'ResourceAttributes': resource, 'ResourceSchemaUrl': '',
                'ScopeName': labels.get('otel_scope_name', target['scope']), 'ScopeVersion': labels.get('otel_scope_version', target['scopever']),
                'ScopeAttributes': {}, 'ScopeDroppedAttrCount': 0, 'ScopeSchemaUrl': '',
                'ServiceName': service, 'MetricName': target['name'],
                'MetricDescription': target['descr'], 'MetricUnit': target['unit'], 'Attributes': attributes}

    def prometheus(self, start, end, key):
        """Backfill one chunk [start, end) for every mapped metric.

        Cutoff per destination table is min(--cutoff, LIVE_T0[table]): no row
        at or after the table's first live write is ever emitted. Chunks are
        per (metric, window); the SQLite journal keys
        them exactly like the logs path, so a restart skips done chunks.
        Series without a ClickHouse counterpart are counted, not guessed.
        """
        mapping = self.prom_map()
        only = [x for x in self.a.metrics.split(',') if x] if getattr(self.a, 'metrics', '') else None
        # Group Prometheus names by ClickHouse target; histograms need their
        # _bucket/_count/_sum series fetched together per label set.
        groups = {}
        for prom_name, target in mapping.items():
            if only and prom_name not in only and target['name'] not in only:
                continue
            groups.setdefault((target['table'], target['name']), (target, []))[1].append(prom_name)
        skipped = 0
        for prom_name in sorted(self._prom_names):
            if prom_name not in mapping and (not only or prom_name in only):
                skipped += 1
        if skipped:
            print(f'prometheus: skipping {skipped} Prometheus series-names without a ClickHouse counterpart in this chunk scope', file=sys.stderr)
        for _group_key in sorted(groups):
            target, prom_names = groups[_group_key]
            ch_name = target['name']
            table = target['table']
            stop = min(end, timestamp(LIVE_T0[table]), self.a.cutoff_ns)
            if start >= stop:
                continue
            subkey = f'{key}/{table}/{ch_name}'
            if self.done(subkey):
                continue
            # Each batch is journaled as its own key; the metric key is marked
            # done only after every batch landed, so a restart re-derives the
            # same series-ordered batches and skips the finished ones.
            for index, rows in enumerate(self.prom_batches(target, sorted(prom_names), start, stop)):
                self.emit(rows, f'{subkey}/{index}', table)
            self.emit([], subkey, table)
        self.emit([], key, 'otel_metrics_gauge')

    def prom_batches(self, target, prom_names, start, end):
        """Yield row batches of about PROM_BATCH_ROWS, cut between series.

        Series are visited in a stable label order so a resumed run yields the
        same batches as the run that was interrupted.
        """
        table = target['table']
        if table == 'otel_metrics_histogram':
            yield from self.prom_histogram(target, prom_names, start, end)
            return
        if table == 'otel_metrics_summary':
            yield from self.prom_summary(target, prom_names, start, end)
            return
        rows = []
        for prom_name in prom_names:
            for series in sorted(self.prom_range(prom_name, start, end), key=lambda s: sorted(s['metric'].items())):
                if len(rows) >= PROM_BATCH_ROWS:
                    yield rows
                    rows = []
                labels = series['metric']
                base = self.prom_base(labels, target)
                samples = [(int(ts) * NS, float(val)) for ts, val in series['values']]
                if table == 'otel_metrics_sum' and target['mono']:
                    # Cumulative counter: StartTimeUnix = first sample of each
                    # reset segment (value drop), AggregationTemporality=2.
                    seg_start, prev = None, None
                    for ts, val in samples:
                        if seg_start is None or val < prev:
                            seg_start = ts
                        prev = val
                        row = dict(base, StartTimeUnix=date(seg_start), TimeUnix=date(ts), Value=val,
                                   Flags=0, AggregationTemporality=2, IsMonotonic=True)
                        row.update({'Exemplars.FilteredAttributes': [], 'Exemplars.TimeUnix': [], 'Exemplars.Value': [], 'Exemplars.SpanId': [], 'Exemplars.TraceId': []})
                        rows.append(row)
                elif table == 'otel_metrics_sum':
                    seg_start = samples[0][0] if samples else start
                    for ts, val in samples:
                        row = dict(base, StartTimeUnix=date(seg_start), TimeUnix=date(ts), Value=val,
                                   Flags=0, AggregationTemporality=2, IsMonotonic=False)
                        row.update({'Exemplars.FilteredAttributes': [], 'Exemplars.TimeUnix': [], 'Exemplars.Value': [], 'Exemplars.SpanId': [], 'Exemplars.TraceId': []})
                        rows.append(row)
                else:
                    for ts, val in samples:
                        row = dict(base, StartTimeUnix=date(samples[0][0] if samples else ts), TimeUnix=date(ts), Value=val, Flags=0)
                        row.update({'Exemplars.FilteredAttributes': [], 'Exemplars.TimeUnix': [], 'Exemplars.Value': [], 'Exemplars.SpanId': [], 'Exemplars.TraceId': []})
                        rows.append(row)
        if rows:
            yield rows

    def prom_histogram(self, target, prom_names, start, end):
        buckets = [n for n in prom_names if n.endswith('_bucket')]
        counts = {n for n in prom_names if n.endswith('_count')}
        sums = {n for n in prom_names if n.endswith('_sum')}
        # Index _count/_sum by (labels-without-name, timestamp).
        def indexed(names):
            out = {}
            for name in names:
                for series in self.prom_range(name, start, end):
                    labels = {k: v for k, v in series['metric'].items() if k != '__name__'}
                    for ts, val in series['values']:
                        out[(tuple(sorted(labels.items())), int(ts))] = float(val)
            return out
        count_by, sum_by = indexed(counts), indexed(sums)
        # Group bucket series by label set (minus le), then by timestamp.
        grouped = {}
        for name in buckets:
            for series in self.prom_range(name, start, end):
                labels = dict(series['metric'])
                le = labels.pop('le', None)
                if le is None:
                    continue
                group_key = tuple(sorted((k, v) for k, v in labels.items() if k != '__name__'))
                grouped.setdefault(group_key, (labels, {}))
                for ts, val in series['values']:
                    grouped[group_key][1].setdefault(int(ts), {})[le] = float(val)
        rows = []
        for group_key in sorted(grouped):
            labels, by_ts = grouped[group_key]
            if len(rows) >= PROM_BATCH_ROWS:
                yield rows
                rows = []
            base = self.prom_base(labels, target)
            seg_start, prev_count = None, None
            for ts in sorted(by_ts):
                cum = by_ts[ts]
                if '+Inf' not in cum:
                    continue
                finite = sorted(((float(k), v) for k, v in cum.items() if k != '+Inf'))
                bounds = [bound for bound, _ in finite]
                # Exporters can expose a cumulative bucket below the bucket
                # before it (Caddy histograms, off by 1, seen 2026-10-09..12),
                # which makes a per-bucket count negative and ClickHouse reject
                # the whole UInt64 BucketCounts batch. Enforce monotonic
                # cumulative counts first, as Prometheus's histogram_quantile does.
                per_bucket, prev = [], 0.0
                for bound, cumulative in finite:
                    cumulative = max(cumulative, prev)
                    per_bucket.append(int(round(cumulative - prev)))
                    prev = cumulative
                per_bucket.append(int(round(max(cum['+Inf'], prev) - prev)))
                total = count_by.get((group_key, ts), cum['+Inf'])
                if seg_start is None or total < (prev_count if prev_count is not None else total):
                    seg_start = ts * NS
                prev_count = total
                row = dict(base, StartTimeUnix=date(seg_start), TimeUnix=date(ts * NS),
                           Count=int(round(total)), Sum=sum_by.get((group_key, ts), 0.0),
                           BucketCounts=per_bucket, ExplicitBounds=bounds, Flags=0, Min=0.0, Max=0.0, AggregationTemporality=2)
                row.update({'Exemplars.FilteredAttributes': [], 'Exemplars.TimeUnix': [], 'Exemplars.Value': [], 'Exemplars.SpanId': [], 'Exemplars.TraceId': []})
                rows.append(row)
        if rows:
            yield rows

    def prom_summary(self, target, prom_names, start, end):
        # Prometheus summaries: quantile series share the base name; _count/_sum are separate names.
        base_names = [n for n in prom_names if not n.endswith(('_count', '_sum', '_bucket'))]
        counts = [n for n in prom_names if n.endswith('_count')]
        sums = [n for n in prom_names if n.endswith('_sum')]
        def indexed(names):
            out = {}
            for name in names:
                for series in self.prom_range(name, start, end):
                    labels = {k: v for k, v in series['metric'].items() if k != '__name__'}
                    for ts, val in series['values']:
                        out[(tuple(sorted(labels.items())), int(ts))] = float(val)
            return out
        count_by, sum_by = indexed(counts), indexed(sums)
        grouped = {}
        for name in base_names:
            for series in self.prom_range(name, start, end):
                labels = dict(series['metric'])
                quantile = labels.pop('quantile', None)
                if quantile is None:
                    continue
                group_key = tuple(sorted((k, v) for k, v in labels.items() if k != '__name__'))
                grouped.setdefault(group_key, (labels, {}))
                for ts, val in series['values']:
                    grouped[group_key][1].setdefault(int(ts), {})[float(quantile)] = float(val)
        rows = []
        for group_key in sorted(grouped):
            labels, by_ts = grouped[group_key]
            if len(rows) >= PROM_BATCH_ROWS:
                yield rows
                rows = []
            base = self.prom_base(labels, target)
            for ts in sorted(by_ts):
                quantiles = by_ts[ts]
                ordered = sorted(quantiles)
                row = dict(base, StartTimeUnix=date(ts * NS), TimeUnix=date(ts * NS),
                           Count=int(round(count_by.get((group_key, ts), 0))), Sum=sum_by.get((group_key, ts), 0.0), Flags=0)
                row['ValueAtQuantiles.Quantile'] = ordered
                row['ValueAtQuantiles.Value'] = [quantiles[q] for q in ordered]
                rows.append(row)
        if rows:
            yield rows

    def chunk(self, start, end, key):
        if self.done(key):
            return
        if self.a.backend == 'loki':
            self.loki(start, end, key)
        elif self.a.backend == 'tempo':
            self.tempo(start, end, key)
        elif self.a.backend == 'prometheus':
            self.prometheus(start, end, key)
        else:
            self.greptime(start, end, key)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('backend', choices=['loki', 'tempo', 'greptime-logs', 'greptime-metrics', 'prometheus'])
    parser.add_argument('--start', required=True)
    parser.add_argument('--cutoff', required=True, help='Exclusive dual-write T0')
    parser.add_argument('--source', required=True)
    parser.add_argument('--ssh', help='aether@10.0.2.3; read HTTP via SSH (Tempo enters pod network)')
    parser.add_argument('--clickhouse', default='https://clickhouse.home.shdr.ch')
    parser.add_argument('--checkpoint', default='telemetry-checkpoint.sqlite')
    parser.add_argument('--chunk-seconds', type=int, default=3600)
    parser.add_argument('--limit', type=int, default=5000)
    parser.add_argument('--interval', type=float, default=0.5)
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--selector', default='{service_name=~".+"}')
    parser.add_argument('--tenants', default='aether,seven30,assay')
    parser.add_argument('--database', default='public')
    parser.add_argument('--table', default='opentelemetry_logs')
    parser.add_argument('--metric-type', choices=['gauge', 'sum'], help='Required explicit Prometheus table classification for Greptime metrics')
    parser.add_argument('--overlap-before', help='Exclusive oldest Loki/Prometheus timestamp; REQUIRED for Greptime')
    parser.add_argument('--metrics', default='', help='Prometheus backend: comma-separated Prometheus or ClickHouse metric names to include (default all mapped)')
    parser.add_argument('--step-seconds', type=int, default=30, help='Prometheus backend: query_range step (recorded scrape resolution)')
    parser.add_argument('--map-hours', type=int, default=24, help='Prometheus backend: ClickHouse lookback window for the distinct-metric map')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--samples', type=int, default=5)
    args = parser.parse_args()
    args.start_ns, args.cutoff_ns = timestamp(args.start), timestamp(args.cutoff)
    end = args.cutoff_ns
    if args.backend.startswith('greptime'):
        if not args.overlap_before:
            parser.error('Greptime requires --overlap-before (oldest primary backend sample)')
        end = min(end, timestamp(args.overlap_before))
    if args.backend == 'greptime-metrics' and not args.metric_type:
        parser.error('Greptime metrics requires --metric-type gauge or sum; metadata was not archived')
    if args.start_ns >= end or args.limit < 2 or args.chunk_seconds < 1 or args.samples < 1 or args.interval < 0:
        parser.error('Invalid range, limit, chunk, samples or interval')
    if not args.dry_run and not os.environ.get('CLICKHOUSE_PASSWORD'):
        parser.error('CLICKHOUSE_PASSWORD required; use --dry-run for read-only operation')
    migration = Migration(args)
    # Include immutable source/range/tenant mapping identity; never reuse a cursor for another export.
    identity = hashlib.sha256(json.dumps({k: v for k, v in vars(args).items() if k not in ('dry_run', 'samples', 'interval', 'timeout', 'checkpoint')}, sort_keys=True).encode()).hexdigest()[:20]
    if migration.db:
        migration.db.execute('CREATE TABLE IF NOT EXISTS configuration (id TEXT PRIMARY KEY)')
        previous = migration.db.execute('SELECT id FROM configuration').fetchone()
        if previous and previous[0] != identity:
            parser.error('Checkpoint belongs to different source/range/limit/mapping settings; do not change them on resume')
        migration.db.execute('INSERT OR IGNORE INTO configuration VALUES (?)', (identity,))
        migration.db.commit()
    try:
        for start in range(args.start_ns, end, args.chunk_seconds * NS):
            stop = min(end, start + args.chunk_seconds * NS)
            migration.chunk(start, stop, f'{identity}/{start}/{stop}')
    except StopIteration:
        pass


if __name__ == '__main__':
    main()
