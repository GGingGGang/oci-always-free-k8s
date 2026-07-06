# scripts

일회성 검증(`kubernetes/test/`)이 아니라 **반복 실행되는 운영 도구**. 서비스가 늘어날 때마다 다시 쓰는 스크립트가 여기 모인다.

## onboard-app-db.sh

서비스가 실제로 DB 를 쓰기 시작하는 시점에 전용 DB/유저 생성 + 대상 네임스페이스에 Secret 등록.

```bash
DB_HOST=$(terraform -chdir=terraform output -raw heatwave_ip) \
DB_PORT=$(terraform -chdir=terraform output -raw heatwave_port) \
  scripts/onboard-app-db.sh <service> <namespace>
```

- 생성물: DB `<service>_db`, 유저 `app_<service>`(해당 DB 한정 SELECT/INSERT/UPDATE/DELETE), 대상 네임스페이스 Secret `db-creds`(keys: `username`/`password`/`database`/`host`/`port`)
- admin 계정으로 1회 접속해 유저를 만드는 방식 — `kubernetes/test/database`의 smoketest 와 동일 패턴(정적 Pod 매니페스트, `default` NS, PSA/ambient 영향 회피) 재사용, PSA·seccomp 준수 컨테이너로 실행 후 자동 정리(`trap cleanup EXIT`)
- 장기적으로는 Vault Database secrets engine 이 이 스크립트를 대체 — 그 전까지의 브릿지. 새로 만든 `app_<service>` 계정은 Vault 이관 대상 목록에 추가할 것.
