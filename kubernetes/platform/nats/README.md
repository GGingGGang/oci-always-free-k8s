# NATS (JetStream)

MSA 이벤트 백본. 단일 서버 + JetStream file store — at-least-once, durable consumer, DLQ, replay 를 제공.

참조:
- https://docs.nats.io/nats-concepts/jetstream (2026-07 확인)
- https://github.com/nats-io/k8s/tree/main/helm/charts/nats (chart `nats/nats`)

## 1. 전제 조건

- `data` 네임스페이스 + PSA `enforce=baseline` + Istio ambient (`../../infra/namespaces/`)
- ArgoCD `platform` AppProject `sourceRepos` 에 `https://nats-io.github.io/k8s/helm/charts/` 등록 (`../argocd/project.yaml`)
- Block Volume CSI (`oci-bv`) 여유 50GB 1칸 — 최소 생성 단위가 50GB 라 그보다 작게 못 잡음
- 차트 버전 확인 (작성 시점 `2.14.2`):
  ```bash
  helm repo add nats https://nats-io.github.io/k8s/helm/charts/
  helm search repo nats/nats --versions | head
  ```

## 2. 설치

GitOps — ArgoCD `nats` Application(`apps/nats.yaml`, wave 6). 차트는 helm repo, values 는 본 레포에서 `$values` 로 참조하는 2-source 구성. 부트스트랩/수동:

```bash
helm install nats nats/nats -n data --version 2.14.2 -f values.yaml --wait
```

## 3. 검증

```bash
kubectl get pods,svc,pvc -n data -l app.kubernetes.io/name=nats
kubectl exec -n data nats-0 -c nats -- nats-server --version

# JetStream 활성 + 스토리지 한도
kubectl exec -n data nats-0 -c nats -- wget -qO- localhost:8222/jsz
```

CLI 왕복은 일회성 nats-box 로 (상주 파드 없음):

```bash
kubectl -n data run natsbox --rm -it --restart=Never \
  --image=docker.io/natsio/nats-box:0.19.7 -- \
  nats -s nats://nats:4222 server report jetstream
```

ambient 캡처 (app↔nats ztunnel mTLS):

```bash
istioctl ztunnel-config workloads -n data | grep nats   # HBONE
```

앱에서 접근 — 클러스터 DNS: `nats://nats.data.svc.cluster.local:4222`.

## 4. subject / stream 설계

subject 최상위를 도메인으로 가른다 — 후속에 account 로 권한 격리할 때 경계가 그대로 쓰임.

| subject | 용도 | stream |
|---------|------|--------|
| `app.schedules.created.v1` / `.updated.v1` / `.deleted.v1` | core → batch 일정 이벤트 | `APP_SCHEDULES` |
| `app.schedules.dlq.>` | 소비 실패 격리 | `APP_SCHEDULES_DLQ` |
| `cicd.>` | 빌드·배포 이벤트 (후속) | `CICD_EVENTS` |

stream 은 subject 가 겹치면 생성이 거부되므로 `APP_SCHEDULES` 는 와일드카드가 아니라 **3개 subject 를 명시**해 DLQ 와 분리한다.

정책: `storage: file`, `replicas: 1`(단일 서버), `max_age: 7d`, `discard: old`, stream 별 `max_bytes` 로 볼륨 대비 상한. 소비는 durable pull consumer `batch-reminders` + `AckExplicit` — DB 트랜잭션 커밋 후 ack.

stream/consumer 생성은 이 레포가 아니라 **앱 쪽 책임**(기동 시 선언 또는 CLI). 선언적 CR 이 필요해지면 nack controller 도입 검토.

## 5. 결정

### Kafka(Strimzi) 대체

요구 시맨틱스(at-least-once, 수동 ack, DLQ, 중복 방어, 저볼륨 순서)는 JetStream 이 전부 충족하는데 Kafka 는 브로커+operator 로 ~1.1Gi 를 쓰고 파티션·컨슈머 그룹·대량 replay 는 미사용이었다. 단일 파드로 축소하고 operator 운영 표면(롤링·CA 갱신·이중 업그레이드)을 제거.

### 단일 서버 + R1 stream

`cluster.enabled: false`. 노드 2개라 JetStream 쿼럼(R3)이 성립하지 않고 R2 는 의미가 없다. 스트림도 `replicas: 1` — HA 없음, 볼륨 내구성으로 대체.

### file store + `max_file_store` 하드캡

`fileStore` 50Gi PVC(`oci-bv`) + `max_file_store: 45Gi`. 캡을 볼륨보다 낮게 둬야 JetStream 이 파일시스템을 100% 채우기 전에 publish 를 거부한다(가득 찬 뒤 복구가 더 비쌈). memoryStore 는 비활성.

### 이미지 풀네임 핀

`fullImageName` 으로 `docker.io/...` 까지 명시. 노드 런타임이 cri-o 라 short-name(`nats:2.14.2-alpine`)은 해석 거부된다. 3개 컨테이너(서버/reloader/exporter) 전부 arm64 매니페스트 보유(A1.Flex).

### restricted-compliant securityContext

NS 는 baseline 이지만 Pod 는 restricted 수준. 공식 nats 이미지에 `USER` 지시자가 없어 기본 root 로 뜨므로 `runAsNonRoot`(1000) 를 명시해야 한다. PVC 는 `fsGroup: 1000` 으로 쓰기 허용, `readOnlyRootFilesystem` — 쓰기 경로는 `/data`(PVC) 와 `/var/run/nats`(emptyDir) 뿐.

### promExporter + PodMonitor

sidecar exporter 가 `localhost:8222` 를 긁어 7777 로 노출. PodMonitor 에 `release: kps` 라벨 — kps Prometheus 의 셀렉터가 그 라벨이라 없으면 수집되지 않는다.

### natsBox / PDB 비활성

nats-box 는 상주시키지 않고 필요할 때 일회성 파드로(§3). PDB 는 replica 1 에서 노드 drain 만 막으므로 끔.

## 6. 주의 사항

### 인증 미설정 — in-mesh 한정

계정/사용자 없음. ClusterIP 라 외부 노출 0, ambient mesh 내부 접근만. 멀티테넌트로 확장 시 account 분리(`app` / `cicd`) + nkey/creds(OpenBao 발급) + AuthorizationPolicy 호출자 제한.

### stream max_bytes 미설정 시 캡이 서버 단위

`max_file_store` 는 서버 전체 한도라 stream 하나가 다 먹을 수 있다. stream 마다 `max_bytes` 를 걸어야 격리된다.

### PVC 크기 하향 불가

`oci-bv` 는 확장만 가능하고 축소가 안 된다. 50Gi 는 OCI 최소 생성 단위라 더 작게 잡을 수도 없다.
