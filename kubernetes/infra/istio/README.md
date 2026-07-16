# Istio Ambient

서비스 메시 + Gateway API 데이터플레인. Ambient 모드 (sidecar 비채택).

참조: https://istio.io/latest/docs/ambient/install/helm/

## 1. 전제 조건

- Gateway API CRD 설치 완료 (`../gateway-api/`)
- `istio-system` 네임스페이스 존재 (`../namespaces/namespaces.yaml`)
- cert-manager Certificate `istio-system/public-wildcard` Ready=True (`../cert-manager/`)
- Helm 3.6+ (또는 4)
- 권장 버전: **Istio 1.29.x** (`~1.29.0` SemVer 범위)

## 2. 설치

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

helm install istio-base istio/base    -n istio-system --version "~1.29.0" -f base.values.yaml    --wait
helm install istiod     istio/istiod  -n istio-system --version "~1.29.0" -f istiod.values.yaml  --wait
helm install istio-cni  istio/cni     -n istio-system --version "~1.29.0" -f cni.values.yaml     --wait
helm install ztunnel    istio/ztunnel -n istio-system --version "~1.29.0" -f ztunnel.values.yaml --wait

kubectl apply -f gateway.yaml
kubectl apply -f http-redirect.yaml
```

## 3. 검증

```bash
kubectl get pods -n istio-system
kubectl get gatewayclass
kubectl get gateway -n istio-system
kubectl get deployment,svc -n istio-system -l gateway.networking.k8s.io/gateway-name=public-gateway
kubectl get httproute -n istio-system

GATEWAY_IP=$(kubectl get gateway public-gateway -n istio-system -o jsonpath='{.status.addresses[0].value}')

# HTTP → 308 redirect to https
curl -vI "http://ggang.cloud" --resolve "ggang.cloud:80:${GATEWAY_IP}"

# HTTPS apex TLS handshake
openssl s_client -connect "${GATEWAY_IP}:443" -servername "ggang.cloud" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

# HTTPS wildcard TLS handshake
openssl s_client -connect "${GATEWAY_IP}:443" -servername "test.ggang.cloud" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject

# HTTPRoute 미연결 상태에서 https 응답은 404 + server: istio-envoy 가 정상
curl -vIk "https://ggang.cloud" --resolve "ggang.cloud:443:${GATEWAY_IP}"
```

## 4. 결정

### Ambient 채택

| 항목 | sidecar | ambient |
|------|---------|---------|
| Pod당 추가 RAM | ~40-50MB (envoy sidecar) | 0 |
| 노드당 추가 RAM | 0 | ~80MB (ztunnel) |
| L7 정책 | 즉시 가능 | waypoint 별도 배포 시 가능 |
| Pod restart | 주입 시 강제 | 불필요 |
| GA | 오래됨 | 2024-11 (1.24) |

OCI Always Free 24GB RAM, 앱 파드 10개 가정 시 sidecar는 400-500MB 추가. ambient는 노드 2개 × 80MB = 160MB. L7 필요 시점에만 waypoint 추가.

### Istio Gateway Helm chart 비채택

Helm으로 깔리는 4개: `base`, `istiod`, `cni`, `ztunnel`.

`istio/gateway` chart는 깔지 않는다. 외부 트래픽을 Gateway API 표준 리소스(`Gateway`, `HTTPRoute`)로 처리하기로 결정. `istio/gateway` chart는 구식 Istio Gateway CR용 envoy를 띄우는 chart라 본 결정과 모순.

Gateway API `Gateway` 리소스를 선언하면 Istio가 reconcile하면서 envoy Deployment + Service를 자동 프로비저닝한다. NLB annotation은 `spec.infrastructure.annotations` 필드로 전달.

### 트래픽 분리 원칙

- 남북(외부 ↔ 클러스터): Gateway API (`Gateway`, `HTTPRoute`, `GRPCRoute`)
- 동서(클러스터 내부 정책): Istio CR (`PeerAuthentication`, `AuthorizationPolicy`)
- `VirtualService` / 구 `Gateway`(Istio CR) 신규 작성 금지

### OCI Network LB (L4 TCP passthrough)

Flexible LB(L7) 대신 NLB 선택.

사유: Istio Gateway envoy가 TLS 종료 + L7 라우팅을 단독 책임. L7 LB를 앞단에 두면 (1) 라우팅 책임 중복, (2) 인증서 두 군데 관리, (3) 불필요한 TLS 재암호화. NLB로 TCP passthrough 시 책임 경계 명확 + cert-manager 단일 관리.

annotation은 `gateway.yaml` 참조. AWS NLB / GCP TCP LB와 동일한 권장 패턴.

### istioctl 비채택

Helm only. istioctl로 설치 시 GitOps drift 추적 불가.

### profile=ambient 사후 변경 불가

ambient → sidecar 전환은 사실상 재설치. 결정 본 단계에서 고정.

### Listener — HTTPS는 apex/wildcard 분리, HTTP는 catch-all

```
http              port 80   hostname 미지정 (catch-all)        → redirect
https-apex        port 443  hostname ggang.cloud               → TLS Terminate
https-wildcard    port 443  hostname *.ggang.cloud             → TLS Terminate
```

`*.ggang.cloud` 와일드카드는 apex `ggang.cloud`를 매칭하지 않음 (RFC 6125). apex 트래픽까지 받으려면 listener 분리 필수. 같은 `public-wildcard-tls` Secret을 두 listener가 참조 — cert SAN에 apex + 와일드카드 둘 다 있으므로 단일 Secret으로 충분.

HTTP listener는 hostname 박지 않음. HTTP는 redirect 전용이라 listener에서 host 매칭 의미 없음. host 매칭은 redirect 후 HTTPS listener + HTTPRoute가 책임.

### HTTP → HTTPS Redirect는 별도 HTTPRoute

`http-redirect.yaml` 분리. Gateway = 네트워크 진입점 정의 / HTTPRoute = 라우팅 정책. 책임 경계 분리.

`parentRefs.sectionName: http` 로 80 listener에만 attach. statusCode 308 (method-preserving) — 301과 달리 POST/PUT 메소드 보존. HSTS와 같이 운영하면 redirect는 첫 접속만 거치므로 코드 차이 체감은 적지만 명목상 정확.

### TLS mode: Terminate

NLB가 TCP passthrough이므로 TLS 종료는 Gateway envoy가 책임. mTLS passthrough (`mode: Passthrough`) 비채택 — Gateway가 SNI만 보고 백엔드로 그대로 전달하는 모드라 L7 라우팅/policy 불가. 클러스터 내부 mTLS는 Istio Ambient ztunnel이 처리하되 **per-namespace opt-in** — `istio.io/dataplane-mode: ambient` 라벨이 붙은 NS(현재 `app`/`cicd`/`vault`/`data`/`core`/`batch`/`auth`, `namespaces.yaml` 참조)에 한해 적용되고, 라벨 없는 NS의 내부 hop은 평문 그대로다.

## 5. 주의 사항

### Cilium chaining 도입 시 CNI 순서 충돌 가능

본 클러스터는 추후 Cilium chaining (`generic-veth` 모드)을 Flannel 위에 올릴 예정. 그 시점에 CNI chain 순서:

```
Flannel  →  Cilium (NetworkPolicy + Hubble)  →  Istio CNI (ambient redirect)
```

Istio CNI는 `cni.chained: true`로 설정되어 마지막 위치를 기대함. Cilium chaining 설치 매니페스트에서 `cni-conf-path` 우선순위를 확인하고 충돌 시 `cniBinDir` / `cniConfDir` 명시 override 필요.

### Certificate Secret 의존

`gateway.yaml` HTTPS listener는 `istio-system/public-wildcard-tls` Secret 참조. cert-manager Certificate (`../cert-manager/certificate.yaml`) 발급 완료(Ready=True) 후 Gateway apply 권장. Secret 미존재 상태로 apply 시 Gateway status에 `ResolvedRefs: False` 박힘 — Certificate 발급되면 자동 회복되지만 Gateway listener status 노이즈 발생.

### istio-system PSA

ambient의 ztunnel + istio-cni는 host network + privileged container 필요. `istio-system` 네임스페이스에 PSA label 적용 금지 (`namespaces.yaml`에서 의도적으로 미적용).

### Values override 범위

`*.values.yaml`은 chart default 위에 *덮어쓰는 override만* 명시. 전체 schema 확인:

```bash
helm show values istio/base    --version "~1.29.0"
helm show values istio/istiod  --version "~1.29.0"
helm show values istio/cni     --version "~1.29.0"
helm show values istio/ztunnel --version "~1.29.0"
```
