# Tempo

단일 인스턴스 트레이스 저장소. community chart `3.2.1` / Tempo `3.1.1`을 고정하며 기존 Prometheus PVC의 `tempo/` subPath를 사용한다. Argo CD `tempo` Application은 자동 Sync·Prune·Self Heal 없이 수동으로 동기화한다.

## 전제 조건

- Loki와 동일하게 관측 PVC가 Bound이고 `prometheus-db/`가 존재해야 한다. PVC 최상위 GID 2000, mode 2770~2777 및 `storage.ggang.cloud/observability=true` 노드 한 개를 먼저 확인한다.
- Prometheus·Loki·Tempo는 RWO PVC를 공유하므로 같은 노드에 배치한다. 기존 데이터 백업과 디스크 여유를 확인한다.
- Tempo는 앱을 자동 계측하지 않는다. 앱에 OpenTelemetry SDK/자동 계측을 적용하고 OTLP 전송을 설정해야 한다.
- Grafana는 현재 비활성화돼 있다. API로 검증하거나 별도 Grafana에서 Tempo 데이터 소스를 연결한다.

## 설치

저장소 루트에서 실행한다. 준비 Job은 PVC 최상위 `tempo/`만 UID 10001 / GID 2000 / mode 2770으로 만들며 기존 Prometheus·Loki 경로는 변경하지 않는다. 기존 경로의 권한이 예상과 다르면 중단한다. root 초기화 컨테이너는 namespace의 PSA baseline에서 허용되며 restricted 경고가 발생할 수 있다.

```bash
kubectl -n monitoring get pvc
kubectl get nodes -l storage.ggang.cloud/observability=true
kubectl create -f kubernetes/platform/monitoring/tempo/prepare-storage.yaml
kubectl -n monitoring wait --for=condition=Complete job/tempo-storage-check --timeout=180s
kubectl -n monitoring logs job/tempo-storage-check -c prepare
kubectl -n monitoring logs job/tempo-storage-check -c check
```

Git의 추적 브랜치에 변경을 반영한 뒤 `platform-root`의 자동 동기화가 Tempo Application을 등록했는지 확인한다. 부모 앱의 sync-wave는 자식 워크로드의 Ready를 보장하지 않는다. Tempo가 Ready인 것을 확인한 후 Alloy를 동기화한다. 이 작업에 KPS 전체 동기화나 prune은 필요 없다.

```bash
argocd app get tempo
argocd app diff tempo
argocd app sync tempo
kubectl -n monitoring rollout status statefulset/tempo --timeout=300s
argocd app diff alloy
argocd app sync alloy
kubectl -n monitoring rollout status deployment/alloy --timeout=180s
```

앱의 OTLP/HTTP 설정 예시다. SDK별 지원 여부를 확인하고 앱 배포 저장소에서 설정한다. 전체 요청의 10%를 시작값으로 사용하며 서비스 간 trace context를 전달해야 하나의 분산 트레이스로 연결된다.

```bash
OTEL_SERVICE_NAME='<service-name>'
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://alloy.monitoring.svc.cluster.local:4318/v1/traces
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1
```

OTLP/gRPC는 `alloy.monitoring.svc.cluster.local:4317`을 사용한다. 로그 수집 namespace 목록은 OTLP 송신자를 제한하지 않는다.

## 검증

```bash
helm pull tempo --repo https://grafana-community.github.io/helm-charts --version 3.2.1 --destination /tmp
helm lint /tmp/tempo-3.2.1.tgz -f kubernetes/platform/monitoring/tempo/values.yaml
helm template tempo /tmp/tempo-3.2.1.tgz --namespace monitoring \
  -f kubernetes/platform/monitoring/tempo/values.yaml > /tmp/tempo.yaml
kubectl -n monitoring get pods -o wide
kubectl -n monitoring top pod -l app.kubernetes.io/instance=tempo --containers
kubectl -n monitoring logs tempo-0 --tail=100
```

각각 별도 터미널에서 수신 경로와 조회 API를 연결한다.

```bash
kubectl -n monitoring port-forward svc/alloy 4318:4318
```

```bash
kubectl -n monitoring port-forward svc/tempo 3200:3200
```

다른 터미널에서 합성 span을 보내고 같은 trace ID가 조회되는지 확인한다. Python 표준 라이브러리만 사용한다.

```bash
curl -fsS http://127.0.0.1:3200/ready
python3 - <<'PY'
import json
import secrets
import time
import urllib.error
import urllib.request

trace_id = secrets.token_hex(16)
now = time.time_ns()
payload = {"resourceSpans": [{
    "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "tempo-smoke"}}]},
    "scopeSpans": [{"scope": {"name": "tempo-smoke"}, "spans": [{
        "traceId": trace_id, "spanId": secrets.token_hex(8), "name": "storage-check",
        "kind": 1, "startTimeUnixNano": str(now), "endTimeUnixNano": str(now + 1000000)
    }]}]
}]}
request = urllib.request.Request("http://127.0.0.1:4318/v1/traces",
    data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
with urllib.request.urlopen(request, timeout=10) as response:
    result = json.load(response)
assert not result.get("partialSuccess"), result
url = "http://127.0.0.1:3200/api/traces/" + trace_id
print("Trace ID:", trace_id, flush=True)
for attempt in range(30):
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            assert response.read(), "Empty trace response"
        print("PASS:", url)
        break
    except urllib.error.HTTPError as error:
        if error.code != 404 or attempt == 29:
            raise
        time.sleep(2)
PY
```

입력 직후 재시작하면 아직 메모리에 있는 트레이스가 유실될 수 있다. 저장소로 flush된 것을 확인한 뒤 Tempo만 재시작하고, port-forward를 다시 연결해 출력된 trace ID를 재조회한다.

```bash
kubectl -n monitoring rollout restart statefulset/tempo
kubectl -n monitoring rollout status statefulset/tempo --timeout=300s
# port-forward를 다시 연결한 뒤 실행한다.
curl -fsS 'http://127.0.0.1:3200/api/traces/<trace-id>'
```

Grafana를 사용할 경우 클러스터 내 데이터 소스 URL은 `http://tempo.monitoring.svc.cluster.local:3200`이다. 외부 Grafana는 이 주소를 바로 해석할 수 없으므로 별도 사설 접근 경로가 필요하다. 서비스 그래프·span metrics는 이번 구성에 포함하지 않는다.

## 결정

- Tempo 3의 monolithic 모드로 Kafka 없이 실행한다. `/var/tempo` 전체를 영속 경로로 마운트하여 trace block·WAL과 기본 런타임 저장 경로를 함께 보존한다.
- 24시간 보존, 1 replica, 요청 250m/512Mi, 메모리 제한 2Gi, Go 메모리 목표 1536MiB로 시작한다. 실제 부하의 적정 용량을 보장하는 값은 아니다. 검색 병렬성을 제한하고 metrics-generator를 비활성화한다.
- Alloy의 기존 로그 파이프라인을 유지하면서 OTLP → memory limiter → batch → Tempo 경로를 추가한다. 별도 Collector·사이드카는 생성하지 않는다.
- 새 PVC·외부 LoadBalancer·Ingress를 생성하지 않는다. 차트의 기본 Jaeger 수신기도 유지하지만 앱 연결은 OTLP를 사용한다. 이는 Tempo 내부의 프로토콜 호환 기능이며 Jaeger 서버·UI는 배포하지 않는다.

## 주의 사항

- 24시간 보존은 디스크 quota가 아니다. Prometheus·Loki와 디스크를 공유하므로 여유율 25% 미만 경고, 20% 미만에서는 앱 trace sampling 축소·전송 중지를 우선한다. Tempo 종료만으로 Alloy의 재시도 큐가 비워지지는 않는다.
- 단일 인스턴스·로컬 저장소는 고가용성 구성이 아니다. 노드 이동은 기존 볼륨 분리 및 모든 소비자의 동일 노드 배치가 필요하다. 공유 PVC와 기존 데이터 경로를 삭제하지 않는다.
- Alloy 큐는 메모리 기반이다. 재시작·과부하·장기 Tempo 장애 시 트레이스가 유실될 수 있다. 로그와 트레이스가 같은 Alloy 프로세스의 자원을 사용한다.
- ClusterIP는 인증이 아니다. 현재 OTLP·Tempo API에는 인증 계층이 없으며 외부 공개하지 않는다. 네트워크 정책 집행 여부가 확인되지 않은 환경에서 namespace 목록만으로 접근이 제한된다고 가정하지 않는다.

근거: [community chart](https://github.com/grafana-community/helm-charts/tree/main/charts/tempo), [Tempo 단일 프로세스 구성](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/deploy/locally/linux/), [Alloy memory limiter](https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.processor.memory_limiter/). 차트와 공식 문서 확인: 2026-10-28.
