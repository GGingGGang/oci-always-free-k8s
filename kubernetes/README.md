# kubernetes

OKE 클러스터 위에서 동작하는 Kubernetes 매니페스트.

각 컴포넌트 폴더에 매니페스트(`.yaml`), helm values 및 운영 안내를 둔다.

GitHub Actions `yaml-lint`는 관련 경로 변경이 포함된 main push와 PR에서 본 트리의 YAML을 검사한다. 규칙은 레포 루트 `.yamllint.yaml`이며 `--strict`를 사용한다.

## 디렉토리

```
kubernetes/
├── infra/                # 클러스터 부트스트랩 인프라
│   ├── namespaces/       # 워크로드·플랫폼 네임스페이스와 PSA/ambient/서명검증 라벨
│   ├── gateway-api/      # Gateway API v1.5.0 CRD 수동 설치
│   ├── istio/            # Ambient mesh + Gateway/HTTPRoute
│   ├── external-dns/     # HTTPRoute hostnames → Cloudflare DNS
│   ├── cert-manager/     # LE DNS-01 + 와일드카드 Certificate
│   ├── metrics-server/   # metrics.k8s.io (kubectl top / HPA)
│   ├── tailscale/        # subnet router — tailnet 사설 접근 경로 (연결 검증 필요)
│   ├── rbac/             # RBAC 설계 문서 (실 YAML은 각 컴포넌트 폴더 동거)
│   └── README.md         # 전체 그림 + 설치 순서
├── platform/             # CI/CD · 관측 · 보안 등 플랫폼 컴포넌트
│   ├── argocd/           # GitOps 컨트롤 플레인 (helm + HTTPRoute)
│   ├── jenkins/          # JCasC + emptyDir, 동적 agent (+ Kaniko podTemplate in build NS)
│   ├── openbao/          # 시크릿 저장소 (Raft 1 + OCI KMS auto-unseal, data NS의 NATS PVC 공유)
│   ├── monitoring/       # 관측 스택
│   │   ├── kps/          # Prometheus / Alertmanager
│   │   ├── loki/         # 로그 저장소
│   │   └── alloy/        # 앱 namespace 6개의 API 로그 수집 → Loki
│   ├── redis/            # MSA 캐시 (ephemeral, cache-aside, data NS)
│   ├── nats/             # MSA 이벤트 백본 (JetStream file store, data NS)
│   └── kyverno/          # 정책 엔진 — 지정 namespace와 이미지의 서명 admission 검증
└── test/                 # 일회성 검증 자산
    ├── networking/       # NLB smoke test
    ├── storage/          # Block Volume CSI smoke test
    └── database/         # HeatWave MySQL 연결 smoke test
```

상세 설치 순서 + 컴포넌트 의존 관계: [`infra/README.md`](./infra/README.md) (부트스트랩), [`platform/README.md`](./platform/README.md) (CI/CD).

## 적용 모델

수동 Helm 설치와 `kubectl apply` 절차는 부트스트랩과 복구에 사용한다. `platform-root`, `platform-project`, `app-layer-root`는 자동 sync하지만 대부분의 플랫폼 워크로드 Application은 수동 sync한다. Gateway API CRD, OpenBao, Tailscale은 별도 관리한다. 별도 GitOps 레포([`k8s-gitops`](https://github.com/GGingGGang/k8s-gitops))의 앱 root와 서비스 Application은 자동 sync, prune, selfHeal을 사용한다. 상세와 의존 순서는 `platform/argocd/README.md` 참조.

## 앱 매니페스트 위치

앱 **매니페스트**(deployment/service/httproute/kustomization)는 본 레포에 두지 않음 — 전용 GitOps 레포(`k8s-gitops`)의 `manifests/<svc>` 가 보유. ArgoCD **Application CR**(포인터)도 `k8s-gitops` 가 보유하며 source 가 `k8s-gitops/manifests/<svc>` 를 가리킴. 즉 *무엇을·어떻게 배포할지(Application + 매니페스트)* 는 `k8s-gitops`, **앱 레포는 코드만**, 본 레포는 **인프라/플랫폼만**.

사유: ArgoCD 공식 권장 *config vs source code 분리* + 인프라/앱 권한 경계 + commit log 오염 방지.

> 결정: deploy 전용 레포 분리 — 매니페스트를 `k8s-gitops/manifests/<svc>` 로 이전. Jenkins 는 앱 main 이 아니라 `k8s-gitops` 에 bump(shared library `deployBump`) → 앱 레포 main 무오염, `k8s-gitops` 는 org folder(`svc-.*`) 밖이라 빌드 루프 없음(`[ci skip]` 불필요). `core`/`batch`/`auth` 이전 완료.

관측 설정은 Grafana를 비활성화한다. Prometheus, Loki, Tempo는 50Gi PVC를 공유하며 subPath별 용량 할당량은 없다. 기존 PVC가 연결된 노드에 라벨과 경로를 준비하고 [관측 설치 순서](platform/monitoring/README.md)에 따라 수동 sync한다. `monitoring` PSA baseline은 node-exporter 기본 hostPath와 충돌하므로 예외가 없으면 Pod가 거부될 수 있다.

OpenBao는 NATS의 50Gi RWO PVC를 공유하며 NATS 준비 후 별도 저장 경로 준비 Job과 Helm 설치가 필요하다. Redis와 NATS는 ClusterIP에 인증 없이 노출되며 ambient 라벨만으로 접근 제한을 보장하지 않는다. Jenkins webhook은 공개 route가 선언되어 있으나 체크인된 HMAC 검증 설정은 없다. 자세한 조건은 [platform 안내](platform/README.md)를 따른다.

## 예정 추가

- `platform/` — Loki / [Alloy](platform/monitoring/alloy/README.md) / [Tempo](platform/monitoring/tempo/README.md) 수동 GitOps 설정 제공, 앱 계측 / Grafana 조회 연결 / Kiali 후속
- 앱 레이어(app-of-apps)는 전용 GitOps 레포(`k8s-gitops`)로 분리 — `core`/`batch`/`auth` Application + 매니페스트 이전 완료. 후속 east-west 통제(Istio mTLS STRICT + AuthorizationPolicy)
