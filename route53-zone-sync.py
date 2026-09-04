#!/usr/bin/env python3
"""
route53-zone-sync.py

APEX 도메인 zone 파일을 읽어 Route 53 호스트존에 반영한다. AWS CloudShell에서
실행하는 걸 기준으로 만들었다 (자격증명은 세션이 알아서 물어다 준다).

- 호스트존이 없으면 새로 만든다.
- 있으면 기존 레코드셋을 받아와 zone 파일과 비교한다.
- 새로 생길 것 / 값이 달라질 것을 화면에 보여주고, 사용자가 전체 적용·개별
  선택·취소 중 골라야 실제로 반영된다.
- apex의 SOA/NS는 Route 53이 호스트존 생성 시 자체 관리하는 값이라 건드리지
  않는다. 위임용 서브도메인 NS는 정상적으로 비교·적용 대상이다.
- Route 53에만 있고 zone 파일에는 없는 레코드는 기본적으로 삭제하지 않는다.
  --allow-delete 를 줘야 삭제 후보로 올라온다.

사용법:
  python3 route53-zone-sync.py example.com example.com.zone
  python3 route53-zone-sync.py -y --dry-run example.com example.com.zone
  python3 route53-zone-sync.py --allow-delete --hosted-zone-id Z123 example.com example.com.zone
"""

import argparse
import re
import sys
import time
import uuid
from collections import defaultdict

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError
except ImportError:
    sys.exit("boto3 가 없다. CloudShell 이라면 기본 설치되어 있어야 한다: pip3 install --user boto3")


PROG = "route53-zone-sync.py"

# Route 53 이 지원하는 레코드 타입. 이 밖의 타입(DNSKEY, SSHFP, TLSA, HINFO 등)은
# 건너뛰고 개수만 알려준다.
SUPPORTED_TYPES = {
    "A", "AAAA", "CAA", "CNAME", "DS", "MX", "NAPTR",
    "NS", "PTR", "SOA", "SPF", "SRV", "TXT",
}
KNOWN_TYPES = SUPPORTED_TYPES | {"DNSKEY", "SSHFP", "TLSA", "HINFO", "CDS", "CDNSKEY"}
CLASS_TOKENS = {"IN", "CH", "HS", "ANY"}

# 값 하나만 갖는 hostname 타입. 마지막에 점이 빠져 있으면 자동으로 붙이고 알린다.
SINGLE_HOST_TYPES = {"NS", "CNAME", "PTR"}

DEFAULT_TTL = 300


# --------------------------------------------------------------------- 유틸

def die(msg):
    print(f"{PROG}: {msg}", file=sys.stderr)
    sys.exit(1)


def warn(msg):
    print(f"[!] {msg}", file=sys.stderr)


def ask(prompt):
    try:
        return input(prompt)
    except EOFError:
        return ""
    except KeyboardInterrupt:
        print()
        die("취소됨")


def confirm(prompt, default=False):
    suffix = " [Y/n] " if default else " [y/N] "
    ans = ask(prompt + suffix).strip().lower()
    if not ans:
        return default
    return ans in ("y", "yes")


def normalize_domain(d):
    d = d.strip().lower().rstrip(".")
    d = re.sub(r"^[a-z]+://", "", d)
    d = d.split("/", 1)[0]
    if not re.match(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", d):
        die(f"APEX 도메인 형식이 아니다: {d}")
    return d + "."


# ---------------------------------------------------------------- zone 파서

def strip_comment(line):
    """따옴표 밖의 ';' 부터 잘라낸다."""
    out = []
    in_quotes = False
    for ch in line:
        if ch == '"':
            in_quotes = not in_quotes
        elif ch == ";" and not in_quotes:
            break
        out.append(ch)
    return "".join(out)


def paren_delta(line):
    depth = 0
    in_quotes = False
    for ch in line:
        if ch == '"':
            in_quotes = not in_quotes
        elif not in_quotes:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
    return depth


def iter_logical_lines(text):
    """여러 줄에 걸친 괄호 레코드(SOA 등)를 한 줄로 합쳐서 돌려준다.
    (leading_whitespace, 합쳐진 한 줄) 튜플을 순서대로 낸다."""
    depth = 0
    buf = []
    leading_ws = False
    for raw in text.splitlines():
        line = strip_comment(raw)
        if depth == 0:
            buf = []
            leading_ws = bool(raw) and raw[0] in " \t"
        depth += paren_delta(line)
        buf.append(line)
        if depth <= 0:
            depth = 0
            full = " ".join(buf).strip()
            if full:
                yield leading_ws, full
            buf = []
    if buf and "".join(buf).strip():
        warn("괄호가 안 닫힌 채로 파일이 끝났다. 마지막 레코드를 무시한다.")


def tokenize(line):
    tokens = []
    cur = ""
    in_quotes = False
    for ch in line:
        if ch == '"':
            in_quotes = not in_quotes
            cur += ch
        elif ch.isspace() and not in_quotes:
            if cur:
                tokens.append(cur)
                cur = ""
        else:
            cur += ch
    if cur:
        tokens.append(cur)

    cleaned = []
    for t in tokens:
        if t.startswith('"'):
            cleaned.append(t)
            continue
        t = t.strip("()")
        if t:
            cleaned.append(t)
    return cleaned


class ZoneRecord:
    __slots__ = ("name", "ttl", "rtype", "rdata")

    def __init__(self, name, ttl, rtype, rdata):
        self.name = name
        self.ttl = ttl
        self.rtype = rtype
        self.rdata = rdata


def normalize_name(owner, origin):
    if owner == "@":
        fqdn = origin
    elif owner.endswith("."):
        fqdn = owner
    else:
        fqdn = owner + "." + origin
    return fqdn.rstrip(".").lower() + "."


def parse_zone_file(path, fallback_origin):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        die(f"zone 파일을 읽을 수 없다: {path} ({e})")

    origin = fallback_origin
    default_ttl = DEFAULT_TTL
    last_owner = None
    records = []
    skipped_unsupported = defaultdict(int)
    malformed = 0

    for leading_ws, line in iter_logical_lines(text):
        tokens = tokenize(line)
        if not tokens:
            continue

        if tokens[0].upper() == "$ORIGIN":
            if len(tokens) < 2:
                warn(f"$ORIGIN 뒤에 값이 없다: {line!r}")
                continue
            val = tokens[1]
            origin = val if val.endswith(".") else val + "."
            origin = origin.lower()
            continue

        if tokens[0].upper() == "$TTL":
            if len(tokens) < 2 or not tokens[1].isdigit():
                warn(f"$TTL 값이 이상하다: {line!r}")
                continue
            default_ttl = int(tokens[1])
            continue

        if tokens[0].startswith("$"):
            continue  # $INCLUDE, $GENERATE 등은 지원하지 않는다

        idx = 0
        if leading_ws:
            if last_owner is None:
                warn(f"소유자 이름 없이 시작하는 줄인데 이전 레코드가 없다: {line!r}")
                malformed += 1
                continue
            owner = last_owner
        else:
            owner = tokens[0]
            idx = 1
            last_owner = owner

        ttl = None
        while idx < len(tokens) and tokens[idx].upper() not in KNOWN_TYPES:
            tok = tokens[idx]
            if tok.isdigit():
                ttl = int(tok)
                idx += 1
            elif tok.upper() in CLASS_TOKENS:
                idx += 1
            else:
                break  # 못 알아듣는 토큰. type 자리로 넘겨서 실패시키고 malformed 처리

        if idx >= len(tokens):
            malformed += 1
            continue

        rtype = tokens[idx].upper()
        idx += 1
        rdata = " ".join(tokens[idx:]).strip()

        if not rdata:
            malformed += 1
            continue

        if rtype not in KNOWN_TYPES:
            malformed += 1
            continue
        if rtype not in SUPPORTED_TYPES:
            skipped_unsupported[rtype] += 1
            continue

        if ttl is None:
            ttl = default_ttl

        name = normalize_name(owner, origin)
        rdata = fixup_rdata(rtype, rdata)
        records.append(ZoneRecord(name, ttl, rtype, rdata))

    if malformed:
        warn(f"형식을 못 알아본 줄 {malformed}개는 건너뛰었다")
    for t, n in sorted(skipped_unsupported.items()):
        warn(f"Route 53 이 지원하지 않는 타입 {t} {n}개는 건너뛰었다")

    return origin, records


def fixup_rdata(rtype, rdata):
    if rtype in ("TXT", "SPF"):
        if not rdata.startswith('"'):
            rdata = '"' + rdata.replace('"', '\\"') + '"'
        return rdata
    if rtype in SINGLE_HOST_TYPES and not rdata.endswith("."):
        warn(f"{rtype} 값 '{rdata}' 끝에 점이 없어서 붙였다")
        rdata += "."
    return rdata


# --------------------------------------------------------------- 레코드 묶기

class RRSet:
    __slots__ = ("name", "rtype", "ttl", "values")

    def __init__(self, name, rtype, ttl, values):
        self.name = name
        self.rtype = rtype
        self.ttl = ttl
        self.values = values  # 정렬된 튜플

    def key(self):
        return (self.name, self.rtype)


def group_records(records):
    """같은 (name, type) 레코드를 하나의 RRSet 으로 묶는다.
    TTL이 여러 개 섞여 있으면 제일 큰 값을 쓴다 (와일드카드/캐시로 흔들리는 값
    보다는 큰 쪽이 안전하다는 zone-rebuild.sh 와 같은 방침)."""
    buckets = defaultdict(lambda: {"ttl": None, "values": set()})
    ttl_conflicts = set()
    for r in records:
        b = buckets[(r.name, r.rtype)]
        b["values"].add(r.rdata)
        if b["ttl"] is not None and b["ttl"] != r.ttl:
            ttl_conflicts.add((r.name, r.rtype))
        b["ttl"] = max(b["ttl"] or 0, r.ttl)

    for name, rtype in sorted(ttl_conflicts):
        warn(f"{name} {rtype} 레코드에 TTL이 여러 값으로 섞여 있어 최댓값을 썼다")

    out = {}
    for (name, rtype), b in buckets.items():
        out[(name, rtype)] = RRSet(name, rtype, b["ttl"], tuple(sorted(b["values"])))
    return out


# ------------------------------------------------------------------- AWS

def make_client(region, profile):
    session = boto3.session.Session(profile_name=profile, region_name=region)
    try:
        return session.client("route53")
    except (BotoCoreError, NoCredentialsError) as e:
        die(f"AWS 클라이언트를 만들 수 없다: {e}")


def find_hosted_zone(client, domain_fqdn, private):
    try:
        paginator = client.get_paginator("list_hosted_zones_by_name")
        matches = []
        for page in paginator.paginate(DNSName=domain_fqdn):
            for z in page["HostedZones"]:
                if z["Name"].lower() != domain_fqdn:
                    continue
                if bool(z["Config"].get("PrivateZone", False)) != private:
                    continue
                matches.append(z)
            # list_hosted_zones_by_name 은 이름순 정렬이라, 더 이상 같은 이름이
            # 안 나오면 멈춰도 된다.
            if page["HostedZones"] and page["HostedZones"][-1]["Name"].lower() > domain_fqdn:
                break
        return matches
    except ClientError as e:
        die(f"호스트존 조회 실패: {e}")


def create_hosted_zone(client, domain_fqdn, private, vpc_id, vpc_region, comment):
    cfg = {"Comment": comment or f"{PROG} 로 생성", "PrivateZone": private}
    kwargs = dict(
        Name=domain_fqdn,
        CallerReference=f"zone-sync-{uuid.uuid4()}",
        HostedZoneConfig=cfg,
    )
    if private:
        kwargs["VPC"] = {"VPCRegion": vpc_region, "VPCId": vpc_id}
    try:
        resp = client.create_hosted_zone(**kwargs)
    except ClientError as e:
        die(f"호스트존 생성 실패: {e}")
    zone = resp["HostedZone"]
    ns_values = []
    if "DelegationSet" in resp:
        ns_values = resp["DelegationSet"].get("NameServers", [])
    return zone, ns_values


def fetch_existing_rrsets(client, hosted_zone_id):
    out = {}
    alias_names = []
    try:
        paginator = client.get_paginator("list_resource_record_sets")
        for page in paginator.paginate(HostedZoneId=hosted_zone_id):
            for rr in page["ResourceRecordSets"]:
                name = rr["Name"].lower()
                rtype = rr["Type"]
                if "AliasTarget" in rr:
                    alias_names.append((name, rtype))
                    continue
                values = tuple(sorted(v["Value"] for v in rr.get("ResourceRecords", [])))
                ttl = rr.get("TTL", DEFAULT_TTL)
                out[(name, rtype)] = RRSet(name, rtype, ttl, values)
    except ClientError as e:
        die(f"기존 레코드 조회 실패: {e}")
    return out, alias_names


# ------------------------------------------------------------------- 비교

class Change:
    def __init__(self, action, rrset, old=None):
        self.action = action  # CREATE / UPSERT / DELETE
        self.rrset = rrset
        self.old = old        # UPSERT 일 때 기존 값


def diff_rrsets(desired, existing, origin, allow_apex_ns, allow_delete):
    changes = []
    skipped_apex = []

    for key, want in sorted(desired.items()):
        name, rtype = key
        is_apex = name == origin

        if rtype == "SOA":
            continue  # Route 53 이 자체 관리
        if rtype == "NS" and is_apex and not allow_apex_ns:
            have = existing.get(key)
            if have is None or have.values != want.values:
                skipped_apex.append(want)
            continue

        have = existing.get(key)
        if have is None:
            changes.append(Change("CREATE", want))
        elif have.values != want.values or have.ttl != want.ttl:
            changes.append(Change("UPSERT", want, old=have))

    deletions = []
    if allow_delete:
        for key, have in sorted(existing.items()):
            name, rtype = key
            if rtype in ("SOA", "NS") and name == origin:
                continue
            if key not in desired:
                deletions.append(Change("DELETE", have))

    return changes, deletions, skipped_apex


# ------------------------------------------------------------------ 출력

def fmt_values(values, width=88):
    s = ", ".join(values)
    if len(s) > width:
        s = s[: width - 15] + f"... (총 {len(values)}개 값)"
    return s


def print_change(c, idx=None):
    prefix = f"[{idx}] " if idx is not None else "    "
    tag = {"CREATE": "생성", "UPSERT": "변경", "DELETE": "삭제"}[c.action]
    print(f"{prefix}{tag:4s} {c.rrset.name:<32} {c.rrset.rtype:<6} TTL={c.rrset.ttl}")
    if c.action == "UPSERT":
        print(f"       - 기존: TTL={c.old.ttl}  {fmt_values(c.old.values)}")
        print(f"       - 변경: TTL={c.rrset.ttl}  {fmt_values(c.rrset.values)}")
    else:
        print(f"       {fmt_values(c.rrset.values)}")


def print_summary(changes, deletions, skipped_apex, allow_delete):
    n_create = sum(1 for c in changes if c.action == "CREATE")
    n_upsert = sum(1 for c in changes if c.action == "UPSERT")
    print()
    print(f"생성 {n_create}건 / 변경 {n_upsert}건" + (f" / 삭제 후보 {len(deletions)}건" if allow_delete else ""))
    if skipped_apex:
        print(f"apex NS 차이 {len(skipped_apex)}건은 위임 정보라 자동으로 건드리지 않는다 (--allow-apex-ns 로 강제 가능):")
        for w in skipped_apex:
            print(f"    {w.name} NS  {fmt_values(w.values)}")
    print()


# --------------------------------------------------------------- 상호작용

def select_changes(changes, label):
    if not changes:
        return []
    print(f"\n--- {label} ({len(changes)}건) ---")
    for i, c in enumerate(changes, 1):
        print_change(c, i)

    while True:
        choice = ask(f"\n{label} 적용 방식 [a]전체 [s]개별 선택 [n]건너뛰기: ").strip().lower()
        if choice in ("a", "all", ""):
            return list(changes)
        if choice in ("n", "none"):
            return []
        if choice in ("s", "select"):
            break
        print("a, s, n 중에서 골라라")

    picked = []
    for i, c in enumerate(changes, 1):
        print_change(c, i)
        if confirm("  적용?", default=(c.action != "DELETE")):
            picked.append(c)
    return picked


# ------------------------------------------------------------------- 적용

def to_change_batch_entry(c):
    action = "DELETE" if c.action == "DELETE" else c.action
    return {
        "Action": action,
        "ResourceRecordSet": {
            "Name": c.rrset.name,
            "Type": c.rrset.rtype,
            "TTL": c.rrset.ttl,
            "ResourceRecords": [{"Value": v} for v in c.rrset.values],
        },
    }


def apply_changes(client, hosted_zone_id, changes, batch_size, wait, dry_run):
    if not changes:
        print("적용할 변경 없음")
        return

    if dry_run:
        print(f"[dry-run] {len(changes)}건은 실제로 적용하지 않았다")
        return

    entries = [to_change_batch_entry(c) for c in changes]
    ok = 0
    for i in range(0, len(entries), batch_size):
        batch = entries[i : i + batch_size]
        try:
            resp = client.change_resource_record_sets(
                HostedZoneId=hosted_zone_id,
                ChangeBatch={"Comment": f"{PROG}", "Changes": batch},
            )
        except ClientError as e:
            warn(f"배치 {i // batch_size + 1} 적용 실패 ({len(batch)}건): {e}")
            continue

        ok += len(batch)
        change_id = resp["ChangeInfo"]["Id"]
        print(f"배치 {i // batch_size + 1}: {len(batch)}건 제출됨 ({change_id})")

        if wait:
            wait_for_sync(client, change_id)

    print(f"완료: {ok}/{len(entries)}건 제출")


def wait_for_sync(client, change_id, timeout=180):
    start = time.time()
    while time.time() - start < timeout:
        try:
            status = client.get_change(Id=change_id)["ChangeInfo"]["Status"]
        except ClientError as e:
            warn(f"상태 조회 실패: {e}")
            return
        if status == "INSYNC":
            print(f"  -> INSYNC ({int(time.time() - start)}초)")
            return
        time.sleep(5)
    warn(f"  -> {timeout}초 안에 INSYNC 안 됨, 나중에 콘솔에서 확인할 것")


# -------------------------------------------------------------------- main

def build_argparser():
    p = argparse.ArgumentParser(prog=PROG, description="zone 파일을 Route 53 호스트존에 반영한다")
    p.add_argument("domain", help="APEX 도메인 (예: example.com)")
    p.add_argument("zone_file", help="zone 파일 경로")
    p.add_argument("--hosted-zone-id", help="호스트존 ID를 직접 지정 (조회 생략)")
    p.add_argument("--private", action="store_true", help="private 호스트존 대상")
    p.add_argument("--vpc-id", help="private 호스트존 신규 생성 시 연결할 VPC ID")
    p.add_argument("--vpc-region", help="private 호스트존 신규 생성 시 VPC 리전")
    p.add_argument("--comment", help="신규 호스트존 생성 시 Comment")
    p.add_argument("--region", default="us-east-1", help="boto3 클라이언트 리전 (기본 us-east-1)")
    p.add_argument("--profile", help="AWS 프로파일 이름")
    p.add_argument("-y", "--yes", action="store_true", help="개별 확인 없이 전체 적용")
    p.add_argument("--dry-run", action="store_true", help="비교만 하고 실제로 적용하지 않음")
    p.add_argument("--allow-delete", action="store_true",
                    help="zone 파일에 없는 Route 53 레코드를 삭제 후보로 올림 (기본은 안 건드림)")
    p.add_argument("--allow-apex-ns", action="store_true",
                    help="apex NS 레코드도 비교/적용 대상에 포함 (위험, 기본 꺼짐)")
    p.add_argument("--batch-size", type=int, default=200, help="change_resource_record_sets 배치 크기 (기본 200)")
    p.add_argument("--wait", action="store_true", help="각 배치 제출 후 INSYNC 될 때까지 대기")
    return p


def main():
    args = build_argparser().parse_args()

    if args.private and not args.hosted_zone_id and (not args.vpc_id or not args.vpc_region):
        die("--private 로 새 호스트존을 만들려면 --vpc-id 와 --vpc-region 이 필요하다")

    domain_fqdn = normalize_domain(args.domain)
    print(f"[*] 대상 도메인 : {domain_fqdn}")
    print(f"[*] zone 파일   : {args.zone_file}")

    origin, records = parse_zone_file(args.zone_file, domain_fqdn)
    if origin != domain_fqdn:
        warn(f"zone 파일의 $ORIGIN({origin})이 도메인 인자({domain_fqdn})와 다르다. $ORIGIN 기준으로 처리한다")

    if not records:
        die("zone 파일에서 유효한 레코드를 하나도 못 읽었다")

    desired = group_records(records)
    print(f"[*] zone 파일에서 레코드셋 {len(desired)}개 읽음")

    client = make_client(args.region, args.profile)

    hosted_zone_id = args.hosted_zone_id
    delegation_ns = None

    if not hosted_zone_id:
        matches = find_hosted_zone(client, origin, args.private)
        if len(matches) > 1:
            print("같은 이름의 호스트존이 여러 개 있다:")
            for i, z in enumerate(matches, 1):
                print(f"  [{i}] {z['Id']}  ({z['ResourceRecordSetCount']}개 레코드)")
            sel = ask("사용할 번호: ").strip()
            if not sel.isdigit() or not (1 <= int(sel) <= len(matches)):
                die("잘못된 선택")
            hosted_zone_id = matches[int(sel) - 1]["Id"]
        elif len(matches) == 1:
            hosted_zone_id = matches[0]["Id"]
        else:
            print(f"[*] {origin} 에 대한 호스트존이 없다")
            if args.dry_run:
                print("[dry-run] 새 호스트존을 만들었을 것이다")
                existing = {}
                hosted_zone_id = None
            elif confirm(f"새 {'private' if args.private else 'public'} 호스트존을 생성할까?"):
                zone, delegation_ns = create_hosted_zone(
                    client, origin, args.private, args.vpc_id, args.vpc_region, args.comment
                )
                hosted_zone_id = zone["Id"]
                print(f"[*] 생성됨: {hosted_zone_id}")
                if delegation_ns:
                    print("[*] 등록기관(레지스트라)에 아래 네임서버로 위임을 걸어야 실제로 서비스된다:")
                    for ns in delegation_ns:
                        print(f"    {ns}")
            else:
                die("취소됨")

    if hosted_zone_id:
        existing, alias_names = fetch_existing_rrsets(client, hosted_zone_id)
        print(f"[*] Route 53 기존 레코드셋 {len(existing)}개" + (f", alias {len(alias_names)}개(비교 대상 아님)" if alias_names else ""))
    else:
        existing = {}

    changes, deletions, skipped_apex = diff_rrsets(
        desired, existing, origin, args.allow_apex_ns, args.allow_delete
    )
    print_summary(changes, deletions, skipped_apex, args.allow_delete)

    if not changes and not deletions:
        print("반영할 차이가 없다")
        return

    if args.yes:
        to_apply = list(changes)
        to_delete = list(deletions)
    else:
        to_apply = select_changes(changes, "생성/변경")
        to_delete = select_changes(deletions, "삭제") if deletions else []

    apply_changes(client, hosted_zone_id, to_apply + to_delete, args.batch_size, args.wait, args.dry_run)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        die("중단됨")
