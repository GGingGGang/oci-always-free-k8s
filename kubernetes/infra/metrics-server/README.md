# metrics-server (Resource Metrics API)

`metrics.k8s.io` aggregated API 제공 — `kubectl top` / HPA(CPU·메모리 기준)의 리소스 메트릭 소스.
kube-prometheus-stack(node-exporter·Prometheus)과 별개: 그쪽은 스크랩 기반 장기 시계열, 이쪽은 in-memory 단기 메트릭 + 쿠버네티스 표준 Metrics API. `kubectl top`은 후자만 사용한다.

참조:
- https://github.com/kubernetes-sigs/metrics-server (chart `metrics-server/metrics-server`)
- https://kubernetes-sigs.github.io/metrics-server/ (helm repo)
- https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/

## 1. 전제 조건

- `kube-system` 네임스페이스 (기본 존재 — 별도 생성 불필요)
- Helm 3.6+
- Argo CD `metrics-server` Application은 chart `3.13.1`을 핀한다. chart↔app 버전이 분리돼 있으니 설치 전 확인:
  ```bash
  helm search repo metrics-server/metrics-server --versions | head
  ```

## 2. 설치

Argo CD Application은 `cicd`에 있으며 sync wave `2`로 `kube-system`에 배포한다. 아래 수동 설치 예시는 저장소 루트에서 실행한다. 같은 릴리스를 Argo CD와 Helm이 동시에 관리하지 않도록 한다.

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --version 3.13.1 -f kubernetes/infra/metrics-server/values.yaml --wait
```

## 3. 검증

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
# 기대: AVAILABLE=True

kubectl get deploy metrics-server -n kube-system

kubectl top nodes
kubectl top pods -A
```

APIService 등록 후 첫 수집까지 `--metric-resolution`(15s) × 2 주기 정도 대기. 그 전엔 `metrics not available yet`이 잠깐 뜰 수 있다.

동작 실패 시:

```bash
kubectl logs -n kube-system -l k8s-app=metrics-server --tail=100
kubectl describe apiservice v1beta1.metrics.k8s.io
```

## 4. 결정

### infra 계층 배치

aggregated API(`metrics.k8s.io`)를 클러스터 전역에 등록하고 HPA·`kubectl top`이 전역으로 의존하는 코어 애드온. 특정 워크로드를 얹는 platform 서비스가 아니라 cert-manager·external-dns와 동급의 클러스터 기반 계층이라 `infra/`에 둔다.

### `--kubelet-insecure-tls`

metrics-server는 기본적으로 kubelet HTTPS 엔드포인트의 serving 인증서를 클러스터 CA로 검증한다. OKE 워커 노드의 kubelet serving cert가 클러스터 CA 체인으로 서명되지 않으면(자체 서명) 검증 실패 → 메트릭 수집 불가(`Metrics API not available`). 플래그로 검증을 우회한다.

- 트레이드오프: metrics-server↔kubelet 구간은 TLS로 암호화되지만 인증서 검증을 생략하므로 중간자 공격에 취약하다.
- 별도로 chart `3.13.1`의 기본 `apiService.insecureSkipTLSVerify: true`는 API 서버가 metrics-server 인증서를 검증하지 않게 한다. 이는 kubelet 연결 플래그와 별개의 구간이다.
- 정석: kubelet serving cert를 클러스터 CA로 서명(`--rotate-server-certificates` + CSR 자동 승인). 관리형 노드는 이 제어가 제한적이라 `--kubelet-insecure-tls`가 현실적.
- 작성 시점 추론 — 플래그 없이 `kubectl top`이 동작하는 환경이면 `values.yaml`의 `args`에서 제거 권장.

### single replica

Always Free tight. metrics-server 다운 시 `top`과 리소스 메트릭 기반 HPA 판단이 일시적으로 불가하다. 여러 메트릭을 쓰는 HPA는 다른 메트릭으로 확장할 수 있다. HA 필요 시 `replicas: 2` + PodDisruptionBudget.

### 리소스 핀

mem limit만 설정(cpu limit 미설정 — throttling 회피, monitoring/openbao 등 기존 컴포넌트 정합). 메모리는 노드·파드 수에 비례 증가하므로 클러스터 확장 시 limit 상향.

## 5. 주의 사항

### Prometheus Adapter 와 공존

HPA를 커스텀/외부 메트릭(Prometheus 쿼리 등)으로 돌릴 땐 Prometheus Adapter가 별도. metrics-server는 `metrics.k8s.io`(리소스 메트릭), adapter는 `custom.metrics.k8s.io`/`external.metrics.k8s.io` 담당 — 둘은 충돌 없이 공존한다. 단 adapter를 `metrics.k8s.io`까지 서빙하도록 설정하면 APIService가 겹치니 한쪽만 그 API를 점유해야 한다.

### 메트릭 지연

`--metric-resolution=15s`(chart 기본)는 수집 주기다. `top` 값과 HPA 판단에는 수집 외에도 HPA 동기화 주기 등의 지연이 더해질 수 있다. 수집 주기를 낮추면 kubelet 부하가 증가한다.

### chart 버전

app 버전(metrics-server)과 chart 버전이 분리돼 있다. upgrade 전 `helm search repo metrics-server/metrics-server --versions`로 app 버전 매핑 확인.
