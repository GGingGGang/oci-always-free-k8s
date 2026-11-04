# cert-manager + Let's Encrypt (DNS-01 / Cloudflare)

Gateway API listener에 박을 TLS 인증서를 Let's Encrypt에서 자동 발급·갱신. solver는 DNS-01 (Cloudflare) — 와일드카드 발급 가능.

참조:
- https://cert-manager.io/docs/installation/helm/
- https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/
- https://cert-manager.io/docs/usage/gateway/

## 1. 전제 조건

- `cert-manager`와 `istio-system` 네임스페이스 존재 (`../namespaces/namespaces.yaml`)
- Gateway API CRD 설치 완료 (`../gateway-api/`)
- Helm 3.6+
- 도메인 zone이 Cloudflare에서 관리됨
- Cloudflare API Token (대시보드 → My Profile → API Tokens → Create Token)
  - Permissions: `Zone : DNS : Edit` + `Zone : Zone : Read`
  - Zone Resources: `Include : Specific zone : ggang.cloud`
  - external-dns용 token과 **분리해서 발급** (사고 시 폭발 반경 최소화)
- Argo CD에 고정된 cert-manager chart `v1.18.6` (`../../platform/argocd/apps/cert-manager.yaml`)

## 2. 설치

수동 부트스트랩 명령은 저장소의 `kubernetes/infra/cert-manager` 디렉터리에서 실행한다. Argo CD 운영 시 Secret을 먼저 직접 생성하고 `cert-manager` Application을 sync한 뒤 준비되면 `cert-manager-resources`를 sync한다 (각 sync wave 1, 3). 기존 Helm release에 다시 `helm install`하지 않는다.

```bash
kubectl create secret generic cloudflare-api-token \
  -n cert-manager \
  --from-literal=api-token='<your-cf-token>'

helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  -n cert-manager \
  --version v1.18.6 \
  -f values.yaml \
  --wait

kubectl apply -f cluster-issuer.yaml
kubectl apply -f certificate.yaml
```

## 3. 검증

```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer
kubectl get certificate -n istio-system
kubectl describe certificate public-wildcard -n istio-system | tail -30
```

발급 성공 시 Ready=True, `public-wildcard-tls` Secret이 `istio-system`에 생성됨.

```bash
kubectl get secret public-wildcard-tls -n istio-system -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

```bash
[cert-manager]$ kubectl get certificate -n istio-system
NAME              READY   SECRET                AGE
public-wildcard   True    public-wildcard-tls   2m34s

[cert-manager]$ kubectl get secret public-wildcard-tls -n istio-system -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
subject=CN=ggang.cloud
issuer=C=US, O=Let's Encrypt, CN=E7
notBefore=May 24 07:30:09 2026 GMT
notAfter=Aug 22 07:30:08 2026 GMT
X509v3 Subject Alternative Name: 
    DNS:*.ggang.cloud, DNS:ggang.cloud

```

발급 실패 시:

```bash
kubectl describe certificaterequest -n istio-system
kubectl describe order -n istio-system
kubectl describe challenge -n istio-system
kubectl logs -n cert-manager -l app.kubernetes.io/component=controller --tail=100
```

## 4. 결정

### DNS-01 / Cloudflare solver

HTTP-01 비채택 사유:
- 와일드카드 발급 불가 (LE 표준 제약) → host 추가 시마다 신규 인증서 + LE rate-limit(50/주/등록도메인) 부담
- solver HTTPRoute가 Gateway 80에 임시 attach → cert-manager가 Gateway에 쓰기 권한을 가져야 함
- 도메인 NS가 Cloudflare에 있는 한 *호환성 측면 의존*은 동일. HTTP-01로 가도 lock-in 감소 효과 없음

DNS-01 채택 결과:
- 와일드카드 `*.ggang.cloud` 1장으로 한 단계 하위 subdomain 커버
- Cloudflare API 의존은 ClusterIssuer 한 장에 응축 (provider 교체 시 solvers 블록만 수정, 인증서 재발급 불필요)
- Gateway 80을 cert-manager가 건드리지 않음 → listener 책임 경계 명확

### Issuer / Certificate를 명시적으로 작성

annotation 기반 자동 생성(`cert-manager.io/cluster-issuer`) 대신 Certificate CR 직접 선언. ArgoCD diff에서 발급 의도가 git 레벨로 기록 + 와일드카드를 listener별로 자동화하지 않고 한 곳에서 통제.

### Wildcard + apex 1장

`ggang.cloud` + `*.ggang.cloud` 을 SAN으로 묶어 1장 발급. 신규 host 추가 시 재발급 불필요. LE 갱신 부하는 host 분리 대비 1/N.

### ECDSA P-256

RSA-2048 대신 ECDSA. 동일 보안 강도에서 키/서명 크기 ↓, TLS handshake CPU ↓. envoy/curl/주요 브라우저 전 범위 호환. `rotationPolicy: Always`로 renew마다 새 키 발급 (탈취 시 노출 창 최소화).

### staging + prod ClusterIssuer 둘 다 생성

현재 `certificate.yaml`은 `letsencrypt-prod`를 참조한다. 테스트 시 `issuerRef.name`을 `letsencrypt-staging`으로 바꿔 DNS 검증과 발급을 확인한 뒤 `letsencrypt-prod`로 되돌린다. staging 인증서는 일반 브라우저에서 신뢰되지 않는다. Argo CD가 관리 중이면 Git에 변경을 반영하고 sync한다.

### DNS-01 recursive nameserver 명시

`dns01RecursiveNameserversOnly: true` + `1.1.1.1,8.8.8.8`. cert-manager가 self-check할 때 클러스터 내부 CoreDNS의 split-horizon/캐시 영향을 우회. Cloudflare DNS 전파가 빠른 편이지만 LE order의 propagation check를 안정적으로 통과시키기 위함.

### Secret은 cert-manager 네임스페이스 한정

ClusterIssuer가 `cert-manager` 네임스페이스의 Secret만 참조 가능 (cert-manager `--cluster-resource-namespace` 기본값). external-dns token과 같은 권한 scope여도 *물리적으로 분리된 Secret 객체*로 운영 → 권한 변경/회전이 한쪽만 영향.

## 5. 주의 사항

### Gateway listener 연결

본 매니페스트는 cert-manager 설치 + Certificate 발급까지. `../istio/gateway.yaml`의 `istio-system/public-gateway` HTTPS listener는 `public-wildcard-tls`를 참조하며 HTTP→HTTPS redirect는 `../istio/http-redirect.yaml`에 선언된다.

### Token 회전

```bash
kubectl delete secret cloudflare-api-token -n cert-manager
kubectl create secret generic cloudflare-api-token -n cert-manager --from-literal=api-token='<new-token>'
kubectl rollout restart deployment/cert-manager -n cert-manager
```

cert-manager는 Secret을 매 reconcile마다 다시 읽으므로 controller restart 없이도 다음 challenge부터 새 token 사용. restart는 안전 마진.

### LE rate-limit 회피

prod issuer로 처음 발급 시도 전에 staging으로 1차 검증. 발급 제한과 인증 실패 제한은 서로 다르므로 [LE rate limits](https://letsencrypt.org/docs/rate-limits/)를 확인한다.

### 갱신 타이밍

`renewBefore: 360h` (15일). 실제 인증서 만료 15일 전에 자동 갱신 시도 (유효기간이 90일이면 약 83% 시점). 실패 시 cert-manager가 backoff 재시도. `values.yaml`은 Prometheus metrics를 비활성화하므로 해당 메트릭 감시에는 별도 설정이 필요하다.

### CRD upgrade

`crds.keep: true`. helm uninstall 시에도 CRD 보존 → 운영 중 Certificate 객체가 의도치 않게 삭제되는 사고 방지. `crds.enabled: true`로 chart가 CRD를 관리한다. 업그레이드 시 대상 버전의 릴리스 노트와 [업그레이드 안내](https://cert-manager.io/docs/installation/upgrade/)를 확인하고 chart와 함께 CRD를 갱신한다.

### Secret 관리 — Vault 이관 예정

Cloudflare token은 현재 `kubectl create secret`으로 직접 생성. OpenBao 도입 완료(`../../platform/openbao/`) — 후속 turn 에서 Vault Agent Injector + Cloudflare token rotation 자동화로 이관.
