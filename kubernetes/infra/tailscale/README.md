# Tailscale

관리 플레인 접근 경로. subnet router pod 1개가 VCN + Service CIDR을 tailnet에 광고하도록 구성 — kubectl / DB / admin UI의 사설 경로를 검증한 뒤 퍼블릭 admin 표면을 제거한다.

참조:
- https://tailscale.com/kb/1185/kubernetes (2026-06 확인)
- https://tailscale.com/kb/1019/subnets (2026-06 확인 — subnet router)
- https://tailscale.com/kb/1068/tags (2026-06 확인 — ACL 태그)

## 동작 원리

노트북에서 사설 IP(10.0.x DB / 10.96.x ClusterIP)에 닿는 경로:

```
노트북 ──tailnet(WireGuard 암호화)──▶ oke-vcn-router pod ──포워딩──▶ VCN/Service 대역 (DB · ClusterIP · private API)
```

router pod는 tailnet 노드이자 subnet router. tailnet으로 들어온 패킷을 광고한 대역(`TS_ROUTES`)으로 포워딩한다. 마법이 아니라 조건 4개가 맞물려서 성립 — 하나라도 빠지면 안 닿음:

1. **키 태그 ↔ deployment `--advertise-tags` 일치** — auth key의 태그와 노드가 advertise하는 태그(`tag:k8s-router`)가 같아야 인증 통과. 불일치 시 `requested tags [] are invalid or not permitted` 로 CrashLoop.
2. **ACL `tagOwners`** — 그 태그를 발급 권한자(admin)가 소유 → 노드가 합법.
3. **ACL `autoApprovers.routes`** — 그 태그 노드가 광고하는 라우트를 자동 승인 → 대역이 열림 (수동 승인 불요).
4. **클라이언트 `--accept-routes`** — 접속 기기가 advertised 서브넷을 실제 라우팅 테이블에 받음.

## 1. 전제 조건

- `tailscale` 네임스페이스 + PSA `enforce=baseline` (`../namespaces/`)
- Tailscale 계정 + admin console 접근
- 노트북 등 접속 기기에 tailscale 클라이언트 설치 + `--accept-routes`
- 이미지 핀: `tailscale/tailscale:v1.92.4` (2026-06 작성 시점 stable)

## 2. 설치

명령은 `kubernetes/infra/tailscale/` 디렉터리에서 실행한다.

### 2-1. ACL — 태그 소유 + 라우트 자동승인

admin console → Access Controls 에 병합 (HuJSON, 저장 시 빨간 에러 없어야 적용됨):

```json
"tagOwners": {
  "tag:k8s-router": ["autogroup:admin"]
},
"autoApprovers": {
  "routes": {
    "10.0.0.0/16":  ["tag:k8s-router"],
    "10.96.0.0/16": ["tag:k8s-router"]
  }
}
```

`acls` 블록이 기본 allow-all이면 본인 기기 → 서브넷 접근이 이미 열림. 좁혀놨으면 기기 → 두 CIDR 허용 규칙 추가.

### 2-2. auth key 발급

admin console → Settings → Keys → Generate auth key:

- **Reusable** 켜기 — pod 재생성 시 재등록 허용
- **Tags**: `tag:k8s-router` 선택 — 노드가 이 태그로 인증/소유됨 (태그 노드는 key expiry 기본 비활성 = 무만료)

키 태그는 deployment의 `--advertise-tags=tag:k8s-router` 와 반드시 일치.

### 2-3. Secret + 적용

```bash
kubectl create secret generic tailscale-auth \
  -n tailscale \
  --from-literal=authkey='<your-tskey-auth-...>'

kubectl apply -f rbac.yaml
kubectl apply -f deployment.yaml
```

라우트는 2-1의 `autoApprovers`가 자동 승인 → 사람 손 가는 단계 0. Machines에서 `oke-vcn-router`의 라우트 2개가 승인됨으로 떠야 함.

### 2-4. kubeconfig private endpoint 전환

```bash
oci ce cluster create-kubeconfig \
  --cluster-id "$(terraform -chdir=../../../terraform output -raw oke_cluster_id)" \
  --file ~/.kube/config \
  --region <your-region> \
  --token-version 2.0.0 \
  --kube-endpoint PRIVATE_ENDPOINT
```

## 3. 검증

```bash
kubectl get pods -n tailscale
kubectl logs -n tailscale deploy/tailscale-router --tail=30   # 'tags' 에러 없고 인증 완료

# 노트북에서 (tailscale up 상태)
tailscale set --accept-routes=true
tailscale status                  # oke-vcn-router 보이는지
nc -vz "$(terraform -chdir=../../../terraform output -raw heatwave_ip)" 3306  # DB (VCN 대역)
curl -I http://<argocd-server ClusterIP>   # admin (Service 대역)
```

직결/릴레이 확인:

```bash
tailscale ping oke-vcn-router
# "via DERP" = 릴레이 경유 — 설계된 동작 (주의 사항 참조)
```

### 검증 후 컷오버 — 퍼블릭 admin 표면 제거

tailnet 경유 kubectl/DB가 **확인된 후에만**:

```bash
# 1. admin UI 퍼블릭 제거 — GitOps 경로 (kubectl delete 금지: out-of-band 라 ArgoCD 가 되돌림)
#    각 httproute 매니페스트를 주석 처리(이미 반영) 후 prune sync → external-dns 가 DNS 레코드 자동 철거
argocd app sync argocd-httproute jenkins-httproute monitoring-httproute --prune --core

# 2. NSG 6443 룰 제거 — terraform/modules/iam/main.tf 의
#    kubectl_api 6443 ingress 룰 삭제 후 apply
```

이후 admin UI 접근(tailnet 경유): `http://<argocd-server ClusterIP>` / `http://<jenkins ClusterIP>:8080`. Grafana는 현재 `monitoring/kps/values.yaml`에서 비활성화되어 있으며 활성화한 경우에만 ClusterIP로 접근한다.

## 4. 결정

### GitOps 제외 — kubectl 부트스트랩

ArgoCD app-of-apps에 편입하지 않음. tailscale은 클러스터·ArgoCD 장애 시 *들어가는* 접근 계층이라 ArgoCD 건강에 의존하면 자기모순(잘못된 prune 한 번에 접근 경로 증발). gateway-api CRD / openbao 와 같은 부트스트랩 등급으로, 매니페스트는 git에 두되 `kubectl apply`로 적용. auth Secret은 git 밖.

### 태그 기반 노드 (untagged 비채택)

노드를 `tag:k8s-router` 태그로 운영. per-user(태그 없는) 노드 대비:
- 태그 노드는 **key expiry 기본 비활성** = 무만료 (재인증 부담 0)
- `autoApprovers`로 **라우트 자동 승인** (수동 클릭 0)
- ACL이 태그 단위로 접근 거버넌스 — 노드 신원이 개인 계정에 안 묶임

키 태그 ↔ deployment `--advertise-tags` 불일치는 `requested tags [] ... not permitted` CrashLoop의 직접 원인 (동작 원리 1번).

### pod (VM 비채택)

Always Free AMD VM subnet router 대안 비채택 — 관리 대상 OS 1개 추가 + tailscale 버전 관리 별도. pod는 이미지 핀 + 매니페스트로 클러스터 운영 모델에 흡수. NAT Gateway 뒤 outbound-only라 인바운드 NSG/SL 룰 0건.

### userspace mode (kernel mode 비채택)

kernel mode는 `/dev/net/tun` + `NET_ADMIN` 필요 = PSA baseline 위반. userspace mode는 특수 권한 없이 TCP/UDP 연결을 pod에서 재생성한다. 일반 IP 포워딩이 아니며 ICMP ping은 재생성해 응답하고 그 외 ICMP 및 다른 IP 프로토콜은 지원하지 않는다 ([Tailscale 문서](https://tailscale.com/docs/reference/kernel-vs-userspace-routers)). 클러스터 → tailnet 방향 발신이 필요해지면 재검토.

### per-device (site-to-site 비채택)

OCI Site-to-Site VPN(IPSec): 집 고정 거점 모델 — 로밍 불가 + 집에 CPE 24/7 + 동적 IP 갱신 부담으로 기각. Tailscale site-to-site(양쪽 subnet router): 집 LAN 전체가 신뢰 범위에 들어와 기기 신원 모델보다 후퇴 — 기각. 키 가진 기기만 접근하는 per-device 채택.

### state를 k8s Secret에 영속

`TS_KUBE_SECRET=tailscale-state` — pod 재생성에도 노드 신원 유지 (재인증 불요). RBAC는 Secret 생성 권한과 `tailscale-state`에 한정된 get/update/patch 권한을 부여한다. create 권한은 `resourceNames`로 제한되지 않는다.

### TS_ACCEPT_DNS=false

tailnet DNS가 pod resolv.conf를 덮으면 클러스터 DNS(CoreDNS) 깨짐. 비활성 고정.

## 5. 주의 사항

### DERP 릴레이 폴백은 설계된 동작

NAT와 방화벽 상태에 따라 직결이 어려우면 DERP 또는 사용 가능한 peer relay를 경유할 수 있다. DERP는 지연이 늘고 처리량이 제한될 수 있으므로 `tailscale ping`과 `tailscale netcheck`로 확인한다 ([Tailscale 문서](https://tailscale.com/docs/reference/troubleshooting/poor-performance-tailnet)).

### 태그 / 키 회전

태그 노드의 device key expiry는 기본 비활성이다. auth key의 유효기간은 별도이므로 재등록 전에 확인한다. auth key 유출 시 admin console에서 revoke + 재발급 → `tailscale-auth` Secret 갱신 → `kubectl rollout restart deploy/tailscale-router -n tailscale`. state Secret(`tailscale-state`)이 살아있는 한 노드 신원은 유지되므로 키는 재등록 시에만 쓰임. OpenBao 이관 후보.

### break-glass — 클러스터 다운 = 접근 경로 동반 다운

tailscale pod가 클러스터 안에 살므로 클러스터 장애 시 사설 경로도 죽음. 복구 경로:

1. OKE API 공인 엔드포인트는 존속 (`is_public_ip_enabled = true` 유지)
2. `terraform/modules/iam/main.tf`에 6443 ingress 룰 재추가 + apply
3. kubeconfig public endpoint로 재생성 → 복구 작업
4. 복구 후 룰 제거 원복

### non-root 기동 실패 시

`runAsUser: 1000` + userspace 조합은 문서상 지원이나, 이미지 버전에 따라 socket 경로 권한 이슈 가능. CrashLoop 시 1차 조치: pod securityContext의 `runAsUser`/`runAsGroup`/`runAsNonRoot` 제거 (root 기동 — baseline은 통과). 원인은 로그로 확인 후 결정.
