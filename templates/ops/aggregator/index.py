"""Weekly ops-reports aggregator (schema_version 1).

Collects per-cluster, per-region summary.json objects from the hub bucket, renders
index.html, rollup.html, and report-YYYY-MM-DD.html (Monday of the ISO
week), and optionally emails an HTML digest with that report name as the
visible link.

Period is the ISO week of the Wednesday digest (YYYY-Www). Sunday
eks_node_upgrade producers write the next Wednesday's ISO week so they
land in the same prefix as that week's infra_upgrade / volume_backup.
"""
from __future__ import annotations

import html
import json
import logging
import os
import re
from datetime import date, datetime, timezone
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET = os.environ['OPS_REPORTS_BUCKET']
EXPECTED_KEY = os.environ.get('EXPECTED_PRODUCERS_KEY', 'config/expected-producers.json')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
DIGEST_FROM_ADDRESS = os.environ.get('DIGEST_FROM_ADDRESS', '')
DIGEST_TO_ADDRESS = os.environ.get('DIGEST_TO_ADDRESS', '')
PRESIGN_TTL = int(os.environ.get('PRESIGN_TTL_SECONDS', '604800'))
PRESIGN_SECRET_ARN = os.environ.get('PRESIGN_SECRET_ARN', '')
REPORT_TYPES = ('infra_upgrade', 'volume_backup', 'eks_node_upgrade')
REQUIRED_FIELDS = (
    'schema_version',
    'client',
    'account_id',
    'cluster',
    'report_type',
    'generated_at',
    'period',
    'status',
)
VALID_STATUSES = ('ok', 'fail', 'warn')
STATUS_RANK = {'fail': 0, 'invalid': 0, 'warn': 1, 'missing': 2, 'ok': 3}
PERIOD_RE = re.compile(r'^\d{4}-W\d{2}$')


class ExpectedProducersError(Exception):
    pass


s3 = boto3.client('s3')
sns = boto3.client('sns')
ses = boto3.client('ses')
secretsmanager = boto3.client('secretsmanager')

_presign_s3 = None


def current_iso_week(now=None):
    now = now or datetime.now(timezone.utc)
    year, week, _ = now.isocalendar()
    return f'{year}-W{week:02d}'


def valid_iso_week_period(period):
    if not PERIOD_RE.fullmatch(period):
        return False
    year_s, week_s = period.split('-W')
    try:
        date.fromisocalendar(int(year_s), int(week_s), 1)
    except ValueError:
        return False
    return True


def presign_ttl_label():
    if PRESIGN_TTL % 86400 == 0:
        days = PRESIGN_TTL // 86400
        return f'{days} day' if days == 1 else f'{days} days'
    if PRESIGN_TTL % 3600 == 0:
        hours = PRESIGN_TTL // 3600
        return f'{hours} hour' if hours == 1 else f'{hours} hours'
    return f'{PRESIGN_TTL} seconds'


def period_monday(period):
    year_s, week_s = period.split('-W')
    return date.fromisocalendar(int(year_s), int(week_s), 1)


def report_label(period):
    return f'report-{period_monday(period).isoformat()}'


def report_html_name(period):
    return f'{report_label(period)}.html'


def _list_keys(prefix):
    keys = []
    token = None
    while True:
        kwargs = {'Bucket': BUCKET, 'Prefix': prefix}
        if token:
            kwargs['ContinuationToken'] = token
        response = s3.list_objects_v2(**kwargs)
        for item in response.get('Contents', []):
            keys.append(item['Key'])
        if not response.get('IsTruncated'):
            break
        token = response.get('NextContinuationToken')
    return keys


def _get_json(key):
    body = s3.get_object(Bucket=BUCKET, Key=key)['Body'].read()
    return json.loads(body)


def load_expected():
    try:
        data = _get_json(EXPECTED_KEY)
    except ClientError as exc:
        raise ExpectedProducersError(f'Could not load {EXPECTED_KEY}: {exc}') from exc
    except (TypeError, ValueError) as exc:
        raise ExpectedProducersError(f'Invalid expected producers JSON: {exc}') from exc
    if not isinstance(data, dict):
        raise ExpectedProducersError(f'{EXPECTED_KEY} must be a JSON object')
    entries = data.get('producers')
    if not isinstance(entries, list) or not entries:
        raise ExpectedProducersError(f'{EXPECTED_KEY} has no producers list')
    producers = []
    report_types = data.get('report_types') or list(REPORT_TYPES)
    if not isinstance(report_types, list) or not report_types:
        report_types = list(REPORT_TYPES)
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        client = entry.get('client')
        cluster = entry.get('cluster')
        region = (entry.get('region') or '').strip()
        if not client or not cluster:
            continue
        if not region:
            logger.warning('Skipping producer without region: %s/%s', client, cluster)
            continue
        for report_type in report_types:
            producers.append({
                'client': client,
                'cluster': cluster,
                'region': region,
                'account_id': entry.get('account_id', ''),
                'report_type': report_type,
            })
    if not producers:
        raise ExpectedProducersError(f'{EXPECTED_KEY} has no usable producer entries')
    return producers


def validate_summary(payload, period, client, cluster, region, report_type):
    if not isinstance(payload, dict):
        return 'not a JSON object'
    missing = [field for field in REQUIRED_FIELDS if field not in payload]
    if missing:
        return f'missing fields: {", ".join(missing)}'
    if payload.get('schema_version') != 1:
        return f'schema_version {payload.get("schema_version")!r} is not 1'
    if payload.get('status') not in VALID_STATUSES:
        return f'status {payload.get("status")!r} is not ok/fail/warn'
    if payload.get('period') != period:
        return f'period {payload.get("period")!r} does not match key period {period}'
    if payload.get('client') != client:
        return f'client {payload.get("client")!r} does not match key'
    if payload.get('cluster') != cluster:
        return f'cluster {payload.get("cluster")!r} does not match key'
    payload_region = payload.get('region') or ''
    if region and payload_region != region:
        return f'region {payload_region!r} does not match key'
    if payload.get('report_type') != report_type:
        return f'report_type {payload.get("report_type")!r} does not match key'
    if payload.get('items') is not None and not isinstance(payload.get('items'), list):
        return 'items must be a list'
    if payload.get('counts') is not None and not isinstance(payload.get('counts'), dict):
        return 'counts must be an object'
    return None


def _row_from_payload(client, cluster, region, report_type, key, payload, error):
    if error:
        return {
            'client': client,
            'cluster': cluster,
            'region': region,
            'report_type': report_type,
            'status': 'invalid',
            'error': error,
            'key': key,
            'summary': payload if isinstance(payload, dict) else {},
        }
    return {
        'client': client,
        'cluster': cluster,
        'region': region or payload.get('region', ''),
        'account_id': payload.get('account_id', ''),
        'report_type': report_type,
        'status': payload['status'],
        'error': None,
        'key': key,
        'summary': payload,
    }


def collect_reports(period, expected):
    found = {}
    legacy = {}
    prefix = f'{period}/'
    for key in _list_keys(prefix):
        if key.endswith('.html') or not key.endswith('.json'):
            continue
        parts = key.split('/')
        # Preferred: {period}/{client}/{cluster}/{region}/{report_type}.json
        # Legacy:    {period}/{client}/{cluster}/{report_type}.json
        if len(parts) == 5:
            _, client, cluster, region, filename = parts
        elif len(parts) == 4:
            _, client, cluster, filename = parts
            region = ''
        else:
            logger.warning('Skipping unexpected key %s', key)
            continue
        report_type = filename[:-5]
        try:
            payload = _get_json(key)
            error = validate_summary(payload, period, client, cluster, region, report_type)
        except (ClientError, TypeError, ValueError) as exc:
            payload = {}
            error = str(exc)
        row = _row_from_payload(client, cluster, region, report_type, key, payload, error)
        if region:
            found[(client, cluster, region, report_type)] = row
        else:
            legacy[(client, cluster, report_type)] = row

    expected_counts = {}
    expected_triples = set()
    for entry in expected:
        triple = (entry['client'], entry['cluster'], entry['report_type'])
        expected_triples.add(triple)
        expected_counts[triple] = expected_counts.get(triple, 0) + 1

    reports = list(found.values())
    seen = set(found)
    consumed_legacy = set()
    for entry in expected:
        region = entry['region']
        identity = (entry['client'], entry['cluster'], region, entry['report_type'])
        if identity in seen:
            continue
        triple = (entry['client'], entry['cluster'], entry['report_type'])
        if expected_counts.get(triple) == 1 and triple in legacy:
            row = dict(legacy[triple])
            row['region'] = region
            reports.append(row)
            consumed_legacy.add(triple)
            continue
        reports.append({
            'client': entry['client'],
            'cluster': entry['cluster'],
            'region': region,
            'account_id': entry.get('account_id', ''),
            'report_type': entry['report_type'],
            'status': 'missing',
            'error': 'producer did not upload summary.json for this period',
            'key': (
                f'{period}/{entry["client"]}/{entry["cluster"]}/'
                f'{region}/{entry["report_type"]}.json'
            ),
            'summary': {},
        })
    for triple, row in legacy.items():
        if triple in consumed_legacy or triple in expected_triples:
            continue
        reports.append(row)
    reports.sort(key=lambda row: (
        STATUS_RANK.get(row['status'], 9),
        row['client'],
        row['cluster'],
        row.get('region', ''),
        row['report_type'],
    ))
    return reports


def _counts(reports):
    totals = {'fail': 0, 'invalid': 0, 'warn': 0, 'missing': 0, 'ok': 0}
    for row in reports:
        totals[row['status']] = totals.get(row['status'], 0) + 1
    return totals


def _items(summary):
    items = summary.get('items') or []
    return [item for item in items if isinstance(item, dict)]


def render_html(period, reports, generated_at):
    totals = _counts(reports)
    action_n = totals['fail'] + totals['invalid'] + totals['warn'] + totals['missing']
    rows = []
    for row in reports:
        summary = row['summary']
        items = _items(summary)
        detail_bits = []
        if row['error']:
            detail_bits.append(row['error'])
        for item in items:
            name = item.get('name', '')
            detail = item.get('detail', '')
            item_status = item.get('status', '')
            line = ' '.join(part for part in (name, item_status, detail) if part)
            if line:
                detail_bits.append(line)
        if not detail_bits and summary.get('counts'):
            detail_bits.append(json.dumps(summary['counts'], sort_keys=True))
        detail = html.escape(' | '.join(detail_bits) or '—')
        status = html.escape(row['status'])
        rows.append(
            '<tr class="s-{status}">'
            '<td>{client}</td><td>{cluster}</td><td>{region}</td><td>{report}</td>'
            '<td class="st">{status}</td><td>{detail}</td>'
            '</tr>'.format(
                status=status,
                client=html.escape(row['client']),
                cluster=html.escape(row['cluster']),
                region=html.escape(row.get('region') or ''),
                report=html.escape(row['report_type']),
                detail=detail,
            )
        )

    headline = (
        f'{action_n} action item(s)' if action_n else 'All expected reports are ok'
    )
    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Weekly ops reports {html.escape(period)}</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 24px; color: #1a1a1a; }}
h1 {{ font-size: 1.4rem; margin: 0 0 8px; }}
.meta {{ color: #555; margin-bottom: 16px; }}
.pill {{ display: inline-block; margin-right: 8px; padding: 2px 8px; border-radius: 999px; font-size: 0.85rem; }}
.fail, .s-fail td.st, .s-invalid td.st {{ background: #fde8e8; }}
.warn, .s-warn td.st {{ background: #fff4d6; }}
.missing, .s-missing td.st {{ background: #e8e8e8; }}
.ok, .s-ok td.st {{ background: #e7f6ec; }}
table {{ border-collapse: collapse; width: 100%; }}
th, td {{ border-bottom: 1px solid #ddd; text-align: left; padding: 8px; vertical-align: top; }}
th {{ background: #f5f5f5; }}
</style>
</head>
<body>
<h1>Weekly ops reports {html.escape(period)}</h1>
<p class="meta">Generated {html.escape(generated_at)}. {html.escape(headline)}.</p>
<p>
<span class="pill fail">fail {totals['fail']}</span>
<span class="pill fail">invalid {totals['invalid']}</span>
<span class="pill warn">warn {totals['warn']}</span>
<span class="pill missing">missing {totals['missing']}</span>
<span class="pill ok">ok {totals['ok']}</span>
</p>
<table>
<thead><tr><th>Client</th><th>Cluster</th><th>Region</th><th>Report</th><th>Status</th><th>Detail</th></tr></thead>
<tbody>
{''.join(rows)}
</tbody>
</table>
</body>
</html>
"""
    return page


def action_lines(reports):
    lines = []
    for row in reports:
        if row['status'] == 'ok':
            continue
        region = row.get('region') or ''
        location = f"{row['client']}/{row['cluster']}" + (f"/{region}" if region else '')
        prefix = f"{row['status'].upper()} {location} {row['report_type']}"
        if row['error']:
            lines.append(f"{prefix}: {row['error']}")
            continue
        items = _items(row['summary'])
        if not items:
            lines.append(prefix)
            continue
        added = False
        for item in items:
            if item.get('status') == 'ok':
                continue
            detail = item.get('detail') or item.get('name') or ''
            name = item.get('name', '')
            lines.append(f"{prefix}: {name} {detail}".strip())
            added = True
        if not added:
            lines.append(prefix)
    return lines


def put_html(period, body, filename):
    key = f'{period}/{filename}'
    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=body.encode('utf-8'),
        ContentType='text/html; charset=utf-8',
        ServerSideEncryption='AES256',
    )
    return key


def presign_s3_client():
    global _presign_s3
    if _presign_s3 is not None:
        return _presign_s3
    if not PRESIGN_SECRET_ARN:
        logger.warning('PRESIGN_SECRET_ARN unset; presign uses Lambda execution credentials')
        _presign_s3 = s3
        return _presign_s3
    raw = secretsmanager.get_secret_value(SecretId=PRESIGN_SECRET_ARN)['SecretString']
    creds = json.loads(raw)
    access_key_id = creds.get('access_key_id') or creds.get('AccessKeyId')
    secret_access_key = creds.get('secret_access_key') or creds.get('SecretAccessKey')
    if not access_key_id or not secret_access_key:
        raise ValueError('presigner secret missing access_key_id/secret_access_key')
    _presign_s3 = boto3.client(
        's3',
        aws_access_key_id=access_key_id,
        aws_secret_access_key=secret_access_key,
    )
    return _presign_s3


def presign(key):
    return presign_s3_client().generate_presigned_url(
        'get_object',
        Params={'Bucket': BUCKET, 'Key': key},
        ExpiresIn=PRESIGN_TTL,
    )


def digest_subject(period, reports):
    totals = _counts(reports)
    action_n = totals['fail'] + totals['invalid'] + totals['warn'] + totals['missing']
    if action_n:
        return (
            f'Weekly ops reports {period}: {totals["fail"]} fail, '
            f'{totals["invalid"]} invalid, '
            f'{totals["warn"]} warn, {totals["missing"]} missing'
        )
    return f'Weekly ops reports {period}: all ok'


def digest_text_body(period, reports, label, url):
    totals = _counts(reports)
    lines = [
        f'Weekly ops reports {period}',
        f'fail={totals["fail"]} invalid={totals["invalid"]} warn={totals["warn"]} '
        f'missing={totals["missing"]} ok={totals["ok"]}',
        '',
    ]
    action = action_lines(reports)
    if action:
        lines.append('Action items:')
        lines.extend(f'  - {line}' for line in action)
        lines.append('')
    else:
        lines.append('No action items.')
        lines.append('')
    lines.append(f'HTML report (presigned, {presign_ttl_label()}): {label}')
    lines.append(url)
    return '\n'.join(lines)


def digest_html_body(period, reports, label, url):
    totals = _counts(reports)
    parts = [
        f'<p>Weekly ops reports {html.escape(period)}</p>',
        '<p>'
        f'fail={totals["fail"]} invalid={totals["invalid"]} warn={totals["warn"]} '
        f'missing={totals["missing"]} ok={totals["ok"]}'
        '</p>',
    ]
    action = action_lines(reports)
    if action:
        parts.append('<p>Action items:</p><ul>')
        parts.extend(f'<li>{html.escape(line)}</li>' for line in action)
        parts.append('</ul>')
    else:
        parts.append('<p>No action items.</p>')
    href = html.escape(url, quote=True)
    parts.append(
        f'<p>HTML report (presigned, {presign_ttl_label()}): '
        f'<a href="{href}">{html.escape(label)}</a></p>'
    )
    return ''.join(parts)


def send_digest(period, reports, report_key):
    label = report_label(period)
    url = presign(report_key)
    subject = digest_subject(period, reports)
    text_body = digest_text_body(period, reports, label, url)
    if DIGEST_FROM_ADDRESS and DIGEST_TO_ADDRESS:
        ses.send_email(
            Source=DIGEST_FROM_ADDRESS,
            Destination={'ToAddresses': [DIGEST_TO_ADDRESS]},
            Message={
                'Subject': {'Data': subject[:100], 'Charset': 'UTF-8'},
                'Body': {
                    'Text': {'Data': text_body, 'Charset': 'UTF-8'},
                    'Html': {
                        'Data': digest_html_body(period, reports, label, url),
                        'Charset': 'UTF-8',
                    },
                },
            },
        )
        logger.info('Published digest via SES: %s (%s)', subject, label)
        return
    if not SNS_TOPIC_ARN:
        logger.warning('No SES or SNS digest destination; skip digest email')
        return
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=text_body)
    logger.info('Published digest via SNS: %s (%s)', subject, label)


def _period_from_s3_key(key):
    period = key.split('/')[0] if key else ''
    if not valid_iso_week_period(period):
        logger.warning('Ignoring S3 key with invalid ISO-week prefix: %s', key)
        return current_iso_week(), False
    return period, False


def period_from_event(event):
    if event.get('period'):
        return event['period'], bool(event.get('send_digest', False))
    if event.get('source') == 'aws.events' or event.get('detail-type') == 'Scheduled Event':
        return current_iso_week(), True
    if event.get('source') == 'aws.s3':
        key = unquote_plus(event.get('detail', {}).get('object', {}).get('key', ''))
        return _period_from_s3_key(key)
    records = event.get('Records') or []
    if records and records[0].get('s3'):
        key = unquote_plus(records[0]['s3']['object']['key'])
        return _period_from_s3_key(key)
    return current_iso_week(), bool(event.get('send_digest', False))


def handler(event, context):
    event = event or {}
    period, send = period_from_event(event)
    logger.info('Aggregating period %s send_digest=%s', period, send)
    try:
        expected = load_expected()
        config_error = None
    except ExpectedProducersError as exc:
        logger.error('%s', exc)
        expected = []
        config_error = str(exc)
    reports = collect_reports(period, expected)
    if config_error:
        reports.insert(0, {
            'client': 'hub',
            'cluster': 'config',
            'region': '',
            'report_type': 'expected_producers',
            'status': 'invalid',
            'error': config_error,
            'key': EXPECTED_KEY,
            'summary': {},
        })
    generated_at = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    page = render_html(period, reports, generated_at)
    report_key = put_html(period, page, report_html_name(period))
    put_html(period, page, 'index.html')
    put_html(period, page, 'rollup.html')
    if send:
        send_digest(period, reports, report_key)
    totals = _counts(reports)
    return {
        'statusCode': 200,
        'period': period,
        'indexKey': report_key,
        'counts': totals,
        'digestSent': send,
    }
