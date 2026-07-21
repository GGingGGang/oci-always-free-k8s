# OCI Kubernetes (Always Free)

OCI 유료 계정(Pay As You Go / Universal Credits)의 **Always Free 리소스(4 OCPU / 24GB · 2노드)** 제약 안에서 설계한 Kubernetes 플랫폼.

**[📖 English Docs](../README.md)**

> **Free Tier(무료 체험)가 아닙니다.**
> Free Tier는 30일 한정 크레딧입니다. 본 프로젝트는 PAYG 계정에 영구 포함되는 Always Free 리소스만 사용하므로 정상 사용 시 **과금 0원**.

## 연결된 레포

본 레포는 진입점. 앱 코드·GitOps 상태·CI 도구는 별도 레포에 있다:

| 레포 | 역할 | 상태 |
|------|------|------|
| **oci-always-free-k8s** (본 레포) | OCI Terraform + Kubernetes 인프라 (VCN/OKE, 플랫폼, 부트스트랩) | 진행 중 |
| [k8s-gitops](https://github.com/GGingGGang/k8s-gitops) | 앱 레이어 GitOps — Application CR + 매니페스트 (`manifests/<svc>`) | `core`, `batch`, `auth` 적용 완료 |
| [app-templates](https://github.com/GGingGGang/app-templates) | 서비스 씨앗 (sed 토큰 치환) → 새 `svc-*` 레포 + `k8s-gitops` | `go-app`, `java-app`, `node-app` 완료 |
| [jenkins-shared-library](https://github.com/GGingGGang/jenkins-shared-library) | Jenkins Global Pipeline Library — `ci()` 진입점 (build/scan/sign/bump, 서비스별 설정은 `services.yaml`) | 사용 중 |
| [svc-core](https://github.com/GGingGGang/svc-core) | 일정 도메인 API (Go/chi) | CI/CD 완주 검증됨, 도메인 로직 진행 중 |
| [svc-batch](https://github.com/GGingGGang/svc-batch) | 리마인더/Kafka consumer (Java/Spring Batch) | CI/CD 완주 검증됨, 배포·운영 중 |
| [svc-auth](https://github.com/GGingGGang/svc-auth) | 인증/세션/토큰 (Node.js/Fastify) | CI/CD 완주 검증됨, 인증 플로우 구현 중 |

## 스택

| 계층 | 컴포넌트 | 상태 |
|------|---------|------|
| IaC | Terraform | 완료 |
| 컨테이너 | OKE Basic, Flannel Overlay, containerd | 완료 |
| 메시 / 게이트웨이 | Gateway API, Istio Ambient, NLB | 완료 |
| DNS | external-dns + Cloudflare | 완료 |
| TLS | cert-manager + Let's Encrypt (DNS-01) | 완료 |
| GitOps | ArgoCD, Jenkins, GHCR | 완료 |
| 앱 (MSA) | core (Go/chi), batch (Java/Spring Batch), auth (Node.js/Fastify) → Kaniko/GHCR → ArgoCD app-of-apps | 진행 중 |
| 시크릿 | OpenBao (Vault), OCI KMS auto-unseal | 완료 |
| 관측 | kube-prometheus-stack (메트릭) | 완료 · Loki/Alloy/Tempo/Kiali 예정 |
| 보안 | Trivy, cosign, Kyverno, PSA, NetworkPolicy | Trivy(CI 스캔) · cosign(이미지 서명) · Kyverno(verifyImages, Audit) · PSA 사용 중 · NetworkPolicy 예정 |
| 앱 데이터 | Strimzi/Kafka (KRaft, ephemeral), Redis (캐시) | 완료 |
| 오토스케일 | HPA + Prometheus Adapter | 예정 |
| DR / 백업 | Velero, OCI Block Volume Backup, Vault Raft Snapshot | 예정 |
| 부하 테스트 | k6 | 예정 |

## 아키텍처

```
                    Internet
                       |
              [ Internet Gateway ]
                       |
            ┌──────────────────────┐
            │  subnet-public       │
            │  10.0.1.0/28         │
            │                      │
            │  ┌────────────────┐  │
            │  │  OCI NLB       │  │  ← Gateway API → istio가 자동 프로비전
            │  │  (TCP L4)      │  │
            │  └──────┬─────────┘  │
            └─────────┼────────────┘
                      │ NodePort (30000-32767)
         ┌────────────┼─────────────────────────┐
         │            │                         │
  ┌──────┴──────────┐ │  ┌──────────────────────┴───┐
  │ subnet-oke-api  │ │  │  subnet-workers           │
  │ 10.0.0.0/28     │ │  │  10.0.102.0/24            │
  │                 │ │  │                           │
  │  ┌───────────┐  │ │  │  ┌─────────────────────┐  │
  │  │ OKE       │◄─┼─┘  │  │  Node Pool          │  │
  │  │ Control   │◄─┼────┼──│  2× VM.Standard     │  │
  │  │ Plane API │  │    │  │     .A1.Flex        │  │
  │  │ (managed) │  │    │  │  2 OCPU / 12GB each │  │
  │  └───────────┘  │    │  └──────────┬──────────┘  │
  └─────────────────┘    └─────────────┼─────────────┘
                                       │
                               [ NAT Gateway ]
                               [ Service GW  ]
                                       │
                           ┌───────────┴────────┐
                           │  subnet-db         │
                           │  10.0.201.0/28     │
                           │                    │
                           │  ┌──────────────┐  │
                           │  │  HeatWave    │  │
                           │  │  MySQL Free  │  │
                           │  └──────────────┘  │
                           └────────────────────┘
```

## Always Free 사용량

| 리소스 | 사용량 | Always Free 한도 | 여유 |
|--------|--------|------------------|------|
| VM.Standard.A1.Flex | 4 OCPU / 24 GB (노드 2개) | 4 OCPU / 24 GB | 한도 도달 |
| OKE Basic Cluster | 1개 (컨트롤 플레인 무료) | — | — |
| MySQL HeatWave | 1개, 50 GB | 1개, 50 GB | — |
| Network Load Balancer | 1개 (Istio Gateway, L4) | 1개 | — |
| Flexible Load Balancer | 0개 | 1개, 10 Mbps | 1개 |
| VCN | 1개 | 2개 | 1개 |

> OKE Basic의 컨트롤 플레인 자체는 무료. 워커는 Always Free A1.Flex 쿼터 사용.
> OKE는 Free Tier 계정에서 사용 불가 — PAYG 계정 필수.

전체 카탈로그: [`docs/summary-kr.md`](./summary-kr.md).

## 디렉토리

```
.
├── terraform/                  # OCI 인프라 (VCN, OKE, MySQL, KMS, IAM/NSG, Object Storage)
│   ├── modules/{networking,oke,database,kms,iam,object-storage}/
│   └── README.md
├── kubernetes/                 # K8s 매니페스트
│   ├── infra/                  # 부트스트랩 인프라
│   │   ├── namespaces/
│   │   ├── gateway-api/
│   │   ├── istio/
│   │   ├── external-dns/
│   │   ├── cert-manager/
│   │   ├── metrics-server/
│   │   ├── rbac/
│   │   ├── tailscale/
│   │   └── README.md
│   ├── platform/               # CI/CD · 플랫폼 · 데이터 서비스
│   │   ├── argocd/             # GitOps 컨트롤 플레인 (self-managed app-of-apps + 앱 레이어 진입점)
│   │   ├── jenkins/            # JCasC + Kaniko 동적 빌드
│   │   ├── openbao/            # 시크릿 저장소 (Raft 1 + OCI KMS auto-unseal)
│   │   ├── monitoring/         # kube-prometheus-stack
│   │   ├── redis/              # MSA 캐시 (ephemeral, cache-aside)
│   │   ├── kafka/              # MSA 이벤트 백본 (Strimzi, KRaft, ephemeral)
│   │   ├── kyverno/            # 정책 엔진 — 이미지 서명 admission 검증
│   │   └── README.md
│   ├── test/                   # 일회성 검증
│   └── README.md
├── scripts/                    # 반복 실행되는 운영 도구 (예: onboard-app-db.sh)
└── docs/
    ├── README-KR.md            # 한국어 미러 (본 문서)
    ├── summary.md              # Always Free 카탈로그 (EN)
    └── summary-kr.md           # Always Free 카탈로그 (KR)
```

앱 레이어 Application CR + 매니페스트는 전용 GitOps 레포(`k8s-gitops`)가, 서비스 씨앗(sed 토큰 치환 → 새 `svc-*` 레포 + `k8s-gitops`)은 `app-templates` 레포가 보유 — 둘 다 본 인프라 레포에는 없음. Quick Start §5 참조.

## Quick Start

### 1. OCI 인프라 프로비저닝

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # OCID, region, SSH key 등 채움
terraform init
terraform apply
```

상세: [`terraform/README.md`](../terraform/README.md).

### 2. kubectl 설정

```bash
oci ce cluster create-kubeconfig \
  --cluster-id "$(terraform output -raw oke_cluster_id)" \
  --file ~/.kube/config \
  --region <your-region> \
  --token-version 2.0.0

kubectl get nodes
```

### 3. Kubernetes 인프라 부트스트랩

설치 순서: `namespaces` → `gateway-api` → `istio` (코어) → `external-dns` → `cert-manager` → `istio` (Gateway HTTPS).

상세: [`kubernetes/infra/README.md`](../kubernetes/infra/README.md).

### 4. 플랫폼 배포

infra 계층 위에: ArgoCD(GitOps 컨트롤 플레인) + Jenkins(JCasC + Kaniko 동적 빌드) + OpenBao(시크릿 저장소, OCI KMS auto-unseal) + 관측(kube-prometheus-stack) + 데이터 서비스(Redis 캐시 + Strimzi Kafka, `data` NS).

상세: [`kubernetes/platform/README.md`](../kubernetes/platform/README.md).

### 5. 애플리케이션 배포

MSA 서비스(`core` — Go/chi 도메인 API, `batch` — Java/Spring Batch consumer, `auth` — Node.js/Fastify 인증 서비스)는 별도 `apps` ArgoCD 프로젝트(app-of-apps)로 배포 — 이 app-of-apps 는 인프라 레포가 아니라 전용 GitOps 레포(`k8s-gitops`)에 있다. 각 서비스 레포(`svc-*`)는 코드 + `Dockerfile` + `Jenkinsfile`만 보유, GitOps 레포가 Application 포인터와 k8s 매니페스트(`manifests/<svc>/`)를 함께 보유. push → Jenkins(webhook → Kaniko → GHCR → shared library `deployBump` 가 `k8s-gitops` 에 태그 커밋) → ArgoCD가 서비스별 NS에 매니페스트 sync → HTTP 노출 서비스는 Istio Gateway가 `api.${domain}/v1/<service>` 로 노출.

## 네트워크 구성

| 서브넷 | CIDR | 유형 | 용도 |
|--------|------|------|------|
| subnet-oke-api | 10.0.0.0/28 | Public | OKE API endpoint |
| subnet-public | 10.0.1.0/28 | Public | OCI Load Balancer / NLB |
| subnet-workers | 10.0.102.0/24 | Private | 워커 노드 |
| subnet-db | 10.0.201.0/28 | Private | HeatWave MySQL |

Security List + NSG 규칙: `terraform/modules/networking`, `terraform/modules/iam` 참조.

## 네트워크 대역폭

| 구간 | 대역폭 | 비고 |
|------|--------|------|
| A1 인스턴스 (OCPU당) | 1 Gbps | 2 OCPU 노드 = 2 Gbps |
| Network Load Balancer | A1 쿼터 기반 | L4 passthrough, 고정 cap 없음 |
| Flexible Load Balancer | 10 Mbps | (미사용. 사용 시 외부 트래픽 병목) |
| Outbound | 월 10TB 무료 | 초과 시 과금. 인바운드 무료 |

VCN 내부 통신(워커↔워커, 워커↔DB)은 인스턴스 전체 대역폭(2 Gbps)까지 사용.

## OKE Basic vs Enhanced

| 기능 | Basic | Enhanced |
|------|-------|----------|
| 요금 | **무료** | $0.10/시간 |
| Virtual Node | ✗ | ✓ |
| OKE Add-on | ✗ | ✓ |
| 컨트롤 플레인 SLA | ✗ | ✓ |
| CNI | Flannel Overlay | Flannel / VCN-Native |

개인 프로젝트 및 비프로덕션 워크로드에는 Basic Cluster로 충분.

## Secrets

토큰은 git 에 들어가지 않음. 채널 2개:

- **`kubernetes/.env`** (gitignored) — `jenkins`, `GHCR_TOKEN`, `GHCR_USER`. Secret 생성 명령 직전에 source. OpenBao 설치 완료 — 이 값들의 이관이 다음 단계.
- **컴포넌트별 인라인** — Cloudflare API token (`<your-cf-token>`) 은 cert-manager / external-dns 각 컴포넌트에서 발급해서 `kubectl create secret` 에 직접 주입 (각 컴포넌트 README 참조).

## 컨벤션

- **Git 박힌 값**: apex 도메인 (`ggang.cloud`) + admin 이메일 (`admin@ggang.cloud`) 하드코딩 — 도메인 변경 시 [`init.sh`](../init.sh) 사용.
- **Secret 성격 placeholder**: `<your-cf-token>`, `<your-region>`, `<your-github-user>`, `<your-ghcr-write-token>` — Secret 생성 시 직접 주입, git 진입 ❌.
- **비밀값**: `*.env`, `*.local.*`, `*.tfvars`, `*.pem`, `*.ppk`, `*.pub` 는 gitignore 적용. 사적 값은 git 추적 제외.
- **README 구조**: 모든 컴포넌트 폴더는 5섹션 — 전제 조건 / 설치 / 검증 / 결정 / 주의 사항.
- **Helm 버전**: `~X.Y.0` SemVer tilde — patch만 자동, minor는 명시적 갱신.
