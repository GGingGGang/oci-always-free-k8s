# Loki

단일 인스턴스 로그 저장소. `monitoring`의 기존 Prometheus PVC에서 `loki/` subPath를 사용한다. chart `18.15.1`, Loki `3.7.8`을 고정하며 Argo CD `loki` Application으로 수동 동기화한다.

## 1. 전제 조건

- 기존 Prometheus PVC가 `Bound`이고 데이터 경로가 `prometheus-db/`여야 한다. 새 PVC를 만들지 않는다.
- `storage.ggang.cloud/observability=true` 라벨은 현재 볼륨이 연결된 노드 한 개에만 지정한다. Prometheus와 Loki가 같은 라벨로 배치된다.
- PVC 최상위 GID는 2000, 권한은 2770~2777이어야 한다. 다른 경우 아래 준비 Job은 변경 없이 중단한다.
- 기존 데이터의 백업·복구 수단을 확인한다. PV의 `Retain`은 백업이 아니다. Prometheus TSDB snapshot API는 `enableAdminAPI`가 필요하며 현재 기본 설정에서 켜져 있지 않다.
- 최초 검증에는 합성 로그만 사용한다. 현재 인증 없는 ClusterIP이므로 실제 로그 수집기를 연결하기 전에 접근 제어를 마련한다.

## 2. 설치

Prometheus의 기존 데이터·보존 설정(`15d`, `45GiB`)을 유지한다. PVC 전체를 마운트한 준비 Job만 최상위 `loki/`를 생성하며, Prometheus 컨테이너의 `/prometheus` 안에 디렉터리를 만들지 않는다.

```bash
PROM_POD=prometheus-kps-kube-prometheus-stack-prometheus-0
PROM_PVC=prometheus-kps-kube-prometheus-stack-prometheus-db-prometheus-kps-kube-prometheus-stack-prometheus-0
OBS_NODE=$(kubectl -n monitoring get pod "$PROM_POD" -o jsonpath='{.spec.nodeName}')
PROM_PV=$(kubectl -n monitoring get pvc "$PROM_PVC" -o jsonpath='{.spec.volumeName}')

kubectl get nodes -l storage.ggang.cloud/observability=true
kubectl get pv "$PROM_PV"
kubectl label node "$OBS_NODE" storage.ggang.cloud/observability=true --overwrite
kubectl patch pv "$PROM_PV" --type merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

kubectl create -f kubernetes/platform/monitoring/loki/prepare-storage.yaml
kubectl -n monitoring wait --for=condition=Complete job/loki-storage-check --timeout=180s
kubectl -n monitoring logs job/loki-storage-check -c prepare
kubectl -n monitoring logs job/loki-storage-check -c check
```

노드 목록에 다른 노드가 있으면 라벨을 추가하기 전에 배치를 확인한다.

준비 Job은 기존 `prometheus-db/`를 변경하지 않고 새 `loki/`만 UID 10001 / GID 2000 / mode 2770으로 만든다. 재실행 시 소유권이 다르면 자동 수정하지 않고 중단한다. API token은 마운트하지 않는다. root 초기화 컨테이너는 namespace의 PSA baseline 안에서 동작하므로 restricted 경고가 나올 수 있다.

Job을 삭제하고 같은 파일로 재생성한 뒤 로그의 `Existing storage marker preserved`를 확인한다. 삭제 대상은 Job이며 PVC는 유지한다.

```bash
kubectl -n monitoring delete job loki-storage-check
kubectl create -f kubernetes/platform/monitoring/loki/prepare-storage.yaml
kubectl -n monitoring wait --for=condition=Complete job/loki-storage-check --timeout=180s
kubectl -n monitoring logs job/loki-storage-check -c check
```

준비 성공 후 Git 변경을 반영한다. `platform-project`는 community chart 저장소를 허용하고, `platform-root`는 `loki` Application을 등록한다. 두 부모 앱에는 자동 동기화가 있지만 `kps`·`loki` 자체는 수동 동기화다. `kps`에서 Prometheus의 노드 라벨·`fsGroupChangePolicy` 변경을 먼저 동기화하고 Ready를 확인한 뒤 `loki`를 동기화한다. Prometheus Pod 교체에 따른 짧은 수집 공백이 있을 수 있다. 전체 prune은 필요 없다.

## 3. 검증

```bash
kubectl -n monitoring rollout status statefulset/loki --timeout=180s
kubectl -n monitoring get pods -o wide
kubectl -n monitoring top pod -l app.kubernetes.io/instance=loki --containers
kubectl -n monitoring port-forward svc/loki 3100:3100
```

별도 터미널에서 소량의 로그를 저장·조회한다.

```bash
curl -fsS http://127.0.0.1:3100/ready
printf '{"streams":[{"stream":{"job":"loki-smoke"},"values":[["%s","loki storage check"]]}]}' "$(date +%s%N)" \
  | curl -fsS -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:3100/loki/api/v1/push
curl -fsSG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="loki-smoke"}' --data-urlencode 'limit=10'
```

Loki만 재시작한 뒤 Ready와 같은 로그의 재조회를 확인한다. port-forward 연결이 끊어졌으면 다시 연결한다.

```bash
kubectl -n monitoring rollout restart statefulset/loki
kubectl -n monitoring rollout status statefulset/loki --timeout=180s
kubectl -n monitoring top pod -l app.kubernetes.io/instance=loki --containers
```

현재 메모리(MiB)를 확인하는 PromQL:

```promql
sum by (pod) (
  container_memory_working_set_bytes{
    namespace="monitoring", pod=~"loki-[0-9]+", container!="", container!="POD"
  }
) / 1024 / 1024
```

기동뿐 아니라 입력·조회 중 사용량, OOM·재시작, 노드 여유를 확인한다. 소량 테스트 성공이 실제 수집 부하 검증을 대신하지 않는다.

## 4. 결정

- WAL·chunk·TSDB index/cache·compactor 상태를 모두 `/var/loki-persistent` 아래에 둔다. 차트의 기본 `/var/loki` emptyDir는 영속 데이터 경로로 사용하지 않는다.
- `singleBinary.persistence.enabled: false`는 차트의 새 PVC 생성을 끄는 설정이다. 실제 저장은 `extraVolumes`의 기존 PVC를 사용한다.
- UID 10001과 공통 fsGroup 2000, OnRootMismatch를 사용한다. 볼륨 전체 재귀 chown은 하지 않는다.
- requests 250m/512Mi, memory limit 1Gi로 시작한다. 입력 1MiB/s·burst 2MiB, query 병렬성 2로 초기 자원 사용을 제한한다.
- filesystem backend, 72h retention, 1 replica. gateway·canary·캐시·MinIO·ruler는 생성하지 않는다. 서비스 계정 API token 및 불필요한 chart RBAC도 생성·마운트하지 않는다.

## 5. 주의 사항

- subPath와 72h retention은 용량 quota가 아니다. 공유 디스크가 차면 Prometheus에도 영향을 준다. 전체 PVC 여유율 25% 미만 경고, 20% 미만에서는 신규 로그 입력 축소·중지를 초기 운영 기준으로 삼는다.
- RWO 공유는 같은 노드 배치가 필요하다. 장애 시 기존 노드의 쓰기 중단·볼륨 분리를 확인하고 모든 소비자를 함께 이동한다. 라벨을 두 노드에 동시에 붙여 자동 장애 복구를 기대하지 않는다.
- Loki 제거 시 공유 PVC를 삭제하거나 `loki/`를 자동 정리하지 않는다. 테스트 Job은 완료 1시간 뒤 정리되지만 marker 파일은 subPath에 남는다.
- Loki 자체의 `auth_enabled`는 사용자 인증을 제공하는 옵션이 아니다. 현재 구성을 외부 공개하지 않으며, 실제 로그 연결 전 허용할 수집기·조회 주체와 강제 가능한 접근 제어를 정한다.

근거: [Loki Helm monolithic 설치](https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/), [retention](https://grafana.com/docs/loki/latest/operations/storage/retention/), [Kubernetes subPath](https://kubernetes.io/docs/concepts/storage/volumes/#using-subpath), [Prometheus snapshot](https://prometheus.io/docs/prometheus/latest/querying/api/#snapshot). 차트 18.15.1은 공식 community index에서 2026-10-09 발행을 확인했으며 문서는 2026-10-13 조회 기준이다.
