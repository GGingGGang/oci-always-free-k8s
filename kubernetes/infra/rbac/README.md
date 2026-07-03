# RBAC 설계

본 폴더는 **설계 문서 전용**. 실 `Role`/`ClusterRole`/`RoleBinding` YAML은 *각 컴포넌트 폴더와 동거*.

```
kubernetes/
├── infra/
│   ├── rbac/README.md             # 본 문서 — 권한 매트릭스 + 컨벤션
│   └── tailscale/rbac.yaml        # Tailscale SA + Role(state Secret) + RoleBinding
└── platform/
    └── jenkins/rbac.yaml          # Jenkins SA + Role + RoleBinding
```

ArgoCD / Prometheus(kube-prometheus-stack)는 아직 전용 `rbac.yaml`이 없음 — chart 가 생성하는 기본 ClusterRole/ClusterRoleBinding 을 그대로 사용 중. 커스텀 RBAC 로 override 하게 되면 그 시점에 `platform/<comp>/rbac.yaml` 신설 + 본 표에 행 추가.

분리 이유: chicken-egg 회피. 적용 대상 SA가 *존재하는 시점*에 RoleBinding을 함께 적용해야 *살아있는 RBAC*. 본 폴더의 설계가 *없는 SA에 대한 권한 설계*가 되면 종이호랑이.

## 1. 전제 조건

- K8s RBAC 기본 (`Role` / `ClusterRole` / `RoleBinding` / `ClusterRoleBinding` / `ServiceAccount`)
- 네임스페이스 구조 (`../namespaces/namespaces.yaml`)
- RBAC API group `rbac.authorization.k8s.io/v1`

## 2. 권한 매트릭스

실제로 작성된 RBAC만 본 표에 박힘. 새 컴포넌트의 `rbac.yaml` 작성 시 본 표에 행 추가 (CLAUDE.md 컨벤션).

| 컴포넌트 | SA | 권한 scope | Kind | 위치 |
|---------|-------|----------|------|------|
| Jenkins controller | `cicd/jenkins` | `cicd` NS Pod/configmap/secret(read)/events (agent 관리) | Role + RoleBinding | `platform/jenkins/rbac.yaml` |
| Jenkins → build | `cicd/jenkins` | `build` NS Pod CRUD (Kaniko 빌드 Pod 관리, cross-NS) | Role + RoleBinding | `platform/jenkins/rbac.yaml` |
| Kaniko 빌드 | `build/kaniko-builder` | 권한 0건 (`automountServiceAccountToken: false`). Pod 신원 전용 | SA only | `platform/jenkins/rbac.yaml` |
| Tailscale router | `tailscale/tailscale` | `tailscale` NS Secret create + `tailscale-state` get/update/patch (노드 state 영속) | Role + RoleBinding | `infra/tailscale/rbac.yaml` |

ArgoCD/Prometheus는 위 §개요 참조 — chart 기본 RBAC 사용 중이라 본 표 미등재.

## 3. 검증

배포된 RBAC 점검 명령:

```bash
# 모든 RoleBinding/ClusterRoleBinding 목록
kubectl get rolebinding,clusterrolebinding -A

# 특정 SA의 권한 시뮬레이션
kubectl auth can-i create pods --as=system:serviceaccount:cicd:jenkins -n cicd
kubectl auth can-i '*' '*' --as=system:serviceaccount:cicd:argocd-application-controller

# cluster-admin 사용 SA 색출 (있으면 사고)
kubectl get clusterrolebinding -o json | jq '.items[] | select(.roleRef.name=="cluster-admin") | {name: .metadata.name, subjects: .subjects}'

# SA별 token 발급 정책 확인 (k8s 1.24+ 정책)
kubectl get sa -A -o json | jq '.items[] | {ns: .metadata.namespace, name: .metadata.name, automount: .automountServiceAccountToken}'
```

cluster-admin 결과는 system 컴포넌트 (`system:masters`, `system:kube-controller-manager` 등)만 나와야 정상. 사용자 정의 SA가 있으면 *사고*.

## 4. 결정

### 네이밍 컨벤션

```
ServiceAccount       : <component>                          예: jenkins, argocd-server, prometheus
Role                 : <component>-<purpose>                예: jenkins-agent, argocd-application
ClusterRole          : <component>-<purpose>                예: prometheus-cluster-reader
RoleBinding          : <component>-<purpose>                예: jenkins-agent (Role과 동일)
ClusterRoleBinding   : <component>-<purpose>                예: prometheus-cluster-reader
```

RoleBinding/ClusterRoleBinding은 *바인딩 대상 Role과 같은 이름*. 추적성 ↑.

### Role vs ClusterRole 결정 기준

기본 원칙: **Role first, ClusterRole only when necessary**.

ClusterRole이 *반드시 필요한* 경우:
1. cluster-scope 리소스 접근 (`Node`, `PersistentVolume`, `ClusterIssuer`, `ClusterRole` 자체 등)
2. 다중 NS에 동일 권한 부여 (이때도 *ClusterRole + 다중 RoleBinding* 패턴이 *ClusterRoleBinding* 보다 안전 — NS별로 명시적 grant)
3. CRD watch (`apiGroups`이 default API group 외부)

ClusterRoleBinding을 *반드시 피해야* 하는 경우:
- 단일 NS 한정 권한 → Role + RoleBinding
- "조금 더 권한 줘서 편하게" 의도 — RBAC 검토 시 *cluster-wide* 가 가장 자주 본 사고 origin

### Secret 권한 격리

모든 SA는 default로 Secret 권한 ❌. 필요한 SA만 *명시적 grant*. 다음 패턴 금지:

```yaml
# ❌ 금지 — 모든 리소스 wildcard
rules:
  - apiGroups: [""]
    resources: ["*"]
    verbs: ["*"]

# ❌ 금지 — Secret까지 verb wildcard
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["*"]

# ✅ 권장 — read-only (env injection용 등)
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
    resourceNames: ["jenkins-admin"]   # 가능하면 특정 Secret 명시
```

`resourceNames` 로 특정 Secret만 grant 가능. 사용 권장.

### cluster-admin 금지 원칙

cluster-admin ClusterRole 사용 ❌. 어떤 SA에도 grant 금지.

사유:
- cluster-admin = *모든 권한*. 사고 시 폭발 반경 무한
- "임시 디버깅" 의도여도 *지속*되는 경향
- audit log에서 cluster-admin 호출 분리 불가 (system 컴포넌트 호출과 섞임)

운영자(사람) 일시 권한 부여도 *명시적 ClusterRole + 시간 제한 token*. cluster-admin 영구 grant ❌.

### Projected SA Token (k8s 1.24+ 기본)

k8s 1.24부터 *legacy Secret 기반 SA Token 자동 생성 ❌*. 권장:

- **Projected SA Token** — token expiration 1h, kubelet이 자동 rotation
- Pod spec에 별도 설정 없이 default로 적용됨 (`serviceAccountToken` projected volume)
- 외부 시스템(GitHub Actions, CI 등)에서 *장기 token 필요* 시에만 명시적 Secret 생성

장기 Secret 기반 SA Token이 필요한 거의 모든 경우는 *재설계 신호*. 짧은 expiration + rotation으로.

### Aggregated ClusterRole 함정

K8s built-in `view` / `edit` / `admin` ClusterRole은 *aggregationRule 기반*. label matching으로 자동 권한 확장.

```yaml
aggregationRule:
  clusterRoleSelectors:
    - matchLabels:
        rbac.authorization.k8s.io/aggregate-to-admin: "true"
```

→ 새 ClusterRole에 위 label 박으면 *기존 admin ClusterRole이 자동 확장*. 의도치 않은 권한 부여 위험. 본 프로젝트는 **명시 ClusterRole 사용**, aggregation 회피.

### automountServiceAccountToken

Pod spec의 default `automountServiceAccountToken: true`. 즉 *모든 Pod에 자동 SA token 마운트*. k8s API 호출 안 하는 Pod에도 token이 박힘 → 컨테이너 침해 시 token 유출.

권장: **app NS Pod은 `automountServiceAccountToken: false`** (앱이 k8s API 호출할 일 없음). 필요한 SA만 `true`.

```yaml
spec:
  automountServiceAccountToken: false  # Pod spec 또는 SA spec에 명시
```

### Audit Annotation (선택)

RBAC 적용 시 권한 부여 이력 추적. RoleBinding의 annotation에 *부여 사유* + *티켓/PR* 명시:

```yaml
metadata:
  annotations:
    rbac.authorization.kubernetes.io/grant-reason: "Jenkins agent Pod 생성 권한"
    rbac.authorization.kubernetes.io/grant-by: "PR #42"
```

OSS 정신 + audit narrative. 필수 아님.

## 5. 주의 사항

### chicken-egg 문제

infra 단계엔 *적용 대상 SA가 미존재* (ArgoCD/Jenkins/Prometheus 등 미설치). 그래서 본 폴더는 *설계 문서만*. 실 YAML은 *컴포넌트 도입 시 함께* (`platform/<comp>/rbac.yaml`).

ArgoCD의 경우 *helm install 시 chart default RBAC 생성됨* → 본 매니페스트로 *override*. 순서:
1. helm install (chart default SA + RBAC 생성)
2. `kubectl apply -f rbac.yaml` (chart default 덮어쓰기 또는 보강)

본 컨벤션 정합한 SA name (`<component>`) 을 helm values에서 *명시*해 chart가 그 이름으로 SA 생성하게 강제.

### RBAC 변경 시 영향 범위

기존 RoleBinding에서 SA 제거 시 *해당 Pod의 k8s API 호출 즉시 실패*. 무중단 변경 위해:

1. 새 Role 또는 ClusterRole 생성
2. 새 RoleBinding 생성 (이전과 새 권한 동시 유효)
3. *충분한 시간* 모니터링 (서비스 동작 확인)
4. 이전 RoleBinding 삭제

### `system:` prefix 사용 금지

`system:` prefix Role/ClusterRole은 *k8s 내장*. 사용자 정의 금지. 새 RBAC 작성 시 prefix 회피.

### CRD 권한

CRD를 watch하려면 *해당 CRD의 apiGroup*을 ClusterRole rules에 명시:

```yaml
# Prometheus가 ServiceMonitor 발견하려면
rules:
  - apiGroups: ["monitoring.coreos.com"]
    resources: ["servicemonitors", "podmonitors"]
    verbs: ["get", "list", "watch"]
```

CRD 새로 도입 시 *기존 SA의 ClusterRole에 apiGroup 추가* 필요. CRD 설치 ≠ 자동 권한 부여.

### 다른 컴포넌트 SA에 grant 금지

Jenkins SA에 *ArgoCD 권한*, ArgoCD SA에 *Vault 권한* 같은 cross-component grant 금지. *각 SA는 자기 책임 영역만*. cross-component 통신은:

- k8s API 경유: 호출자가 자기 SA로 호출 (RBAC는 호출자 기준)
- 앱 레벨 통신: HTTP/gRPC (k8s API 무관)
- 시크릿 공유: Vault/ESO 경유 (직접 cross-namespace Secret read ❌)

### 본 문서의 진행 상태 유지

새 컴포넌트 도입 시 권한 매트릭스(2번)에 항목 추가 + 상태 업데이트. 진행 상태 표가 *실제 적용 상태*와 어긋나면 본 문서의 가치 ↓.
