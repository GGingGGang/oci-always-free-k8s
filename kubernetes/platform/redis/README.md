# Redis (cache)

MSA 워크로드용 인메모리 캐시. cache-aside 패턴 — source of truth 는 DB(HeatWave MySQL), Redis 는 읽기 가속 계층. ephemeral(PV 0).

참조:
- https://redis.io/docs/latest/operate/oss_and_stack/management/config/ (2026-06 확인)

## 1. 전제 조건

- `data` 네임스페이스 + PSA `enforce=baseline` + Istio ambient (`../../infra/namespaces/`)
- 이미지: `docker.io/redis:8.6.4-alpine` (`redis.yaml` 핀, 멀티아치 = ARM64 A1.Flex). 설치 전 태그/아치 확인:
  ```bash
  docker manifest inspect redis:8.6.4-alpine | grep arm64
  ```

## 2. 설치

GitOps — ArgoCD `redis` Application(`apps/redis.yaml`, `path: kubernetes/platform/redis`, `include: "*.yaml"`)이 sync. 부트스트랩/수동 적용:

```bash
kubectl apply -f redis.yaml
```

## 3. 검증

```bash
kubectl get pods,svc -n data -l app.kubernetes.io/name=redis
kubectl exec -n data deploy/redis -- redis-cli ping                          # PONG
kubectl exec -n data deploy/redis -- redis-cli config get maxmemory-policy   # allkeys-lru
```

ambient 캡처 (app↔redis ztunnel mTLS):

```bash
istioctl ztunnel-config workloads -n data | grep redis   # HBONE
```

앱에서 접근 — 클러스터 DNS: `redis.data.svc.cluster.local:6379`.

## 4. 결정

### raw 매니페스트 + 공식 이미지 (Helm/Operator 비채택)

단일 캐시라 operator 불필요. Bitnami 차트는 무료 이미지 정리 이슈 + ArgoCD `platform` AppProject `sourceRepos` 추가 부담. 공식 `redis:*-alpine`(멀티아치) + Deployment/Service 로 재현성·라이선스 단순화. git 만 source 라 `sourceRepos` 변경 0. (OSI 라이선스 필요 시 Valkey 포크가 드롭인 대안.)

### ephemeral (PV 0)

Block Volume 한도(부트 2 + PV 2)의 PV 2칸은 Vault/Prometheus 가 선점 → 캐시에 줄 PV 없음. 캐시는 source of truth 가 아니라 ephemeral 가 *정상* — 재시작 시 비어도 cache-aside 가 DB 에서 백필. `save ""` + `appendonly no` 로 RDB/AOF 비활성, `/data` 는 emptyDir.

### cache-aside + allkeys-lru

`maxmemory 256mb` + `maxmemory-policy allkeys-lru` — 메모리 차면 LRU 축출(캐시 동작). limit `384Mi` 로 redis 오버헤드 헤드룸. cpu limit 미설정(throttling 회피, monitoring 정신과 정합).

### restricted-compliant securityContext

NS 는 baseline 이지만 Pod 는 restricted 수준 — `runAsNonRoot`(999) + `drop: ALL` + `readOnlyRootFilesystem` + seccomp `RuntimeDefault`. `/data` emptyDir 는 `fsGroup: 999` 로 쓰기 허용.

### data 네임스페이스 — app 과 분리

백킹 데이터 서비스(Redis, NATS)를 `app`(restricted, 워크로드)과 분리. `data` 는 baseline + ambient enrolled — app↔redis hop 은 ztunnel L4 mTLS.

## 5. 주의 사항

### 인증 미설정 — in-mesh 한정

현재 `requirepass` 없음. ClusterIP 라 외부 노출 0, ambient mesh 내부 접근만. 멀티테넌트/민감 캐시로 확장 시 `requirepass`(OpenBao 발급) + NetworkPolicy 로 호출자 제한. OpenBao 이관 후보.

### 재시작 = 캐시 비움

ephemeral 이라 pod 재시작/리스케줄 시 전체 비움. cache-aside 라 무손실(DB 백필)이지만 직후 miss 폭증으로 DB 일시 부하 — thundering herd 우려 시 앱에서 TTL 지터/싱글플라이트.

### maxmemory vs container limit

`maxmemory(256mb)` < container limit(`384Mi`) 유지. limit 까지 키우면 redis 가 maxmemory 인지 못 해 OOMKill 위험. 상향 시 동시 조정.
