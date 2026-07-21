# scripts

일회성 검증(`kubernetes/test/`)이 아니라 **반복 실행되는 운영 도구**. 서비스가 늘어날 때마다 다시 쓰는 스크립트가 여기 모인다.

## onboard-app-db.sh

서비스가 실제로 DB 를 쓰기 시작하는 시점에 전용 DB/유저 생성 + 대상 네임스페이스에 Secret 등록.

```bash
DB_HOST=$(terraform -chdir=terraform output -raw heatwave_ip) \
DB_PORT=$(terraform -chdir=terraform output -raw heatwave_port) \
  scripts/onboard-app-db.sh <service> <namespace>
```

- 생성물: DB `<service>_db`, 유저 `app_<service>`(해당 DB 한정 CREATE/ALTER/INDEX/SELECT/INSERT/UPDATE/DELETE), 대상 네임스페이스 Secret `db-creds`(keys: `username`/`password`/`database`/`host`/`port`)
- admin 계정으로 1회 접속해 유저를 만드는 방식 — `kubernetes/test/database`의 smoketest 와 동일 패턴(정적 Pod 매니페스트, `default` NS, PSA/ambient 영향 회피) 재사용, PSA·seccomp 준수 컨테이너로 실행 후 자동 정리(`trap cleanup EXIT`)
- 장기적으로는 Vault Database secrets engine 이 이 스크립트를 대체 — 그 전까지의 브릿지. 새로 만든 `app_<service>` 계정은 Vault 이관 대상 목록에 추가할 것.
- **재실행 주의**: 이미 존재하는 서비스에 다시 돌리면 `CREATE USER IF NOT EXISTS`가 기존 유저 비밀번호는 그대로 두는 반면, 스크립트는 매번 새 랜덤 비밀번호를 생성해 k8s Secret을 덮어쓴다 — 그러면 Secret과 실제 DB 비밀번호가 어긋나 앱이 연결을 잃는다. 유저를 새로 만드는 게 아니라면 아래 `onboard-app-grant.sh`를 대신 써라.

## onboard-app-grant.sh

이미 `onboard-app-db.sh`로 만든 `app_<service>` 유저에게, 유저/비밀번호/Secret은 그대로 두고 **추가 스키마만 만들어 GRANT**한다.

```bash
DB_HOST=$(terraform -chdir=terraform output -raw heatwave_ip) \
DB_PORT=$(terraform -chdir=terraform output -raw heatwave_port) \
  scripts/onboard-app-grant.sh <service> <extra-db>
```

용도 두 가지:
- 서비스가 두 번째 스키마를 추가로 쓰게 될 때. 예: batch 의 Spring Batch 메타 스키마 — `scripts/onboard-app-grant.sh batch batch_meta`
- `onboard-app-db.sh`가 만든 기존 스키마에 권한을 더 부여해야 할 때 (예: 최초 GRANT에 없던 `DROP`/`REFERENCES`). `<extra-db>`에 기존 DB 이름(예: `auth_db`)을 그대로 넘기면 `CREATE DATABASE IF NOT EXISTS`는 no-op이 되고 GRANT만 새로 적용된다.

`CREATE USER`를 하지 않고 항상 존재하는 유저를 대상으로 GRANT만 실행하므로 몇 번을 다시 돌려도 비밀번호/Secret에는 영향이 없다.
