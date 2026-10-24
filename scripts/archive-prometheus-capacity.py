#!/usr/bin/env python3
"""Archive capacity query_range results to S3; never insert into live telemetry.

Run from the Nix dev shell with AWS credentials in the environment. Export is
sequential, oldest first, at five-minute resolution. Each object is read back
and hashed before its manifest entry is accepted. Resume with the identical
source, range, destination AND --chunk-hours to read already archived objects.
Use a fresh destination when changing queries or chunking. Measure the source's
oldest retained timestamp before selecting a range; completed archives are not
extended or refreshed automatically.
"""
import argparse
import datetime as dt
import gzip
import hashlib
import json
import subprocess
import time
import urllib.parse
import urllib.request

QUERIES = {
    'node_busy_cores': 'sum by (instance) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))',
    'node_memory_available': 'node_memory_MemAvailable_bytes',
    'node_memory_total': 'node_memory_MemTotal_bytes',
    'node_pressure': '{__name__=~"node_pressure_(cpu|memory|io)_.*"}',
    'container_cpu_cores': 'rate(container_cpu_usage_seconds_total{job="kubelet-cadvisor",namespace!="",pod!="",container!="",container!="POD"}[5m])',
    'container_memory_working_set': 'container_memory_working_set_bytes{job="kubelet-cadvisor",namespace!="",pod!="",container!="",container!="POD"}',
    'container_requests': 'kube_pod_container_resource_requests',
    'container_limits': 'kube_pod_container_resource_limits',
    'node_allocatable': 'kube_node_status_allocatable',
    'pod_phase': 'kube_pod_status_phase',
    'gpu_fb_used': 'DCGM_FI_DEV_FB_USED',
    'gpu_util': 'DCGM_FI_DEV_GPU_UTIL',
    'filesystem_available': 'node_filesystem_avail_bytes{mountpoint=~"/|/var|/var/mnt/ci|/var/mnt/gpu-storage"}',
    'filesystem_size': 'node_filesystem_size_bytes{mountpoint=~"/|/var|/var/mnt/ci|/var/mnt/gpu-storage"}',
}
LOADER = """Objects are gzip-compressed original Prometheus query_range JSON, not TSDB
blocks. Values remain strings (including NaN/Inf); labels are unmodified. CPU
queries are already rates, not cumulative counters. Missing samples remain
missing. node_pressure contains the raw cumulative PSI counters. Five-minute
evaluation has Prometheus lookback/rate semantics; it is not a raw scrape dump.

Load into a separate no-TTL table, NOT the 30-day otel tables (old rows there
would expire). Example ClickHouse schema:
CREATE DATABASE IF NOT EXISTS capacity_archive;
CREATE TABLE capacity_archive.prometheus
(SampleTime DateTime64(3, 'UTC'), Query String, Labels Map(String,String), Value String)
ENGINE=MergeTree ORDER BY (Query, SampleTime);

Download objects with aws --endpoint-url <endpoint> s3 cp <uri> <file>.
Verify each compressed object's sha256 against manifest.json before loading.
For each file, use its query_id from the manifest:
python3 scripts/archive-prometheus-capacity.py rows --query-id <query_id> <file> |
  clickhouse-client --query 'INSERT INTO capacity_archive.prometheus FORMAT JSONEachRow'
The rows command only writes stdout; authentication and INSERT are operator-owned.
Load each object once; this table does not deduplicate repeated imports.
"""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def stamp(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def api(source, path, params=None):
    url = source.rstrip('/') + path
    if params:
        url += '?' + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=120) as response:
        raw = response.read(256 * 1024 * 1024 + 1)
    if len(raw) > 256 * 1024 * 1024:
        raise RuntimeError('Response exceeds 256 MiB; use a smaller --chunk-hours')
    payload = json.loads(raw)
    if payload.get('status') != 'success' or payload.get('warnings'):
        raise RuntimeError(f'Incomplete or unsuccessful response: {payload}')
    return payload


def aws(args, *command, body=None, missing_ok=False):
    result = subprocess.run(['aws', '--endpoint-url', args.endpoint, 's3', *command],
                            input=body, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        error = result.stderr.decode()
        if missing_ok and ('NoSuchKey' in error or '404' in error):
            return None
        raise RuntimeError(error)
    return result.stdout


def put_verified(args, name, body):
    uri = args.destination.rstrip('/') + '/' + name
    aws(args, 'cp', '-', uri, '--only-show-errors', body=body)
    restored = aws(args, 'cp', uri, '-', '--only-show-errors')
    if sha(restored) != sha(body):
        raise RuntimeError('Read-back checksum mismatch: ' + uri)
    return sha(body)


def export(args):
    if args.start is None or args.end is None or args.start >= args.end:
        raise ValueError('Explicit epoch-second --start and --end are required, start < end')
    if args.chunk_hours < 1:
        raise ValueError('--chunk-hours must be positive')
    manifest = {'format': 'prometheus-query-range-json-gzip-v1', 'source': args.source,
                'start': args.start, 'end_exclusive': args.end, 'start_utc': stamp(args.start),
                'end_exclusive_utc': stamp(args.end), 'step_seconds': 300,
                'queries': QUERIES, 'files': [], 'verification': 'Every object GET and SHA256 checked before manifest publication'}
    for start in range(args.start, args.end, args.chunk_hours * 3600):
        stop = min(args.end, start + args.chunk_hours * 3600)
        for query_id, query in QUERIES.items():
            name = f'{start}-{stop}/{query_id}.json.gz'
            uri = args.destination.rstrip('/') + '/' + name
            body = aws(args, 'cp', uri, '-', '--only-show-errors', missing_ok=True)
            if body is None:
                payload = api(args.source, '/api/v1/query_range',
                              {'query': query, 'start': start, 'end': stop - 1, 'step': 300})
                body = gzip.compress(json.dumps(payload, separators=(',', ':')).encode(), mtime=0)
                checksum = put_verified(args, name, body)
                time.sleep(0.5)
            else:
                checksum = sha(body)
                payload = json.loads(gzip.decompress(body))
            if payload.get('status') != 'success' or payload.get('warnings') or payload['data']['resultType'] != 'matrix':
                raise RuntimeError('Invalid archived response: ' + uri)
            series = payload['data']['result']
            rows = sum(len(item['values']) for item in series)
            times = [v[0] for item in series for v in item['values']]
            manifest['files'].append({'file': name, 'query_id': query_id, 'start': start,
                                      'end_exclusive': stop, 'series': len(series), 'rows': rows,
                                      'first_sample': min(times) if times else None,
                                      'last_sample': max(times) if times else None,
                                      'bytes': len(body), 'sha256': checksum})
            print(f'{name}: {rows} rows, {len(body)} bytes, verified', flush=True)
    manifest['rows'] = sum(item['rows'] for item in manifest['files'])
    manifest['compressed_bytes'] = sum(item['bytes'] for item in manifest['files'])
    put_verified(args, 'LOADER.txt', LOADER.encode())
    manifest['loader_sha256'] = sha(LOADER.encode())
    body = (json.dumps(manifest, indent=2) + '\n').encode()
    checksum = put_verified(args, 'manifest.json', body)
    put_verified(args, 'manifest.sha256', (checksum + '  manifest.json\n').encode())
    print(json.dumps({'destination': args.destination, 'manifest_sha256': checksum,
                      'rows': manifest['rows'], 'compressed_bytes': manifest['compressed_bytes'],
                      'files': len(manifest['files'])}, indent=2))


def rows(args):
    with gzip.open(args.file, 'rt') as source:
        payload = json.load(source)
    for series in payload['data']['result']:
        for timestamp, value in series['values']:
            moment = dt.datetime.fromtimestamp(timestamp, dt.timezone.utc)
            print(json.dumps({'SampleTime': moment.strftime('%Y-%m-%d %H:%M:%S.%f')[:-3],
                              'Query': args.query_id, 'Labels': series['metric'], 'Value': value}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    command = commands.add_parser('export')
    command.add_argument('--source', default='https://prometheus.home.shdr.ch')
    command.add_argument('--endpoint', default='https://s3.seaweed.home.shdr.ch')
    command.add_argument('--destination', required=True)
    command.add_argument('--start', type=int, required=True)
    command.add_argument('--end', type=int, required=True)
    command.add_argument('--chunk-hours', type=int, default=6)
    command = commands.add_parser('rows')
    command.add_argument('--query-id', required=True, choices=QUERIES)
    command.add_argument('file')
    args = parser.parse_args()
    (export if args.command == 'export' else rows)(args)


if __name__ == '__main__':
    main()
