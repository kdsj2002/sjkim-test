# route53-zone-sync.py

zone 파일 하나를 Route 53 호스트존에 반영하는 스크립트다. AWS CloudShell에서
바로 돌리는 걸 기준으로 만들었고, `zone-rebuild.sh`가 뽑아낸 zone 파일을 그대로
입력으로 쓸 수 있다.

```
python3 route53-zone-sync.py example.com example.com.zone
```

## 동작 순서

1. zone 파일을 파싱해서 (이름, 타입)별로 레코드를 묶는다.
2. 도메인 이름으로 Route 53 호스트존을 찾는다.
   - 없으면 새로 만들지 물어본다. 만들면 위임에 써야 할 네임서버 목록을 출력한다.
     (이 네임서버로 등록기관 위임을 안 걸면 아무 것도 서비스되지 않는다.)
   - 있으면 그 존의 레코드셋을 전부 받아온다.
3. zone 파일 쪽과 Route 53 쪽을 (이름, 타입) 단위로 비교해서 생성/변경 대상을 뽑는다.
   Route 53이 이름을 돌려줄 때 `*` 같은 특수문자를 `\052`처럼 8진수로 이스케이프해서
   주는데, 그대로 두면 zone 파일의 `*`와 문자열이 달라서 같은 레코드인데도 신규로
   보인다. 비교 전에 항상 풀어준다.
4. 화면에 목록을 보여주고, 전체 적용·개별 선택·취소 중 고르게 한다.
5. 고른 것만 `change_resource_record_sets`로 제출한다.

## apex SOA/NS

apex(도메인 자체)의 SOA와 NS는 Route 53이 호스트존 만들 때 자체 배정하는
값이라 항상 적용 대상에서 뺀다. 삭제 후보로도 절대 안 잡는다(`--allow-delete`를
줘도 마찬가지). zone 파일 값과 실제 값이 다르면 손대지 않은 채로 화면에
정보로만 보여준다 — SOA는 MNAME이 Route 53 자체 네임서버로 고정돼 있어서
강제 적용 옵션 자체가 없고, NS는 zone 파일에 남아 있는 옛날 네임서버로
덮어쓰면 위임이 깨지기 때문에 정말 필요할 때만 `--allow-apex-ns`로 강제한다
(거의 쓸 일 없다).

서브도메인 NS(위임용, 예: `sub.example.com NS ns1.other.com.`)는 이 예외에
안 걸리고 정상적으로 비교·적용된다.

## 삭제

기본은 삭제를 하지 않는다. Route 53에는 있는데 zone 파일에는 없는 레코드는
그냥 무시한다. `--allow-delete`를 주면 그런 레코드를 삭제 후보로 올리고,
개별 선택 화면에서 기본값이 "아니오"인 채로 확인을 받는다.

## 옵션

| 옵션 | 설명 |
|---|---|
| `--hosted-zone-id ID` | 조회 없이 이 존 ID를 바로 쓴다 |
| `--private` | private 호스트존 대상. 새로 만들 땐 `--vpc-id`, `--vpc-region` 필요 |
| `--comment TEXT` | 신규 호스트존 Comment |
| `--region` | boto3 클라이언트 리전. 기본 `us-east-1` (Route 53 API는 글로벌이라 서명용) |
| `--profile` | AWS 프로파일 |
| `-y, --yes` | 개별 확인 없이 감지된 걸 전부 적용 |
| `--dry-run` | 비교까지만 하고 아무 것도 쓰지 않음 |
| `--allow-delete` | 삭제 후보 노출 (기본 꺼짐) |
| `--allow-apex-ns` | apex NS도 비교/적용 대상에 포함 (기본 꺼짐, 위험) |
| `--batch-size N` | 한 번의 `change_resource_record_sets` 요청에 담을 변경 수. 기본 200 |
| `--wait` | 배치 제출 후 INSYNC 될 때까지 기다림 |

## zone 파일 파싱

BIND 문법을 대충 흉내낸 정도다. 지원하는 것:

- `$ORIGIN`, `$TTL` 지시자
- `;` 주석 (따옴표 안의 `;`는 주석으로 안 본다)
- 괄호로 여러 줄에 걸친 레코드 (SOA 등)
- 소유자 이름 생략(들여쓰기로 이전 레코드와 같은 이름 표시)
- TTL·class(`IN`) 생략, 순서 무관

Route 53이 지원하는 타입만 반영한다: A, AAAA, CAA, CNAME, DS, MX, NAPTR, NS,
PTR, SOA(무시), SPF, SRV, TXT. DNSKEY, SSHFP, TLSA, HINFO 등은 건너뛰고
개수만 알려준다.

값 비교는 (이름, 타입) 단위 레코드셋 전체로 한다. 같은 이름·타입에 값이
여러 개 나오면(A 레코드 여러 IP처럼) 하나의 레코드셋으로 묶고, TTL이 서로
다르면 제일 큰 값을 쓴다.

## 알아둘 것

- CloudShell은 콘솔 세션 자격증명을 자동으로 물려받는다. 별도 설정 없이
  그냥 실행하면 된다. 로컬에서 쓰려면 `--profile`로 지정하거나
  `aws configure`로 자격증명을 맞춰 둘 것.
- alias 레코드(예: ALB 앞단에 건 A 레코드)는 비교 대상에서 뺀다. zone 파일
  문법으로는 alias 여부를 표현할 방법이 없어서, Route 53 쪽에 alias로 되어
  있는 레코드는 그대로 두고 개수만 알려준다.
- 존 자체를 실수로 지우거나 대량 삭제하는 걸 막으려고 삭제는 항상
  명시적으로 켜야 하고, 개별 확인의 기본값도 "아니오"다.
- 호스트존 조회(`list_hosted_zones_by_name`)는 boto3 표준 페이지네이터가 없는
  오퍼레이션이라 `IsTruncated`/`NextDNSName`/`NextHostedZoneId`로 직접 돈다.
  같은 파일에서 쓰는 `list_resource_record_sets`는 표준 방식이라 페이지네이터를
  그대로 쓴다.
