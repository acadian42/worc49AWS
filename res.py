from datetime import datetime, timezone, timedelta
from logging import Logger
from statistics import mean, median
from typing import Any, Dict, Optional
from collections import Counter
import re

from crowdstrike.foundry.function import Function, Request, Response, APIError
from falconpy import Alerts, MessageCenter

FUNC = Function.instance()


@FUNC.handler(method="POST", path="/monthly-kpis")
def monthly_kpis(
    request: Request,
    _config: Optional[Dict[str, Any]],
    logger: Logger
) -> Response:
    try:
        raw_body = request.body or {}
        body = raw_body if isinstance(raw_body, dict) else {}

        def parse_ts(value):
            try:
                if value is None:
                    return None

                if isinstance(value, datetime):
                    return value.astimezone(timezone.utc) if value.tzinfo else value.replace(tzinfo=timezone.utc)

                if isinstance(value, (int, float)):
                    value = float(value)
                    while value > 9999999999:
                        value = value / 1000
                    return datetime.fromtimestamp(value, tz=timezone.utc)

                value = str(value).strip()
                if not value:
                    return None

                if value.isdigit():
                    value = float(value)
                    while value > 9999999999:
                        value = value / 1000
                    return datetime.fromtimestamp(value, tz=timezone.utc)

                if value.endswith("Z"):
                    value = value[:-1] + "+00:00"

                match = re.match(r"^(.*?\.\d{6})\d+([+-]\d{2}:\d{2})$", value)
                if match:
                    value = match.group(1) + match.group(2)

                dt = datetime.fromisoformat(value)
                return dt.astimezone(timezone.utc) if dt.tzinfo else dt.replace(tzinfo=timezone.utc)

            except Exception:
                return None

        def falcon_ts(value):
            return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        def month_window():
            report_month = body.get("report_month")

            if report_month:
                year, month = str(report_month).split("-")
                start_dt = datetime(int(year), int(month), 1, tzinfo=timezone.utc)
            else:
                now = datetime.now(timezone.utc)
                first_this_month = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
                last_prev_month = first_this_month - timedelta(days=1)
                start_dt = last_prev_month.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

            if start_dt.month == 12:
                end_dt = start_dt.replace(year=start_dt.year + 1, month=1)
            else:
                end_dt = start_dt.replace(month=start_dt.month + 1)

            return start_dt.strftime("%Y-%m"), falcon_ts(start_dt), falcon_ts(end_dt), start_dt, end_dt

        def get_value(record, key):
            if not isinstance(record, dict):
                return None

            if key in record:
                return record.get(key)

            current = record
            for part in str(key).split("."):
                if not isinstance(current, dict) or part not in current:
                    return None
                current = current.get(part)

            return current

        def first_value(record, keys):
            for key in keys:
                value = get_value(record, key)
                if value is not None and str(value).strip() != "":
                    return value
            return None

        def first_ts(record, keys):
            for key in keys:
                value = parse_ts(get_value(record, key))
                if value:
                    return value
            return None

        def seconds_between(start_dt, end_dt):
            if not start_dt and not end_dt:
                return None, "missing_start_and_end"
            if not start_dt:
                return None, "missing_start"
            if not end_dt:
                return None, "missing_end"

            seconds = (end_dt - start_dt).total_seconds()

            if seconds < 0:
                return None, "negative_duration"

            return seconds, None

        def in_window(value, start_dt, end_dt):
            return bool(value and start_dt <= value < end_dt)

        def summarize(values):
            values = sorted(values)

            if not values:
                return {
                    "count": 0,
                    "mean_minutes": None,
                    "median_minutes": None,
                    "p90_minutes": None,
                    "mean_hours": None,
                    "median_hours": None,
                    "p90_hours": None
                }

            p90_index = int(round((len(values) - 1) * 0.90))

            return {
                "count": len(values),
                "mean_minutes": round(mean(values) / 60, 2),
                "median_minutes": round(median(values) / 60, 2),
                "p90_minutes": round(values[p90_index] / 60, 2),
                "mean_hours": round(mean(values) / 3600, 2),
                "median_hours": round(median(values) / 3600, 2),
                "p90_hours": round(values[p90_index] / 3600, 2)
            }

        def ok_body(response, label):
            if not isinstance(response, dict) or response.get("status_code") not in [200, 201, 202]:
                raise RuntimeError(f"{label} API error: {response}")
            return response.get("body", {}) or {}

        def chunks(items, size):
            for index in range(0, len(items), size):
                yield items[index:index + size]

        def tokens(value):
            return set(re.findall(r"[a-z0-9]+", str(value).lower()))

        def status_category(raw_status):
            raw = str(raw_status or "").strip()
            if not raw:
                return "missing"

            exact_terminal = set(
                str(item).strip().lower()
                for item in body.get("terminal_statuses", [
                    "closed",
                    "resolved",
                    "remediated",
                    "completed",
                    "complete",
                    "done"
                ])
            )

            exact_nonterminal = set(
                str(item).strip().lower()
                for item in body.get("nonterminal_statuses", [
                    "new",
                    "open",
                    "opened",
                    "in progress",
                    "investigating",
                    "awaiting customer",
                    "awaiting response",
                    "pending",
                    "reopened"
                ])
            )

            terminal_tokens = set(
                str(item).strip().lower()
                for item in body.get("terminal_status_tokens", [
                    "closed",
                    "resolved",
                    "remediated",
                    "completed",
                    "complete",
                    "done"
                ])
            )

            nonterminal_tokens = set(
                str(item).strip().lower()
                for item in body.get("nonterminal_status_tokens", [
                    "new",
                    "open",
                    "opened",
                    "progress",
                    "investigating",
                    "investigation",
                    "awaiting",
                    "pending",
                    "reopened",
                    "triage",
                    "triaged"
                ])
            )

            normalized = raw.lower()
            token_set = tokens(raw)

            if normalized in exact_terminal:
                return "terminal"
            if normalized in exact_nonterminal:
                return "not_terminal"
            if token_set.intersection(terminal_tokens):
                return "terminal"
            if token_set.intersection(nonterminal_tokens):
                return "not_terminal"

            return "unknown"

        def counter_list(counter, limit=20):
            return [
                {"value": key, "count": value}
                for key, value in counter.most_common(limit)
            ]

        def process_alerts(start, end):
            client = Alerts()
            after = None
            values = []
            reasons = Counter()
            count = 0
            page_count = 0

            fql = body.get("alert_filter") or f"created_timestamp:>='{start}'+created_timestamp:<'{end}'"

            if body.get("alert_filter_extra"):
                fql = f"{fql}+{body['alert_filter_extra']}"

            while True:
                page_count += 1

                args = {
                    "filter": fql,
                    "sort": body.get("alert_sort", "created_timestamp|asc"),
                    "limit": min(int(body.get("alert_limit", 1000)), 1000)
                }

                if after:
                    args["after"] = after

                response_body = ok_body(client.get_alerts_combined(**args), "Alerts get_alerts_combined")
                records = response_body.get("resources", []) or []

                for alert in records:
                    if not isinstance(alert, dict):
                        reasons["non_dict_alert"] += 1
                        continue

                    count += 1

                    event_time = first_ts(
                        alert,
                        body.get("alert_start_keys", ["timestamp"])
                    )

                    created_time = first_ts(
                        alert,
                        body.get("alert_created_keys", ["created_timestamp"])
                    )

                    seconds, reason = seconds_between(event_time, created_time)

                    if reason:
                        reasons[reason] += 1
                    else:
                        values.append(seconds)

                after = (
                    response_body.get("meta", {})
                    .get("pagination", {})
                    .get("after")
                )

                if not after:
                    break

                max_pages = int(body.get("max_alert_pages", 0) or 0)
                if max_pages and page_count >= max_pages:
                    reasons["stopped_at_max_alert_pages"] += 1
                    break

            return {
                "filter": fql,
                "count": count,
                "values": values,
                "reasons": reasons
            }

        def process_cases(start, end, start_dt, end_dt):
            client = MessageCenter()
            values = []
            reasons = Counter()
            status_counts = Counter()
            status_categories = Counter()
            close_sources = Counter()
            case_count = 0
            offset = 0
            page_count = 0
            limit = min(int(body.get("case_limit", 500)), 500)

            fql = body.get("case_filter") or f"case.last_modified_time:>='{start}'+case.last_modified_time:<'{end}'"

            if body.get("case_filter_extra"):
                fql = f"{fql}+{body['case_filter_extra']}"

            while True:
                page_count += 1

                query_body = ok_body(
                    client.query_cases(
                        filter=fql,
                        sort=body.get("case_sort", "case.last_modified_time.asc"),
                        limit=limit,
                        offset=offset
                    ),
                    "Message Center query_cases"
                )

                ids = [str(item) for item in (query_body.get("resources", []) or []) if item]

                for id_chunk in chunks(ids, int(body.get("case_hydrate_chunk", 100))):
                    get_body = ok_body(client.get_cases(ids=id_chunk), "Message Center get_cases")
                    cases = get_body.get("resources", []) or []

                    for case_record in cases:
                        if not isinstance(case_record, dict):
                            reasons["non_dict_case"] += 1
                            continue

                        case_count += 1

                        raw_status = first_value(
                            case_record,
                            body.get("case_status_keys", [
                                "case.status",
                                "status",
                                "case.state",
                                "state"
                            ])
                        )

                        category = status_category(raw_status)

                        status_key = str(raw_status).strip() if raw_status is not None and str(raw_status).strip() else "<missing>"
                        status_counts[status_key] += 1
                        status_categories[category] += 1

                        opened_time = first_ts(
                            case_record,
                            body.get("case_open_keys", [
                                "case.created_time",
                                "created_time",
                                "case.created_timestamp",
                                "created_timestamp",
                                "created_at",
                                "case.created_at"
                            ])
                        )

                        last_modified_time = first_ts(
                            case_record,
                            body.get("case_last_modified_keys", [
                                "case.last_modified_time",
                                "last_modified_time",
                                "case.updated_timestamp",
                                "updated_timestamp",
                                "updated_at",
                                "case.updated_at",
                                "modified_time",
                                "case.modified_time"
                            ])
                        )

                        if category == "terminal":
                            close_time = last_modified_time
                            close_source = "terminal_last_modified_fallback"
                        elif category == "unknown" and body.get("use_last_modified_for_unknown_status", False):
                            close_time = last_modified_time
                            close_source = "unknown_status_last_modified_fallback"
                        else:
                            reasons[f"{category}_status_no_close_time"] += 1
                            continue

                        if not in_window(close_time, start_dt, end_dt):
                            reasons["close_time_outside_period"] += 1
                            continue

                        seconds, reason = seconds_between(opened_time, close_time)

                        if reason:
                            reasons[reason] += 1
                        else:
                            values.append(seconds)
                            close_sources[close_source] += 1

                if len(ids) < limit:
                    break

                max_pages = int(body.get("max_case_pages", 0) or 0)
                if max_pages and page_count >= max_pages:
                    reasons["stopped_at_max_case_pages"] += 1
                    break

                offset += limit

            return {
                "filter": fql,
                "count": case_count,
                "values": values,
                "reasons": reasons,
                "status_counts": status_counts,
                "status_categories": status_categories,
                "close_sources": close_sources
            }

        report_month, start, end, start_dt, end_dt = month_window()

        alert_result = process_alerts(start, end)
        case_result = process_cases(start, end, start_dt, end_dt)

        mttd = summarize(alert_result["values"])
        mttr = summarize(case_result["values"])

        title = body.get("report_title", "Falcon Monthly KPI Report")
        subject = body.get("email_subject") or f"{title} - {report_month}"

        status_lines = "\n".join(
            f"- {item['value']}: {item['count']}"
            for item in counter_list(case_result["status_counts"], 10)
        ) or "- none"

        email_body = (
            f"{title} - {report_month}\n\n"
            f"Reporting period UTC:\n"
            f"{start} through {end}\n\n"
            f"Mean Time to Detect:\n"
            f"Definition: alert.created_timestamp - alert.timestamp\n"
            f"Alert filter: {alert_result['filter']}\n"
            f"Alerts reviewed: {alert_result['count']}\n"
            f"MTTD mean: {mttd['mean_minutes']} minutes\n"
            f"MTTD median: {mttd['median_minutes']} minutes\n"
            f"MTTD p90: {mttd['p90_minutes']} minutes\n"
            f"MTTD records used: {mttd['count']}\n"
            f"MTTD exclusions: {dict(alert_result['reasons'])}\n\n"
            f"Mean Time to Remediate:\n"
            f"Definition: Message Center case.last_modified_time - case.created_time for terminal cases\n"
            f"Case filter: {case_result['filter']}\n"
            f"Message Center cases reviewed: {case_result['count']}\n"
            f"MTTR mean: {mttr['mean_hours']} hours\n"
            f"MTTR median: {mttr['median_hours']} hours\n"
            f"MTTR p90: {mttr['p90_hours']} hours\n"
            f"MTTR records used: {mttr['count']}\n"
            f"MTTR exclusions: {dict(case_result['reasons'])}\n"
            f"MTTR close-time sources: {dict(case_result['close_sources'])}\n\n"
            f"Message Center case status categories:\n"
            f"{dict(case_result['status_categories'])}\n\n"
            f"Top Message Center case statuses observed:\n"
            f"{status_lines}\n"
        )

        return Response(
            code=200,
            body={
                "email_subject": subject,
                "email_body": email_body,
                "report_month": report_month,
                "period_start": start,
                "period_end": end,
                "mttd": mttd,
                "mttr": mttr,
                "definitions": {
                    "mttd": "alert.created_timestamp - alert.timestamp",
                    "mttr": "Message Center case.last_modified_time - case.created_time for terminal cases"
                },
                "filters": {
                    "alerts": alert_result["filter"],
                    "cases": case_result["filter"]
                },
                "counts": {
                    "alerts_reviewed": alert_result["count"],
                    "mttd_records_used": mttd["count"],
                    "message_center_cases_reviewed": case_result["count"],
                    "mttr_records_used": mttr["count"]
                },
                "exclusions": {
                    "mttd": dict(alert_result["reasons"]),
                    "mttr": dict(case_result["reasons"])
                },
                "case_status_categories": dict(case_result["status_categories"]),
                "case_status_counts": counter_list(case_result["status_counts"], 50),
                "mttr_close_time_sources": dict(case_result["close_sources"]),
                "settings": {
                    "use_last_modified_for_unknown_status": bool(
                        body.get("use_last_modified_for_unknown_status", False)
                    )
                }
            }
        )

    except Exception as exc:
        logger.error(str(exc))
        return Response(
            code=500,
            errors=[APIError(code=500, message=str(exc))]
        )


if __name__ == "__main__":
    FUNC.run()
