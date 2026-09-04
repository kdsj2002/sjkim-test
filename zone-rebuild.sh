#!/usr/bin/env bash
#
# zone-rebuild.sh
#
# APEX 도메인 하나를 받아 공개 DNS 응답만으로 zone 파일을 재구성한다.
# AXFR이 열려 있으면 받아온 존을 그대로 쓰고, 막혀 있으면 apex 레코드 조회 +
# 2차 도메인(서브도메인) 추측으로 채운다.
#
# 와일드카드(*.example.com)가 걸린 존은 없는 이름을 물어봐도 같은 값을
# 돌려준다. 그렇게 얻은 동일 응답은 전부 중복으로 처리해서 개별 레코드로
# 찍지 않고, 어떤 이름들이 접혔는지만 주석으로 남긴다.
#
set -uo pipefail

VERSION="1.0.0"
PROG="${0##*/}"

DOMAIN=""
OUTPUT=""
WORDLIST=""
PROBE_TYPES="A,AAAA,TXT,MX"
APEX_TYPES="SOA,NS,A,AAAA,MX,TXT,CAA,DNSKEY"
RESOLVER_MODE="auto"          # auto | dig | doh
DNS_SERVER=""
JOBS=8
TIMEOUT=5
DUP_THRESHOLD=8               # 와일드카드가 안 잡혀도 동일 응답이 N개 이상이면 접는다 (0=끔)
WILDCARD_FILTER=1
WILDCARD_PROBES=4             # 와일드카드 확인용 랜덤 라벨 질의 횟수
TRY_AXFR=1
QUIET=0
VERBOSE=0
WORKDIR=""
HAVE_JQ=0

DOH_ENDPOINTS=(
  "https://dns.google/resolve"
  "https://cloudflare-dns.com/dns-query"
)

# ------------------------------------------------------------------- 유틸

log()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }
vlog() { [ "$VERBOSE" -eq 1 ] && printf '   . %s\n' "$*" >&2; return 0; }
die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$PROG $VERSION - APEX 도메인의 zone 파일 재구성

사용법:
  $PROG [옵션] <apex-domain>

옵션:
  -o, --output FILE      결과 zone 파일 (기본: <domain>.zone, '-' 는 표준출력)
  -w, --wordlist FILE    2차 도메인 후보 목록 (한 줄에 하나, # 주석 허용)
  -t, --types LIST       서브도메인 조회 타입 (기본: $PROBE_TYPES)
      --apex-types LIST  apex 조회 타입 (기본: $APEX_TYPES)
  -r, --resolver MODE    auto | dig | doh (기본: auto, dig 없으면 doh)
  -s, --server ADDR      dig 모드에서 질의할 네임서버
  -j, --jobs N           동시 질의 수 (기본: $JOBS)
      --timeout SEC      질의 타임아웃 (기본: $TIMEOUT)
      --dup-threshold N  와일드카드 미검출 시에도 같은 응답이 N개 이상이면
                         중복 처리 (기본: $DUP_THRESHOLD, 0이면 사용 안 함)
      --wildcard-probes N  와일드카드 확인용 랜덤 라벨 질의 횟수 (기본: $WILDCARD_PROBES)
      --no-wildcard      중복 제거 없이 얻은 응답을 전부 개별 출력
      --no-axfr          AXFR 시도 생략
  -q, --quiet            진행 로그 끔
  -v, --verbose          질의 단위 로그
  -h, --help             도움말
      --version          버전

예:
  $PROG example.com
  $PROG -s 8.8.8.8 -j 16 -w subs.txt -o out.zone example.com
  $PROG -r doh -t A,AAAA,TXT,MX,SRV --dup-threshold 0 example.com
EOF
}

lower() { printf '%s' "${1,,}"; }

# "A,AAAA,TXT" -> TYPE_ARR 배열
split_types() {
  TYPE_ARR=()
  local old="$IFS" tok
  IFS=','
  for tok in $1; do
    tok="${tok//[[:space:]]/}"; tok="${tok^^}"
    [ -n "$tok" ] && TYPE_ARR+=("$tok")
  done
  IFS="$old"
}

num_type() {
  case "$1" in
    1) echo A ;;      2) echo NS ;;      5) echo CNAME ;;   6) echo SOA ;;
    12) echo PTR ;;   13) echo HINFO ;;  15) echo MX ;;     16) echo TXT ;;
    28) echo AAAA ;;  33) echo SRV ;;    35) echo NAPTR ;;  43) echo DS ;;
    44) echo SSHFP ;; 48) echo DNSKEY ;; 52) echo TLSA ;;   64) echo SVCB ;;
    65) echo HTTPS ;; 99) echo SPF ;;    257) echo CAA ;;
    *) echo "TYPE$1" ;;
  esac
}

# zone 파일 안에서의 정렬 순서
type_rank() {
  case "$1" in
    SOA) echo 00 ;; NS) echo 10 ;; A) echo 20 ;;   AAAA) echo 21 ;;
    CNAME) echo 30 ;; MX) echo 40 ;; TXT) echo 50 ;; SPF) echo 51 ;;
    SRV) echo 60 ;; CAA) echo 70 ;; *) echo 90 ;;
  esac
}

rand_label() {
  local s
  s=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ -n "$s" ] || s="$RANDOM$RANDOM$RANDOM"
  printf 'zr%s' "${s:0:14}"
}

# ---------------------------------------------------------------- 리졸버

# dig 응답의 answer section 만 뽑아 "TYPE<TAB>TTL<TAB>DATA" 로 정규화.
# dig 은 컬럼 정렬용으로 탭을 여러 개 넣기 때문에 공백 단위로 자른다.
resolve_dig() {
  local name="$1" type="$2"
  dig ${DNS_SERVER:+@"$DNS_SERVER"} +tries=2 +time="$TIMEOUT" \
      +nocmd +noall +answer "$type" "$name" 2>/dev/null \
  | awk -v want="$name" '
      /^;/ { next }
      NF >= 5 && $3 == "IN" {
        owner = tolower($1); sub(/\.$/, "", owner)
        if (owner != want) next
        data = $5
        for (i = 6; i <= NF; i++) data = data " " $i
        print $4 "\t" $2 "\t" data
      }'
}

doh_fetch() {
  local name="$1" type="$2" ep json
  for ep in "${DOH_ENDPOINTS[@]}"; do
    json=$(curl -sS --max-time "$TIMEOUT" \
                -H 'accept: application/dns-json' \
                --get --data-urlencode "name=$name" --data-urlencode "type=$type" \
                "$ep" 2>/dev/null)
    case "$json" in *'"Status"'*) printf '%s' "$json"; return 0 ;; esac
  done
  return 1
}

resolve_doh() {
  local name="$1" type="$2" json
  json=$(doh_fetch "$name" "$type") || return 2

  if [ "$HAVE_JQ" -eq 1 ]; then
    printf '%s' "$json" | jq -r --arg n "${name}." '
        (.Answer // [])[]
          | select((.name | ascii_downcase | sub("\\.$";"") + ".") == ($n | ascii_downcase))
          | "\(.type)\t\(.TTL)\t\(.data)"' 2>/dev/null
  else
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
want = sys.argv[1].lower().rstrip(".")
for a in d.get("Answer") or []:
    if a.get("name", "").lower().rstrip(".") == want:
        print("%s\t%s\t%s" % (a.get("type"), a.get("TTL"), a.get("data")))
' "$name" 2>/dev/null
  fi \
  | while IFS=$'\t' read -r tnum ttl data; do
      [ -n "${data:-}" ] || continue
      printf '%s\t%s\t%s\n' "$(num_type "$tnum")" "$ttl" "$data"
    done
}

# zone 파일 문법에 맞게 응답 데이터를 손본다.
#  - TXT/SPF: 제공자마다 인용부호를 붙이기도 하고 안 붙이기도 한다.
#    안 붙어 있으면 이스케이프 후 255바이트 단위로 잘라 인용한다.
normalize_rr() {
  awk -F'\t' '
    function chunk_quote(s,   out, part) {
      out = ""
      while (length(s) > 255) {
        part = substr(s, 1, 255); s = substr(s, 256)
        gsub(/\\/, "\\\\", part); gsub(/"/, "\\\"", part)
        out = out "\"" part "\" "
      }
      gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
      return out "\"" s "\""
    }
    {
      data = $3
      if (($1 == "TXT" || $1 == "SPF") && substr(data, 1, 1) != "\"")
        data = chunk_quote(data)
      print $1 "\t" $2 "\t" data
    }'
}

# 같은 (TYPE, DATA) 가 여러 번 나오면 TTL 이 제일 큰 것 하나만 남긴다.
# 타입별로 나눠 질의하다 보면 같은 CNAME 이 캐시 TTL 만 달리해서 여러 번 잡힌다.
dedupe_rr() {
  awk -F'\t' '
    { k = $1 SUBSEP $3; if (!(k in ttl) || $2 + 0 > ttl[k]) ttl[k] = $2 + 0 }
    END { for (k in ttl) { split(k, p, SUBSEP); print p[1] "\t" ttl[k] "\t" p[2] } }' \
  | LC_ALL=C sort -u
}

# resolve <name> <type> -> "TYPE<TAB>TTL<TAB>DATA" 여러 줄
# CNAME 이 걸려 있으면 CNAME 만 돌려준다. 뒤에 붙어오는 A/AAAA 는
# 다른 존 소유라 이 존 파일에 넣으면 안 된다.
resolve() {
  local name type out cn
  name=$(lower "${1%.}")
  type="${2^^}"

  if [ "$RESOLVER_MODE" = "dig" ]; then
    out=$(resolve_dig "$name" "$type")
  else
    out=$(resolve_doh "$name" "$type")
  fi
  [ -n "$out" ] || return 1

  cn=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "CNAME"')
  if [ -n "$cn" ] && [ "$type" != "CNAME" ]; then
    printf '%s\n' "$cn" | normalize_rr
  else
    printf '%s\n' "$out" | awk -F'\t' -v t="$type" '$1 == t' | normalize_rr
  fi
}

# --------------------------------------------------------------- 서명 비교

# 응답을 "TYPE 값" 한 줄씩으로 정규화한다.
#  - TTL 은 제외한다. 와일드카드 응답은 캐시 상태에 따라 TTL 이 흔들린다.
#  - 조회한 라벨이 데이터에 박혀 있으면 {LABEL} 로 치환한다.
#    (`*.d.com CNAME <label>.cdn.net` 처럼 라벨을 되돌려주는 구성 대응)
sig_lines() {
  local label="$1" t d
  while IFS=$'\t' read -r t _ d; do
    [ -n "${t:-}" ] || continue
    d="${d,,}"
    # 라벨이 값 안에 되돌아오는 구성(`*.d.com CNAME <label>.cdn.net`)만 치환한다.
    # 부분 문자열까지 바꾸면 `mail` 이 include:mail.zendesk.com 을 건드리는 식으로
    # 멀쩡한 값이 서로 달라 보인다. 그래서 이름의 맨 앞 라벨 자리만 본다.
    if [ -n "$label" ]; then
      case "$d" in
        "$label".*)   d="{LABEL}.${d#"$label".}" ;;
        *" $label".*) d="${d/" $label."/" {LABEL}."}" ;;
      esac
    fi
    printf '%s %s\n' "$t" "$d"
  done | LC_ALL=C sort -u
}

# ---------------------------------------------------------------- 워커

probe_label() {
  local label="$1" fqdn="$1.$ZR_DOMAIN" t out
  local file="$ZR_WORKDIR/probe/${label//\//_}"
  local tmp="$file.part"

  split_types "$ZR_PROBE_TYPES"
  : > "$tmp"
  for t in "${TYPE_ARR[@]}"; do
    out=$(resolve "$fqdn" "$t") && printf '%s\n' "$out" >> "$tmp"
  done

  if [ -s "$tmp" ]; then
    dedupe_rr < "$tmp" > "$file"
    vlog "hit  $fqdn"
  fi
  rm -f "$tmp"
}

# ------------------------------------------------------------ 내장 워드리스트

builtin_wordlist() {
  cat <<'EOW'
www
www2
www3
ww2
m
mobile
api
api2
app
apps
admin
administrator
portal
panel
cpanel
whm
plesk
webmail
mail
mail2
smtp
smtp2
pop
pop3
imap
mx
mx1
mx2
mta
relay
autodiscover
autoconfig
lyncdiscover
sip
enterpriseregistration
enterpriseenrollment
ns
ns1
ns2
ns3
ns4
dns
dns1
dns2
_dmarc
_domainkey
default._domainkey
selector1._domainkey
selector2._domainkey
google._domainkey
mail._domainkey
k1._domainkey
dkim
ftp
sftp
files
file
share
download
downloads
static
assets
cdn
cdn1
cdn2
img
image
images
media
video
stream
cloud
s3
storage
backup
archive
dev
develop
development
test
testing
stage
staging
uat
qa
sandbox
demo
beta
alpha
preview
new
old
legacy
git
gitlab
svn
jenkins
ci
build
deploy
release
registry
docker
nexus
sonar
harbor
argocd
db
mysql
mariadb
postgres
mssql
oracle
redis
mongo
elastic
elasticsearch
kibana
logstash
grafana
prometheus
monitor
monitoring
zabbix
nagios
log
logs
syslog
metrics
auth
sso
login
signin
id
idp
oauth
account
accounts
my
mypage
secure
vpn
remote
rdp
ssh
gw
gateway
proxy
edge
origin
lb
router
firewall
fw
nas
print
printer
blog
news
forum
community
wiki
docs
doc
help
support
status
ticket
crm
erp
hr
sales
shop
store
mall
order
cart
pay
payment
billing
invoice
partner
partners
intranet
internal
extranet
office
meet
chat
im
voip
pbx
phone
conference
jira
confluence
bitbucket
ldap
ad
dc
dc1
dc2
exchange
owa
time
ntp
radius
dashboard
console
EOW
}

# ---------------------------------------------------------------- AXFR

try_axfr() {
  local ns out
  command -v dig >/dev/null 2>&1 || return 1
  for ns in $NS_HOSTS; do
    vlog "AXFR 시도 @${ns%.}"
    out=$(dig +time=5 +tries=1 "@${ns%.}" AXFR "$DOMAIN" 2>/dev/null \
          | grep -v '^;' | grep -v '^[[:space:]]*$')
    if [ -n "$out" ] && printf '%s\n' "$out" | grep -qE '[[:space:]]SOA[[:space:]]'; then
      AXFR_NS="${ns%.}"
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 1
}

# ------------------------------------------------------------- 인자 / 준비

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output)     OUTPUT="${2:-}";        shift 2 ;;
      -w|--wordlist)   WORDLIST="${2:-}";      shift 2 ;;
      -t|--types)      PROBE_TYPES="${2:-}";   shift 2 ;;
      --apex-types)    APEX_TYPES="${2:-}";    shift 2 ;;
      -r|--resolver)   RESOLVER_MODE="${2:-}"; shift 2 ;;
      -s|--server)     DNS_SERVER="${2:-}";    shift 2 ;;
      -j|--jobs)       JOBS="${2:-}";          shift 2 ;;
      --timeout)       TIMEOUT="${2:-}";       shift 2 ;;
      --dup-threshold) DUP_THRESHOLD="${2:-}"; shift 2 ;;
      --wildcard-probes) WILDCARD_PROBES="${2:-}"; shift 2 ;;
      --no-wildcard)   WILDCARD_FILTER=0;      shift ;;
      --no-axfr)       TRY_AXFR=0;             shift ;;
      -q|--quiet)      QUIET=1;                shift ;;
      -v|--verbose)    VERBOSE=1;              shift ;;
      -h|--help)       usage; exit 0 ;;
      --version)       echo "$PROG $VERSION"; exit 0 ;;
      -*)              die "알 수 없는 옵션: $1 (--help 참고)" ;;
      *)               [ -z "$DOMAIN" ] || die "도메인은 하나만 지정한다"
                       DOMAIN="$1"; shift ;;
    esac
  done

  [ -n "$DOMAIN" ] || { usage >&2; exit 2; }
  DOMAIN=$(lower "${DOMAIN%.}")
  DOMAIN="${DOMAIN#*://}"
  DOMAIN="${DOMAIN%%/*}"
  printf '%s' "$DOMAIN" \
    | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
    || die "APEX 도메인 형식이 아니다: $DOMAIN"

  local n
  for n in JOBS TIMEOUT DUP_THRESHOLD WILDCARD_PROBES; do
    case "${!n}" in
      ''|*[!0-9]*) die "$n 값은 0 이상의 정수여야 한다" ;;
    esac
  done
  [ "$JOBS" -ge 1 ] || JOBS=1
  [ "$TIMEOUT" -ge 1 ] || TIMEOUT=1
  [ "$WILDCARD_PROBES" -ge 1 ] || WILDCARD_PROBES=1
  [ -n "$OUTPUT" ] || OUTPUT="$DOMAIN.zone"

  split_types "$PROBE_TYPES";  [ "${#TYPE_ARR[@]}" -gt 0 ] || die "-t 목록이 비었다"
  split_types "$APEX_TYPES";   [ "${#TYPE_ARR[@]}" -gt 0 ] || die "--apex-types 목록이 비었다"
}

preflight() {
  case "$RESOLVER_MODE" in
    auto) if command -v dig >/dev/null 2>&1; then RESOLVER_MODE="dig"; else RESOLVER_MODE="doh"; fi ;;
    dig)  command -v dig >/dev/null 2>&1 || die "dig 이 없다 (-r doh 로 우회 가능)" ;;
    doh)  ;;
    *)    die "-r 는 auto|dig|doh 중 하나" ;;
  esac

  if [ "$RESOLVER_MODE" = "doh" ]; then
    command -v curl >/dev/null 2>&1 || die "doh 모드에는 curl 이 필요하다"
    if command -v jq >/dev/null 2>&1; then
      HAVE_JQ=1
    elif command -v python3 >/dev/null 2>&1; then
      HAVE_JQ=0
    else
      die "doh 모드에는 jq 또는 python3 중 하나가 필요하다"
    fi
    TRY_AXFR=0   # DoH 로는 존 전송을 못 한다
  fi
}

# ---------------------------------------------------------------- 수집

collect_apex() {
  local t out
  split_types "$APEX_TYPES"
  : > "$WORKDIR/apex"
  for t in "${TYPE_ARR[@]}"; do
    out=$(resolve "$DOMAIN" "$t") && printf '%s\n' "$out" >> "$WORKDIR/apex"
  done
  dedupe_rr < "$WORKDIR/apex" > "$WORKDIR/apex.dedup" && mv "$WORKDIR/apex.dedup" "$WORKDIR/apex"
  [ -s "$WORKDIR/apex" ] || die "$DOMAIN 에서 아무 응답도 못 받았다. 도메인/네트워크 확인"

  NS_HOSTS=$(awk -F'\t' '$1 == "NS" { print $3 }' "$WORKDIR/apex" | tr -d '\r')
}

detect_wildcard() {
  WILDCARD_FOUND=0
  : > "$WORKDIR/wildcard.set"   # "TYPE 값" 한 줄씩. 와일드카드가 돌려준 값의 합집합
  : > "$WORKDIR/wildcard.rr"    # TYPE<TAB>TTL<TAB>DATA

  if [ "$WILDCARD_FILTER" -eq 0 ]; then
    log "[*] 와일드카드 중복 제거 비활성 (--no-wildcard)"
    return
  fi

  local t i lbl out ok
  split_types "$PROBE_TYPES"
  for t in "${TYPE_ARR[@]}"; do
    ok=1
    : > "$WORKDIR/wc.set"
    : > "$WORKDIR/wc.rr"

    # 없는 이름을 여러 번 물어본다. 매번 답이 오면 와일드카드가 걸려 있는 것이다.
    # 답이 매번 똑같지 않아도 (라운드로빈, 라벨 반사) 값을 전부 모아 합집합으로 둔다.
    for ((i = 1; i <= WILDCARD_PROBES; i++)); do
      lbl=$(rand_label)
      out=$(resolve "$lbl.$DOMAIN" "$t")
      if [ -z "$out" ]; then ok=0; break; fi
      printf '%s\n' "$out" | sig_lines "$lbl" >> "$WORKDIR/wc.set"
      printf '%s\n' "$out" | sed "s/$lbl/*/g" >> "$WORKDIR/wc.rr"
    done

    if [ "$ok" -eq 1 ] && [ -s "$WORKDIR/wc.set" ]; then
      WILDCARD_FOUND=1
      LC_ALL=C sort -u "$WORKDIR/wc.set" >> "$WORKDIR/wildcard.set"
      dedupe_rr < "$WORKDIR/wc.rr" >> "$WORKDIR/wildcard.rr"
      log "[!] 와일드카드: *.$DOMAIN $t -> $(awk -F'\t' '{ print $3 }' "$WORKDIR/wc.rr" | LC_ALL=C sort -u | tr '\n' ' ')"
    fi
    rm -f "$WORKDIR/wc.set" "$WORKDIR/wc.rr"
  done

  LC_ALL=C sort -u "$WORKDIR/wildcard.set" -o "$WORKDIR/wildcard.set"
  [ "$WILDCARD_FOUND" -eq 1 ] || vlog "와일드카드 없음"
}

build_candidates() {
  [ -z "$WORDLIST" ] || [ -r "$WORDLIST" ] || die "워드리스트를 읽을 수 없다: $WORDLIST"
  {
    if [ -n "$WORDLIST" ]; then
      cat "$WORDLIST"
    else
      builtin_wordlist
    fi
  } | tr '[:upper:]' '[:lower:]' | tr -d '\r' \
    | sed 's/#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | sed "s/\.${DOMAIN//./\\.}\.\?\$//" \
    | grep -E '^[a-z0-9_]([a-z0-9._-]*[a-z0-9_])?$' \
    | LC_ALL=C sort -u > "$WORKDIR/candidates"
  [ -s "$WORKDIR/candidates" ] || die "조회할 후보가 없다"
}

run_probes() {
  local self
  self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

  export ZR_DOMAIN="$DOMAIN" ZR_WORKDIR="$WORKDIR" ZR_PROBE_TYPES="$PROBE_TYPES"
  export ZR_RESOLVER="$RESOLVER_MODE" ZR_SERVER="$DNS_SERVER" ZR_TIMEOUT="$TIMEOUT"
  export ZR_HAVE_JQ="$HAVE_JQ" ZR_VERBOSE="$VERBOSE" ZR_QUIET="$QUIET"

  xargs -a "$WORKDIR/candidates" -P "$JOBS" -I '{}' \
        bash "$self" --__probe '{}'
}

# 얻은 응답을 고유 레코드와 중복으로 가른다.
# 타입 단위로 비교해서, 와일드카드가 주는 값과 같은 타입만 버리고
# 그 이름이 따로 들고 있는 레코드는 살린다.
classify_results() {
  : > "$WORKDIR/live"      # label<TAB>TYPE<TAB>TTL<TAB>DATA
  : > "$WORKDIR/hits"      # 응답이 온 label 전체
  : > "$WORKDIR/sig.map"   # TYPE<TAB>sig<TAB>label
  : > "$WORKDIR/mass"      # TYPE<TAB>sig<TAB>건수<TAB>label,label,...
  : > "$WORKDIR/mass.wc"   # 위 중 와일드카드 로테이션으로 판단한 그룹

  local f label t sub lines
  local -a check_types
  split_types "$PROBE_TYPES,CNAME"
  check_types=("${TYPE_ARR[@]}")

  for f in "$WORKDIR"/probe/*; do
    [ -f "$f" ] || continue
    label="${f##*/}"
    printf '%s\n' "$label" >> "$WORKDIR/hits"

    for t in "${check_types[@]}"; do
      sub=$(awk -F'\t' -v t="$t" '$1 == t' "$f")
      [ -n "$sub" ] || continue

      lines=$(printf '%s\n' "$sub" | sig_lines "$label")

      # 응답값이 전부 와일드카드가 주는 값 안에 들어 있으면 이 이름 고유의
      # 레코드가 아니다. 하나라도 밖에 있으면 실제로 등록된 레코드로 본다.
      if [ -s "$WORKDIR/wildcard.set" ] \
         && ! printf '%s\n' "$lines" | grep -qvxF -f "$WORKDIR/wildcard.set"; then
        continue
      fi

      printf '%s\t%s\t%s\n' "$t" "$(printf '%s\n' "$lines" | tr '\n' '|')" "$label" \
        >> "$WORKDIR/sig.map"
      printf '%s\n' "$sub" | awk -F'\t' -v l="$label" '{ print l "\t" $1 "\t" $2 "\t" $3 }' \
        >> "$WORKDIR/live"
    done
  done

  LC_ALL=C sort -u "$WORKDIR/hits" -o "$WORKDIR/hits"
  HIT_COUNT=$(grep -c . "$WORKDIR/hits" || true)

  find_mass_duplicates
  drop_mass_duplicates

  awk -F'\t' '{ print $1 }' "$WORKDIR/live" | LC_ALL=C sort -u > "$WORKDIR/live.labels"
  comm -23 "$WORKDIR/hits" "$WORKDIR/live.labels" > "$WORKDIR/dup"
  LIVE_LABELS=$(grep -c . "$WORKDIR/live.labels" || true)
  DUP_LABELS=$(grep -c . "$WORKDIR/dup" || true)
}

# 와일드카드 질의에는 안 걸렸는데 서로 다른 이름들이 같은 값을 무더기로
# 돌려주는 경우(로테이션되는 와일드카드, catch-all, 파킹, CDN 공통 진입점)를 찾는다.
find_mass_duplicates() {
  [ "$WILDCARD_FILTER" -eq 1 ] || return 0
  [ "$DUP_THRESHOLD" -gt 0 ] || return 0
  [ -s "$WORKDIR/sig.map" ] || return 0

  LC_ALL=C sort "$WORKDIR/sig.map" \
    | awk -F'\t' -v n="$DUP_THRESHOLD" '
        { k = $1 "\t" $2; cnt[k]++; lab[k] = lab[k] (lab[k] ? "," : "") $3 }
        END { for (k in cnt) if (cnt[k] >= n) print k "\t" cnt[k] "\t" lab[k] }
      ' | LC_ALL=C sort -t$'\t' -k1,1 -k3,3nr > "$WORKDIR/mass"
}

# 위에서 찾은 그룹을 live 에서 걷어낸다.
# 같은 타입에 이미 와일드카드가 잡혀 있었다면 그 와일드카드가 값을 돌려 쓰는
# 것으로 보고 * 레코드 쪽에 합친다.
drop_mass_duplicates() {
  [ -s "$WORKDIR/mass" ] || return 0

  local t sig cnt labels first esc
  : > "$WORKDIR/mass.keep"

  while IFS=$'\t' read -r t sig cnt labels; do
    if [ -s "$WORKDIR/wildcard.set" ] && grep -q "^$t " "$WORKDIR/wildcard.set"; then
      first="${labels%%,*}"
      esc="${first//./\\.}"
      awk -F'\t' -v t="$t" '$1 == t' "$WORKDIR/probe/$first" | sed "s/$esc/*/g" \
        >> "$WORKDIR/wildcard.rr"
      printf '%s' "$sig" | tr '|' '\n' | grep -v '^$' >> "$WORKDIR/wildcard.set"
      printf '%s\t%s\t%s\t%s\n' "$t" "$sig" "$cnt" "$labels" >> "$WORKDIR/mass.wc"
    else
      printf '%s\t%s\t%s\t%s\n' "$t" "$sig" "$cnt" "$labels" >> "$WORKDIR/mass.keep"
    fi
  done < "$WORKDIR/mass"

  LC_ALL=C sort -u "$WORKDIR/wildcard.set" -o "$WORKDIR/wildcard.set"
  if [ -s "$WORKDIR/wildcard.rr" ]; then
    dedupe_rr < "$WORKDIR/wildcard.rr" > "$WORKDIR/wildcard.rr.new"
    mv "$WORKDIR/wildcard.rr.new" "$WORKDIR/wildcard.rr"
  fi

  # (label, type) 조합을 live 에서 제거
  awk -F'\t' '{ n = split($4, a, ","); for (i = 1; i <= n; i++) print a[i] "\t" $1 }' \
      "$WORKDIR/mass" | LC_ALL=C sort -u > "$WORKDIR/mass.pairs"
  awk -F'\t' 'NR == FNR { drop[$1 FS $2] = 1; next } !(($1 FS $2) in drop)' \
      "$WORKDIR/mass.pairs" "$WORKDIR/live" > "$WORKDIR/live.new"
  mv "$WORKDIR/live.new" "$WORKDIR/live"

  local n_wc n_keep
  n_wc=$(grep -c . "$WORKDIR/mass.wc" || true)
  n_keep=$(grep -c . "$WORKDIR/mass.keep" || true)
  [ "$n_wc" -gt 0 ] && log "[!] 와일드카드가 값을 돌려 쓰는 그룹 ${n_wc}개 -> * 로 합침"
  [ "$n_keep" -gt 0 ] && log "[!] 와일드카드는 없지만 동일 응답이 ${DUP_THRESHOLD}건 이상인 그룹 ${n_keep}개 -> 중복 처리"

  mv "$WORKDIR/mass.keep" "$WORKDIR/mass"
  return 0
}

# ---------------------------------------------------------------- 출력

zone_header() {
  cat <<EOF
;
; zone file : $DOMAIN
; generated : $(date '+%Y-%m-%d %H:%M:%S %z') / $PROG $VERSION
; method    : $1
; resolver  : $RESOLVER_MODE${DNS_SERVER:+ @$DNS_SERVER}
;
EOF
}

dump_groups() {
  local t sig cnt labels
  while IFS=$'\t' read -r t sig cnt labels; do
    printf ';   [%s] %s개 = %s\n' "$t" "$cnt" "${sig%|}"
    printf '%s\n' "$labels" | tr ',' ' ' | fold -s -w 88 \
      | sed 's/[[:space:]]*$//; s/^/;     /'
  done < "$1"
}

rr_line() { printf '%-26s %-7s IN %-7s %s\n' "$1" "$2" "$3" "$4"; }

write_axfr_zone() {
  {
    zone_header "AXFR (@$AXFR_NS) - 전송받은 존 원본"
    echo "\$ORIGIN $DOMAIN."
    echo
    cat "$WORKDIR/axfr"
  } > "$WORKDIR/zone.out"
  emit_output
}

write_zone() {
  local soa ttl_default=3600 minttl
  soa=$(awk -F'\t' '$1 == "SOA" { print; exit }' "$WORKDIR/apex")
  if [ -n "$soa" ]; then
    minttl=$(printf '%s' "$soa" | awk -F'\t' '{ print $3 }' | awk '{ print $NF }')
    case "$minttl" in ''|*[!0-9]*) ;; *) ttl_default="$minttl" ;; esac
  fi

  {
    zone_header "공개 질의로 재구성 (AXFR 불가) - 실제 존과 다를 수 있다"
    echo "\$ORIGIN $DOMAIN."
    echo "\$TTL $ttl_default"
    echo

    if [ -n "$soa" ]; then
      printf '%s\n' "$soa" | while IFS=$'\t' read -r t ttl d; do
        rr_line "@" "$ttl" "$t" "$d"
      done
    else
      echo "; SOA 응답이 없어 아래 값은 자리표시자다"
      rr_line "@" "$ttl_default" "SOA" \
        "ns1.$DOMAIN. hostmaster.$DOMAIN. ( 1 7200 3600 1209600 $ttl_default )"
    fi

    awk -F'\t' '$1 != "SOA"' "$WORKDIR/apex" \
      | while IFS=$'\t' read -r t ttl d; do
          printf '%s\t%s\t%s\t%s\n' "$(type_rank "$t")" "$t" "$ttl" "$d"
        done \
      | LC_ALL=C sort -t$'\t' -k1,1 -k4,4 \
      | while IFS=$'\t' read -r _ t ttl d; do
          rr_line "@" "$ttl" "$t" "$d"
        done

    if [ -s "$WORKDIR/wildcard.rr" ]; then
      echo
      echo "; ---- wildcard ----"
      echo "; 이 아래로는 어떤 라벨을 물어도 같은 값이 돌아온다."
      local reflected=0
      while IFS=$'\t' read -r t ttl d; do
        case "$d" in
          # 응답에 질의 라벨이 그대로 박혀 나오는 구성. 그 자리를 * 로 바꿔 두면
          # zone 파일 문법상 쓸 수 없는 값이 되므로 주석으로만 남긴다.
          *'*'*) reflected=1; printf '; %s\n' "$(rr_line '*' "$ttl" "$t" "$d")" ;;
          *)     rr_line "*" "$ttl" "$t" "$d" ;;
        esac
      done < <(LC_ALL=C sort -u "$WORKDIR/wildcard.rr")
      [ "$reflected" -eq 1 ] && \
        echo "; 위 주석 줄의 * 자리에는 질의한 라벨이 그대로 들어간다. 값을 직접 채워 쓸 것"
    fi

    echo
    echo "; ---- subdomains ----"
    if [ -s "$WORKDIR/live" ]; then
      LC_ALL=C sort -u "$WORKDIR/live" \
        | while IFS=$'\t' read -r label t ttl d; do
            printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$(type_rank "$t")" "$t" "$ttl" "$d"
          done \
        | LC_ALL=C sort -t$'\t' -k1,1 -k2,2 -k5,5 \
        | while IFS=$'\t' read -r label _ t ttl d; do
            rr_line "$label" "$ttl" "$t" "$d"
          done
    else
      echo "; 고유한 응답을 준 2차 도메인이 없다"
    fi

    if [ -s "$WORKDIR/dup" ] || [ -s "$WORKDIR/mass" ] || [ -s "$WORKDIR/mass.wc" ]; then
      echo
      echo "; ---- 중복 처리 ----"
    fi
    if [ -s "$WORKDIR/dup" ]; then
      echo "; 응답은 왔지만 값이 와일드카드/공통 응답과 같아 개별 레코드로 쓰지 않은 이름 (${DUP_LABELS}개):"
      LC_ALL=C sort "$WORKDIR/dup" | tr '\n' ' ' | fold -s -w 92 \
        | sed 's/[[:space:]]*$//; s/^/;   /'
      echo
    fi
    if [ -s "$WORKDIR/mass.wc" ]; then
      echo "; 와일드카드가 값을 돌려 쓰는 것으로 보고 * 에 합친 그룹:"
      dump_groups "$WORKDIR/mass.wc"
    fi
    if [ -s "$WORKDIR/mass" ]; then
      echo "; 와일드카드는 안 잡혔지만 동일 응답이 ${DUP_THRESHOLD}건 이상 묶인 그룹:"
      dump_groups "$WORKDIR/mass"
    fi

    echo
    printf '; 후보 %s개 질의 -> 응답 %s개, 고유 이름 %s개, 중복 %s개\n' \
      "$(grep -c . "$WORKDIR/candidates")" "$HIT_COUNT" "$LIVE_LABELS" "$DUP_LABELS"
  } > "$WORKDIR/zone.out"

  emit_output
}

emit_output() {
  if [ "$OUTPUT" = "-" ]; then
    cat "$WORKDIR/zone.out"
  else
    cp "$WORKDIR/zone.out" "$OUTPUT" || die "출력 파일을 쓸 수 없다: $OUTPUT"
  fi
}

# ---------------------------------------------------------------- main

main() {
  # xargs 로 재진입하는 워커 경로
  if [ "${1:-}" = "--__probe" ]; then
    RESOLVER_MODE="${ZR_RESOLVER:-doh}"
    DNS_SERVER="${ZR_SERVER:-}"
    TIMEOUT="${ZR_TIMEOUT:-5}"
    HAVE_JQ="${ZR_HAVE_JQ:-0}"
    VERBOSE="${ZR_VERBOSE:-0}"
    QUIET="${ZR_QUIET:-0}"
    probe_label "$2"
    exit 0
  fi

  parse_args "$@"
  preflight

  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/zonerebuild.XXXXXX") || die "임시 디렉터리 생성 실패"
  trap 'rm -rf "$WORKDIR"' EXIT INT TERM
  mkdir -p "$WORKDIR/probe"

  log "[*] 대상   : $DOMAIN"
  log "[*] 리졸버 : $RESOLVER_MODE${DNS_SERVER:+ @$DNS_SERVER}"

  collect_apex
  log "[*] apex 레코드 $(grep -c . "$WORKDIR/apex")건, NS $(printf '%s\n' "$NS_HOSTS" | grep -c . || true)개"

  AXFR_NS=""
  if [ "$TRY_AXFR" -eq 1 ] && [ -n "$NS_HOSTS" ]; then
    if try_axfr > "$WORKDIR/axfr" && [ -s "$WORKDIR/axfr" ]; then
      log "[!] AXFR 열려 있음 (@$AXFR_NS) - 전송받은 존을 그대로 쓴다"
      write_axfr_zone
      log "[*] 완료 -> $OUTPUT"
      return 0
    fi
    vlog "AXFR 불가, 추측 모드로 진행"
  fi

  detect_wildcard
  build_candidates
  log "[*] 2차 도메인 후보 $(grep -c . "$WORKDIR/candidates")개 조회 (동시 $JOBS)"
  run_probes
  classify_results
  write_zone

  log "[*] 완료: 고유 ${LIVE_LABELS}개 / 중복 ${DUP_LABELS}개 -> $OUTPUT"
}

main "$@"
