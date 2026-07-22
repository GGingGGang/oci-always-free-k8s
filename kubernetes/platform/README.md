# platform

infra 부트스트랩(Gateway / TLS / DNS) 위에서 동작하는 플랫폼 계층. CI/CD(ArgoCD, Jenkins) + 시크릿(OpenBao) + 관측(kube-prometheus-stack) + 데이터 백킹(Redis, Kafka — `data` NS) 도입.

각 폴더는 독립 컴포넌트 단위. helm 릴리즈 단위로 의존이 닫혀있어 개별 turn으로 진행 가능.

## 1. 구성

| 폴더 | 역할 | helm 릴리즈 | NS | 외부 노출 |
|------|------|------------|-----|----------|
| `argocd/` | GitOps 컨트롤 플레인 | argo/argo-cd `~7.7.0` | `cicd` (PSA baseline) | tailnet (parked — `argocd.ggang.cloud` 주석 처리) |
| `jenkins/` | JCasC Jenkins + Kaniko 동적 빌드 | jenkins/jenkins `~5.9.0` | `cicd` controller / `build` 빌드 Pod (PSA privileged) | admin: tailnet (parked) / webhook: `ci-hook.ggang.cloud` `/github-webhook/` (active) |
| `openbao/` | 시크릿 저장소 (Raft 1 + OCI KMS auto-unseal, ephemeral) | openbao/openbao `~0.28.0` | `vault` (PSA baseline) | 없음 (port-forward) |
| `monitoring/` | 관측 (메트릭/알림/대시보드) | prometheus-community/kube-prometheus-stack `~75.0.0` | `monitoring` (PSA baseline) | tailnet (parked — `grafana.ggang.cloud` 주석 처리) |
| `redis/` | MSA 캐시 (cache-aside, ephemeral) | — (raw manifest, `redis:*-alpine`) | `data` (PSA baseline, ambient) | 없음 (ClusterIP, in-mesh) |
| `kafka/` | MSA 이벤트 백본 (Strimzi, KRaft, ephemeral) | strimzi/strimzi-kafka-operator `1.0.1` + Kafka CR | `data` (PSA baseline, ambient) | 없음 (ClusterIP, in-mesh) |
| `kyverno/` | 정책 엔진 — 이미지 서명 admission 검증 (cosign 공급망 체인) | kyverno/kyverno `3.8.2` + ClusterPolicy | `kyverno` (PSA baseline) | 없음 |

## 2. 전제 조건 (infra 의존)

platform 컴포넌트는 모두 infra 계층(`../infra/`) 위에서 동작. 부트스트랩 미완료 상태로 설치하면 HTTPRoute가 `ResolvedRefs: False`로 멈춤.

- `cicd` + `build` 네임스페이스 + PSA 라벨 (`../infra/namespaces/`)
- Gateway API CRD + `public-gateway` (`*.ggang.cloud` listener) 동작 (`../infra/istio/`)
- wildcard TLS Secret `public-wildcard-tls` Ready=True (`../infra/cert-manager/`)
- external-dns 동작 (`../infra/external-dns/`) — HTTPRoute hostname → Cloudflare DNS 자동 sync
- Helm 3.6+

## 3. 설치 순서

infra 부트스트랩 완료 후:

```
1. argocd       helm + httproute
2. jenkins      rbac + Secret(ghcr-push@build · jenkins-git-pat@cicd · jenkins-admin-fixed@cicd) + helm + webhook httproute
3. openbao      terraform (kms + iam) 선행 → helm + operator init
4. monitoring   helm (kube-prometheus-stack) + httproute
5. redis        kubectl apply (raw manifest, data NS)
6. kafka        strimzi operator(helm) → Kafka CR (CRD 선행)
7. kyverno      helm → ClusterPolicy (정책은 kyverno CRD 선행)
```

대체로 상호 독립 — argocd/jenkins/monitoring/redis 는 순서 무관. openbao 만 terraform 선행(KMS 키 + Dynamic Group/Policy), kafka 만 strimzi operator(CRD) 선행, kyverno 정책(ClusterPolicy)은 kyverno 차트(CRD) 선행. 각 단계 상세는 해당 폴더 README 참조.

## 4. 외부 노출 / TLS

admin UI(argocd/jenkins/grafana) HTTPRoute는 `public-gateway`의 `https-wildcard` listener에 attach하되 **tailnet 컷오버로 대부분 parked**(주석) — 운영 접근은 tailnet ClusterIP. 현재 active public 인입은 Jenkins webhook(`ci-hook.ggang.cloud` `/github-webhook/`, HMAC)뿐. `*.ggang.cloud` 와일드카드 인증서로 Gateway 단일 TLS 종료, HTTP→HTTPS redirect는 `../infra/istio/http-redirect.yaml` catch-all.

**데이터 계층(redis/kafka)은 외부 노출 0** — ClusterIP, mesh 내부 caller 전용. 모든 내부 hop은 Istio Ambient(ztunnel) L4 mTLS. external-dns가 active HTTPRoute의 `hostnames`를 source로 Cloudflare A 레코드 등록.

## 5. GitOps 모델

본 레포(인프라)는 self-managed Application + 기존 helm release adopt 구조로 전환. app-of-apps(`argocd/project.yaml` + `argocd/root.yaml` + `argocd/apps/`)가 컴포넌트별 Application 으로 기존 release 를 흡수 — 부트스트랩·adopt 절차·sync-wave·제외(gateway-api CRD / openbao)는 `argocd/README.md` 6장. adopt 단계는 수동 sync + prune off(ArgoCD = 구경꾼), selfHeal/prune 활성은 하드닝 turn. 앱 sync는 별도 deploy repo([`k8s-gitops`](https://github.com/GGingGGang/k8s-gitops)) 대상 — config vs source code 분리 원칙 유지.

빌드/배포 흐름의 권한 경계가 git 레벨에서 강제됨:

```
Jenkins (Kaniko) ──build──► GHCR
       │
       └──image tag bump──► k8s-gitops manifests/<svc>/kustomization.yaml
                                      │
                              ArgoCD ─sync─► app NS
```

Jenkins는 `app` NS 권한 0건 — k8s API 직접 호출 ❌, git commit만. ArgoCD가 git diff를 감지해 적용. 상세 RBAC narrative는 `jenkins/README.md` 참조.

## 6. Secret

- `argocd-secret` (`admin.password`) — argo/argo-cd chart 생성. admin 비번 고정을 위해 bcrypt 해시로 patch (git 밖 — chart 랜덤 생성 회피, `jenkins-admin-fixed` 와 동일 철학). chart 부팅 시 만드는 `argocd-initial-admin-secret`(랜덤) 은 patch 후 삭제
- `jenkins-admin-fixed` — Jenkins admin 고정 자격, `cicd` NS (`existingSecret` — chart 랜덤 생성 회피)
- `grafana-admin-fixed` — Grafana admin 고정 자격, `monitoring` NS (`grafana.admin.existingSecret` — chart 자체 관리 회피, keys `admin-user`/`admin-password`)
- `jenkins-git-pat` — manifest bump 용 git PAT, `cicd` NS (key `token` → `containerEnv` `GIT_PAT` → JCasC `github-token` credential)
- `ghcr-push` — Kaniko GHCR push 자격, `build` NS (`kubernetes.io/dockerconfigjson`)

`argocd-secret` admin patch(§argocd/README.md 2·4장) 포함 위 시크릿은 `kubectl` 로 직접 주입/생성. OpenBao 설치 완료 — Cloudflare / GHCR / DB / PAT 시크릿의 OpenBao 이관(Agent Injector / ESO 비교 포함)은 후속 turn.

placeholder · helm 버전 핀 · 5섹션 README 구조 등 공통 컨벤션은 `../infra/README.md` 참조.

## 7. 다음 후보

- monitoring 후속 — Loki / Alloy / Tempo / Kiali (kube-prometheus-stack 완료)
- 데이터 계층 하드닝 — Redis `requirepass` / Kafka 인증(`scram-sha-512`) + NetworkPolicy (현재 in-mesh 무인증)
- 시크릿 이관 — Cloudflare / DB / GHCR / webhook Secret → OpenBao (Agent Injector / ESO 비교)
- ArgoCD SSO — `dex.enabled: true` + GitHub OAuth, `admin` 사용자 비활성
- MSA 워크로드 — redis/kafka 소비하는 producer/consumer (별도 앱 레포 + Jenkins 파이프라인)
