# kubernetes

OKE 클러스터 위에서 동작하는 Kubernetes 매니페스트.

각 컴포넌트 폴더에 매니페스트(`.yaml`) + helm values + README. 모든 README는 5섹션 표준 (전제 조건 / 설치 / 검증 / 결정 / 주의 사항).

## 디렉토리

```
kubernetes/
├── infra/                # 클러스터 부트스트랩 인프라
│   ├── namespaces/       # 네임스페이스 + PSA 라벨
│   ├── gateway-api/      # Gateway API CRD
│   ├── istio/            # Ambient mesh + Gateway/HTTPRoute
│   ├── external-dns/     # HTTPRoute hostnames → Cloudflare DNS
│   ├── cert-manager/     # LE DNS-01 + 와일드카드 Certificate
│   ├── metrics-server/   # metrics.k8s.io (kubectl top / HPA)
│   ├── tailscale/        # subnet router — 관리 플레인 사설화 (tailnet)
│   ├── rbac/             # RBAC 설계 문서 (실 YAML은 각 컴포넌트 폴더 동거)
│   └── README.md         # 전체 그림 + 설치 순서
├── platform/             # CI/CD · 관측 · 보안 등 플랫폼 컴포넌트
│   ├── argocd/           # GitOps 컨트롤 플레인 (helm + HTTPRoute)
│   ├── jenkins/          # JCasC + emptyDir, 동적 agent (+ Kaniko podTemplate in build NS)
│   ├── openbao/          # 시크릿 저장소 (Raft 1 + OCI KMS auto-unseal + Injector, ephemeral)
│   ├── monitoring/       # kube-prometheus-stack (Prometheus/Alertmanager/Grafana)
│   ├── redis/            # MSA 캐시 (ephemeral, cache-aside, data NS)
│   ├── kafka/            # MSA 이벤트 백본 (Strimzi, KRaft, ephemeral, data NS)
│   └── kyverno/          # 정책 엔진 — 이미지 서명 admission 검증 (kyverno NS)
└── test/                 # 일회성 검증 자산
    ├── networking/       # NLB smoke test
    ├── storage/          # Block Volume CSI smoke test
    └── database/         # HeatWave MySQL 연결 smoke test
```

상세 설치 순서 + 컴포넌트 의존 관계: [`infra/README.md`](./infra/README.md) (부트스트랩), [`platform/README.md`](./platform/README.md) (CI/CD).

## 적용 모델

helm install + `kubectl apply` 수동(멱등) 흐름이 cold-start / DR 복구 자산으로 유지되며, 이와 별개로 본 레포(인프라)는 self-managed Application + 기존 helm release adopt 구조로 **전환 완료**(`platform/argocd/apps/*.yaml`) — 단 adopt 단계는 수동 sync + prune off, selfHeal/prune 활성은 하드닝 turn. 앱 sync 는 별도 GitOps 레포([`k8s-gitops`](https://github.com/GGingGGang/k8s-gitops)) 대상 — config vs source code 분리 원칙 유지. 상세는 `platform/argocd/README.md` §6.

## 앱 매니페스트 위치

앱 **매니페스트**(deployment/service/httproute/kustomization)는 본 레포에 두지 않음 — 전용 GitOps 레포(`k8s-gitops`)의 `manifests/<svc>` 가 보유. ArgoCD **Application CR**(포인터)도 `k8s-gitops` 가 보유하며 source 가 `k8s-gitops/manifests/<svc>` 를 가리킴. 즉 *무엇을·어떻게 배포할지(Application + 매니페스트)* 는 `k8s-gitops`, **앱 레포는 코드만**, 본 레포는 **인프라/플랫폼만**.

사유: ArgoCD 공식 권장 *config vs source code 분리* + 인프라/앱 권한 경계 + commit log 오염 방지.

> 결정: deploy 전용 레포 분리 — 매니페스트를 `k8s-gitops/manifests/<svc>` 로 이전. Jenkins 는 앱 main 이 아니라 `k8s-gitops` 에 bump(shared library `deployBump`) → 앱 레포 main 무오염, `k8s-gitops` 는 org folder(`svc-.*`) 밖이라 빌드 루프 없음(`[ci skip]` 불필요). `core`/`batch`/`auth` 이전 완료.

## 예정 추가

- `platform/` — argocd, jenkins, openbao, monitoring, 데이터 계층(redis/kafka, `data` NS), kyverno(이미지 서명 admission 검증, Audit) 도입 완료. 관측 후속(Loki / Alloy / Tempo / Kiali) 예정
- 앱 레이어(app-of-apps)는 전용 GitOps 레포(`k8s-gitops`)로 분리 — `core`/`batch`/`auth` Application + 매니페스트 이전 완료. 후속 east-west 메시(NetworkPolicy/AuthorizationPolicy)
