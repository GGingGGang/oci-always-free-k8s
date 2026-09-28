# Namespaces

클러스터 전체 Namespace 구조 + PSA(Pod Security Admission) 라벨.

출처: [`namespaces.yaml`](./namespaces.yaml). `notify`와 `web` 선언은 커밋 [`7258ae0`](https://github.com/GGingGGang/oci-always-free-k8s/commit/7258ae0c70f037d1586451184bd0a00bf5bd6308)에서 2026-09-17에 추가됐다.

## 1. 전제 조건

- OKE 클러스터에 kubectl 접근 가능

## 2. 설치

```bash
kubectl apply -f namespaces.yaml
```

생성되는 네임스페이스:

| Namespace | 용도 |
|-----------|------|
| `istio-system` | Istio 컨트롤 플레인 (istiod, ztunnel, istio-cni, Gateway) |
| `cert-manager` | cert-manager 전용 |
| `external-dns` | external-dns 전용 |
| `cicd` | ArgoCD, Jenkins (PSA `enforce=baseline`, Istio ambient enrolled) |
| `build` | Kaniko 빌드 Pod 전용 (PSA `enforce=privileged`) |
| `monitoring` | kube-prometheus-stack (Prometheus/Alertmanager/Grafana, PSA `enforce=baseline`) — Loki/Tempo/Kiali 는 예정 |
| `vault` | OpenBao (PSA `enforce=baseline`, Istio ambient enrolled) |
| `tailscale` | Tailscale subnet router (PSA `enforce=baseline`) |
| `app` | 워크로드 (PSA `enforce=restricted`, Istio ambient enrolled) |
| `core` | MSA 도메인 API 서비스 (PSA `enforce=restricted`, Istio ambient enrolled) |
| `batch` | MSA 도메인 batch 서비스 (PSA `enforce=restricted`, Istio ambient enrolled) |
| `auth` | MSA 도메인 auth API 서비스 (PSA `enforce=restricted`, Istio ambient enrolled) |
| `notify` | 알림 워크로드 (PSA `enforce=restricted`, Istio ambient enrolled, 이미지 서명 검증) |
| `web` | 웹 워크로드 (PSA `enforce=restricted`, Istio ambient enrolled, 이미지 서명 검증) |
| `data` | 백킹 데이터 서비스 — Redis, NATS (PSA `enforce=baseline`, Istio ambient enrolled) |
| `kyverno` | Kyverno 정책 엔진 — admission 이미지 서명 검증 (PSA `enforce=baseline`) |

## 3. 검증

```bash
kubectl get ns
kubectl get ns app -o jsonpath='{.metadata.labels}' | jq .
kubectl get ns -L pod-security.kubernetes.io/enforce
kubectl get ns -L istio.io/dataplane-mode
```

ambient enrollment 확인 — 해당 NS의 Pod가 ztunnel 캡처 대상으로 잡히는지:

```bash
istioctl ztunnel-config workloads | grep <pod-name>   # protocol HBONE 이면 mesh 진입
```

PSA enforce 적용 네임스페이스:

- `app` → `restricted`
- `cicd` → `baseline` (Jenkins/ArgoCD 는 root 불필요, agent 도 non-root)
- `build` → `privileged` (Kaniko 가 root + capability 요구)
- `monitoring` → `baseline` (kube-prometheus-stack)
- `vault` → `baseline` (OpenBao 는 non-root + `disable_mlock` 운영, IPC_LOCK 불필요)
- `tailscale` → `baseline` (userspace mode — `/dev/net/tun`/NET_ADMIN 불필요)
- `core`/`batch`/`auth`/`notify`/`web` → `restricted` (서비스 워크로드 — `app`과 동일 정책)
- `data` → `baseline` (Redis/NATS 백킹 — non-root 운영, host 권한 불필요)
- `kyverno` → `baseline` (정책 엔진)
- `istio-system`/`cert-manager`/`external-dns` → enforce 미적용 (매니페스트 기준)

## 4. 결정

### app 단일 환경

dev/staging/prod 멀티 네임스페이스 분리는 OCI Always Free 24GB RAM 제약에서 비현실적 (각 환경 stack을 N배). 단일 `app` 네임스페이스 + LE staging/prod ClusterIssuer로 환경 분리 역할 흡수.

### PSA 라벨 분배

`app`만이 아니라 플랫폼과 데이터 네임스페이스에도 PSA enforce를 적용한다. 라벨 strength 분배:

- `app` → `restricted`: 워크로드의 Pod Security Standards 위반을 admission에서 거부. distroless 이미지, non-root 실행, read-only root filesystem은 각 애플리케이션 Pod 설정으로 별도 지정
- `cicd` → `baseline`: Jenkins/ArgoCD controller. 둘 다 non-root 운영 가능하지만 `baseline` 까지만 — chart 가 가끔 capability 요구 (예: net_bind_service)
- `build` → `privileged`: Kaniko 가 chroot/extract 위해 root + capabilities 필요. enforce 제거 ❌, 명시적으로 `privileged` 부여해서 *의도된 격리* 표현
- `monitoring`/`kyverno` → `baseline`: 각각 kube-prometheus-stack과 정책 엔진
- `vault` → `baseline`: 시크릿 저장소가 무방비 NS 에 살면 안 됨. OpenBao 는 k8s 에서 `disable_mlock` 운영이 기조라 IPC_LOCK capability 불필요 → baseline 통과
- `istio-system`/`cert-manager`/`external-dns` → enforce 미적용. ambient ztunnel + istio-cni 가 host network / hostPath 등 권한 요구 (cert-manager/external-dns 는 후속 라벨 후보)

핵심: Kaniko 가 root 필요하다고 `cicd` 전체 enforce 풀지 않음 — `build` 로 분리해서 *root 권한이 도달하는 NS* 를 최소화.

### Istio ambient enrollment

`profile: ambient` 설치는 ztunnel/istio-cni(데이터플레인 *능력*)만 깔 뿐, namespace에 `istio.io/dataplane-mode: ambient` 라벨이 없으면 ztunnel이 아무것도 캡처하지 않음. 즉 라벨 없는 NS는 평문 그대로 — `tls_disable`/`--insecure` 같은 "내부 hop은 ztunnel mTLS가 보호" 전제가 성립하지 않음.

enrollment은 opt-in + **무중단** — sidecar 주입과 달리 Pod 재시작/스펙 변경 없이 노드 레벨에서 기존 Pod를 캡처. PSA `restricted`와도 충돌 없음 (Pod에 추가 컨테이너가 안 붙음).

- `app` → enrolled (워크로드 mTLS canary, 최초)
- `core`/`batch`/`auth`/`notify`/`web` → enrolled (서비스 워크로드의 동서 통신 mTLS — east-west AuthorizationPolicy 의 신원 기반)
- `cicd` → enrolled (ArgoCD `--insecure` 내부 hop 평문 해소)
- `vault` → enrolled (OpenBao `tls_disable` 평문 hop 보호 — secret 경로 mTLS)
- `data` → enrolled (app↔Redis/NATS hop mTLS — 백킹 서비스 평문 hop 해소)
- 제외: `istio-system`(컨트롤플레인 자신), `tailscale`(subnet router — 캡처 시 advertise route 동작 깨짐), `build`(Kaniko 빌드 네트워킹), `kube-*`/`default`
- 보류: `monitoring`(Prometheus scrape 간섭 별도 검토), `cert-manager`/`external-dns`(egress 위주, 가치 낮음)

### 명시적 네임스페이스 선언

helm chart의 `--create-namespace` 옵션 비채택. 네임스페이스 라이프사이클 + 라벨/annotation을 단일 매니페스트로 통제. helm uninstall 시 네임스페이스가 사라지지 않음 (의도된 격리).

## 5. 주의 사항

### PSA 위반 시 동작

`pod-security.kubernetes.io/enforce` 위반 시 Pod 생성이 거부됨 (admission level). Deployment는 만들어지지만 ReplicaSet 단계에서 실패. 디버깅 시 `kubectl get events -n app | grep -i security` 또는 Deployment status의 `FailedCreate` 확인.

### warn / audit 라벨 추가 가능

워크로드 마이그레이션 단계에서 `enforce` 대신 `warn` / `audit`만 부여하면 위반 시 거부 없이 경고/감사 로그만 남김:

```yaml
pod-security.kubernetes.io/warn: restricted
pod-security.kubernetes.io/audit: restricted
```

현재 매니페스트는 `enforce` + `warn` 모두 박힘 (`build` 는 `enforce` 만 — privileged NS 에 restricted warn 은 노이즈).

### 신규 네임스페이스 추가

워크로드를 `app` 외부로 확장할 때 (예: dedicated namespace per tenant) 매니페스트에 추가하고 역할에 맞는 PSA 라벨을 명시한다. 현재 서비스 워크로드는 `restricted`, `cicd`/`monitoring`/`vault`/`tailscale`/`data`/`kyverno`는 `baseline`, `build`는 `privileged`이며 `istio-system`/`cert-manager`/`external-dns`에는 enforce 라벨이 없다.

### 서비스 워크로드별 네임스페이스

서비스당 1 NS. 단일 `app` NS 에 몰지 않는 사유: 동서(east-west) 격리 정책(Istio AuthorizationPolicy `source.namespaces`)이 NS 단위 경계라, NS 경계로 선언하면 정책이 단순하고 실수 여지가 준다. `app`(데모 워크로드)과도 분리한다. `core`/`batch`/`auth`와 새 `notify`/`web`은 모두 `restricted` PSA와 ambient enrollment를 사용하며, `notify`/`web`은 네임스페이스만 이 저장소에서 선언한다. 서비스 Application과 매니페스트의 소관은 `k8s-gitops`다.

### `verify-images` 라벨

`core`/`batch`/`auth`/`notify`/`web`에 `verify-images: "true"`. Kyverno `verify-svc-image-signature` 정책(`../../platform/kyverno/README.md`)이 `namespaceSelector`로 이 라벨을 매칭한다. 신규 서비스 온보딩 때 이 라벨을 네임스페이스 선언과 함께 추가해야 서명 검증 범위에 포함된다. `jenkins-shared-library`의 `ci()`가 `services.yaml` `defaults.sign: true`로 서비스 서명을 기본값으로 사용하므로, 서명 없이 라벨만 먼저 붙이면 Enforce 상태에서 admission이 거부될 수 있다.
