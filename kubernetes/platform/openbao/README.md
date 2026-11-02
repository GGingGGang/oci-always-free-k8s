# OpenBao

`data` namespace의 단일 Raft 서버. OCI KMS instance principal로 auto-unseal하고 기존 NATS PVC의 `openbao` subPath에 데이터를 저장한다. Helm chart `openbao/openbao` **0.28.5**, 서버 이미지 **2.6.0**을 사용한다. Agent Injector는 비활성화하며 ESO 연결은 별도로 구성한다.

## 저장소와 배치

| 항목 | 설정 |
|---|---|
| PVC | `data/nats-js-nats-0`, 50Gi, RWO, `oci-bv` |
| OpenBao | `openbao` subPath → `/openbao/data`, UID 100, mode 0700 |
| NATS | `jetstream` subPath → `/data/jetstream`, UID 1000 |
| PV 삭제 정책 | `Retain` |
| requests | CPU 50m / 메모리 256Mi |
| limits | 메모리 512Mi, CPU 상한 없음 |

두 Pod에 `storage.ggang.cloud/volume: shared-data` 라벨과 필수 Pod affinity를 설정해 같은 노드에 배치한다. 첫 Pod는 자신의 라벨을 만족하는 self-affinity로 배치할 수 있다. 같은 RWO PVC를 사용하는 두 Pod를 서로 다른 노드에서 동시에 실행하지 않는다. replicas를 늘려 HA로 전환하려면 각 Raft 인스턴스에 독립 PVC와 장애 도메인이 필요하다.

두 Pod의 fsGroup은 1000이고 `fsGroupChangePolicy: OnRootMismatch`를 사용한다. 볼륨 루트가 올바른 그룹과 권한을 유지해야 하위 디렉터리에 재귀적 권한 변경이 발생하지 않는다. OpenBao 디렉터리는 `100:1000:700`을 유지한다. subPath는 용량 쿼터나 독립 볼륨 수준의 보안 경계가 아니다. NATS의 45Gi 상한과 별개로 OpenBao 사용량 및 볼륨 전체 여유 공간도 관측한다.

## 공유 PVC 준비

NATS values의 subPath·affinity 설정을 먼저 반영하고 기존 stream/consumer와 송수신을 확인한다. 기존 JetStream 물리 경로는 옮기지 않는다. NATS가 PVC 전체를 마운트한 상태에서 OpenBao 데이터를 넣지 않는다.

```bash
set -e
NATS_PV=$(kubectl get pvc -n data nats-js-nats-0 -o jsonpath='{.spec.volumeName}')
test -n "$NATS_PV"
kubectl patch pv "$NATS_PV" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl get pv "$NATS_PV"
kubectl apply -f storage-prepare.yaml
kubectl wait -n data --for=condition=complete job/openbao-storage-prepare --timeout=180s
kubectl logs -n data job/openbao-storage-prepare
kubectl delete job -n data openbao-storage-prepare
```

준비 Job은 root와 CHOWN capability로 새 `openbao` 디렉터리만 생성한다. 기존 디렉터리의 소유권·권한이 예상과 다르면 실패하며, 기존 데이터에 재귀적 chown/chmod를 하지 않는다. ServiceAccount 토큰은 마운트하지 않는다. namespace의 PSA baseline에서 실행 가능하며 restricted 경고는 예상된다.

Retain은 PVC 삭제 시 backing volume의 자동 삭제를 막는다. 백업을 대신하지 않는다. 공유 PVC는 NATS StatefulSet에서 생성되므로 NATS 제거·PVC 정리 시 OpenBao 사용 여부도 확인한다.

## 설치

`data` namespace, NATS PVC, KMS 키와 instance principal 접근 권한이 필요하다. 기존 `vault` 설치의 values.local.yaml을 그대로 재사용하지 말고 현재 values에서 생성한다.

```bash
KEY_ID=$(terraform -chdir=../../../terraform output -raw kms_unseal_key_id)
CRYPTO=$(terraform -chdir=../../../terraform output -raw kms_crypto_endpoint)
MGMT=$(terraform -chdir=../../../terraform output -raw kms_management_endpoint)

sed -e "s|<your-kms-key-ocid>|${KEY_ID}|" -e "s|<your-kms-crypto-endpoint>|${CRYPTO}|" -e "s|<your-kms-management-endpoint>|${MGMT}|" values.yaml > values.local.yaml

helm repo add openbao https://openbao.github.io/openbao-helm
helm upgrade --install openbao openbao/openbao -n data --version 0.28.5 -f values.local.yaml
kubectl exec -n data openbao-0 -- bao status
```

처음에는 Initialized=false이므로 초기화 전 Ready가 되지 않는다. 이미 초기화된 저장소에 `operator init`을 다시 실행하지 않는다. 데이터가 있는 이전 설치를 옮길 때는 snapshot 복구 등 별도 데이터 이전이 필요하다. namespace 변경은 데이터를 복사하지 않는다.

빈 저장소의 최초 초기화 결과는 Git·동기화 폴더 밖의 접근 제한 파일에 저장한다.

```bash
set -e
BACKUP_DIR="$HOME/.local/share/openbao-bootstrap"
umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
test ! -e "$BACKUP_DIR/bootstrap.json"
set -C
kubectl exec -n data openbao-0 -- bao operator init -format=json > "$BACKUP_DIR/bootstrap.json"
set +C
chmod 600 "$BACKUP_DIR/bootstrap.json"
```

recovery key와 초기 root token은 오프라인으로 별도 보관한다. root token을 자동화의 상시 인증으로 사용하지 않는다. recovery key는 KMS 키를 대신해 데이터를 복호화하지 못한다. KMS 키와 IAM 접근 권한도 유지한다.

## 확인과 운영

```bash
kubectl get pods -n data -o wide
kubectl exec -n data openbao-0 -- bao status
kubectl exec -n data openbao-0 -- stat -c '%u:%g:%a' /openbao/data
kubectl exec -n data nats-0 -c nats -- wget -qO- localhost:8222/jsz
kubectl port-forward -n data svc/openbao 8200:8200
```

정상 상태는 Initialized=true, Sealed=false, storage=raft, seal=ocikms다. API 주소는 `http://openbao.data.svc.cluster.local:8200`이다. listener는 평문이므로 Istio ambient enrollment와 실제 caller 경로의 mTLS를 확인한다. namespace 라벨만으로 모든 클라이언트의 보호를 보장하지 않는다.

PVC 검증은 인증된 시험 값을 기록하고 새 data/OpenBao Pod를 교체한 뒤 cluster ID·시험 값·auto-unseal의 유지를 확인한다. 이전 emptyDir 설치의 Pod를 삭제해서 시험하지 않는다. Helm StatefulSet 갱신 전략은 OnDelete이므로 Helm upgrade만으로 기존 Pod가 교체되지 않는다.

`server.authDelegator.enabled: false`이며 Kubernetes auth는 아직 구성하지 않았다. ESO 연결 시 `data/openbao` ServiceAccount의 TokenReview 권한, OpenBao auth role/policy와 소비 namespace의 SecretStore를 함께 구성한다. 이전 릴리스의 공용 ClusterRoleBinding을 새 릴리스가 자동 인수하지 않는다.

단일 서버는 HA가 아니다. 노드·볼륨 장애는 함께 배치된 NATS에도 영향을 준다. 다른 노드에서 재개하려면 이전 노드의 안전한 분리와 볼륨 재연결이 필요하다. ESO로 이미 동기화된 유효한 Secret을 쓰는 앱은 OpenBao 중단만으로 즉시 중단되지는 않지만 신규 동기화와 갱신은 실패한다.

## Snapshot

인증과 권한을 갖춘 CLI에서 실행한다. subPath여도 Raft snapshot은 가능하고 NATS 파일은 포함하지 않는다.

```bash
bao operator raft snapshot save openbao.snap
```

파일은 CLI 실행 위치에 저장된다. 공유 PVC 외부에 보관하고 복구를 별도로 검증한다. 자동 백업은 아직 구성하지 않았다.

## 근거

- [OpenBao Helm chart](https://github.com/openbao/openbao-helm): 고정 chart 0.28.5 렌더 결과로 검증.
- [OpenBao Raft snapshot](https://openbao.org/docs/commands/operator/raft/#snapshot)
- [OpenBao OCI KMS seal](https://openbao.org/docs/configuration/seal/ocikms/)
- [Kubernetes RWO](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes)
- [Kubernetes 볼륨 권한](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#configure-volume-permission-and-ownership-change-policy-for-pods)

공식 웹 문서의 작성일은 미확정이다. 최신 웹 문서와 설치 버전의 차이는 chart 렌더와 실제 실행으로 검증한다.
