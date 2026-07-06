# OpenBao

시크릿 저장소. Raft 단일 replica + OCI KMS auto-unseal (instance principal). Agent Injector 동반.

참조:
- https://github.com/openbao/openbao-helm (chart `openbao/openbao`)
- https://openbao.org/docs/configuration/seal/ocikms/ (2026-06 확인)

## 1. 전제 조건

- terraform apply 완료 — `kms` 모듈 (Vault + unseal key) + `iam` 모듈 (Dynamic Group + Policy). `terraform output`으로 `kms_*` 3종 확인
- `vault` 네임스페이스 + PSA `enforce=baseline` (`../../infra/namespaces/`)
- Block Volume CSI (`oci-bv` StorageClass) — PV 50Gi 1칸 소모 (분배표 1순위)
- Helm 3.6+
- 권장 버전: openbao/openbao chart `~0.28.0` (2026-06 작성 시점 0.28.3, 설치 전 `helm search repo openbao/openbao --versions` 확인)

## 2. 설치

placeholder 치환본은 git 추적 제외(`*.local.*`)로 분리:

```bash
KEY_ID=$(terraform -chdir=../../../terraform output -raw kms_unseal_key_id)
CRYPTO=$(terraform -chdir=../../../terraform output -raw kms_crypto_endpoint)
MGMT=$(terraform -chdir=../../../terraform output -raw kms_management_endpoint)

sed -e "s|<your-kms-key-ocid>|${KEY_ID}|" \
    -e "s|<your-kms-crypto-endpoint>|${CRYPTO}|" \
    -e "s|<your-kms-management-endpoint>|${MGMT}|" \
    values.yaml > values.local.yaml
```

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update

helm install openbao openbao/openbao -n vault --version "~0.28.0" -f values.local.yaml
```

초기화 — auto-unseal 환경이라 unseal key 대신 **recovery key**가 발급됨:

```bash
kubectl exec -n vault openbao-0 -- bao operator init
```

출력된 recovery key 5장 + initial root token을 **오프라인 보관** (git, 클러스터, 노트북 단일 저장 금지. 분산 보관).

## 3. 검증

```bash
kubectl get pods -n vault
kubectl exec -n vault openbao-0 -- bao status
# 기대: Initialized=true, Sealed=false, Recovery Seal Type=shamir, Seal Type 항목에 ocikms 반영
```

auto-unseal 동작 검증 — pod 재시작 후 사람 개입 없이 unseal 되는지:

```bash
kubectl delete pod -n vault openbao-0
kubectl wait -n vault --for=condition=Ready pod/openbao-0 --timeout=300s
kubectl exec -n vault openbao-0 -- bao status | grep Sealed
# 기대: Sealed  false
```

UI는 외부 비노출 — 필요 시:

```bash
kubectl port-forward -n vault svc/openbao 8200:8200
# http://localhost:8200
```

## 4. 결정

### OpenBao (Vault 비채택)

HashiCorp Vault는 2023-08부터 BSL 1.1 (2.5년 경과 정보 — 이후 라이선스 정책 변동 여부 확인 권장). OpenBao는 MPL 2.0 + Linux Foundation 거버넌스. self-host 환경이라 BSL의 직접 제약은 없으나, 라이선스 변경 리스크 차단 + 스택 전반의 자유 라이선스 일관성으로 OpenBao 채택. Vault helm chart fork라 구조 동일 — 마이그레이션 비용 낮음.

### ocikms seal + instance principal

API key 방식 비채택 — 키 파일을 Pod에 배포/회전하는 부담 제거. 워커 인스턴스의 identity(Dynamic Group)로 KMS 호출.

폭발 반경 트레이드오프: instance principal은 노드 단위 신원이라, **metadata service(169.254.169.254)에 닿는 모든 Pod이 같은 권한 획득 가능**. 완화:

- Policy를 `use keys` + `target.key.id` 단일 키로 한정 — 탈취해도 unseal 키 encrypt/decrypt만 가능, 키 자체 export 불가
- metadata service 접근 차단(NetworkPolicy/AuthorizationPolicy)은 후속 보안 turn 항목

### software-protected key

HSM 키는 키 버전당 과금, software 키는 무료 — Always Free 0원 유지. FIPS 140-2 Level 3 경계 포기 트레이드오프 (개인 운영 환경에서 수용).

### Raft 단일 replica

3 replica HA는 노드 2개 환경에서 anti-affinity 미충족 + quorum(2/3) 의미 없음. 단일 replica + auto-unseal + PV 영속 + (후속) snapshot 백업 조합:

- pod 다운 시: 이미 주입된 시크릿은 각 Pod 메모리에 유지, 신규 Pod만 시크릿 대기
- PV 생존 시 재기동 ~5분 (auto-unseal이라 무인). PV 손상 시 snapshot 복원

### TLS 종료 위임 (tls_disable)

listener 평문 — `vault` 네임스페이스가 Istio Ambient에 enrolled되어 있어(`istio.io/dataplane-mode: ambient`), 메시 내부 caller↔OpenBao hop은 ztunnel L4 mTLS로 보호된다. 라벨이 곧 스위치 — enrollment 없으면 내부 hop도 평문이므로 이 전제는 `vault` enrolled 상태에 의존한다. ArgoCD `--insecure`와 동일 패턴. 외부 노출 자체가 없어 Gateway TLS 경로도 불요. (보호는 *메시 내부* hop 한정 — 현재 ESO 등 in-mesh caller는 후속.)

### Agent Injector (일부 시크릿은 ESO 필수로 확정)

annotation 기반 sidecar 주입을 기본 채택하되, `ghcr-push`/`ghcr-pull`처럼 **Pod 생성 이전에 이미 존재해야 하는 k8s Secret 객체**(imagePullSecret, projected volume 참조)는 Injector 로 구조적으로 만들 수 없음 — Injector는 Pod 내부에 런타임 파일을 주입할 뿐 Secret 오브젝트 자체를 사전 생성하지 못하는 닭-달걀 문제. 이 부류는 **ESO 채택 확정**. 그 외(런타임에 파일/env 로 받아도 되는 시크릿, 예: DB 자격증명)는 Injector 유지. 두 방식이 시크릿 종류별로 공존.

## 5. 주의 사항

### recovery key

auto-unseal에서 recovery key는 seal 마이그레이션·rekey·일부 운영 행위에만 사용 — 일상 unseal에는 불필요. 분실 시 KMS 키 장애와 겹치면 복구 불가. init 출력은 1회성.

### KMS 의존 = unseal 경로의 단일 실패점

OpenBao 기동 시마다 KMS 호출 필요. OCI KMS 장애 또는 Policy/Dynamic Group 변경 실수 시 재기동 불가 (떠있는 인스턴스는 영향 없음). Policy 변경은 plan diff 확인 후 적용.

### KMS vault 삭제 대기

OCI KMS vault는 즉시 삭제 불가 — 최소 7일 pending deletion. `terraform destroy` 시 해당 기간 동안 같은 이름 재생성 충돌 주의.

### unseal 키 회전

OCI KMS 키 rotation은 새 key version 생성 방식 — `key_id` 불변이라 OpenBao 설정 변경 불요. `key_id` 자체를 바꾸려면 shamir로 seal migration 후 재마이그레이션 필요.

### cold-start / DR 복구 순서

```
terraform (KMS + IAM) → OKE 노드 → namespaces → openbao (auto-unseal) → 시크릿 소비 컴포넌트
```

시크릿을 OpenBao로 이관할수록 이 순서가 복구의 크리티컬 패스가 됨. 수동 적용 흐름 문서를 이 순서와 정합하게 유지할 것.
