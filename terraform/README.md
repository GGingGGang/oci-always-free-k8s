# terraform

OCI 인프라 프로비저닝. VCN, OKE Basic Cluster, ARM Always Free 노드 풀, HeatWave MySQL Free, KMS (OpenBao auto-unseal), IAM (NSG / Dynamic Group / Policy), Object Storage.

## 1. 전제 조건

- OCI 유료 계정 (Pay As You Go / Universal Credits) — OKE는 Free Tier 계정 미지원
- Terraform `>= 1.3.0`
- OCI API Key (`.pem`) + fingerprint + tenancy/user OCID
- SSH 공개키 (워커 노드 접근용)
- OCI CLI — kubeconfig 생성 시 사용

## 2. 설치

### 2-1. 인증 정보 작성

```bash
cp terraform.tfvars.example terraform.tfvars
# tenancy_ocid, user_ocid, fingerprint, private_key_path, region,
# compartment_ocid, ssh_authorized_keys, db_admin_password, allowed_cidr 채움
```

`private_key_path`는 `./secrets/oci-api-key.pem` 권장 (`secrets/`는 `.gitignore` 적용).

### 2-2. remote state 백엔드

state 는 OCI Object Storage 의 네이티브 `oci` 백엔드에 저장 (Terraform ≥ 1.12 필요 — 백엔드 자체가 1.12.0 도입, changelog #34465, 2026-07 확인). 잠금은 Object Storage `If-None-Match` 헤더 기반으로 백엔드가 자체 지원.

버킷은 1회 수동 생성 (state 를 담을 통이라 terraform 자신으로 못 만듦 — 닭-달걀):

```bash
oci os bucket create --name tfstate \
  --compartment-id <tenancy-ocid> --versioning Enabled
```

`--versioning Enabled` — state 파일 이력 보존 (잘못된 apply 후 이전 버전 복구 경로).

백엔드 값은 커밋하지 않고 `backend.local.hcl` 로 주입 (`*.local.*` gitignore):

```bash
cp backend.hcl.example backend.local.hcl
# namespace(oci os ns get), region 채움
```

### 2-3. 적용

```bash
terraform init -backend-config=backend.local.hcl
terraform plan
terraform apply
```

기존 로컬 state 에서 이관할 때는 `terraform init -backend-config=backend.local.hcl -migrate-state` — 이관 후 `terraform plan` 이 no-op 인지 확인하고 로컬 `terraform.tfstate*` 는 백업 후 삭제 (state 에 `db_admin_password` 등 민감값 포함 — 로컬 잔존 사본 자체가 리스크).

### 2-4. kubeconfig 생성

```bash
oci ce cluster create-kubeconfig \
  --cluster-id "$(terraform output -raw oke_cluster_id)" \
  --file ~/.kube/config \
  --region <your-region> \
  --token-version 2.0.0
```

## 3. 검증

```bash
terraform output
kubectl get nodes -o wide
kubectl get svc -A
```

노드 2개가 `Ready` 상태로 보이면 정상. `terraform output`의 `heatwave_ip`/`heatwave_port`로 MySQL 접속 가능 (워커 노드 또는 Bastion 경유).

## 4. 결정

### Basic Cluster

Enhanced ($0.10/h) 대신 Basic 선택. 컨트롤 플레인 자체 무료, 워커는 A1.Flex Always Free 쿼터 사용 → **클러스터 전체 0원**. 단 Virtual Nodes / OKE Add-ons / 컨트롤 플레인 SLA 미지원.

### Flannel Overlay CNI

`cluster_pod_network_options.cni_type = "FLANNEL_OVERLAY"`. Basic Cluster는 VCN-Native CNI 미지원이라 Flannel 강제. Pod CIDR `10.244.0.0/16`, Service CIDR `10.96.0.0/16`.

### ARM A1.Flex × 2 노드

`VM.Standard.A1.Flex`, 노드당 2 OCPU / 12 GB. 2노드 = 4 OCPU / 24 GB → Always Free 한도 정확히 일치. AMD VM (1/8 OCPU, 1 GB) 대비 ARM이 24배 더 큰 메모리 → k8s 워커 최적.

### 이미지 동적 조회 (regex)

`Oracle-Linux-8\.\d+-aarch64-.*` 정규식으로 리전별 최신 ARM 이미지 조회. region마다 OCID가 달라 하드코딩 불가. `sort_by=TIMECREATED DESC`로 가장 최근 빌드 선택.

### NSG 기반 admin 접근 제한

`oci_core_network_security_group.public_access` — `allowed_cidr` 에서 TCP 6443(OKE API) / 443 / 80 만 허용 (포트 명시, `protocol all` 비채택 — 허용 IP 침해 시에도 도달 포트 최소화). 현재 OKE API endpoint(`endpoint_nsg_ids`)에만 부착 — LoadBalancer(Gateway API가 프로비전하는 NLB)는 `kubernetes/infra/istio/gateway.yaml`의 `infrastructure.annotations`에 NSG 지정이 없어 미부착 상태. Security List가 `0.0.0.0/0` 허용해도 API endpoint는 NSG가 한 번 더 거름. CIDR 변경은 `terraform apply` 한 번으로 동기.

### KMS — OpenBao auto-unseal 키

`kms` 모듈: Standard Vault(`DEFAULT`) + AES-256 키 1개. `protection_mode = "SOFTWARE"` — software-protected 키는 과금 없음 (HSM 키 버전만 과금) → Always Free 0원 유지. FIPS HSM 경계 포기 트레이드오프.

### Dynamic Group + Policy — instance principal

`iam` 모듈: 워커 인스턴스를 compartment 단위로 매칭하는 Dynamic Group + `use keys` 를 `target.key.id` (unseal 키 1개)로 한정하는 Policy. API key 파일을 Pod 에 배포하지 않고 인스턴스 신원으로 KMS 호출. compartment 내 모든 인스턴스가 매칭되는 폭발 반경은 키 1개 한정 + `use` verb 로 제한.

### Service Gateway "All Services" 명시적 선택

```hcl
all_services = [
  for s in data.oci_core_services.all.services :
  s if startswith(s.name, "All ")
][0]
```

`services[0]` 인덱스는 리전마다 순서가 달라 Object Storage 한정 SGW가 잡힐 수 있음. `"All <Region> Services in Oracle Services Network"` 를 이름 prefix로 명시적 필터.

### 4-subnet 분리

| Subnet | CIDR | 유형 | 용도 |
|--------|------|------|------|
| subnet-oke-api | 10.0.0.0/28 | Public | OKE API endpoint |
| subnet-public | 10.0.1.0/28 | Public | OCI Load Balancer |
| subnet-workers | 10.0.102.0/24 | Private | Worker nodes |
| subnet-db | 10.0.201.0/28 | Private | HeatWave MySQL |

DB가 Service Gateway 경유 OCI 내부 서비스(패치/백업)에 접근 — 인터넷 비노출. 워커는 NAT Gateway로 image pull / OS 업데이트.

### HeatWave MySQL.Free

`MySQL.Free` shape, 50GB. AlwaysFree 1 인스턴스 한도. `deletion_policy.is_delete_protected = false` — terraform destroy 시 함께 제거. 운영 데이터 유의.

### terraform 모듈 분리

`networking` → `oke` / `iam` / `database` 의존. `kms` 는 독립, `iam` 이 unseal 키 OCID 를 참조. `object-storage` 도 독립. 모듈별 책임 명확, 부분 적용 가능.

```
networking ──┬──► oke
             ├──► iam ◄── kms (unseal_key_id)
             └──► database
object-storage (독립)
```

### object-storage 모듈

`bucket_names` 리스트로 버킷 일괄 생성. **기본 빈 리스트 — 모듈 배선만 선반영하고 버킷은 소비처(Loki/Velero/Vault-snapshot) 준비 시점에 채움.** `bucket_names = []` 면 버킷 리소스 0개, namespace 조회(read-only)와 endpoint output 만 확보. `NoPublicAccess` + 버저닝 비활성 (Loki compactor 가 retention 직접 관리). namespace + S3-compat endpoint 를 output 으로 노출 — `https://<namespace>.compat.objectstorage.<region>.oraclecloud.com`. S3 자격(Customer Secret Key)은 **state 오염 회피로 terraform 미포함** — 콘솔에서 수동 발급 후 소비처(k8s Secret/OpenBao)에 주입.

## 5. 주의 사항

### A1 capacity error

OCI 리전별 ARM 노드 가용성 부족 시 `Out of host capacity` 에러. 적용 실패 시 재시도하거나 다른 AD (`availability_domain`) 시도. `local.availability_domain = ...availability_domains[0].name` 이라 AD 변경은 코드 수정 필요.

### `allowed_cidr` 변경 시 NSG drift

CIDR 변경 후 `terraform apply` 즉시 NSG가 갱신됨. 이전 IP에서 활성 연결 중인 kubectl 세션이 끊김. 작업 IP 바뀌면 사전 갱신.

### kubernetes_version 리전 가용성

default `v1.34.2`가 리전에서 미지원일 수 있음. 적용 전 `oci ce cluster-options get --cluster-option-id all`로 가용 버전 확인.

### terraform state

현재 로컬 state. 팀 운영 또는 다중 환경 시 OCI Object Storage backend로 이관 권고:

```hcl
terraform {
  backend "s3" {  # OCI Object Storage S3 호환
    bucket   = "<your-state-bucket>"
    key      = "oci-always-free-k8s.tfstate"
    region   = "<your-region>"
    endpoint = "https://<namespace>.compat.objectstorage.<region>.oraclecloud.com"
  }
}
```

### db_admin_password rotation

`sensitive = true`로 plan/apply 출력에서 마스킹. tfvars 자체는 `.gitignore` 적용. 회전은 OCI 콘솔에서 직접 변경 후 `terraform refresh` 또는 변수만 갱신해서 in-place update.

### secrets/ 폴더

`secrets/oci-api-key.pem`, `secrets/bastion.pem` 등 키 자산은 `*.pem`/`*.ppk`/`*.pub` gitignore 패턴으로 추적 제외. 본 폴더는 컨벤션이며 임의 경로 사용 가능.

### 모듈 그래프와 destroy 순서

`terraform destroy`는 의존 역순으로 자동 처리. 단 HeatWave MySQL은 삭제까지 5~10분 소요. 중간에 중단하면 stuck 가능 → 완전 종료까지 대기.

### KMS vault 삭제 대기

OCI KMS vault 는 즉시 삭제 불가 — 최소 7일 pending deletion 후 삭제됨. destroy 후 같은 display_name 재생성은 가능하지만 pending 상태의 vault 가 콘솔에 남아있음에 유의.

### Dynamic Group 은 tenancy 레벨

`oci_identity_dynamic_group` 은 compartment 가 아닌 tenancy(루트)에 생성됨 — `tenancy_ocid` 필요. 같은 tenancy 에서 이름(`dg-oke-workers`) 충돌 시 apply 실패.
