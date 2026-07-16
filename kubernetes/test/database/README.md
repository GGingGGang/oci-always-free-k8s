# DB Connection Smoke Test

OKE worker subnet → HeatWave MySQL (`10.0.201.0/28`, port 3306) 의 L4 reachability + TLS handshake + 인증 + 권한까지 한 번에 검증.

본 테스트가 통과해야 추후 앱이 DB 에 붙을 수 있음. 통과 전에 앱 stack (Strimzi / Redis / 앱 서버) 진입 X.

## 1. 전제 조건

- Terraform apply 완료 → HeatWave MySQL 가 떠 있어야
- `terraform output heatwave_ip` 값 확보 (예: `10.0.201.7`)
- `terraform output heatwave_port` 값 확인 (`3306`)
- `terraform.tfvars` 의 `db_admin_password` 값 보유 (Secret 생성용)
- OKE 클러스터 도달 가능 (`kubectl get nodes` OK)

## 2. 설치 (테스트 자원 배포)

### 2-1. Secret 생성

```bash
# tfvars 의 db_admin_password 를 환경변수로 가져옴 (직접 echo 금지)
read -s -p "db_admin_password: " DB_PASSWORD ; echo

kubectl -n default create secret generic db-smoketest-creds \
  --from-literal=username=admin \
  --from-literal=password="$DB_PASSWORD"

unset DB_PASSWORD
```

> admin user 이름은 `terraform/modules/database/variables.tf` 의 `admin_username` default 값 (`admin`). 변경했다면 그 값으로.

### 2-2. Pod 배포

```bash
HEATWAVE_IP=$(terraform -chdir=terraform output -raw heatwave_ip)

sed "s|<heatwave-private-ip>|$HEATWAVE_IP|" \
  kubernetes/test/database/db-smoketest.yaml \
  | kubectl apply -f -
```

기대 출력:
```bash
pod/db-smoketest created
```

## 3. 검증

### 3-1. Pod Running 확인

```bash
kubectl get pod db-smoketest
```

```bash
NAME           READY   STATUS    RESTARTS   AGE
db-smoketest   1/1     Running   0          15s
```

### 3-2. probe 결과 확인

```bash
kubectl logs db-smoketest
```

기대 출력:
```bash
=== probe: TCP + handshake + auth + TLS ===
server_version  server_host  server_now           auth_as    tls_supported  os
8.4.x           <internal>   2026-05-27 10:00:00  admin@%    YES            Linux
=== exit=0 ===
=== probe: schema + privileges ===
Database
information_schema
mysql
performance_schema
sys
Grants for admin@%
GRANT USAGE ON *.* TO `admin`@`%` ...
=== exit=0 ===
```

검증 항목:
- `server_version` — HeatWave 가 노출하는 MySQL 버전 (8.x)
- `auth_as` — 인증된 user 가 `admin@%` 형태로 표시
- `tls_supported` — `YES` (TLS handshake 성공)
- 두 probe 모두 `exit=0`

### 3-3. 대화형 추가 확인 (선택)

```bash
kubectl exec -it db-smoketest -- sh -c \
  'mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" --ssl-mode=REQUIRED'
```

→ 인터랙티브 mysql shell 진입. `\s` 명령으로 connection / SSL cipher 확인 가능.

## 4. 결정

### 4-1. 별도 NS (`app`) 대신 `default` NS 사용

- 다른 smoketest (`nlb-smoketest`, `csi-smoketest`) 와 동일 패턴
- 일시 자원이라 PSA 강제 NS 에 둘 필요 없음
- 실 앱은 `app` NS (PSA restricted) — 거기엔 OTel SDK 가 instrument 된 정식 앱 deployment 가 들어감

### 4-2. 이미지 `docker.io/mysql:8.0`

- MySQL 공식 — HeatWave 와 정확한 wire-protocol 호환
- multi-arch (`linux/amd64`, `linux/arm64`) — Ampere A1 worker 호환
- entrypoint 를 override 해서 mysqld 미시작, client (`mysql` CLI) 만 사용
- uid 999 (mysql user) 로 동작 — `runAsNonRoot: true` 충족

### 4-3. 비밀번호 전달 — `MYSQL_PWD` 환경변수

- `mysql -p<password>` 는 `ps aux` 노출 위험
- `MYSQL_PWD` env var 는 mysql client 가 자동 인식, `ps` 에 노출 X
- 값은 Kubernetes Secret 에서 주입 (코드에 박지 않음)

### 4-4. TLS — `--ssl-mode=REQUIRED`

- HeatWave 는 TLS 강제. `DISABLED` 로는 핸드셰이크 실패
- `REQUIRED` = 암호화 강제, 단 CA 검증 안 함 (HeatWave 의 server cert 가 OCI 내부 CA 발급)
- 실 앱은 `VERIFY_CA` + OCI CA bundle 마운트가 정공법 — 단 본 smoketest 는 reachability + auth + 암호화 동작 확인까지가 목표

### 4-5. Hardcoded IP placeholder + sed 치환

- YAML 내 `<heatwave-private-ip>` 는 placeholder. git 에 실 IP 커밋 X
- `terraform output` 으로 실값 주입 → `kubectl apply` 일회성

## 5. 주의 사항

### 5-1. Always Free / 단일 가용성 도메인

- HeatWave MySQL.Free 는 단일 AD. AD 장애 시 회복 절차 = manual restore from backup
- smoketest 가 통과해도 prod 수준 가용성 보장 X. SLO 산정 시 반영

### 5-2. 사용 후 즉시 정리

```bash
kubectl delete -f kubernetes/test/database/db-smoketest.yaml
kubectl -n default delete secret db-smoketest-creds
```

- Pod 가 `sleep 3600` 으로 살아 있음 — 방치 시 1시간 후 자동 종료. 그래도 명시 삭제 권장
- Secret 도 평문 admin 비밀번호 보유 → 검증 끝나면 즉시 삭제

### 5-3. 실패 시 점검 표

| 증상 | 원인 후보 | 대응 |
|------|-----------|------|
| `Can't connect to MySQL server on '10.0.201.x' (110)` / timeout | sl-db ingress 누락 | `terraform/modules/networking/main.tf` `oci_core_security_list.db` ingress 규칙 확인. workers CIDR (`10.0.102.0/24`) → 3306 허용 여부 |
| 동일 timeout + sl-db 정상 | workers SL egress 누락 | `oci_core_security_list.workers` egress to `10.0.201.0/28:3306` 확인 |
| 동일 timeout + SL 둘 다 정상 | **HeatWave Always Free 인스턴스가 장기 미사용으로 inactive 상태** | OCI 콘솔에서 DB System 상태 확인. `INACTIVE` 면 콘솔에서 재기동(Start) → `UPDATING` 거쳐 `ACTIVE` 전환까지 대기 후 재시도 |
| `Access denied for user 'admin'@'%'` | password 불일치 | `kubectl get secret db-smoketest-creds -o jsonpath='{.data.password}' \| base64 -d` 로 저장값 확인 (디버그 후 즉시 종료) |
| `SSL connection error: protocol version mismatch` | client TLS 버전이 server 미지원 | `--tls-version=TLSv1.2,TLSv1.3` 명시 |
| `ERROR 2003 ... Unknown MySQL server host` | DNS 가 IP literal 을 호스트로 해석 시도 (드물게) | `<heatwave-private-ip>` placeholder 가 sed 치환 안 됨. `kubectl describe pod db-smoketest` env 확인 |
| `ImagePullBackOff` on `mysql:8.0` | OKE worker egress 막힘 / containerd config | `kubectl describe pod db-smoketest` Events. nat gateway / image registry 도달성 확인 |
| `CreateContainerConfigError` | Secret 미생성 또는 key 이름 불일치 | `kubectl get secret db-smoketest-creds` + key 가 `username`/`password` 인지 |
| `Pod 가 Running 되는데 mysql 명령 exit=2` | `command` override 가 적용 안 됨 (옛 manifest cache 등) | `kubectl delete -f ...` 후 재배포 |

### 5-4. 잔여 추적

- 본 smoketest 는 admin user 로 검증. 실 앱은 별도 user (`app_*`) + 제한 권한으로 접속 — 서비스별 온보딩은 [`scripts/README.md`](../../../scripts/README.md)의 `onboard-app-db.sh` 참조 (본 smoketest 와 동일한 admin 1회 접속 패턴)
- Vault 도입 후엔 Secret 직접 생성 대신 Vault Database secrets engine 으로 dynamic credentials 발급. 본 Secret 패턴은 임시
