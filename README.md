# sjkim-test

APEX 도메인의 zone 파일을 공개 DNS 응답으로 재구성하고, 그걸 Route 53
호스트존에 반영하는 스크립트 두 개가 있다. 순서대로 이어 쓰는 걸 기준으로
만들었다.

```
./zone-rebuild.sh example.com                              # example.com.zone 생성
python3 route53-zone-sync.py example.com example.com.zone   # Route 53에 반영
```

## zone-rebuild.sh

도메인 하나를 받아 apex 레코드(SOA, NS, A, AAAA, MX, TXT, CAA, DNSKEY)를
조회하고, NS로 AXFR을 찔러본 뒤 막혀 있으면 내장 워드리스트(209개, `-w`로
교체 가능)로 2차 도메인을 추측 조회해서 zone 파일을 만든다.

`*.example.com` 같은 와일드카드가 걸린 존은 등록되지 않은 이름도 전부 같은
값으로 응답하기 때문에, 랜덤 라벨로 와일드카드 값을 먼저 파악한 뒤 같은 값이
나온 이름은 개별 레코드로 쓰지 않고 zone 파일 끝에 주석으로 몰아둔다. 로테이션
와일드카드나 라벨을 되돌려주는 CNAME 구성도 처리한다. `dig`이 있으면 그걸,
없으면 DNS-over-HTTPS로 대신 조회한다.

자세한 동작과 옵션은 [`zone-rebuild.md`](./zone-rebuild.md) 참고.

## route53-zone-sync.py

`zone-rebuild.sh`가 뽑은 zone 파일(또는 손으로 쓴 zone 파일)을 읽어서 AWS
CloudShell에서 Route 53 호스트존에 반영한다. 호스트존이 없으면 생성 여부를
물어보고, 있으면 기존 레코드셋과 (이름, 타입) 단위로 비교해서 생성/변경 대상을
화면에 보여준 뒤 전체 적용·개별 선택·취소 중 고르게 한다.

apex의 SOA와 NS는 Route 53이 자체 관리하는 값이라 항상 적용에서 빼고
차이만 정보로 보여준다(NS는 `--allow-apex-ns`로 강제 가능, SOA는 불가).
서브도메인 위임용 NS는 정상적으로 비교·적용된다. Route 53에만 있고 zone
파일에는 없는 레코드는 `--allow-delete`를 줘야 삭제 후보로 올라오고, 그
안에서도 개별 확인 기본값은 "아니오"다.

자세한 동작과 옵션은 [`route53-zone-sync.md`](./route53-zone-sync.md) 참고.

## 요구사항

- `zone-rebuild.sh`: bash 4 이상, awk, sed, coreutils. `dig` 또는 (`curl` +
  `jq`나 `python3`)
- `route53-zone-sync.py`: python3, boto3. AWS 자격증명(CloudShell이면 자동)
