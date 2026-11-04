# terraform

OCI 인프라 프로비저닝. VCN, OKE Basic Cluster, ARM A1.Flex 노드 풀, HeatWave MySQL Free, KMS (OpenBao auto-unseal), IAM (NSG / Dynamic Group / Policy), Object Storage.

## 1. 전제 조건

- OCI 유료 계정 (Pay As You Go / Universal Credits) — OKE는 Free Tier 계정 미지원
- Terraform `>= 1.12.0` (`oci` 백엔드 요구, §2-2)
- OCI API Key (`.pem`) + fingerprint + tenancy/user OCID
- SSH 공개키 (워커 노드 접근용)
- OCI CLI — kubeconfig 생성 시 사용

## 2. 설치

아래 명령은 `terraform/` 디렉터리에서 실행한다. OCI CLI와 백엔드에 사용할 `~/.oci/config`의 `DEFAULT` 프로필을 설정하고 버킷 생성 및 state 객체 읽기/쓰기 권한을 준비한다. Provider의 `terraform.tfvars` 인증과 백엔드 인증은 별개다.

### 2-1. 인증 정보 작성

```bash
cp terraform.tfvars.example terraform.tfvars
# tenancy_ocid, user_ocid, fingerprint, private_key_path, region,
# compartment_ocid, ssh_authorized_keys, db_admin_password, allowed_cidr 채움
```

`private_key_path`는 `./secrets/oci-api-key.pem` 권장 (`*.pem`은 `.gitignore` 적용).

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

노드 2개가 `Ready` 상태로 보이는지 확인한다. `terraform output`의 `heatwave_ip`/`heatwave_port`는 private DB endpoint이며 현재 DB ingress는 워커 서브넷의 TCP 3306만 허용한다. Bastion 등 다른 경로에는 별도 네트워크 규칙이 필요하다.

## 4. 결정

### Basic Cluster

Enhanced ($0.10/h) 대신 Basic 선택. 컨트롤 플레인은 무료이며 워커는 A1.Flex를 사용한다. 부트/블록 볼륨, Object Storage, 네트워크 등의 사용량과 기존 tenancy 사용량에 따라 비용이 발생할 수 있다. Virtual Nodes와 컨트롤 플레인 SLA는 미지원이며, 필수 OKE add-on의 사용자 지정은 유지가 보장되지 않는다.

### Flannel Overlay CNI

`cluster_pod_network_options.cni_type = "FLANNEL_OVERLAY"`. 이 구성은 Flannel을 사용한다. Pod CIDR `10.244.0.0/16`, Service CIDR `10.96.0.0/16`.

### ARM A1.Flex × 2 노드

`VM.Standard.A1.Flex`, 노드당 2 OCPU / 12 GB, 2노드 합계 4 OCPU / 24 GB를 선언한다. [Oracle Always Free 안내](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)는 홈 리전의 A1 VM에 대해 모든 tenancy에 월 1,500 OCPU-hour / 9,000 GB-hour를 제공하며 Always Free tenancy에서는 2 OCPU / 12 GB에 해당한다고 설명한다. 이 프로젝트의 PAYG 계정에는 4 OCPU / 24 GB 무료 조건이 적용되므로 위 워커 구성은 그 조건에 맞춘다.

### 이미지 동적 조회 (regex)

`Oracle-Linux-8\.\d+-aarch64-.*` 정규식으로 리전별 최신 ARM 이미지 조회. `sort_by=TIMECREATED DESC`로 조건에 맞는 가장 최근 빌드를 선택한다. 이 필터는 Kubernetes 버전이나 OKE 지원 이미지 목록을 확인하지 않으므로 적용 전 `oci ce node-pool-options get --node-pool-option-id all`로 호환성을 확인한다.

### NSG 기반 admin 접근 제한

`oci_core_network_security_group.public_access` — `allowed_cidr` 에서 TCP 6443(OKE API) / 443 / 80 만 허용 (포트 명시, `protocol all` 비채택 — 허용 IP 침해 시에도 도달 포트 최소화). 현재 OKE API endpoint(`endpoint_nsg_ids`)에만 부착 — LoadBalancer(Gateway API가 프로비전하는 NLB)는 `kubernetes/infra/istio/gateway.yaml`의 `infrastructure.annotations`에 NSG 지정이 없어 미부착 상태. Security List와 NSG의 허용 규칙은 합집합이므로 Security List가 `0.0.0.0/0`을 허용하면 NSG가 이를 차단하지 못한다. 현재 API subnet Security List의 6443 ingress는 워커 CIDR만 허용한다. CIDR 변경은 `terraform apply` 한 번으로 동기.

### KMS — OpenBao auto-unseal 키

`kms` 모듈: Standard Vault(`DEFAULT`) + AES-256 키 1개. `protection_mode = "SOFTWARE"` — software-protected 키는 과금 없음 (HSM 키 버전에도 무료 한도 적용). FIPS HSM 경계 포기 트레이드오프.

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

DB route table은 Service Gateway 경로를 갖지만 DB Security List의 egress는 VCN CIDR의 TCP만 허용하므로 OCI 서비스 접근을 보장하지 않는다. DB는 인터넷에 노출되지 않는다. 워커는 NAT Gateway로 image pull / OS 업데이트.

### HeatWave MySQL.Free

`MySQL.Free` shape, 50 GiB. Always Free는 tenancy의 홈 리전에서 DB 시스템 1개로 제한된다. `deletion_policy.is_delete_protected = false` — terraform destroy 시 함께 제거. 운영 데이터 유의.

### terraform 모듈 분리

`networking` → `oke` / `iam` / `database` 의존. `kms` 는 독립, `iam` 이 unseal 키 OCID 를 참조. `object-storage` 도 독립. 모듈별 책임 명확, 부분 적용 가능.

```
networking ──┬──► oke
             ├──► iam ◄── kms (unseal_key_id)
             └──► database
object-storage (독립)
```

### object-storage 모듈

`bucket_names` 리스트로 버킷 일괄 생성. **기본값에 `bao-snapshots`(OpenBao raft snapshot) 1개 포함 — 나머지 소비처(Loki/Velero)는 준비 시점에 추가.** `bucket_names = []` 면 버킷 리소스 0개, namespace 조회(read-only)와 endpoint output 만 확보. `NoPublicAccess` + 버저닝 비활성 (Loki compactor 가 retention 직접 관리). namespace + S3-compat endpoint 를 output 으로 노출 — `https://<namespace>.compat.objectstorage.<region>.oraclecloud.com`. S3 자격(Customer Secret Key)은 **state 오염 회피로 terraform 미포함** — 콘솔에서 수동 발급 후 소비처(k8s Secret/OpenBao)에 주입.

### CI — GitHub Actions fmt/validate

`.github/workflows/terraform-ci.yml` — `terraform/**` 변경이 있는 push(main)/PR 에서 GitHub-hosted runner 가 `terraform fmt -check -recursive` → `terraform init -backend=false` → `terraform validate` 를 실행. `-backend=false` 라 remote state / OCI 자격증명에 접근하지 않음 → GitHub Secrets 불요. 검사 실패 = 워크플로 실패(차단). `terraform plan` 은 실 자격증명이 필요해 CI 범위 제외. terraform 버전은 미핀 — 액션 기본(latest)이 `required_version >= 1.12.0` 을 충족.

## 5. 주의 사항

### A1 capacity error

OCI 리전별 ARM 노드 가용성 부족 시 `Out of host capacity` 에러. 적용 실패 시 재시도하거나 다른 AD (`availability_domain`) 시도. `local.availability_domain = ...availability_domains[0].name` 이라 AD 변경은 코드 수정 필요.

### `allowed_cidr` 변경 시 NSG drift

CIDR 변경 후 `terraform apply` 즉시 NSG가 갱신됨. 이전 IP에서 활성 연결 중인 kubectl 세션이 끊김. 작업 IP 바뀌면 사전 갱신.

### kubernetes_version 리전 가용성

default `v1.34.2`가 리전에서 미지원일 수 있음. 적용 전 `oci ce cluster-options get --cluster-option-id all`로 가용 버전 확인.

### db_admin_password rotation

`sensitive = true`로 plan/apply 출력에서 마스킹. tfvars 자체는 `.gitignore` 적용. 회전 시 `terraform.tfvars`의 값을 갱신하고 `terraform plan`으로 변경을 확인한 뒤 적용한다. 콘솔에서만 변경하면 선언된 값과 불일치할 수 있다.

### secrets/ 폴더

`secrets/oci-api-key.pem`, `secrets/bastion.pem` 등 키 자산은 `*.pem`/`*.ppk`/`*.pub` gitignore 패턴으로 추적 제외. 본 폴더는 컨벤션이며 임의 경로 사용 가능.

### 모듈 그래프와 destroy 순서

`terraform destroy`는 의존 역순으로 자동 처리. 단 HeatWave MySQL은 삭제까지 5~10분 소요. 중간에 중단하면 stuck 가능 → 완전 종료까지 대기.

### KMS vault 삭제 대기

OCI KMS vault 는 즉시 삭제 불가 — 최소 7일 pending deletion 후 삭제됨. destroy 후 같은 display_name 재생성은 가능하지만 pending 상태의 vault 가 콘솔에 남아있음에 유의.

### Dynamic Group 은 tenancy 레벨

`oci_identity_dynamic_group` 은 compartment 가 아닌 tenancy(루트)에 생성됨 — `tenancy_ocid` 필요. 같은 tenancy 에서 이름(`dg-oke-workers`) 충돌 시 apply 실패.
