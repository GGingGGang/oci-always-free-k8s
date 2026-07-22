# Namespaces

클러스터 전체 Namespace 구조 + PSA(Pod Security Admission) 라벨.

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
| `monitoring` | kube-prometheus-stack (Prometheus/Alertmanager/Grafana) — Loki/Tempo/Kiali 는 예정 |
| `vault` | OpenBao (PSA `enforce=baseline`, Istio ambient enrolled) |
| `tailscale` | Tailscale subnet router (PSA `enforce=baseline`) |
| `app` | 워크로드 (PSA `enforce=restricted`, Istio ambient enrolled) |
| `core` | MSA 도메인 API 서비스 (PSA `enforce=restricted`, Istio ambient enrolled) |
| `batch` | MSA 도메인 batch 서비스 (PSA `enforce=restricted`, Istio ambient enrolled) |
| `auth` | MSA 도메인 auth API 서비스 (PSA `enforce=restricted`, Istio ambient enrolled) |
| `data` | 백킹 데이터 서비스 — Redis (PSA `enforce=baseline`, Istio ambient enrolled) |
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
- `vault` → `baseline` (OpenBao 는 non-root + `disable_mlock` 운영, IPC_LOCK 불필요)
- `tailscale` → `baseline` (userspace mode — `/dev/net/tun`/NET_ADMIN 불필요)
- `core`/`batch`/`auth` → `restricted` (MSA 서비스 — `app`과 동일 정책)
- `data` → `baseline` (Redis 백킹 — non-root 운영, host 권한 불필요)
- 그 외 인프라 NS → enforce 미적용 (ztunnel/istio-cni 권한 요구)

## 4. 결정

### app 단일 환경

dev/staging/prod 멀티 네임스페이스 분리는 OCI Always Free 24GB RAM 제약에서 비현실적 (각 환경 stack을 N배). 단일 `app` 네임스페이스 + LE staging/prod ClusterIssuer로 환경 분리 역할 흡수.

### PSA 라벨 분배

`app` 만이 아니라 `cicd`/`build` 도 PSA enforce 적용. 라벨 strength 분배:

- `app` → `restricted`: 워크로드. distroless + non-root + read-only FS 강제
- `cicd` → `baseline`: Jenkins/ArgoCD controller. 둘 다 non-root 운영 가능하지만 `baseline` 까지만 — chart 가 가끔 capability 요구 (예: net_bind_service)
- `build` → `privileged`: Kaniko 가 chroot/extract 위해 root + capabilities 필요. enforce 제거 ❌, 명시적으로 `privileged` 부여해서 *의도된 격리* 표현
- `vault` → `baseline`: 시크릿 저장소가 무방비 NS 에 살면 안 됨. OpenBao 는 k8s 에서 `disable_mlock` 운영이 기조라 IPC_LOCK capability 불필요 → baseline 통과
- `istio-system`/`cert-manager`/`external-dns` → enforce 미적용. ambient ztunnel + istio-cni 가 host network / hostPath 등 권한 요구 (cert-manager/external-dns 는 후속 라벨 후보)

핵심: Kaniko 가 root 필요하다고 `cicd` 전체 enforce 풀지 않음 — `build` 로 분리해서 *root 권한이 도달하는 NS* 를 최소화.

### Istio ambient enrollment

`profile: ambient` 설치는 ztunnel/istio-cni(데이터플레인 *능력*)만 깔 뿐, namespace에 `istio.io/dataplane-mode: ambient` 라벨이 없으면 ztunnel이 아무것도 캡처하지 않음. 즉 라벨 없는 NS는 평문 그대로 — `tls_disable`/`--insecure` 같은 "내부 hop은 ztunnel mTLS가 보호" 전제가 성립하지 않음.

enrollment은 opt-in + **무중단** — sidecar 주입과 달리 Pod 재시작/스펙 변경 없이 노드 레벨에서 기존 Pod를 캡처. PSA `restricted`와도 충돌 없음 (Pod에 추가 컨테이너가 안 붙음).

- `app` → enrolled (워크로드 mTLS canary, 최초)
- `core`/`batch`/`auth` → enrolled (MSA 동서 통신 mTLS — east-west AuthorizationPolicy 의 신원 기반)
- `cicd` → enrolled (ArgoCD `--insecure` 내부 hop 평문 해소)
- `vault` → enrolled (OpenBao `tls_disable` 평문 hop 보호 — secret 경로 mTLS)
- `data` → enrolled (app↔Redis hop mTLS — 백킹 서비스 평문 hop 해소)
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

워크로드를 `app` 외부로 확장할 때 (예: dedicated namespace per tenant) 매니페스트에 추가하고 동일 PSA 라벨 부여. 인프라 네임스페이스는 PSA 미적용 원칙 유지.

### MSA 서비스별 네임스페이스

서비스당 1 NS. 단일 `app` NS 에 몰지 않는 사유: NetworkPolicy(L3/L4) 경계와 Istio AuthorizationPolicy `source.namespaces`(L7) 가 모두 NS 단위라, 동서(east-west) 격리를 NS 경계로 선언하면 정책이 단순하고 실수 여지가 준다. `app`(데모 워크로드)과도 분리 — 데모와 MSA 혼재 방지. `core`/`batch`/`auth` 모두 동일 정책(`restricted` + ambient enrolled)으로 실존 — 서비스 레이어(ArgoCD Application/매니페스트)는 세 서비스 모두 적용 완료(`k8s-gitops` 레포 소관, `../../platform/argocd/README.md` §6 참조).

### `verify-images` 라벨

`core`/`batch`/`auth` 에 `verify-images: "true"`. Kyverno `verify-svc-image-signature` 정책(`../../platform/kyverno/README.md`)이 `namespaceSelector`로 이 라벨을 매칭 — 신규 MSA 서비스 온보딩 시 정책 파일 무수정, 이 라벨만 추가하면 서명 검증 스코프에 들어감. `jenkins-shared-library`의 `ci()`가 `services.yaml` `defaults.sign: true`로 전 서비스 서명을 기본값으로 깔기 때문에 라벨도 서비스 NS 생성 시점에 함께 붙이는 게 원칙(서명 없이 라벨만 먼저 붙이면 Enforce 전환 후 admission 거부 위험 — 위 kyverno README §5 참조).
