# infra

OKE 클러스터의 기반 인프라 계층. 네임스페이스/PSA, Gateway API, Ambient mesh, DNS 자동화, 인증서, 리소스 메트릭과 사설 접근 경로.

각 폴더는 컴포넌트 단위이며 설치 시 아래 의존 순서를 따른다.

## 1. 구성

| 폴더 | 역할 | helm 릴리즈 | 외부 의존 |
|------|------|------------|----------|
| `namespaces/` | 워크로드·플랫폼 네임스페이스와 PSA/ambient/서명검증 라벨 | — | — |
| `gateway-api/` | Gateway API v1.5.0 standard CRD | — | — |
| `istio/` | Ambient mesh(`base`/`istiod`/`cni`/`ztunnel`) + Gateway/HTTPRoute | 4 | — |
| `external-dns/` | HTTPRoute hostnames → Cloudflare DNS sync | 1 | Cloudflare zone + API token |
| `cert-manager/` | LE DNS-01 + 와일드카드 Certificate | 1 | Cloudflare zone + API token |
| `metrics-server/` | `metrics.k8s.io` 리소스 메트릭 (`kubectl top` / HPA) | 1 | — |
| `rbac/` | RBAC 설계 문서 (권한 매트릭스 + 컨벤션). 실 YAML은 각 컴포넌트 폴더 동거 | — | — |
| `tailscale/` | subnet router — VCN+Service CIDR을 tailnet에 광고 (관리 플레인 사설화) | — | Tailscale 계정 |

## 2. 설치 순서

의존 그래프 기준. 각 단계의 상세는 해당 폴더 README 참조.

```
1. namespaces            네임스페이스 + PSA
2. gateway-api           Gateway API v1.5.0 standard CRD 수동 설치
3. istio (코어)          base → istiod → istio-cni → ztunnel
4. external-dns          Cloudflare Secret + helm
5. cert-manager          helm + ClusterIssuer + Certificate (Ready=True 대기)
6. istio (Gateway)       gateway.yaml + http-redirect.yaml — Certificate Secret 의존
```

3번 helm 4개는 명시한 순서로. Gateway API CRD는 `base`가 제공하지 않으므로 먼저 별도 설치한다. `istiod`는 컨트롤 플레인, `istio-cni`는 노드 데이터 플레인 redirect, `ztunnel`은 ambient L4 mTLS를 담당한다. Argo CD Application은 Istio `1.29.3`을 사용한다.

5번과 6번 사이에 Certificate `Ready=True` 검증 필요. Secret 미존재 상태로 Gateway HTTPS listener를 apply하면 `ResolvedRefs: False` — Certificate 발급되면 자동 회복되지만 status 노이즈 발생.

`namespaces/`는 수동 부트스트랩 후 Argo CD `namespaces` Application이 관리한다. `metrics-server/`는 위 의존 그래프와 독립이며 Argo CD `metrics-server` Application이 chart `3.13.1`을 `kube-system`에 배포한다.

`tailscale/`도 독립 — 부트스트랩 등급(`kubectl apply`), ArgoCD GitOps 제외. 사설 접근 경로는 실제 연결 검증 후에만 퍼블릭 admin 표면 컷오버에 사용한다. OCI NSG와 Security List는 허용 규칙의 합집합이므로 양쪽을 확인한다. 상세는 `tailscale/README.md`.

## 3. 외부 의존

- **OCI** — OKE 클러스터, Network Load Balancer (Gateway API → istio가 자동 프로비전)
- **Cloudflare** — 도메인 zone (DNS 관리 + ACME DNS-01 challenge)
- **helm registries** — `jetstack`, `kubernetes-sigs/external-dns`, `kubernetes-sigs/metrics-server`, `istio-release`

Cloudflare API Token은 컴포넌트별 분리 발급 권장 (cert-manager/external-dns 각각). 사고 시 폭발 반경 최소화.
두 Secret은 각각의 네임스페이스에 별도 생성한다. Argo CD의 external-dns Application은 chart `1.16.1`과 `ggang.cloud` 도메인 필터를 지정한다.

## 4. 컨벤션

### Placeholder 패턴

apex 도메인 + admin 이메일은 git 박힘 (`ggang.cloud` / `admin@ggang.cloud`). secret 성격 값만 `<your-*>` placeholder + Secret 생성 시 직접 주입.

```bash
kubectl create secret generic cloudflare-api-token \
  -n cert-manager \
  --from-literal=api-token='<your-cf-token>'
```

사용하는 placeholder:

| 토큰 | 의미 |
|------|------|
| `<your-cf-token>` | Cloudflare API Token (Secret 생성 시) |
| `<your-github-user>` / `<your-ghcr-write-token>` | GHCR push 자격 (Jenkins 빌드용 Secret 생성 시) |
| `<your-tskey-auth-...>` | Tailscale auth key (`tailscale-auth` Secret 생성 시) |

### 비밀값

`*.env`, `*.local.*` 는 `.gitignore`로 git 추적 제외. 본인 값은 각 컴포넌트 폴더의 `.env` 또는 루트 `values.local.env`(예정)에 보관.

### README 구조 (5섹션 표준)

각 폴더 README는 동일 구조:

1. 전제 조건
2. 설치
3. 검증
4. 결정 — 채택 사유 / 비채택 대안
5. 주의 사항 — 운영 시 함정, 회전·갱신·업그레이드 가이드

### helm 버전 핀

Argo CD Application은 chart 버전을 명시적으로 고정한다. 수동 설치 시에도 해당 Application과 같은 버전과 values를 사용한다.

## 5. 다음 후보

- `cert-manager` / `external-dns` ambient enrollment (현재 보류 — egress 위주라 가치 낮음, `namespaces/README.md` 참조)
- 백업 / DR — Velero · OCI Block Volume Backup · Vault Raft Snapshot
