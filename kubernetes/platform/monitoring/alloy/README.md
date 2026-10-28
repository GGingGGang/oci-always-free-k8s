# Alloy

앱 namespace(`app`, `web`, `auth`, `core`, `batch`, `notify`)의 컨테이너 stdout/stderr를 Kubernetes API로 읽어 Loki에 전송한다. `monitoring`에 Deployment 1개·컨테이너 1개로 실행하며 앱 사이드카나 DaemonSet은 추가하지 않는다. chart `1.13.1` / Alloy `v1.20.1`을 고정한다.

## 전제 조건

- 대상 namespace 및 `monitoring`이 존재하고 Loki의 `loki.monitoring.svc.cluster.local:3100` 서비스가 Ready여야 한다.
- Alloy에서 Kubernetes API와 Loki로 통신할 수 있어야 한다. 앱의 HTTP 서비스에 직접 접근할 필요는 없다.
- Loki의 공유 PVC 여유 공간을 확인한다. 기존 72시간 보존은 용량 quota가 아니다.

## 설치

Git 변경을 반영한 뒤 `platform-project`의 chart 저장소 허용과 `platform-root`의 `alloy` Application 등록을 확인한다. Loki와 [Tempo](../tempo/README.md)가 Ready인 상태에서 `alloy`를 수동 동기화한다. 부모 앱의 wave는 자식 워크로드의 Ready를 보장하지 않는다.

```bash
argocd app sync platform-project
argocd app sync platform-root
kubectl -n monitoring rollout status statefulset/loki --timeout=180s
kubectl -n monitoring rollout status statefulset/tempo --timeout=300s
argocd app diff alloy
argocd app sync alloy
kubectl -n monitoring rollout status deployment/alloy --timeout=180s
```

`rbac.namespaces`가 수집 대상의 단일 설정이다. Helm이 이 목록으로 namespace별 Role/RoleBinding과 Alloy discovery 설정을 함께 생성한다. namespace 제거 시 이전 Role/RoleBinding도 Argo CD에서 대상별 prune해야 권한이 회수된다.

## 검증

```bash
helm pull alloy --repo https://grafana.github.io/helm-charts \
  --version 1.13.1 --destination /tmp
helm lint /tmp/alloy-1.13.1.tgz \
  -f kubernetes/platform/monitoring/alloy/values.yaml
helm template alloy alloy --repo https://grafana.github.io/helm-charts \
  --version 1.13.1 --namespace monitoring \
  -f kubernetes/platform/monitoring/alloy/values.yaml > /tmp/alloy.yaml

for ns in app web auth core batch notify; do
  kubectl auth can-i list pods -n "$ns" --as=system:serviceaccount:monitoring:alloy
  kubectl auth can-i get pods/log -n "$ns" --as=system:serviceaccount:monitoring:alloy
done
# 아래 두 항목은 no가 정상이다.
kubectl auth can-i get secrets -n app --as=system:serviceaccount:monitoring:alloy
kubectl auth can-i get pods/log -n data --as=system:serviceaccount:monitoring:alloy
kubectl -n monitoring logs deployment/alloy --tail=100
kubectl -n monitoring top pod -l app.kubernetes.io/instance=alloy --containers
kubectl -n monitoring top pod -l app.kubernetes.io/instance=loki --containers
kubectl -n monitoring port-forward svc/loki 3100:3100
```

별도 터미널에서 최근 실제 앱 로그를 조회하고 해당 Pod의 `kubectl logs`와 비교한다. 대상 Pod가 없거나 새 로그가 없으면 빈 결과만으로 수집 실패를 판단하지 않는다.

```bash
curl -fsSG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={cluster="oci-always-free-k8s",namespace=~"app|web|auth|core|batch|notify"}' \
  --data-urlencode 'since=15m' --data-urlencode 'limit=20'
```

평상시와 앱 배포 중 Alloy/Loki의 메모리, OOM·재시작, 전송 오류(403/429/5xx), 노드 CPU 및 공유 PVC 증가량을 확인한다. 전체 PVC 여유율 25% 미만은 경고, 20% 미만이면 수집 축소·중지를 우선한다. 자원값은 실측 전 시작값이다.

## 결정

- API 기반 수집: hostPath·root·privileged 없이 현재 namespace 보안 정책을 유지한다. node 로그·이벤트·앱 내부 파일은 수집하지 않는다.
- namespace별 Pod `get/list/watch`, `pods/log`의 `get`만 허용한다. Secret·Node·클러스터 전체 조회 권한은 없다.
- Alloy CPU 요청 100m, 메모리 요청 256Mi / 제한 512Mi. CPU 제한은 두지 않는다. 메모리 제한은 과부하 시 로그 전달을 보장하지 않는다.
- namespace, pod, container, service_name, cluster 라벨로 검색한다. service_name은 `app.kubernetes.io/name`, 없으면 컨테이너 이름이다. 로그 본문에서 request ID·사용자 ID 등을 라벨로 만들지 않는다.
- 로그 레벨 필터 없이 앱이 현재 출력하는 로그를 전송한다. 앱의 DEBUG 활성화나 메트릭 수집은 추가하지 않는다.
- Recreate로 교체 중 중복 수집을 줄인다. config reloader는 끄고 차트의 ConfigMap checksum으로 설정 변경 시 Pod를 교체한다.

## 주의 사항

OTLP 트레이스는 4317(gRPC) / 4318(HTTP)에서 수신하여 memory limiter(384MiB, spike 96MiB) → batch(최대 512 spans) → Tempo로 보낸다. 큐는 128 batches, consumer 2개로 제한한다. 앱 계측·전송 설정과 합성 트레이스 검증은 [Tempo 안내](../tempo/README.md)를 따른다. 로그 namespace 목록은 OTLP 접근 제어가 아니다. 트레이스 큐는 메모리 기반이며 로그와 같은 프로세스 자원을 사용한다.

- 단일 인스턴스이며 영속 버퍼를 추가하지 않았다. Alloy 재시작·교체, 장시간 Loki 장애, 노드 로그 회전/삭제 때 로그 유실 또는 재수집이 가능하다. 감사 로그의 무손실 보관 용도가 아니다.
- API 수집은 파일 직접 읽기보다 kubelet CPU·네트워크 사용량이 증가한다. 대상과 로그량을 늘리기 전에 실측한다.
- 기존 Loki는 인증 게이트웨이가 없는 내부 서비스다. 외부로 노출하지 않는다. RBAC는 Kubernetes 로그 읽기 범위를 제한하며 Loki 조회/쓰기 접근 제어를 대신하지 않는다.
- 긴급 중지는 아래처럼 Alloy만 축소한다. 수동 동기화 시 replicas 1로 복구된다. 로그 저장소와 공유 PVC는 삭제하지 않는다.

```bash
kubectl -n monitoring scale deployment/alloy --replicas=0
```

근거: [공식 chart](https://github.com/grafana/alloy/tree/main/operations/helm/charts/alloy), [API 로그 수집](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.kubernetes/), [Kubernetes 로그 수집 예제](https://grafana.com/docs/alloy/latest/collect/logs-in-kubernetes/). 배포 버전과 문서 확인: 2026-10-14.
