# Gateway API CRD

Gateway API v1.5.0 standard channel CRD. Istio (`base`/Gateway 컨트롤러), cert-manager (Gateway integration), external-dns (`gateway-httproute` source) 모두의 선행 조건.

참조: https://gateway-api.sigs.k8s.io/guides/getting-started/introduction/#installing-gateway-api

## 1. 전제 조건

- kubectl 접근 가능

## 2. 설치

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
```

CRD 8개 + ValidatingAdmissionPolicy 1개 설치:

- `gatewayclasses`, `gateways`, `httproutes`, `grpcroutes`, `tlsroutes`
- `backendtlspolicies`, `referencegrants`, `listenersets`
- `safe-upgrades.gateway.networking.k8s.io` (ValidatingAdmissionPolicy + Binding)

`--server-side` 필수 — CRD가 client-side apply의 annotation size 제한(262144 bytes)을 초과.

## 3. 검증

```bash
kubectl get crd -l gateway.networking.k8s.io/bundle-version
kubectl get crd -o jsonpath='{range .items[?(@.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version)]}{.metadata.name}{"\t"}{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}{end}'
```

모든 CRD가 `v1.5.0` 으로 표기되어야 함.

## 4. 결정

### Gateway API CRD를 단독 핀 관리

Istio `base` chart는 Gateway API CRD를 번들하지 않음 — 클러스터에 CRD가 미리 설치돼 있어야 istiod가 Gateway API 지원을 활성화함. (istio/base에 `enableGatewayCRDs` 식 자동 설치 값을 넣자는 건 커뮤니티 제안 단계로 미병합 — istio/istio Discussion #57636, 작성 시점 2026-06.)

따라서 Gateway API CRD는 본 매니페스트에서 단독 설치·버전 핀. CRD 버전 소유권이 이 레포에 있어 Istio 업그레이드와 독립적으로 관리됨 — 단 Istio가 지원하는 Gateway API 버전 범위와 교집합 안에서만 갈아끼움(5장).

istiod의 Gateway 자동 프로비저닝(`PILOT_ENABLE_GATEWAY_API_DEPLOYMENT_CONTROLLER`)은 CRD 설치와 무관한 별개 기능 — Gateway 리소스로부터 게이트웨이 데이터플레인(Service+Deployment)을 띄우는 데 사용하며 istiod default(켜짐) 유지.

### Standard channel

Standard channel — GA + Beta 리소스만. Experimental channel(`experimental-install.yaml`)은 BackendLBPolicy, ServiceImport 등 알파 리소스 포함. 현 단계 미사용 → standard로 충분.

향후 멀티 클러스터 traffic split, BackendLBPolicy 같은 알파 기능 도입 시 experimental 채널로 교체 검토.

### Server-side apply

`--server-side`로 적용. CRD가 client-side annotation 제한 초과 + 추후 cert-manager/Istio가 동일 CRD를 server-side 소유권으로 reconcile할 때 충돌 회피.

## 5. 주의 사항

### CRD 업그레이드

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/vX.Y.Z/standard-install.yaml
```

major 변경(v1.x → v2.x) 시 호환성 표 확인 (`https://gateway-api.sigs.k8s.io/concepts/versioning/`). Istio가 지원하는 Gateway API 버전 범위와 교집합 안에서 갈아끼움.

### CRD 삭제 금지

`kubectl delete crd ...` 는 해당 CRD의 모든 CR을 cascade 삭제 → Gateway/HTTPRoute 다 사라지고 트래픽 절단. CRD 제거는 클러스터 폐기 시점 한정.

### Istio가 CRD 설치를 떠안는지 확인

현재 Istio는 Gateway API CRD를 설치하지 않으므로 충돌 없음. 단 #57636 같은 자동 설치 기능이 향후 병합되면 Istio 업그레이드 시 본 매니페스트의 단독 핀과 이중 설치·버전 경합이 날 수 있음 → release notes에서 Gateway API CRD 번들 여부 확인.
