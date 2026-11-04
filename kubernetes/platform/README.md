# platform

infra 부트스트랩(Gateway / TLS / DNS) 위에서 동작하는 플랫폼 계층. CI/CD(ArgoCD, Jenkins) + 시크릿(OpenBao) + 관측(kube-prometheus-stack) + 데이터 백킹(Redis, NATS — `data` NS) 도입.

각 폴더는 컴포넌트 단위로 관리한다. OpenBao와 관측 저장소 등은 다른 구성요소와 PVC·CRD 의존성이 있으므로 각 설치 순서를 따른다.

Jenkins controller의 CPU request는 100m, 빌드 agent 컨테이너의 CPU request는 0이다. Jenkins의 Trivy는 [노드별 hostPath 캐시](jenkins/README.md)를 사용한다. 공유 라이브러리 반영 후 Jenkins를 동기화하면 새 빌드가 배치된 노드에서 캐시를 재사용한다. 별도 PV/PVC와 노드 고정은 없다.
Trivy에는 Jenkins 공유 작업 경로의 실행·로그 파일에 접근하는 `DAC_OVERRIDE`만 추가하고 나머지 capability는 제거한다.
2026-10-14 `svc-auth`의 동일 노드 후속 빌드에서 Image Scan은 98.281초에서 27.338초로 단축됐다. [실측 조건과 빌드별 결과](jenkins/README.md#캐시-재사용-실측--2026-10-14)를 기록했다.

## 1. 구성

| 폴더 | 역할 | helm 릴리즈 | NS | 외부 노출 |
|------|------|------------|-----|----------|
| `argocd/` | GitOps 컨트롤 플레인 | argo/argo-cd `7.7.23` | `cicd` (PSA baseline) | tailnet (parked — `argocd.ggang.cloud` 주석 처리) |
| `jenkins/` | JCasC Jenkins + Kaniko 동적 빌드 | jenkins/jenkins `5.10.3` | `cicd` controller / `build` 빌드 Pod (PSA privileged) | admin: tailnet (parked) / webhook: `ci-hook.ggang.cloud` `/github-webhook/` (active) |
| `openbao/` | 시크릿 저장소 (Raft 1 + OCI KMS auto-unseal, NATS PVC subPath 공유, Injector 비활성) | openbao/openbao `0.28.5` | `data` (PSA baseline) | 없음 (port-forward) |
| `monitoring/kps/` | 관측 (메트릭/알림, Grafana 비활성) | prometheus-community/kube-prometheus-stack `75.0.0` | `monitoring` (PSA baseline) | 없음 (Grafana 비활성, HTTPRoute 주석 처리) |
| `monitoring/loki/` | 로그 저장소, 기존 관측 PVC의 별도 subPath | grafana-community/loki `18.15.1` | `monitoring` (PSA baseline) | 없음 (ClusterIP) |
| `monitoring/tempo/` | 트레이스 저장소, 기존 관측 PVC의 별도 subPath | grafana-community/tempo `3.2.1` | `monitoring` (PSA baseline) | 없음 (ClusterIP) |
| `monitoring/alloy/` | 앱 namespace 6개의 API 로그 수집 → Loki, 단일 Deployment | grafana/alloy `1.13.1` | `monitoring` (PSA baseline) | 없음 (ClusterIP) |
| `redis/` | MSA 캐시 (cache-aside, ephemeral) | — (raw manifest, `redis:*-alpine`) | `data` (PSA baseline, ambient) | 없음 (ClusterIP) |
| `nats/` | MSA 이벤트 백본 (JetStream file store) | nats/nats `2.14.2` | `data` (PSA baseline, ambient) | 없음 (ClusterIP) |
| `kyverno/` | 정책 엔진 — 지정 namespace와 `ghcr.io/ggingggang/svc-*` 이미지 서명 admission 검증 | kyverno/kyverno `3.8.2` + ClusterPolicy | `kyverno` (PSA baseline) | 없음 |

## 2. 전제 조건 (infra 의존)

platform 컴포넌트는 infra 계층(`../infra/`) 위에서 동작한다. Gateway, TLS, DNS는 공개 HTTPRoute 사용 시 필요하다.

- `cicd`, `build`, `data`, `monitoring`, `kyverno` 네임스페이스와 PSA 라벨 (`../infra/namespaces/`)
- 공개 노출 시 Gateway API CRD + `public-gateway` (`*.ggang.cloud` listener) 동작 (`../infra/istio/`)
- 공개 노출 시 wildcard TLS Secret `public-wildcard-tls` Ready=True (`../infra/cert-manager/`)
- 공개 노출 시 external-dns 동작 (`../infra/external-dns/`) — HTTPRoute hostname → Cloudflare DNS 자동 sync
- Helm 3.6+

## 3. 설치 순서

infra 부트스트랩 완료 후:

```
1. argocd       helm + AppProject/root 부트스트랩 (HTTPRoute는 주석 처리)
2. jenkins      rbac + Secret(ghcr-push · ghcr-pull · cosign-key@build, jenkins-git-pat · jenkins-admin-fixed@cicd) + helm + webhook httproute
3. nats         JetStream file store + oci-bv PVC 50Gi
4. monitoring   KPS CRD → monitoring-resources → KPS, 이후 저장 경로 준비 후 Loki/Tempo → Alloy
5. redis        kubectl apply (raw manifest, data NS)
6. openbao      terraform (kms + iam) + NATS Pod/PVC 준비 → 수동 storage-prepare Job → data에 Helm 설치 → 빈 저장소만 초기화
7. kyverno      helm → ClusterPolicy (정책은 kyverno CRD 선행)
```

OpenBao는 KMS 권한과 실행 중인 NATS Pod·PVC의 `jetstream` 디렉터리가 필요하다. 준비 Job과 OpenBao는 수동 관리하며, 기존 데이터가 있는 저장소를 재초기화하지 않는다. NATS와 OpenBao는 단일 50Gi RWO PVC를 subPath로 공유하므로 용량과 장애가 격리되지 않는다. 자동 백업은 구성되지 않았다. Kyverno 정책은 차트의 CRD가 선행되어야 한다. 각 단계와 기존 데이터 이전은 해당 폴더 README를 따른다.

## 4. 외부 노출 / TLS

Argo CD와 Jenkins admin UI의 public HTTPRoute는 주석 처리되어 tailnet ClusterIP 접근을 사용한다. Grafana는 비활성이다. 체크인된 Jenkins webhook route는 `ci-hook.ggang.cloud`의 `/github-webhook/` PathPrefix를 공개하며, HMAC 검증 설정은 확인되지 않는다. `*.ggang.cloud` 와일드카드 인증서로 Gateway 단일 TLS 종료, HTTP→HTTPS redirect는 `../infra/istio/http-redirect.yaml` catch-all.

**데이터 계층(redis/nats)**은 ClusterIP이며 인증이 설정되어 있지 않다. Ambient namespace 라벨만으로 모든 경로의 mTLS나 비인가 클라이언트 차단을 보장하지 않으므로 실제 경로와 접근 정책을 검증해야 한다. external-dns가 active HTTPRoute의 `hostnames`를 source로 Cloudflare A 레코드 등록.

## 5. GitOps 모델

본 레포의 app-of-apps(`argocd/project.yaml` + `argocd/root.yaml` + `argocd/apps/`)는 Application 정의를 관리한다. `platform-root`, `platform-project`, `app-layer-root`는 자동 sync하지만 플랫폼 워크로드 Application은 수동 sync한다. 부모의 sync-wave만으로 자식 워크로드의 준비가 보장되지는 않는다. Gateway API CRD, OpenBao, Tailscale은 별도 관리한다. 부트스트랩과 의존 순서는 [Argo CD 안내](argocd/README.md)를 따른다.

`app-layer-root`가 가리키는 별도 [k8s-gitops](https://github.com/GGingGGang/k8s-gitops)의 `apps-root`와 서비스 Application은 자동 sync, prune, selfHeal을 사용한다. `apps` AppProject는 Argo CD가 있는 `cicd`에도 배포할 수 있으므로 독립적인 보안 경계가 아니다. 해당 저장소 쓰기 권한과 Argo CD RBAC를 신뢰할 수 있는 관리자에게 제한한다.

빌드/배포 흐름:

```
Jenkins (Kaniko) ──build──► GHCR
       └──image tag bump──► k8s-gitops main ─► ArgoCD ─sync─► 서비스 NS
```

Jenkins ServiceAccount는 서비스 namespace에 직접 권한이 없지만 Kubernetes API로 `cicd`와 `build` Pod를 관리하고 `cicd` Secret·ConfigMap을 읽을 수 있다. Pod 생성 권한으로 해당 namespace의 Secret을 마운트할 수도 있다. Jenkins가 GitOps `main`에 이미지 태그를 직접 push하면 ArgoCD가 git diff를 감지해 해당 서비스 NS에 적용한다. Jenkins 성공은 GitOps push까지이며 실제 배포 완료는 ArgoCD의 Sync와 Health 상태로 확인한다. 상세 RBAC narrative는 `jenkins/README.md` 참조.

## 6. Secret

- `argocd-secret` (`admin.password`) — argo/argo-cd chart 생성. admin 비번 고정을 위해 bcrypt 해시로 patch (git 밖 — chart 랜덤 생성 회피, `jenkins-admin-fixed` 와 동일 철학). chart 부팅 시 만드는 `argocd-initial-admin-secret`(랜덤) 은 patch 후 삭제
- `jenkins-admin-fixed` — Jenkins admin 고정 자격, `cicd` NS (`existingSecret` — chart 랜덤 생성 회피)
- `grafana-admin-fixed` — Grafana 재활성화 시 참조할 자격 (`monitoring` NS); 현재 Grafana는 비활성
- `jenkins-git-pat` — manifest bump 용 git PAT, `cicd` NS (key `token` → `containerEnv` `GIT_PAT` → JCasC `github-token` credential)
- `ghcr-push` — Kaniko GHCR push 자격, `build` NS (`kubernetes.io/dockerconfigjson`)
- `ghcr-pull`, `cosign-key` — 빌드 이미지 pull 및 서명 자격, `build` NS

`argocd-secret` admin patch(§argocd/README.md 2·4장) 포함 위 시크릿은 `kubectl` 로 직접 주입/생성. OpenBao의 Agent Injector와 Kubernetes auth는 비활성이며 ESO 연결은 별도 구성이다. Cloudflare / GHCR / DB / PAT 시크릿 이관도 별도 작업이다.

placeholder · helm 버전 핀 · 5섹션 README 구조 등 공통 컨벤션은 `../infra/README.md` 참조.

Grafana는 `monitoring/kps/values.yaml`에서 비활성화한다. `monitoring` PSA baseline은 node-exporter 기본 hostPath를 금지하므로 예외가 없으면 Pod가 거부될 수 있다. 기존 Grafana 정리는 [KPS 안내](monitoring/kps/README.md)의 대상별 prune 절차를 따른다. [Loki](monitoring/loki/README.md)는 기존 Prometheus PVC를 공유하므로 저장소 노드 라벨·디렉터리 준비 후 KPS, Loki 순서로 수동 동기화한다. [Tempo](monitoring/tempo/README.md)는 기존 PVC의 `tempo/` 경로 준비 후 수동 동기화한다. 이후 Alloy를 동기화하면 OTLP 트레이스를 Tempo로 전달한다. 앱 계측과 Grafana 연결은 별도 설정이다. Prometheus 15d/45GiB, Loki 72h, Tempo 24h 보존 설정은 공유 50Gi PVC의 용량 격리가 아니다. 준비 Job 전에 기존 PVC가 연결된 노드 한 곳에 관측 라벨을 지정하고 전체 여유 공간을 확인한다.

## 7. 다음 후보

- monitoring 후속 — 앱 트레이스 계측 / Grafana 조회 연결 / Kiali (Loki·Alloy·Tempo 수동 설치 설정 제공)
- 데이터 계층 하드닝 — Redis `requirepass` / NATS account 분리 + AuthorizationPolicy 호출자 제한 (현재 ClusterIP 무인증)
- 시크릿 이관 — Cloudflare / DB / GHCR / webhook Secret → OpenBao (Agent Injector / ESO 비교)
- ArgoCD SSO — `dex.enabled: true` + GitHub OAuth, `admin` 사용자 비활성
- MSA 워크로드 — redis/nats 소비하는 producer/consumer (별도 앱 레포 + Jenkins 파이프라인)
